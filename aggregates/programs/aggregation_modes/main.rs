//! Same-executable comparison of FlowLog aggregation pipelines.
//!
//! `batch` and `inc` are the pipelines generated today: dedup, then
//! `flowlog_reduce`. The other pipelines are prototypes:
//!
//! - `batch-nodedup`: batch min/max without dedup (idempotent semirings).
//! - `batch-fused`: one keyed arrangement that dedups and folds each group.
//! - `inc-fused`: incremental reduce without dedup; needs a runtime whose
//!   `i32` reduce counts each positively weighted value once.
//! - `inc-weight`: dedup, then abelian `(sum, count)` weights through
//!   `count_total`, the incremental analogue of batch semiring weights. It
//!   exists only for sum and count: min and max have no inverse.
//!
//! Each source row `(group, value, witness)` projects to `(group, value)`,
//! so witnesses are duplicate derivations of one distinct row.

use std::cell::RefCell;
use std::error::Error;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::Barrier;
use std::time::Instant;

use flowlog_runtime::differential_dataflow::AsCollection;
use flowlog_runtime::differential_dataflow::VecCollection;
use flowlog_runtime::differential_dataflow::consolidation::consolidate_updates;
use flowlog_runtime::differential_dataflow::difference::Present;
use flowlog_runtime::differential_dataflow::input::Input;
use flowlog_runtime::differential_dataflow::operators::CountTotal;
use flowlog_runtime::differential_dataflow::trace::Cursor;
use flowlog_runtime::differential_dataflow::trace::Navigable;
use flowlog_runtime::operators::{Count, Max, Min, Sum, flowlog_dedup, flowlog_map, flowlog_reduce};
use flowlog_runtime::timely;
use timely::dataflow::channels::pact::Pipeline;
use timely::dataflow::operators::generic::Operator;
use timely::dataflow::operators::probe::Handle;

type Row = (u32, i64);
type Source = (u32, i64, u32);

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Batch,
    BatchNoDedup,
    BatchFused,
    Inc,
    IncFused,
    IncWeight,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Min,
    Max,
    Sum,
    Count,
}

#[derive(Clone, Copy)]
struct Parameters {
    mode: Mode,
    kind: Kind,
    workers: usize,
    groups: u32,
    values: i64,
    duplicates: u32,
    warmup: u32,
    rounds: u32,
    touched: u32,
}

impl Parameters {
    fn incremental(&self) -> bool {
        matches!(self.mode, Mode::Inc | Mode::IncFused | Mode::IncWeight)
    }

    /// Aggregate over base values `0, 2, ..., 2(V-1)`, plus `-2` and `2V`
    /// while a round's extra values are present.
    fn expected(&self, extra: bool) -> i64 {
        let v = self.values;
        match (self.kind, extra) {
            (Kind::Min, false) => 0,
            (Kind::Min, true) => -2,
            (Kind::Max, false) => 2 * (v - 1),
            (Kind::Max, true) => 2 * v,
            (Kind::Sum, false) => v * (v - 1),
            (Kind::Sum, true) => v * (v - 1) + 2 * v - 2,
            (Kind::Count, false) => v,
            (Kind::Count, true) => v + 2,
        }
    }

    /// Groups whose extra values toggle in `round` (1-based), and disjoint
    /// groups whose value 0 loses or regains one of several witnesses.
    fn round_groups(&self, round: u32) -> (Vec<u32>, Vec<u32>) {
        let base = ((round - 1) / 2) as u64 * self.touched as u64;
        let groups = self.groups as u64;
        let changed = (0..self.touched as u64)
            .map(|i| ((base + i) % groups) as u32)
            .collect();
        let churned = if self.duplicates > 1 {
            (0..self.touched as u64)
                .map(|i| ((base + i + groups / 2) % groups) as u32)
                .collect()
        } else {
            Vec::new()
        };
        (changed, churned)
    }
}

