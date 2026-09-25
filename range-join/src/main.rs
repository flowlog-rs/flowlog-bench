//! End-to-end timings of FlowLog's current range-join lowering (an
//! equijoin plus a fused filter) against the sorted range join.
//!
//! Usage: `rangejoin-toy <workload> <method> [key=value ...]`
//!
//! Workloads (all FlowLog batch semantics: `Present` weights, `()` time):
//!   band      Out(x,y)   :- R(x), R(y), x < y, y < x + width.
//!   keyed     Out(k,y,z) :- R(k,y), S(k,z), y < z, z < y + width.
//!   interval  Out(s,e,p) :- I(s,e), P(p), s <= p, p < e.
//!   hop       Reach(y) :- Src(y).  Reach(y) :- Reach(x), P(y), x < y, y < x + width.
//!             (recursive; signed weights, so it runs in a DD `iterate`)
//!   txn       Out(x,y) :- L(x), R(y), x < y, y < x + width.
//!             (incremental: preload, then `rounds` transactions that each
//!             insert `delta` points into the relations named by `side`)
//!
//! Methods:
//!   cross    today's plan: `flowlog_join` with every predicate in the filter
//!   nested   the range tactic told every pair is in range (isolates overhead)
//!   range1   only the lower bound is a range predicate, as var-var planning
//!            yields for `y < x + width` (band, keyed); `s <= p` (interval)
//!   range    every inequality is a range predicate: var-var in `interval`,
//!            and via a precomputed shadow column `x + width` otherwise
//!   seek     `range`, but each left value seeks its run in the right
//!            arrangement rather than the right key group being read whole
//!   back     `range`, but each right value seeks its run in the left
//!            arrangement (not `interval`: its ranges don't rise with `s`)
//!   auto     `range`, `seek` or `back`, chosen per unit of work from batch
//!            sizes
//!   arrange  build the inputs' arrangements only (the fixed cost)
//!
//! Options: n, m, gap, width, keys, skew, rounds, delta, side, workers, seed,
//! check=1.

use std::cmp::Ordering;
use std::collections::BTreeSet;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::AtomicU64;
use std::time::Duration;
use std::time::Instant;

use differential_dataflow::Data;
use differential_dataflow::VecCollection;
use differential_dataflow::difference::Present;
use differential_dataflow::input::Input;
use differential_dataflow::operators::Iterate;
use flowlog_runtime::operators::flowlog_join;
use mimalloc::MiMalloc;
use rangejoin_toy::range_join;
use rangejoin_toy::seek_range_join;
use rangejoin_toy::seek_range_join_both;
use rangejoin_toy::seek_join::Strategy;
use timely::dataflow::operators::Inspect;
use timely::dataflow::operators::Probe;
use timely::dataflow::operators::probe::Handle;
use timely::progress::Timestamp;

#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

type Ts = ();

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Method {
    Arrange,
    Cross,
    Nested,
    Range1,
    Range,
    Seek,
    Back,
    Auto,
}

impl Method {
    fn parse(text: &str) -> Method {
        match text {
            "arrange" => Method::Arrange,
            "cross" => Method::Cross,
            "nested" => Method::Nested,
            "range1" => Method::Range1,
            "range" => Method::Range,
            "seek" => Method::Seek,
            "back" => Method::Back,
            "auto" => Method::Auto,
            other => panic!("unknown method '{other}'"),
        }
    }

    /// The seeking join's strategy, for the methods that use it.
    fn strategy(self) -> Strategy {
        match self {
            Method::Seek => Strategy::Seek,
            Method::Back => Strategy::SeekBack,
            _ => Strategy::Auto,
        }
    }
}

#[derive(Clone, Debug)]
struct Args {
    workload: String,
    method: Method,
    n: usize,
    m: usize,
    gap: i64,
    width: i64,
    keys: usize,
    skew: f64,
    rounds: usize,
    delta: usize,
    side: String,
    workers: usize,
    seed: u64,
    check: bool,
}

