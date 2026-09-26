use std::cell::RefCell;
use std::error::Error;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

use flowlog_runtime::differential_dataflow::consolidation::consolidate_updates;
use flowlog_runtime::differential_dataflow::input::Input;
use flowlog_runtime::operators::{Max, Min, Sum, flowlog_reduce};
use flowlog_runtime::timely;
use timely::dataflow::operators::probe::Handle;

type Update = ((u32, i64), u32, i32);

#[derive(Clone, Copy)]
enum Kind {
    Min,
    Max,
    Sum,
}

#[derive(Clone, Copy)]
enum Implementation {
    Runtime,
    Scan,
    Endpoint,
}

#[derive(Clone, Copy)]
struct Parameters {
    kind: Kind,
    implementation: Implementation,
    interior: bool,
    workers: usize,
    groups: u32,
    values: i64,
    warmup: u32,
    rounds: u32,
}

struct Measurements {
    load_start: f64,
    load_end: f64,
    updates_start: f64,
    updates_end: f64,
    output: Vec<Update>,
}

fn run(parameters: Parameters) -> Result<(), Box<dyn Error>> {
    let ready = Arc::new([AtomicUsize::new(0), AtomicUsize::new(0)]);
    let origin = Instant::now();
    let workers = timely::execute(timely::Config::process(parameters.workers), move |worker| {
        let seen = Rc::new(RefCell::new(Vec::new()));
        let probe = Handle::new();
        let mut input = worker.dataflow::<u32, _, _>(|scope| {
            let (input, rows) = scope.new_collection::<(u32, i64), i32>();
            let seen = Rc::clone(&seen);
            let output = match parameters.implementation {
                Implementation::Runtime => match parameters.kind {
                    Kind::Min => {
                        flowlog_reduce(rows, "Min", Min, None, |row| row, |key, value| (key, value))
                    }
                    Kind::Max => {
                        flowlog_reduce(rows, "Max", Max, None, |row| row, |key, value| (key, value))
                    }
                    Kind::Sum => {
                        flowlog_reduce(rows, "Sum", Sum, None, |row| row, |key, value| (key, value))
                    }
                },
                Implementation::Scan | Implementation::Endpoint => {
                    let endpoint = matches!(parameters.implementation, Implementation::Endpoint);
                    rows.map(|row| row).reduce(move |_, input, output| {
                        let value = match (parameters.kind, endpoint) {
                            (Kind::Min, true) => *input[0].0,
                            (Kind::Max, true) => *input[input.len() - 1].0,
                            (Kind::Min, false) => input
                                .iter()
                                .fold(i64::MAX, |acc, (value, _)| acc.min(**value)),
                            (Kind::Max, false) => input
                                .iter()
                                .fold(i64::MIN, |acc, (value, _)| acc.max(**value)),
                            (Kind::Sum, true | false) => {
                                input.iter().fold(0, |acc, (value, _)| acc + **value)
                            }
                        };
                        output.push((value, 1_i32));
                    })
                }
            };
            output
                .inspect(move |update| seen.borrow_mut().push(*update))
                .probe_with(&probe);
            input
        });
        let groups: Vec<_> = (0..parameters.groups)
            .filter(|group| *group as usize % parameters.workers == worker.index())
            .collect();
        let load_start = origin.elapsed().as_secs_f64();
        for &group in &groups {
            for value in (0..parameters.values).rev() {
                input.update((group, value), 1);
            }
        }
        input.advance_to(1);
        input.flush();
        worker.step_while(|| probe.less_than(&1));
        let load_end = origin.elapsed().as_secs_f64();

        // Keep servicing progress while other workers finish the phase.
        ready[0].fetch_add(1, Ordering::AcqRel);
        worker.step_while(|| ready[0].load(Ordering::Acquire) < parameters.workers);
        let changed_value = if parameters.interior {
            parameters.values / 2
        } else {
            match parameters.kind {
                Kind::Min => -1,
                Kind::Max | Kind::Sum => parameters.values,
            }
        };
        let mut updates_start = 0.0;
        for epoch in 1..=parameters.warmup + parameters.rounds {
            if epoch == parameters.warmup + 1 {
                ready[1].fetch_add(1, Ordering::AcqRel);
                worker.step_while(|| ready[1].load(Ordering::Acquire) < parameters.workers);
                updates_start = origin.elapsed().as_secs_f64();
            }
            let mut diff = if epoch % 2 == 1 { 1 } else { -1 };
            if parameters.interior {
                diff = -diff;
            }
            for &group in &groups {
                input.update((group, changed_value), diff);
            }
            let next = epoch + 1;
            input.advance_to(next);
            input.flush();
            worker.step_while(|| probe.less_than(&next));
        }
        let updates_end = origin.elapsed().as_secs_f64();
        input.close();
        while worker.step() {}
        Measurements {
            load_start,
            load_end,
            updates_start,
            updates_end,
            output: seen.take(),
        }
    })?;

    let mut load_start = f64::INFINITY;
    let mut load_end: f64 = 0.0;
    let mut updates_start = f64::INFINITY;
    let mut updates_end: f64 = 0.0;
    let mut actual = Vec::new();
    for result in workers.join() {
        let measurement = result?;
        load_start = load_start.min(measurement.load_start);
        load_end = load_end.max(measurement.load_end);
        updates_start = updates_start.min(measurement.updates_start);
        updates_end = updates_end.max(measurement.updates_end);
        actual.extend(measurement.output);
    }

    // Validate every timestamped output, outside the measured update phase.
    let initial = match parameters.kind {
        Kind::Min => 0,
        Kind::Max => parameters.values - 1,
        Kind::Sum => parameters.values * (parameters.values - 1) / 2,
    };
    let alternate = if parameters.interior {
        match parameters.kind {
            Kind::Min | Kind::Max => initial,
            Kind::Sum => initial - parameters.values / 2,
        }
    } else {
        match parameters.kind {
            Kind::Min => -1,
            Kind::Max => parameters.values,
            Kind::Sum => initial + parameters.values,
        }
    };
    let mut expected = Vec::new();
    for group in 0..parameters.groups {
        expected.push(((group, initial), 0, 1));
        if alternate != initial {
            for epoch in 1..=parameters.warmup + parameters.rounds {
                let (old, new) = if epoch % 2 == 1 {
                    (initial, alternate)
                } else {
                    (alternate, initial)
                };
                expected.push(((group, old), epoch, -1));
                expected.push(((group, new), epoch, 1));
            }
        }
    }
    consolidate_updates(&mut actual);
    consolidate_updates(&mut expected);
    if actual != expected {
        let first = actual.iter().zip(&expected).position(|(a, b)| a != b);
        return Err(format!(
            "output mismatch: actual={} expected={} first_mismatch={first:?}",
            actual.len(),
            expected.len()
        )
        .into());
    }
    let mut digest = 0_u64;
    for &((group, value), time, diff) in &actual {
        for word in [group as u64, value as u64, time as u64, diff as u64] {
            digest = digest.wrapping_mul(1099511628211).wrapping_add(word);
        }
    }
    println!(
        "{{\"load_s\":{:.9},\"updates_s\":{:.9},\"verified\":true,\
         \"checked_updates\":{},\"digest\":\"{digest:016x}\"}}",
        load_end - load_start,
        updates_end - updates_start,
        actual.len(),
    );
    Ok(())
}

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 8 && args.len() != 9 {
        return Err(
            "expected: min|max|sum winner|interior WORKERS GROUPS VALUES WARMUP ROUNDS [runtime|scan|endpoint]".into(),
        );
    }
    let kind = match args[1].as_str() {
        "min" => Kind::Min,
        "max" => Kind::Max,
        "sum" => Kind::Sum,
        _ => return Err("unknown aggregation".into()),
    };
    let interior = match args[2].as_str() {
        "winner" => false,
        "interior" => true,
        _ => return Err("unknown update pattern".into()),
    };
    let parameters = Parameters {
        kind,
        implementation: match args.get(8).map(String::as_str).unwrap_or("runtime") {
            "runtime" => Implementation::Runtime,
            "scan" => Implementation::Scan,
            "endpoint" => Implementation::Endpoint,
            _ => return Err("unknown implementation".into()),
        },
        interior,
        workers: args[3].parse()?,
        groups: args[4].parse()?,
        values: args[5].parse()?,
        warmup: args[6].parse()?,
        rounds: args[7].parse()?,
    };
    if parameters.workers == 0
        || parameters.groups == 0
        || parameters.values < 3
        || parameters.rounds == 0
        || parameters
            .warmup
            .checked_add(parameters.rounds)
            .and_then(|epoch| epoch.checked_add(1))
            .is_none()
    {
        return Err("invalid workload dimensions".into());
    }
    run(parameters)
}