/// Instantiates `$body` with `$agg` bound to the runtime aggregation type.
macro_rules! with_kind {
    ($kind:expr, $agg:ident => $body:expr) => {
        match $kind {
            Kind::Min => {
                let $agg = Min;
                $body
            }
            Kind::Max => {
                let $agg = Max;
                $body
            }
            Kind::Sum => {
                let $agg = Sum;
                $body
            }
            Kind::Count => {
                let $agg = Count;
                $body
            }
        }
    };
}

/// Batch prototype: one exchange and arrangement by group. At `()` each
/// worker's single batch holds every distinct value once, in order.
fn fused_batch<'scope>(
    rows: VecCollection<'scope, (), Row, Present>,
    kind: Kind,
) -> VecCollection<'scope, (), Row, Present> {
    rows.arrange_by_key()
        .stream
        .unary(Pipeline, "FusedAggregate", move |_, _| {
            move |input, output| {
                input.for_each(|capability, batches| {
                    let mut session = output.session(&capability);
                    for batch in batches.drain(..) {
                        let mut cursor = batch.cursor();
                        while let Some(key) = cursor.get_key(&batch) {
                            let result = match kind {
                                Kind::Min => *cursor.get_val(&batch).expect("nonempty group"),
                                Kind::Max | Kind::Sum | Kind::Count => {
                                    let (mut last, mut sum, mut count) = (0, 0, 0);
                                    while let Some(value) = cursor.get_val(&batch) {
                                        last = *value;
                                        sum += *value;
                                        count += 1;
                                        cursor.step_val(&batch);
                                    }
                                    match kind {
                                        Kind::Max => last,
                                        Kind::Sum => sum,
                                        _ => count,
                                    }
                                }
                            };
                            session.give(((*key, result), (), Present));
                            cursor.step_key(&batch);
                        }
                    }
                });
            }
        })
        .as_collection()
}

fn parse(args: &[String]) -> Result<Parameters, Box<dyn Error>> {
    if args.len() != 10 {
        return Err(
            "expected: MODE KIND WORKERS GROUPS VALUES DUPLICATES WARMUP ROUNDS TOUCHED".into(),
        );
    }
    let parameters = Parameters {
        mode: match args[1].as_str() {
            "batch" => Mode::Batch,
            "batch-nodedup" => Mode::BatchNoDedup,
            "batch-fused" => Mode::BatchFused,
            "inc" => Mode::Inc,
            "inc-fused" => Mode::IncFused,
            "inc-weight" => Mode::IncWeight,
            _ => return Err("unknown mode".into()),
        },
        kind: match args[2].as_str() {
            "min" => Kind::Min,
            "max" => Kind::Max,
            "sum" => Kind::Sum,
            "count" => Kind::Count,
            _ => return Err("unknown aggregation".into()),
        },
        workers: args[3].parse()?,
        groups: args[4].parse()?,
        values: args[5].parse()?,
        duplicates: args[6].parse()?,
        warmup: args[7].parse()?,
        rounds: args[8].parse()?,
        touched: args[9].parse()?,
    };
    let extrema = matches!(parameters.kind, Kind::Min | Kind::Max);
    if parameters.mode == Mode::BatchNoDedup && !extrema {
        return Err("batch-nodedup is valid only for min/max".into());
    }
    if parameters.mode == Mode::IncWeight && extrema {
        return Err("min/max have no invertible weight".into());
    }
    if parameters.workers == 0
        || parameters.groups < 2
        || parameters.values == 0
        || parameters.duplicates == 0
        || parameters.warmup % 2 == 1
        || parameters.rounds % 2 == 1
        || (parameters.incremental() && parameters.rounds == 0)
        || parameters.touched == 0
        || parameters.touched > parameters.groups / 2
    {
        return Err("invalid workload dimensions".into());
    }
    Ok(parameters)
}

/// Rows owned by one worker for the initial load, in a scrambled order.
fn initial_rows(parameters: &Parameters, index: usize) -> Vec<Source> {
    let mut rows = Vec::new();
    for group in (0..parameters.groups).filter(|g| *g as usize % parameters.workers == index) {
        for value in 0..parameters.values {
            for witness in 0..parameters.duplicates {
                rows.push((group, 2 * value, witness));
            }
        }
    }
    let mut state = 0x9E37_79B9_7F4A_7C15_u64 ^ index as u64;
    for i in (1..rows.len()).rev() {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        rows.swap(i, (state % (i as u64 + 1)) as usize);
    }
    rows
}