impl Args {
    fn parse() -> Args {
        let mut argv = std::env::args().skip(1);
        let workload = argv.next().expect("missing workload");
        let method = Method::parse(&argv.next().expect("missing method"));
        let mut args = Args {
            workload,
            method,
            n: 10_000,
            m: 0,
            gap: 10,
            width: 100,
            keys: 1_000,
            skew: 1.0,
            rounds: 20,
            delta: 10,
            side: "l".to_string(),
            workers: 1,
            seed: 7,
            check: false,
        };
        for option in argv {
            let (name, value) = option.split_once('=').expect("options are key=value");
            match name {
                "n" => args.n = value.parse().unwrap(),
                "m" => args.m = value.parse().unwrap(),
                "gap" => args.gap = value.parse().unwrap(),
                "width" => args.width = value.parse().unwrap(),
                "keys" => args.keys = value.parse().unwrap(),
                "skew" => args.skew = value.parse().unwrap(),
                "rounds" => args.rounds = value.parse().unwrap(),
                "delta" => args.delta = value.parse().unwrap(),
                "side" => args.side = value.to_string(),
                "workers" | "w" => args.workers = value.parse().unwrap(),
                "seed" => args.seed = value.parse().unwrap(),
                "check" => args.check = value == "1" || value == "true",
                other => panic!("unknown option '{other}'"),
            }
        }
        if args.m == 0 {
            args.m = args.n;
        }
        args
    }
}

/// Output cardinality and an order-insensitive fingerprint of the rows.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Summary {
    count: u64,
    sum: u64,
}

impl Summary {
    fn add<D: Fingerprint>(&mut self, datum: &D) {
        self.add_weighted(datum, 1);
    }
    fn add_weighted<D: Fingerprint>(&mut self, datum: &D, weight: u64) {
        self.count = self.count.wrapping_add(weight);
        self.sum = self.sum.wrapping_add(datum.fingerprint().wrapping_mul(weight));
    }
}

/// A row's multiplicity; signed weights wrap, so retractions cancel.
trait Weight {
    fn weight(&self) -> u64;
}

impl Weight for Present {
    fn weight(&self) -> u64 {
        1
    }
}

impl Weight for isize {
    fn weight(&self) -> u64 {
        *self as u64
    }
}

#[derive(Default)]
struct Tally {
    count: AtomicU64,
    sum: AtomicU64,
}

impl Tally {
    fn summary(&self) -> Summary {
        Summary {
            count: self.count.load(std::sync::atomic::Ordering::SeqCst),
            sum: self.sum.load(std::sync::atomic::Ordering::SeqCst),
        }
    }
}

trait Fingerprint {
    fn fingerprint(&self) -> u64;
}

fn mix(mut z: u64) -> u64 {
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    z ^ (z >> 31)
}

impl Fingerprint for i64 {
    fn fingerprint(&self) -> u64 {
        mix(*self as u64)
    }
}

impl Fingerprint for (i64, i64) {
    fn fingerprint(&self) -> u64 {
        mix(mix(self.0 as u64) ^ self.1 as u64)
    }
}

impl Fingerprint for (i64, i64, i64) {
    fn fingerprint(&self) -> u64 {
        mix(mix(mix(self.0 as u64) ^ self.1 as u64) ^ self.2 as u64)
    }
}

/// Counts and fingerprints join output where it is produced, so no
/// exchange or consolidation is charged to the join under test.
fn tally<T: Timestamp, D: Data + Fingerprint, R: Weight + 'static>(
    output: VecCollection<'_, T, D, R>,
    tally: Arc<Tally>,
) {
    output.inner.inspect_batch(move |_, batch| {
        let mut local = Summary::default();
        for (datum, _, weight) in batch.iter() {
            local.add_weighted(datum, weight.weight());
        }
        let relaxed = std::sync::atomic::Ordering::Relaxed;
        tally.count.fetch_add(local.count, relaxed);
        tally.sum.fetch_add(local.sum, relaxed);
    });
}

/// Places `value` against the open range `(lower, ∞)`.
fn locate_above(lower: i64, value: i64) -> Ordering {
    if value <= lower { Ordering::Less } else { Ordering::Equal }
}

