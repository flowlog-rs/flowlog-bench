//! The range join must agree with a brute-force oracle at every time, not
//! just at the end of a batch: these tests drive retractions through
//! incremental rounds and through an iterative scope, which exercise the
//! per-time edit handling (meet advancement, consolidation, time joins).
//! Each runs the merging join and the seeking join under every strategy
//! its ranges allow: seeking back needs ranges that rise with the left
//! values.

use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::collections::BTreeSet;
use std::sync::Arc;
use std::sync::Mutex;

use differential_dataflow::input::Input;
use differential_dataflow::operators::Iterate;
use rangejoin_toy::range_join;
use rangejoin_toy::seek_join::Strategy;
use rangejoin_toy::seek_range_join;
use rangejoin_toy::seek_range_join_both;
use timely::dataflow::operators::probe::Handle;

/// The joins under test: `None` for `range_join`, else the seeking join.
const JOINS: [Option<Strategy>; 5] = [
    None,
    Some(Strategy::Merge),
    Some(Strategy::Seek),
    Some(Strategy::SeekBack),
    Some(Strategy::Auto),
];

type Updates<D> = Arc<Mutex<Vec<(D, u64, isize)>>>;

struct Rng(u64);

impl Rng {
    fn below(&mut self, bound: u64) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        (z ^ (z >> 31)) % bound
    }
}

/// Per-round batches of `(row, +1 | -1)` that keep a set valid: rows are
/// only retracted while present and only inserted while absent.
fn churn<D: Ord + Clone>(
    rounds: usize,
    per_round: usize,
    rng: &mut Rng,
    mut fresh: impl FnMut(&mut Rng) -> D,
) -> Vec<Vec<(D, isize)>> {
    let mut live: BTreeSet<D> = BTreeSet::new();
    (0..rounds)
        .map(|_| {
            let mut batch = Vec::new();
            let mut touched = BTreeSet::new();
            for _ in 0..per_round {
                if !live.is_empty() && rng.below(3) == 0 {
                    let victim = live.iter().nth(rng.below(live.len() as u64) as usize).cloned().unwrap();
                    if touched.insert(victim.clone()) {
                        live.remove(&victim);
                        batch.push((victim, -1));
                    }
                } else {
                    let row = fresh(rng);
                    if !live.contains(&row) && touched.insert(row.clone()) {
                        live.insert(row.clone());
                        batch.push((row, 1));
                    }
                }
            }
            batch
        })
        .collect()
}

/// The set a sequence of batches leaves after `round`.
fn state_at<D: Ord + Clone>(batches: &[Vec<(D, isize)>], round: usize) -> BTreeSet<D> {
    let mut live = BTreeSet::new();
    for batch in &batches[..=round] {
        for (row, diff) in batch {
            if *diff > 0 {
                live.insert(row.clone());
            } else {
                live.remove(row);
            }
        }
    }
    live
}

/// Accumulates captured output through `round`, dropping zero weights.
fn accumulated<D: Ord + Clone>(updates: &[(D, u64, isize)], round: u64) -> BTreeMap<D, isize> {
    let mut totals = BTreeMap::new();
    for (row, time, diff) in updates {
        if *time <= round {
            *totals.entry(row.clone()).or_insert(0) += diff;
        }
    }
    totals.retain(|_, diff| *diff != 0);
    totals
}

type Left = (i64, i64, i64, i64); // (key, tag, lo, hi)
type Right = (i64, i64, i64); // (key, y, w)
type Joined = (i64, i64, i64, i64, i64, i64);

/// `Out(k,tag,lo,hi,y,w) :- L(k,tag,lo,hi), R(k,y,w), lo <= y, y < hi, (tag + w) % 3 != 0.`
///
/// Left values lead with `tag`. Random tags put the bounds in no useful
/// order, so the search has to move backwards as well as forwards; band
/// rows instead set `tag = lo` and `hi = lo + BAND`, so that the ranges rise
/// with the left values and the join may seek back.
fn keyed_locate(_: &i64, l: &(i64, i64, i64), r: &(i64, i64)) -> Ordering {
    if r.0 < l.1 {
        Ordering::Less
    } else if r.0 >= l.2 {
        Ordering::Greater
    } else {
        Ordering::Equal
    }
}

/// The least right value at `lo`: an exact seek target.
fn keyed_lower(_: &i64, l: &(i64, i64, i64)) -> (i64, i64) {
    (l.1, i64::MIN)
}

const BAND: i64 = 8;