type Interval = (f64, f64);

fn widen(total: &mut Interval, part: Interval) {
    total.0 = total.0.min(part.0);
    total.1 = total.1.max(part.1);
}

fn run_batch(parameters: Parameters) -> Result<(Interval, Vec<(Row, (), Present)>), Box<dyn Error>> {
    let barrier = Arc::new(Barrier::new(parameters.workers));
    let origin = Instant::now();
    let workers = timely::execute(timely::Config::process(parameters.workers), move |worker| {
        let seen = Rc::new(RefCell::new(Vec::new()));
        let probe = Handle::new();
        let mut input = worker.dataflow::<(), _, _>(|scope| {
            let (input, source) = scope.new_collection::<Source, Present>();
            let rows = source.map(|(group, value, _)| (group, value));
            let output = match parameters.mode {
                Mode::Batch => with_kind!(parameters.kind, agg => flowlog_reduce(
                    flowlog_dedup(rows), "Reduce", agg, None, |row| row, |g, c: i64| (g, c),
                )),
                Mode::BatchNoDedup => with_kind!(parameters.kind, agg => flowlog_reduce(
                    rows, "Reduce", agg, None, |row| row, |g, c: i64| (g, c),
                )),
                Mode::BatchFused => fused_batch(rows, parameters.kind),
                Mode::Inc | Mode::IncFused | Mode::IncWeight => unreachable!("batch mode"),
            };
            let seen = Rc::clone(&seen);
            output
                .inspect(move |update| seen.borrow_mut().push(*update))
                .probe_with(&probe);
            input
        });
        let rows = initial_rows(&parameters, worker.index());
        barrier.wait();
        let start = origin.elapsed().as_secs_f64();
        for row in rows {
            input.update(row, Present);
        }
        input.close();
        worker.step_while(|| !probe.done());
        let end = origin.elapsed().as_secs_f64();
        while worker.step() {}
        ((start, end), seen.take())
    })?;
    let mut load = (f64::INFINITY, 0.0);
    let mut output = Vec::new();
    for result in workers.join() {
        let (interval, updates) = result?;
        widen(&mut load, interval);
        output.extend(updates);
    }
    Ok((load, output))
}

type IncResult = ((Interval, Interval), Vec<(Row, u32, i32)>);