/// Places `value` against the open range `(lower, upper)`.
fn locate_between(lower: i64, upper: i64, value: i64) -> Ordering {
    if value <= lower {
        Ordering::Less
    } else if value >= upper {
        Ordering::Greater
    } else {
        Ordering::Equal
    }
}

/// Places `value` against the half-open range `[lower, upper)`.
fn locate_within(lower: i64, upper: i64, value: i64) -> Ordering {
    if value < lower {
        Ordering::Less
    } else if value >= upper {
        Ordering::Greater
    } else {
        Ordering::Equal
    }
}

// =============================================================================
// Data
// =============================================================================

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        mix(self.0)
    }
    fn below(&mut self, bound: u64) -> u64 {
        self.next() % bound
    }
    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }
}

/// `n` distinct points in increasing order with mean spacing `gap`.
fn points(n: usize, gap: i64, rng: &mut Rng) -> Vec<i64> {
    let mut next = 0;
    (0..n)
        .map(|_| {
            next += 1 + rng.below((2 * gap - 1).max(1) as u64) as i64;
            next
        })
        .collect()
}

/// `n` distinct `(key, value)` pairs; key frequencies follow `u^skew`.
fn keyed_pairs(n: usize, keys: usize, span: i64, skew: f64, rng: &mut Rng) -> Vec<(i64, i64)> {
    let mut pairs: Vec<(i64, i64)> = (0..n)
        .map(|_| {
            let key = ((keys as f64) * rng.unit().powf(skew)) as i64;
            (key, rng.below(span as u64) as i64)
        })
        .collect();
    pairs.sort_unstable();
    pairs.dedup();
    pairs
}

// =============================================================================
// Workloads
// =============================================================================

struct Outcome {
    elapsed: Duration,
    output: Summary,
    expected: Option<Summary>,
    /// Workload-specific measurements, appended to the report.
    detail: String,
}

fn run<F>(workers: usize, logic: F) -> Duration
where
    F: Fn(&mut timely::worker::Worker) + Send + Sync + 'static,
{
    let start = Instant::now();
    timely::execute(timely::Config::process(workers), logic)
        .expect("timely failed to start")
        .join()
        .into_iter()
        .for_each(|result| result.expect("worker failed"));
    start.elapsed()
}

/// `Out(x,y) :- R(x), R(y), x < y, y < x + width.`
fn band(args: &Args) -> Outcome {
    let rows = Arc::new(points(args.n, args.gap, &mut Rng(args.seed)));
    let expected = args.check.then(|| {
        let mut summary = Summary::default();
        for (i, &x) in rows.iter().enumerate() {
            for &y in rows[i + 1..].iter().take_while(|&&y| y < x + args.width) {
                summary.add(&(x, y));
            }
        }
        summary
    });
    let (method, width) = (args.method, args.width);
    let output = Arc::new(Tally::default());
    let elapsed = run(args.workers, {
        let (rows, output) = (rows.clone(), output.clone());
        move |worker| {
            let (index, peers) = (worker.index(), worker.peers());
            let output = output.clone();
            let mut input = worker.dataflow::<Ts, _, _>(|scope| {
                let (input, r) = scope.new_collection::<i64, Present>();
                let rr = r.clone().map(|y| ((), (y,))).arrange_by_key();
                match method {
                    Method::Arrange => {
                        rr.stream.inspect_batch(|_, _| {});
                    }
                    Method::Cross => tally(
                        flowlog_join(rr.clone(), rr, "cross", move |_, l, r| {
                            (l.0 < r.0 && r.0 < l.0 + width).then_some((l.0, r.0))
                        }),
                        output,
                    ),
                    Method::Nested => tally(
                        range_join(
                            rr.clone(),
                            rr,
                            |_, _, _| Ordering::Equal,
                            move |_, l, r| (l.0 < r.0 && r.0 < l.0 + width).then_some((l.0, r.0)),
                        ),
                        output,
                    ),
                    Method::Range1 => tally(
                        range_join(
                            rr.clone(),
                            rr,
                            |_, l, r| locate_above(l.0, r.0),
                            move |_, l, r| (r.0 < l.0 + width).then_some((l.0, r.0)),
                        ),
                        output,
                    ),
                    Method::Range => {
                        // `x + width` as a shadow column turns the bound var-var.
                        let rl = r.map(move |x| ((), (x, x + width))).arrange_by_key();
                        tally(
                            range_join(
                                rl,
                                rr,
                                |_, l, r| locate_between(l.0, l.1, r.0),
                                |_, l, r| Some((l.0, r.0)),
                            ),
                            output,
                        )
                    }
                    Method::Seek | Method::Back | Method::Auto => {
                        let rl = r.map(move |x| ((), (x, x + width))).arrange_by_key();
                        tally(
                            seek_range_join_both(
                                rl,
                                rr,
                                |_, l, r| locate_between(l.0, l.1, r.0),
                                |_, l| (l.0,),
                                move |_, r| (r.0 - width + 1, i64::MIN),
                                method.strategy(),
                                |_, l, r| Some((l.0, r.0)),
                            ),
                            output,
                        )
                    }
                }
                input
            });
            for &x in rows.iter().skip(index).step_by(peers) {
                input.update(x, Present);
            }
            input.close();
            while worker.step() {}
        }
    });
    Outcome { elapsed, output: output.summary(), expected, detail: String::new() }
}