/// A band row that starts a full band below `y`, wholly below it: the join
/// must step past it.
fn band_lower_back(_: &i64, r: &(i64, i64)) -> (i64, i64, i64) {
    (r.0 - BAND, i64::MIN, i64::MIN)
}

fn keyed_result(k: &i64, l: &(i64, i64, i64), r: &(i64, i64)) -> Option<Joined> {
    ((l.0 + r.1) % 3 != 0).then_some((*k, l.0, l.1, l.2, r.0, r.1))
}

fn joined_oracle(left: &BTreeSet<Left>, right: &BTreeSet<Right>) -> BTreeMap<Joined, isize> {
    let mut out = BTreeMap::new();
    for &(k, tag, lo, hi) in left {
        for &(rk, y, w) in right {
            if rk == k && lo <= y && y < hi && (tag + w) % 3 != 0 {
                out.insert((k, tag, lo, hi, y, w), 1);
            }
        }
    }
    out
}

fn run_keyed(join: Option<Strategy>, band: bool, workers: usize, seed: u64) {
    let rounds = 10;
    // Band runs churn the right side slowly, so that small fresh right
    // batches meet large left traces, where seeking back pays. They also
    // sprinkle rows over rare keys, so that batches on both sides miss keys
    // the other side has.
    let key = move |rng: &mut Rng| match band && rng.below(4) == 0 {
        true => 4 + rng.below(12) as i64,
        false => rng.below(4) as i64,
    };
    let mut rng = Rng(seed);
    let left = Arc::new(churn(rounds, 40, &mut rng, |rng| {
        let (key, lo) = (key(rng), rng.below(60) as i64);
        if band { (key, lo, lo, lo + BAND) } else { (key, rng.below(50) as i64, lo, lo + rng.below(15) as i64) }
    }));
    let right = Arc::new(churn(rounds, if band { 4 } else { 40 }, &mut rng, |rng| {
        (key(rng), rng.below(70) as i64, rng.below(3) as i64)
    }));
    let captured: Updates<Joined> = Arc::new(Mutex::new(Vec::new()));

    timely::execute(timely::Config::process(workers), {
        let (left, right, captured) = (left.clone(), right.clone(), captured.clone());
        move |worker| {
            let (index, peers) = (worker.index(), worker.peers());
            let probe = Handle::new();
            let captured = captured.clone();
            let (mut left_in, mut right_in) = worker.dataflow::<u64, _, _>(|scope| {
                let (left_in, l) = scope.new_collection::<Left, isize>();
                let (right_in, r) = scope.new_collection::<Right, isize>();
                let la = l.map(|(k, tag, lo, hi)| (k, (tag, lo, hi))).arrange_by_key();
                let ra = r.map(|(k, y, w)| (k, (y, w))).arrange_by_key();
                match join {
                    None => range_join(la, ra, keyed_locate, keyed_result),
                    Some(strategy) if band => seek_range_join_both(
                        la,
                        ra,
                        keyed_locate,
                        keyed_lower,
                        band_lower_back,
                        strategy,
                        keyed_result,
                    ),
                    Some(strategy) => seek_range_join(la, ra, keyed_locate, keyed_lower, strategy, keyed_result),
                }
                .inspect(move |(row, time, diff)| captured.lock().unwrap().push((*row, *time, *diff)))
                .probe_with(&probe);
                (left_in, right_in)
            });
            for round in 0..rounds {
                for (row, diff) in left[round].iter().skip(index).step_by(peers) {
                    left_in.update(*row, *diff);
                }
                for (row, diff) in right[round].iter().skip(index).step_by(peers) {
                    right_in.update(*row, *diff);
                }
                let next = round as u64 + 1;
                left_in.advance_to(next);
                right_in.advance_to(next);
                left_in.flush();
                right_in.flush();
                // Stepping every other round packs two times into each
                // batch, so fresh and accumulated times really differ.
                if round % 2 == 1 || next == rounds as u64 {
                    worker.step_while(|| probe.less_than(&next));
                }
            }
        }
    })
    .unwrap()
    .join();

    let captured = captured.lock().unwrap();
    let mut nonempty = 0;
    for round in 0..rounds {
        let expected = joined_oracle(&state_at(&left, round), &state_at(&right, round));
        nonempty += usize::from(!expected.is_empty());
        assert_eq!(
            accumulated(&captured, round as u64),
            expected,
            "round {round}, {workers} workers, {join:?}, band {band}"
        );
    }
    assert!(nonempty > rounds / 2, "the oracle should be exercised");
}