fn run_inc(parameters: Parameters) -> Result<IncResult, Box<dyn Error>> {
    let barrier = Arc::new(Barrier::new(parameters.workers));
    let origin = Instant::now();
    let workers = timely::execute(timely::Config::process(parameters.workers), move |worker| {
        let seen = Rc::new(RefCell::new(Vec::new()));
        let probe = Handle::new();
        let mut input = worker.dataflow::<u32, _, _>(|scope| {
            let (input, source) = scope.new_collection::<Source, i32>();
            let rows = source.map(|(group, value, _)| (group, value));
            let output = match parameters.mode {
                Mode::Inc => with_kind!(parameters.kind, agg => flowlog_reduce(
                    flowlog_dedup(rows), "Reduce", agg, None, |row| row, |g, c: i64| (g, c),
                )),
                Mode::IncFused => with_kind!(parameters.kind, agg => flowlog_reduce(
                    rows, "Reduce", agg, None, |row| row, |g, c: i64| (g, c),
                )),
                Mode::IncWeight => {
                    let deduped = flowlog_dedup(rows);
                    match parameters.kind {
                        Kind::Sum => {
                            flowlog_map(deduped, "Lift", |(group, value), time, diff: i32| {
                                let diff = diff as i64;
                                std::iter::once((group, time, (value * diff, diff)))
                            })
                            .count_total_core::<i32>()
                            .map(|(group, (sum, _count))| (group, sum))
                        }
                        Kind::Count => {
                            flowlog_map(deduped, "Lift", |(group, _), time, diff: i32| {
                                std::iter::once((group, time, diff as i64))
                            })
                            .count_total_core::<i32>()
                        }
                        Kind::Min | Kind::Max => unreachable!("rejected by parse"),
                    }
                }
                Mode::Batch | Mode::BatchNoDedup | Mode::BatchFused => unreachable!("inc mode"),
            };
            let seen = Rc::clone(&seen);
            output
                .inspect(move |update| seen.borrow_mut().push(*update))
                .probe_with(&probe);
            input
        });
        let index = worker.index();
        let owned = move |group: &&u32| **group as usize % parameters.workers == index;
        let rows = initial_rows(&parameters, index);
        barrier.wait();
        let load_start = origin.elapsed().as_secs_f64();
        for row in rows {
            input.update(row, 1);
        }
        input.advance_to(1);
        input.flush();
        worker.step_while(|| probe.less_than(&1));
        let load_end = origin.elapsed().as_secs_f64();

        let extremes = [-2, 2 * parameters.values];
        let mut updates_start = load_end;
        for round in 1..=parameters.warmup + parameters.rounds {
            if round == parameters.warmup + 1 {
                barrier.wait();
                updates_start = origin.elapsed().as_secs_f64();
            }
            let insert = round % 2 == 1;
            let (changed, churned) = parameters.round_groups(round);
            for group in changed.iter().filter(owned) {
                for value in extremes {
                    for witness in 0..parameters.duplicates {
                        input.update((*group, value, witness), if insert { 1 } else { -1 });
                    }
                }
            }
            for group in churned.iter().filter(owned) {
                input.update((*group, 0, 0), if insert { -1 } else { 1 });
            }
            let next = round + 1;
            input.advance_to(next);
            input.flush();
            worker.step_while(|| probe.less_than(&next));
        }
        let updates_end = origin.elapsed().as_secs_f64();
        input.close();
        while worker.step() {}
        (((load_start, load_end), (updates_start, updates_end)), seen.take())
    })?;
    let mut load = (f64::INFINITY, 0.0);
    let mut updates = (f64::INFINITY, 0.0);
    let mut output = Vec::new();
    for result in workers.join() {
        let ((load_interval, updates_interval), seen) = result?;
        widen(&mut load, load_interval);
        widen(&mut updates, updates_interval);
        output.extend(seen);
    }
    Ok(((load, updates), output))
}

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args().collect();
    let parameters = parse(&args)?;
    let initial = parameters.expected(false);
    let (load, updates, checked) = if parameters.incremental() {
        let ((load, updates), mut actual) = run_inc(parameters)?;
        let mut expected: Vec<(Row, u32, i32)> =
            (0..parameters.groups).map(|g| ((g, initial), 0, 1)).collect();
        let extra = parameters.expected(true);
        for round in 1..=parameters.warmup + parameters.rounds {
            let (old, new) = if round % 2 == 1 { (initial, extra) } else { (extra, initial) };
            for group in parameters.round_groups(round).0 {
                expected.push(((group, old), round, -1));
                expected.push(((group, new), round, 1));
            }
        }
        consolidate_updates(&mut actual);
        consolidate_updates(&mut expected);
        if actual != expected {
            return Err(format!("output mismatch: {} vs {}", actual.len(), expected.len()).into());
        }
        (load, format!("{:.9}", updates.1 - updates.0), actual.len())
    } else {
        let (load, mut actual) = run_batch(parameters)?;
        let mut expected: Vec<(Row, (), Present)> =
            (0..parameters.groups).map(|g| ((g, initial), (), Present)).collect();
        let emitted = actual.len();
        consolidate_updates(&mut actual);
        consolidate_updates(&mut expected);
        if actual != expected || emitted != expected.len() {
            return Err(format!("output mismatch: {emitted} vs {}", expected.len()).into());
        }
        (load, "null".to_string(), emitted)
    };
    println!(
        "{{\"load_s\":{:.9},\"updates_s\":{updates},\"verified\":true,\"checked_updates\":{checked}}}",
        load.1 - load.0,
    );
    Ok(())
}