/// `Out(k,y,z) :- R(k,y), S(k,z), y < z, z < y + width.`
fn keyed(args: &Args) -> Outcome {
    let span = (args.n as i64 / args.keys.max(1) as i64).max(1) * args.gap;
    let mut rng = Rng(args.seed);
    let r_rows = Arc::new(keyed_pairs(args.n, args.keys, span, args.skew, &mut rng));
    let s_rows = Arc::new(keyed_pairs(args.m, args.keys, span, args.skew, &mut rng));
    let expected = args.check.then(|| {
        let mut summary = Summary::default();
        for &(k, y) in r_rows.iter() {
            let start = s_rows.partition_point(|&(sk, z)| (sk, z) <= (k, y));
            for &(_, z) in s_rows[start..].iter().take_while(|&&(sk, z)| sk == k && z < y + args.width) {
                summary.add(&(k, y, z));
            }
        }
        summary
    });
    let (method, width) = (args.method, args.width);
    let output = Arc::new(Tally::default());
    let elapsed = run(args.workers, {
        let (r_rows, s_rows, output) = (r_rows.clone(), s_rows.clone(), output.clone());
        move |worker| {
            let (index, peers) = (worker.index(), worker.peers());
            let output = output.clone();
            let (mut r_input, mut s_input) = worker.dataflow::<Ts, _, _>(|scope| {
                let (r_input, r) = scope.new_collection::<(i64, i64), Present>();
                let (s_input, s) = scope.new_collection::<(i64, i64), Present>();
                let sa = s.map(|(k, z)| (k, (z,))).arrange_by_key();
                match method {
                    Method::Arrange => {
                        let ra = r.map(|(k, y)| (k, (y,))).arrange_by_key();
                        ra.stream.inspect_batch(|_, _| {});
                        sa.stream.inspect_batch(|_, _| {});
                    }
                    Method::Cross => {
                        let ra = r.map(|(k, y)| (k, (y,))).arrange_by_key();
                        tally(
                            flowlog_join(ra, sa, "cross", move |k, l, r| {
                                (l.0 < r.0 && r.0 < l.0 + width).then_some((*k, l.0, r.0))
                            }),
                            output,
                        )
                    }
                    Method::Nested => {
                        let ra = r.map(|(k, y)| (k, (y,))).arrange_by_key();
                        tally(
                            range_join(
                                ra,
                                sa,
                                |_, _, _| Ordering::Equal,
                                move |k, l, r| (l.0 < r.0 && r.0 < l.0 + width).then_some((*k, l.0, r.0)),
                            ),
                            output,
                        )
                    }
                    Method::Range1 => {
                        let ra = r.map(|(k, y)| (k, (y,))).arrange_by_key();
                        tally(
                            range_join(
                                ra,
                                sa,
                                |_, l, r| locate_above(l.0, r.0),
                                move |k, l, r| (r.0 < l.0 + width).then_some((*k, l.0, r.0)),
                            ),
                            output,
                        )
                    }
                    Method::Range => {
                        let ra = r.map(move |(k, y)| (k, (y, y + width))).arrange_by_key();
                        tally(
                            range_join(
                                ra,
                                sa,
                                |_, l, r| locate_between(l.0, l.1, r.0),
                                |k, l, r| Some((*k, l.0, r.0)),
                            ),
                            output,
                        )
                    }
                    Method::Seek | Method::Back | Method::Auto => {
                        let ra = r.map(move |(k, y)| (k, (y, y + width))).arrange_by_key();
                        tally(
                            seek_range_join_both(
                                ra,
                                sa,
                                |_, l, r| locate_between(l.0, l.1, r.0),
                                |_, l| (l.0,),
                                move |_, r| (r.0 - width + 1, i64::MIN),
                                method.strategy(),
                                |k, l, r| Some((*k, l.0, r.0)),
                            ),
                            output,
                        )
                    }
                }
                (r_input, s_input)
            });
            for &row in r_rows.iter().skip(index).step_by(peers) {
                r_input.update(row, Present);
            }
            for &row in s_rows.iter().skip(index).step_by(peers) {
                s_input.update(row, Present);
            }
            r_input.close();
            s_input.close();
            while worker.step() {}
        }
    });
    Outcome { elapsed, output: output.summary(), expected, detail: String::new() }
}