#[test]
fn keyed_range_join_tracks_retractions() {
    for band in [false, true] {
        for join in JOINS {
            if join == Some(Strategy::SeekBack) && !band {
                continue;
            }
            for seed in 0..6 {
                for workers in [1, 3] {
                    run_keyed(join, band, workers, seed);
                }
            }
        }
    }
}

const HOP: i64 = 6;

/// Points reachable from `source` by upward hops shorter than `HOP`.
fn reach_oracle(points: &BTreeSet<i64>, source: i64) -> BTreeMap<i64, isize> {
    let mut reached = BTreeMap::from([(source, 1)]);
    let mut frontier = source;
    for &y in points.range(source + 1..) {
        if y - frontier < HOP {
            reached.insert(y, 1);
            frontier = y;
        }
    }
    reached
}

/// Places `r` against the open range `(x, x + HOP)` of a hop from `x`.
fn hop_locate(_: &(), l: &(i64, i64), r: &(i64,)) -> Ordering {
    if r.0 <= l.0 {
        Ordering::Less
    } else if r.0 >= l.1 {
        Ordering::Greater
    } else {
        Ordering::Equal
    }
}

/// `x` itself, which is below the range: the join must step past it.
fn hop_lower(_: &(), l: &(i64, i64)) -> (i64,) {
    (l.0,)
}

/// A hop from a full `HOP` below `y`, which falls short: the join must
/// step past it.
fn hop_lower_back(_: &(), r: &(i64,)) -> (i64, i64) {
    (r.0 - HOP, i64::MIN)
}

fn hop_result(_: &(), _: &(i64, i64), r: &(i64,)) -> Option<i64> {
    Some(r.0)
}

fn run_recursive(join: Option<Strategy>, workers: usize, seed: u64) {
    let rounds = 10;
    let source = 0;
    let mut rng = Rng(seed);
    let points = Arc::new(churn(rounds, 30, &mut rng, |rng| 1 + rng.below(60) as i64));
    let captured: Updates<i64> = Arc::new(Mutex::new(Vec::new()));

    timely::execute(timely::Config::process(workers), {
        let (points, captured) = (points.clone(), captured.clone());
        move |worker| {
            let (index, peers) = (worker.index(), worker.peers());
            let probe = Handle::new();
            let captured = captured.clone();
            let (mut source_in, mut points_in) = worker.dataflow::<u64, _, _>(|scope| {
                let (source_in, sources) = scope.new_collection::<i64, isize>();
                let (points_in, points) = scope.new_collection::<i64, isize>();
                // Reach(y) :- Source(y).
                // Reach(y) :- Reach(x), P(y), x < y, y < x + HOP.
                // `P` is arranged outside the loop and entered, as in FlowLog.
                let targets = points.map(|y| ((), (y,))).arrange_by_key();
                sources
                    .clone()
                    .iterate(|scope, reach| {
                        let hops = reach.map(|x| ((), (x, x + HOP))).arrange_by_key();
                        let targets = targets.enter(scope);
                        match join {
                            None => range_join(hops, targets, hop_locate, hop_result),
                            Some(strategy) => seek_range_join_both(
                                hops,
                                targets,
                                hop_locate,
                                hop_lower,
                                hop_lower_back,
                                strategy,
                                hop_result,
                            ),
                        }
                        .concat(sources.enter(scope))
                        .distinct()
                    })
                    .inspect(move |(row, time, diff)| captured.lock().unwrap().push((*row, *time, *diff)))
                    .probe_with(&probe);
                (source_in, points_in)
            });
            if index == 0 {
                source_in.insert(source);
            }
            for round in 0..rounds {
                for (row, diff) in points[round].iter().skip(index).step_by(peers) {
                    points_in.update(*row, *diff);
                }
                let next = round as u64 + 1;
                source_in.advance_to(next);
                points_in.advance_to(next);
                source_in.flush();
                points_in.flush();
                if round % 2 == 1 || next == rounds as u64 {
                    worker.step_while(|| probe.less_than(&next));
                }
            }
        }
    })
    .unwrap()
    .join();

    let captured = captured.lock().unwrap();
    let mut longest = 0;
    for round in 0..rounds {
        let expected = reach_oracle(&state_at(&points, round), source);
        longest = longest.max(expected.len());
        assert_eq!(
            accumulated(&captured, round as u64),
            expected,
            "round {round}, {workers} workers, {join:?}"
        );
    }
    assert!(longest > 8, "chains should span several iterations, got {longest}");
}

#[test]
fn recursive_range_join_tracks_retractions() {
    for join in JOINS {
        for seed in 0..6 {
            for workers in [1, 3] {
                run_recursive(join, workers, seed);
            }
        }
    }
}
