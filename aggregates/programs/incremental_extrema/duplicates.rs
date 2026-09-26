use std::cell::RefCell;
use std::error::Error;
use std::rc::Rc;
use std::time::Instant;

use flowlog_runtime::differential_dataflow::consolidation::consolidate_updates;
use flowlog_runtime::differential_dataflow::input::Input;
use flowlog_runtime::operators::flowlog_dedup;
use flowlog_runtime::timely;
use timely::dataflow::operators::probe::Handle;

type Update = ((u32, i64), u32, i32);

#[derive(Clone, Copy)]
enum Kind {
    Min,
    Max,
}

#[derive(Clone, Copy)]
enum Implementation {
    Scan,
    Endpoint,
}

#[derive(Clone, Copy)]
struct Parameters {
    kind: Kind,
    implementation: Implementation,
    workers: usize,
    groups: u32,
    values: i64,
    duplicates: u32,
    warmup: u32,
    rounds: u32,
}

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 9 {
        return Err(
            "expected: min|max scan|endpoint WORKERS GROUPS VALUES DUPLICATES WARMUP ROUNDS".into(),
        );
    }
    let parameters = Parameters {
        kind: match args[1].as_str() {
            "min" => Kind::Min,
            "max" => Kind::Max,
            _ => return Err("unknown aggregation".into()),
        },
        implementation: match args[2].as_str() {
            "scan" => Implementation::Scan,
            "endpoint" => Implementation::Endpoint,
            _ => return Err("unknown implementation".into()),
        },
        workers: args[3].parse()?,
        groups: args[4].parse()?,
        values: args[5].parse()?,
        duplicates: args[6].parse()?,
        warmup: args[7].parse()?,
        rounds: args[8].parse()?,
    };
    if parameters.workers == 0
        || parameters.groups == 0
        || parameters.values < 3
        || parameters.duplicates == 0
        || parameters.rounds == 0
    {
        return Err("invalid workload dimensions".into());
    }

    let origin = Instant::now();
    let workers = timely::execute(timely::Config::process(parameters.workers), move |worker| {
        let seen = Rc::new(RefCell::new(Vec::new()));
        let probe = Handle::new();
        let mut input = worker.dataflow::<u32, _, _>(|scope| {
            let (input, source) = scope.new_collection::<(u32, i64, u32), i32>();
            let candidates = flowlog_dedup(source.map(|(group, value, _)| (group, value)));
            let endpoint = matches!(parameters.implementation, Implementation::Endpoint);
            let kind = parameters.kind;
            let seen = Rc::clone(&seen);
            candidates
                .reduce(move |_, input, output| {
                    let value = match (kind, endpoint) {
                        (Kind::Min, true) => *input[0].0,
                        (Kind::Max, true) => *input[input.len() - 1].0,
                        (Kind::Min, false) => input
                            .iter()
                            .fold(i64::MAX, |current, (value, _)| current.min(**value)),
                        (Kind::Max, false) => input
                            .iter()
                            .fold(i64::MIN, |current, (value, _)| current.max(**value)),
                    };
                    output.push((value, 1_i32));
                })
                .inspect(move |update| seen.borrow_mut().push(*update))
                .probe_with(&probe);
            input
        });
        let groups: Vec<_> = (0..parameters.groups)
            .filter(|group| *group as usize % parameters.workers == worker.index())
            .collect();
        for &group in &groups {
            for value in 0..parameters.values {
                for duplicate in 0..parameters.duplicates {
                    input.update((group, value, duplicate), 1);
                }
            }
        }
        input.advance_to(1);
        input.flush();
        worker.step_while(|| probe.less_than(&1));
        let changed = match parameters.kind {
            Kind::Min => -1,
            Kind::Max => parameters.values,
        };
        let mut start = 0.0;
        for epoch in 1..=parameters.warmup + parameters.rounds {
            if epoch == parameters.warmup + 1 {
                start = origin.elapsed().as_secs_f64();
            }
            let diff = if epoch % 2 == 1 { 1 } else { -1 };
            for &group in &groups {
                for duplicate in 0..parameters.duplicates {
                    input.update((group, changed, duplicate), diff);
                }
            }
            let next = epoch + 1;
            input.advance_to(next);
            input.flush();
            worker.step_while(|| probe.less_than(&next));
        }
        let end = origin.elapsed().as_secs_f64();
        input.close();
        while worker.step() {}
        (start, end, seen.take())
    })?;

    let mut start = f64::INFINITY;
    let mut end: f64 = 0.0;
    let mut actual = Vec::new();
    for result in workers.join() {
        let (worker_start, worker_end, updates) = result?;
        start = start.min(worker_start);
        end = end.max(worker_end);
        actual.extend(updates);
    }
    let initial = match parameters.kind {
        Kind::Min => 0,
        Kind::Max => parameters.values - 1,
    };
    let changed = match parameters.kind {
        Kind::Min => -1,
        Kind::Max => parameters.values,
    };
    let mut expected = Vec::new();
    for group in 0..parameters.groups {
        expected.push(((group, initial), 0, 1));
        for epoch in 1..=parameters.warmup + parameters.rounds {
            let (old, new) = if epoch % 2 == 1 {
                (initial, changed)
            } else {
                (changed, initial)
            };
            expected.push(((group, old), epoch, -1));
            expected.push(((group, new), epoch, 1));
        }
    }
    consolidate_updates(&mut actual);
    consolidate_updates(&mut expected);
    if actual != expected {
        return Err(format!(
            "output mismatch: actual={} expected={}",
            actual.len(),
            expected.len()
        )
        .into());
    }
    println!(
        "{{\"updates_s\":{:.9},\"verified\":true,\"checked_updates\":{}}}",
        end - start,
        actual.len()
    );
    Ok(())
}