/// `Out(s,e,p) :- I(s,e), P(p), s <= p, p < e.`
fn interval(args: &Args) -> Outcome {
    assert!(args.method != Method::Back, "interval ranges don't rise with the left values: no seeking back");
    let mut rng = Rng(args.seed);
    let p_rows = Arc::new(points(args.n, args.gap, &mut rng));
    let span = p_rows.last().copied().unwrap_or(1);
    let mut i_rows: Vec<(i64, i64)> = (0..args.m)
        .map(|_| {
            let start = rng.below(span as u64) as i64;
            (start, start + 1 + rng.below((2 * args.width - 1).max(1) as u64) as i64)
        })
        .collect();
    i_rows.sort_unstable();
    i_rows.dedup();
    let i_rows = Arc::new(i_rows);
    let expected = args.check.then(|| {
        let mut summary = Summary::default();
        for &(s, e) in i_rows.iter() {
            let first = p_rows.partition_point(|&p| p < s);
            for &p in p_rows[first..].iter().take_while(|&&p| p < e) {
                summary.add(&(s, e, p));
            }
        }
        summary
    });
    let method = args.method;
    let output = Arc::new(Tally::default());
    let elapsed = run(args.workers, {
        let (p_rows, i_rows, output) = (p_rows.clone(), i_rows.clone(), output.clone());
        move |worker| {
            let (index, peers) = (worker.index(), worker.peers());
            let output = output.clone();
            let (mut i_input, mut p_input) = worker.dataflow::<Ts, _, _>(|scope| {
                let (i_input, i) = scope.new_collection::<(i64, i64), Present>();
                let (p_input, p) = scope.new_collection::<i64, Present>();
                let ia = i.map(|(s, e)| ((), (s, e))).arrange_by_key();
                let pa = p.map(|p| ((), (p,))).arrange_by_key();
                let inside = |l: &(i64, i64), r: &(i64,)| l.0 <= r.0 && r.0 < l.1;
                match method {
                    Method::Arrange => {
                        ia.stream.inspect_batch(|_, _| {});
                        pa.stream.inspect_batch(|_, _| {});
                    }
                    Method::Cross => tally(
                        flowlog_join(ia, pa, "cross", move |_, l, r| inside(l, r).then_some((l.0, l.1, r.0))),
                        output,
                    ),
                    Method::Nested => tally(
                        range_join(
                            ia,
                            pa,
                            |_, _, _| Ordering::Equal,
                            move |_, l, r| inside(l, r).then_some((l.0, l.1, r.0)),
                        ),
                        output,
                    ),
                    Method::Range1 => tally(
                        range_join(
                            ia,
                            pa,
                            |_, l, r| if r.0 < l.0 { Ordering::Less } else { Ordering::Equal },
                            |_, l, r| (r.0 < l.1).then_some((l.0, l.1, r.0)),
                        ),
                        output,
                    ),
                    Method::Range => tally(
                        range_join(ia, pa, |_, l, r| locate_within(l.0, l.1, r.0), |_, l, r| {
                            Some((l.0, l.1, r.0))
                        }),
                        output,
                    ),
                    Method::Back => unreachable!(),
                    Method::Seek | Method::Auto => tally(
                        seek_range_join(
                            ia,
                            pa,
                            |_, l, r| locate_within(l.0, l.1, r.0),
                            |_, l| (l.0,),
                            method.strategy(),
                            |_, l, r| Some((l.0, l.1, r.0)),
                        ),
                        output,
                    ),
                }
                (i_input, p_input)
            });
            for &row in i_rows.iter().skip(index).step_by(peers) {
                i_input.update(row, Present);
            }
            for &row in p_rows.iter().skip(index).step_by(peers) {
                p_input.update(row, Present);
            }
            i_input.close();
            p_input.close();
            while worker.step() {}
        }
    });
    Outcome { elapsed, output: output.summary(), expected, detail: String::new() }
}

/// `Reach(y) :- Src(y).  Reach(y) :- Reach(x), P(y), x < y, y < x + width.`
///
/// Each iteration's delta is a handful of points, while `P` is the whole
/// input: this is where per-unit costs linear in the accumulated side show.
fn hop(args: &Args) -> Outcome {
    let rows = Arc::new(points(args.n, args.gap, &mut Rng(args.seed)));
    let source = rows[0];
    let expected = args.check.then(|| {
        let mut summary = Summary::default();
        let mut frontier = source;
        summary.add(&source);
        for &y in &rows[1..] {
            if y - frontier < args.width {
                summary.add(&y);
                frontier = y;
            }
        }
        summary
    });
    let (method, width) = (args.method, args.width);
    let output = Arc::new(Tally::default());
    let elapsed = run(args.workers, {
        let (rows, output) = (rows.clone(), output.clone());
        move |worker| {
            let (index, peers) = (worker.index(), worker.peers());
            let output = output.clone();
            let (mut src_input, mut p_input) = worker.dataflow::<Ts, _, _>(|scope| {
                let (src_input, src) = scope.new_collection::<i64, isize>();
                let (p_input, p) = scope.new_collection::<i64, isize>();
                // Arranged outside the loop and entered, as FlowLog shares
                // lower-stratum arrangements with recursive strata.
                let targets = p.map(|y| ((), (y,))).arrange_by_key();
                let reach = src.clone().iterate(|scope, reach| {
                    let targets = targets.enter(scope);
                    let step = match method {
                        Method::Arrange => reach.filter(|_| false),
                        Method::Cross => flowlog_join(
                            reach.map(|x| ((), (x,))).arrange_by_key(),
                            targets,
                            "cross",
                            move |_, l, r| (l.0 < r.0 && r.0 < l.0 + width).then_some(r.0),
                        ),
                        Method::Nested => range_join(
                            reach.map(|x| ((), (x,))).arrange_by_key(),
                            targets,
                            |_, _, _| Ordering::Equal,
                            move |_, l, r| (l.0 < r.0 && r.0 < l.0 + width).then_some(r.0),
                        ),
                        Method::Range1 => range_join(
                            reach.map(|x| ((), (x,))).arrange_by_key(),
                            targets,
                            |_, l, r| locate_above(l.0, r.0),
                            move |_, l, r| (r.0 < l.0 + width).then_some(r.0),
                        ),
                        Method::Range => range_join(
                            reach.map(move |x| ((), (x, x + width))).arrange_by_key(),
                            targets,
                            |_, l, r| locate_between(l.0, l.1, r.0),
                            |_, _, r| Some(r.0),
                        ),
                        Method::Seek | Method::Back | Method::Auto => seek_range_join_both(
                            reach.map(move |x| ((), (x, x + width))).arrange_by_key(),
                            targets,
                            |_, l, r| locate_between(l.0, l.1, r.0),
                            |_, l| (l.0,),
                            move |_, r| (r.0 - width + 1, i64::MIN),
                            method.strategy(),
                            |_, _, r| Some(r.0),
                        ),
                    };
                    step.concat(src.enter(scope)).distinct()
                });
                tally(reach, output);
                (src_input, p_input)
            });
            if index == 0 {
                src_input.insert(source);
            }
            for &y in rows.iter().skip(index).step_by(peers) {
                p_input.insert(y);
            }
            src_input.close();
            p_input.close();
            while worker.step() {}
        }
    });
    Outcome { elapsed, output: output.summary(), expected, detail: String::new() }
}

/// `Out(x,y) :- L(x), R(y), x < y, y < x + width.` in FlowLog's incremental
/// mode: preload `n` and `m` points, then `rounds` transactions that each
/// insert `delta` fresh points into `L`, `R` or both (`side=l|r|lr`).
fn txn(args: &Args) -> Outcome {
    let mut rng = Rng(args.seed);
    let mut l_set: BTreeSet<i64> = points(args.n, args.gap, &mut rng).into_iter().collect();
    let mut r_set: BTreeSet<i64> = points(args.m, args.gap, &mut rng).into_iter().collect();
    let preload: Arc<(Vec<i64>, Vec<i64>)> =
        Arc::new((l_set.iter().copied().collect(), r_set.iter().copied().collect()));
    let span = args.n.max(args.m) as i64 * args.gap;
    let fresh = |set: &mut BTreeSet<i64>, rng: &mut Rng| {
        let mut rows = Vec::new();
        while rows.len() < args.delta {
            let row = rng.below(span as u64) as i64;
            if set.insert(row) {
                rows.push(row);
            }
        }
        rows
    };
    let txns: Arc<Vec<(Vec<i64>, Vec<i64>)>> = Arc::new(
        (0..args.rounds)
            .map(|_| {
                let l = if args.side.contains('l') { fresh(&mut l_set, &mut rng) } else { Vec::new() };
                let r = if args.side.contains('r') { fresh(&mut r_set, &mut rng) } else { Vec::new() };
                (l, r)
            })
            .collect(),
    );
    let expected = args.check.then(|| {
        let mut summary = Summary::default();
        for &x in &l_set {
            for &y in r_set.range(x + 1..x + args.width) {
                summary.add(&(x, y));
            }
        }
        summary
    });
    let (method, width) = (args.method, args.width);
    let output = Arc::new(Tally::default());
    let phases = Arc::new(Mutex::new((Duration::ZERO, Duration::ZERO)));
    let elapsed = run(args.workers, {
        let (preload, txns, output, phases) = (preload.clone(), txns.clone(), output.clone(), phases.clone());
        move |worker| {
            let (index, peers) = (worker.index(), worker.peers());
            let started = Instant::now();
            let probe = Handle::new();
            let output = output.clone();
            let (mut l_input, mut r_input) = worker.dataflow::<u64, _, _>(|scope| {
                let (l_input, l) = scope.new_collection::<i64, isize>();
                let (r_input, r) = scope.new_collection::<i64, isize>();
                let ra = r.map(|y| ((), (y,))).arrange_by_key();
                let joined = match method {
                    Method::Arrange => {
                        l.clone().map(|x| ((), (x,))).arrange_by_key().stream.probe_with(&probe);
                        ra.stream.probe_with(&probe);
                        l.map(|x| (x, x)).filter(|_| false)
                    }
                    Method::Cross => {
                        flowlog_join(l.map(|x| ((), (x,))).arrange_by_key(), ra, "cross", move |_, l, r| {
                            (l.0 < r.0 && r.0 < l.0 + width).then_some((l.0, r.0))
                        })
                    }
                    Method::Nested => range_join(
                        l.map(|x| ((), (x,))).arrange_by_key(),
                        ra,
                        |_, _, _| Ordering::Equal,
                        move |_, l, r| (l.0 < r.0 && r.0 < l.0 + width).then_some((l.0, r.0)),
                    ),
                    Method::Range1 => range_join(
                        l.map(|x| ((), (x,))).arrange_by_key(),
                        ra,
                        |_, l, r| locate_above(l.0, r.0),
                        move |_, l, r| (r.0 < l.0 + width).then_some((l.0, r.0)),
                    ),
                    Method::Range => range_join(
                        l.map(move |x| ((), (x, x + width))).arrange_by_key(),
                        ra,
                        |_, l, r| locate_between(l.0, l.1, r.0),
                        |_, l, r| Some((l.0, r.0)),
                    ),
                    Method::Seek | Method::Back | Method::Auto => seek_range_join_both(
                        l.map(move |x| ((), (x, x + width))).arrange_by_key(),
                        ra,
                        |_, l, r| locate_between(l.0, l.1, r.0),
                        |_, l| (l.0,),
                        move |_, r| (r.0 - width + 1, i64::MIN),
                        method.strategy(),
                        |_, l, r| Some((l.0, r.0)),
                    ),
                };
                tally(joined.probe_with(&probe), output);
                (l_input, r_input)
            });
            for &x in preload.0.iter().skip(index).step_by(peers) {
                l_input.insert(x);
            }
            for &y in preload.1.iter().skip(index).step_by(peers) {
                r_input.insert(y);
            }
            let mut time = 1;
            l_input.advance_to(time);
            r_input.advance_to(time);
            l_input.flush();
            r_input.flush();
            worker.step_while(|| probe.less_than(&time));
            let loaded = started.elapsed();
            for (l_rows, r_rows) in txns.iter() {
                for &x in l_rows.iter().skip(index).step_by(peers) {
                    l_input.insert(x);
                }
                for &y in r_rows.iter().skip(index).step_by(peers) {
                    r_input.insert(y);
                }
                time += 1;
                l_input.advance_to(time);
                r_input.advance_to(time);
                l_input.flush();
                r_input.flush();
                worker.step_while(|| probe.less_than(&time));
            }
            if index == 0 {
                *phases.lock().unwrap() = (loaded, started.elapsed() - loaded);
            }
        }
    });
    let (loaded, updated) = *phases.lock().unwrap();
    let detail = format!(
        " side={} load={:.3} per_txn_ms={:.3}",
        args.side,
        loaded.as_secs_f64(),
        updated.as_secs_f64() * 1e3 / args.rounds.max(1) as f64
    );
    Outcome { elapsed, output: output.summary(), expected, detail }
}

fn main() {
    let args = Args::parse();
    let outcome = match args.workload.as_str() {
        "band" => band(&args),
        "keyed" => keyed(&args),
        "interval" => interval(&args),
        "hop" => hop(&args),
        "txn" => txn(&args),
        other => panic!("unknown workload '{other}'"),
    };
    let verdict = match outcome.expected {
        None => "unchecked",
        Some(_) if args.method == Method::Arrange => "n/a",
        Some(expected) if expected == outcome.output => "ok",
        Some(_) => "MISMATCH",
    };
    println!(
        "{:<8} {:<7} n={:<8} m={:<8} w={:<2} out={:<11} secs={:.3} check={}{}",
        args.workload,
        format!("{:?}", args.method).to_lowercase(),
        args.n,
        args.m,
        args.workers,
        outcome.output.count,
        outcome.elapsed.as_secs_f64(),
        verdict,
        outcome.detail,
    );
    if verdict == "MISMATCH" {
        eprintln!("expected {:?}, got {:?}", outcome.expected.unwrap(), outcome.output);
        std::process::exit(1);
    }
}
