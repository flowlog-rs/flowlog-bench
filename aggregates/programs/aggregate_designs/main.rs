//! Same-executable comparison of FlowLog aggregate designs.
//!
//! Source rows `(group, value, witness)` project to `(group, value)`, so
//! witnesses are duplicate derivations of one distinct row. Each group
//! holds values `0, 2, ..., 2(V-1)`, each with `K` witnesses.
//!
//! Batch designs (`()` time, `Present` diffs):
//! - `b-main`: dedup, then the runtime's semiring-weight reduce.
//! - `b-weights`: the same reduce without dedup (min/max only).
//! - `b-weights-combine`: per-worker hash combine, then `b-weights`.
//! - `b-fused`: one arrangement by group; fold each group's distinct values.
//! - `b-hash`: exchange by group into hash-map state.
//! - `b-hash-combine`: per-worker hash combine, then `b-hash`.
//! - `b-hash-local`: bounded per-activation fold, then `b-hash` (min/max).
//! - `b-hash-adaptive`: as `b-hash-local`, but a time whose sampled rows
//!   do not shrink by half is forwarded unfolded (min/max).
//! - `b-dedup-hash`: dedup, then per-group hash totals (count/sum).
//! - `b-dedup-local`: dedup, bounded per-activation fold, hash totals.
//! - `b-pair-local`: hash dedup partitioned by pair, then as `b-dedup-local`.
//!
//! Incremental designs (`u32` time, `i32` diffs):
//! - `i-runtime`: the runtime reduce (no dedup; counts > 0 contribute).
//! - `i-main`: dedup, then the runtime reduce.
//! - `i-scan`: a local copy of `i-runtime`.
//! - `i-endpoint`: `i-scan`, reading only the first/last present value.
//! - `i-hier`: endpoint reduce per (group, bucket), then per group.
//! - `i-weights`: dedup, then abelian `(sum, count)` weights.
//! - `i-custom`: exchange by group into per-group ordered state.
//! - `i-lean`: exchange by group into one ordered map per worker.
//!
//! Every run checks its whole consolidated output stream against the
//! expected answers; batch runs also require one output per group.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::collections::hash_map::Entry;
use std::error::Error;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::Barrier;
use std::time::Instant;

use flowlog_runtime::differential_dataflow::AsCollection;
use flowlog_runtime::differential_dataflow::ExchangeData;
use flowlog_runtime::differential_dataflow::VecCollection;
use flowlog_runtime::differential_dataflow::consolidation::consolidate;
use flowlog_runtime::differential_dataflow::consolidation::consolidate_updates;
use flowlog_runtime::differential_dataflow::difference::Present;
use flowlog_runtime::differential_dataflow::hashable::Hashable;
use flowlog_runtime::differential_dataflow::input::Input;
use flowlog_runtime::differential_dataflow::operators::CountTotal;
use flowlog_runtime::differential_dataflow::trace::Cursor;
use flowlog_runtime::differential_dataflow::trace::Navigable;
use flowlog_runtime::differential_dataflow::trace::implementations::ValBuilder;
use flowlog_runtime::differential_dataflow::trace::implementations::ValSpine;
use flowlog_runtime::operators::{Count, Max, Min, Sum, flowlog_dedup, flowlog_map, flowlog_reduce};
use flowlog_runtime::timely;
use rustc_hash::FxHashMap;
use rustc_hash::FxHashSet;
use timely::container::CapacityContainerBuilder;
use timely::dataflow::channels::pact::Exchange;
use timely::dataflow::channels::pact::Pipeline;
use timely::dataflow::operators::Capability;
use timely::dataflow::operators::InputCapability;
use timely::dataflow::operators::generic::Operator;
use timely::dataflow::operators::probe::Handle;
use timely::order::TotalOrder;
use timely::progress::Timestamp;
use timely::progress::frontier::MutableAntichain;

// Generated FlowLog crates use this allocator.
#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

type Row = (u32, i64);
type Source = (u32, i64, u32);

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    BMain,
    BWeights,
    BWeightsCombine,
    BFused,
    BHash,
    BHashCombine,
    BHashLocal,
    BHashAdaptive,
    BDedupHash,
    BDedupLocal,
    BPairLocal,
    IRuntime,
    IMain,
    IScan,
    IEndpoint,
    IHier,
    IWeights,
    ICustom,
    ILean,
}

const MODES: [(&str, Mode); 19] = [
    ("b-main", Mode::BMain),
    ("b-weights", Mode::BWeights),
    ("b-weights-combine", Mode::BWeightsCombine),
    ("b-fused", Mode::BFused),
    ("b-hash", Mode::BHash),
    ("b-hash-combine", Mode::BHashCombine),
    ("b-hash-local", Mode::BHashLocal),
    ("b-hash-adaptive", Mode::BHashAdaptive),
    ("b-dedup-hash", Mode::BDedupHash),
    ("b-dedup-local", Mode::BDedupLocal),
    ("b-pair-local", Mode::BPairLocal),
    ("i-runtime", Mode::IRuntime),
    ("i-main", Mode::IMain),
    ("i-scan", Mode::IScan),
    ("i-endpoint", Mode::IEndpoint),
    ("i-hier", Mode::IHier),
    ("i-weights", Mode::IWeights),
    ("i-custom", Mode::ICustom),
    ("i-lean", Mode::ILean),
];

impl Mode {
    fn incremental(self) -> bool {
        matches!(
            self,
            Mode::IRuntime
                | Mode::IMain
                | Mode::IScan
                | Mode::IEndpoint
                | Mode::IHier
                | Mode::IWeights
                | Mode::ICustom
                | Mode::ILean
        )
    }

    fn supports(self, kind: Kind) -> bool {
        match self {
            // Without dedup, repeated rows would count or sum again.
            Mode::BWeights | Mode::BWeightsCombine | Mode::BHashLocal | Mode::BHashAdaptive => {
                kind.extremum()
            }
            // Dedup exists to make count and sum exact.
            Mode::BDedupHash | Mode::BDedupLocal | Mode::BPairLocal => !kind.extremum(),
            // Only the extremes have an endpoint.
            Mode::IEndpoint | Mode::IHier => kind.extremum(),
            // Min and max have no inverse, so no abelian weight.
            Mode::IWeights => !kind.extremum(),
            _ => true,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Min,
    Max,
    Sum,
    Count,
}

impl Kind {
    fn extremum(self) -> bool {
        matches!(self, Kind::Min | Kind::Max)
    }

    /// Whether bound `new` replaces bound `old`.
    #[inline]
    fn better(self, new: i64, old: i64) -> bool {
        match self {
            Kind::Min => new < old,
            Kind::Max => new > old,
            Kind::Sum | Kind::Count => unreachable!("not an extremum"),
        }
    }

    /// The aggregate of the base values `0, 2, ..., 2(V-1)` and `extra`.
    fn fold(self, values: i64, extra: &[i64]) -> i64 {
        match self {
            Kind::Min => extra.iter().copied().fold(0, i64::min),
            Kind::Max => extra.iter().copied().fold(2 * (values - 1), i64::max),
            Kind::Sum => values * (values - 1) + extra.iter().sum::<i64>(),
            Kind::Count => values + extra.len() as i64,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Placement {
    /// All rows of a group start on one worker.
    Local,
    /// Rows start on workers chosen by a hash of the whole row.
    Spread,
}

#[derive(Clone, Copy)]
enum Change {
    /// Toggle `-2` and `2V`: every aggregate changes.
    Winner,
    /// Toggle `1`: only count and sum change.
    Interior,
    /// Toggle one of several witnesses of value `0`: nothing changes.
    Support,
}

impl Change {
    fn extra(self, values: i64) -> Vec<i64> {
        match self {
            Change::Winner => vec![-2, 2 * values],
            Change::Interior => vec![1],
            Change::Support => Vec::new(),
        }
    }
}

struct Phase {
    name: String,
    change: Change,
    touched: u32,
    rounds: u32,
    offset: u64,
}

#[derive(Clone, Copy)]
struct Parameters {
    mode: Mode,
    kind: Kind,
    workers: usize,
    groups: u32,
    values: i64,
    duplicates: u32,
    placement: Placement,
    warmup: u32,
    /// `(touched groups, timed rounds)` for the latency phases.
    latency: (u32, u32),
    /// `(touched groups, timed rounds)` for the throughput phases.
    throughput: (u32, u32),
}

impl Parameters {
    fn phases(&self) -> Vec<Phase> {
        let mut phases = Vec::new();
        for (label, change) in [
            ("winner", Change::Winner),
            ("interior", Change::Interior),
            ("support", Change::Support),
        ] {
            if matches!(change, Change::Support) && self.duplicates < 2 {
                continue;
            }
            for (size, (touched, rounds)) in [("lat", self.latency), ("thr", self.throughput)] {
                if rounds > 0 {
                    let offset = phases.len() as u64 * 7919;
                    let name = format!("{label}-{size}");
                    phases.push(Phase { name, change, touched, rounds, offset });
                }
            }
        }
        phases
    }

    /// Groups changed in `round` (1-based). An insert round and the
    /// following delete round touch the same groups.
    fn round_groups(&self, phase: &Phase, round: u32) -> impl Iterator<Item = u32> {
        let groups = self.groups as u64;
        let base = phase.offset + ((round - 1) / 2) as u64 * phase.touched as u64;
        (0..phase.touched as u64).map(move |i| ((base + i) % groups) as u32)
    }

    fn for_updates(&self, change: Change, group: u32, insert: bool, mut f: impl FnMut(Source, i32)) {
        let diff = if insert { 1 } else { -1 };
        match change {
            Change::Winner => {
                for value in [-2, 2 * self.values] {
                    for witness in 0..self.duplicates {
                        f((group, value, witness), diff);
                    }
                }
            }
            Change::Interior => {
                for witness in 0..self.duplicates {
                    f((group, 1, witness), diff);
                }
            }
            Change::Support => f((group, 0, 0), -diff),
        }
    }

    /// Rows one worker loads initially, in a scrambled order.
    fn initial_rows(&self, index: usize) -> Vec<Source> {
        let workers = self.workers as u64;
        let mut rows = Vec::new();
        for group in 0..self.groups {
            let local = group as usize % self.workers == index;
            if self.placement == Placement::Local && !local {
                continue;
            }
            for value in 0..self.values {
                for witness in 0..self.duplicates {
                    let row = (group, 2 * value, witness);
                    let key = ((group as u64) << 32) ^ ((row.1 as u64) << 8) ^ witness as u64;
                    if self.placement == Placement::Local || mix(key) % workers == index as u64 {
                        rows.push(row);
                    }
                }
            }
        }
        let mut state = mix(index as u64);
        for i in (1..rows.len()).rev() {
            state = mix(state);
            rows.swap(i, (state % (i as u64 + 1)) as usize);
        }
        rows
    }

    fn expected_incremental(&self) -> Vec<(Row, u32, i32)> {
        let base = self.kind.fold(self.values, &[]);
        let mut expected: Vec<_> = (0..self.groups).map(|g| ((g, base), 0, 1)).collect();
        let mut epoch = 1;
        for phase in self.phases() {
            let changed = self.kind.fold(self.values, &phase.change.extra(self.values));
            for round in 1..=self.warmup + phase.rounds {
                if changed != base {
                    let (old, new) = if round % 2 == 1 { (base, changed) } else { (changed, base) };
                    for group in self.round_groups(&phase, round) {
                        expected.push(((group, old), epoch, -1));
                        expected.push(((group, new), epoch, 1));
                    }
                }
                epoch += 1;
            }
        }
        expected
    }
}

fn mix(mut x: u64) -> u64 {
    x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
    x = (x ^ (x >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    x = (x ^ (x >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    x ^ (x >> 31)
}

/// One of 64 buckets, spread over nearby values.
fn bucket(value: i64) -> u8 {
    ((value as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15) >> 58) as u8
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

// =============================================================================
// Per-time state for totally ordered clocks
// =============================================================================

/// State for each time the input frontier has not yet passed.
struct Pending<T: Timestamp, S> {
    slots: Vec<(Capability<T>, S)>,
}

impl<T: Timestamp, S> Default for Pending<T, S> {
    fn default() -> Self {
        Self { slots: Vec::new() }
    }
}

impl<T: Timestamp + TotalOrder, S: Default> Pending<T, S> {
    #[inline]
    fn slot(&mut self, capability: &InputCapability<T>, time: &T) -> &mut S {
        let index = match self.slots.iter().rposition(|(held, _)| held.time() == time) {
            Some(index) => index,
            None => {
                self.slots.push((capability.delayed(time, 0), S::default()));
                self.slots.len() - 1
            }
        };
        &mut self.slots[index].1
    }

    /// Removes the times the frontier has passed, in time order.
    fn ready(&mut self, frontier: &MutableAntichain<T>) -> Vec<(Capability<T>, S)> {
        let mut ready = Vec::new();
        let mut index = 0;
        while index < self.slots.len() {
            if frontier.less_equal(self.slots[index].0.time()) {
                index += 1;
            } else {
                ready.push(self.slots.swap_remove(index));
            }
        }
        ready.sort_by(|a, b| a.0.time().cmp(b.0.time()));
        ready
    }
}

/// Rows that arrived at one time, reduced as they arrive: the best bound
/// per group for min/max, the distinct pairs for count/sum.
#[derive(Default)]
struct Delta {
    bounds: FxHashMap<u32, i64>,
    pairs: FxHashSet<Row>,
}

impl Delta {
    #[inline]
    fn add(&mut self, kind: Kind, (group, value): Row) {
        if kind.extremum() {
            self.bounds
                .entry(group)
                .and_modify(|bound| {
                    if kind.better(value, *bound) {
                        *bound = value;
                    }
                })
                .or_insert(value);
        } else {
            self.pairs.insert((group, value));
        }
    }
}

/// Everything a batch hash aggregate has seen.
#[derive(Default)]
struct HashState {
    bounds: FxHashMap<u32, i64>,
    pairs: FxHashSet<Row>,
    totals: FxHashMap<u32, (i64, i64)>,
}

impl HashState {
    /// Folds one completed time into the state and emits each group whose
    /// answer changed, as the semiring threshold does.
    fn absorb(&mut self, kind: Kind, delta: Delta, mut emit: impl FnMut(Row)) {
        if kind.extremum() {
            if self.bounds.is_empty() {
                self.bounds = delta.bounds;
                self.bounds.iter().for_each(|(&group, &bound)| emit((group, bound)));
                return;
            }
            for (group, bound) in delta.bounds {
                match self.bounds.entry(group) {
                    Entry::Vacant(entry) => {
                        entry.insert(bound);
                        emit((group, bound));
                    }
                    Entry::Occupied(mut entry) => {
                        if kind.better(bound, *entry.get()) {
                            entry.insert(bound);
                            emit((group, bound));
                        }
                    }
                }
            }
            return;
        }
        let answer = |(sum, count): (i64, i64)| if kind == Kind::Sum { sum } else { count };
        if self.pairs.is_empty() {
            self.pairs = delta.pairs;
            for &(group, value) in &self.pairs {
                let total = self.totals.entry(group).or_insert((0, 0));
                total.0 += value;
                total.1 += 1;
            }
            self.totals.iter().for_each(|(&group, &total)| emit((group, answer(total))));
            return;
        }
        let mut before = FxHashMap::<u32, Option<i64>>::default();
        for (group, value) in delta.pairs {
            if self.pairs.insert((group, value)) {
                let total = self.totals.entry(group).or_insert((0, 0));
                let old = (total.1 > 0).then(|| answer(*total));
                before.entry(group).or_insert(old);
                total.0 += value;
                total.1 += 1;
            }
        }
        for (group, old) in before {
            let new = answer(self.totals[&group]);
            if old != Some(new) {
                emit((group, new));
            }
        }
    }
}

// =============================================================================
// Batch designs
// =============================================================================

fn batch_design<'scope>(
    rows: VecCollection<'scope, (), Row, Present>,
    parameters: Parameters,
) -> VecCollection<'scope, (), Row, Present> {
    let kind = parameters.kind;
    match parameters.mode {
        // FlowLog keys a global aggregate by `()`, not by a constant group.
        Mode::BMain if parameters.groups == 1 => with_kind!(kind, agg => flowlog_reduce(
            flowlog_dedup(rows), "Reduce", agg, None, |(_, value)| ((), value), |(), c: i64| (0, c),
        )),
        Mode::BWeights if parameters.groups == 1 => with_kind!(kind, agg => flowlog_reduce(
            rows, "Reduce", agg, None, |(_, value)| ((), value), |(), c: i64| (0, c),
        )),
        Mode::BMain => with_kind!(kind, agg => flowlog_reduce(
            flowlog_dedup(rows), "Reduce", agg, None, |row| row, |g, c: i64| (g, c),
        )),
        Mode::BWeights => with_kind!(kind, agg => flowlog_reduce(
            rows, "Reduce", agg, None, |row| row, |g, c: i64| (g, c),
        )),
        Mode::BWeightsCombine => with_kind!(kind, agg => flowlog_reduce(
            combine(rows, kind), "Reduce", agg, None, |row| row, |g, c: i64| (g, c),
        )),
        Mode::BFused => fused_batch(rows, kind),
        Mode::BHash => hash_batch(rows, kind),
        Mode::BHashCombine => hash_batch(combine(rows, kind), kind),
        Mode::BHashLocal => {
            let tighten = move |bound: &mut i64, value: i64| {
                if kind.better(value, *bound) {
                    *bound = value;
                }
            };
            hash_batch(local_fold(rows, tighten), kind)
        }
        Mode::BHashAdaptive => {
            let tighten = move |bound: &mut i64, value: i64| {
                if kind.better(value, *bound) {
                    *bound = value;
                }
            };
            hash_batch(adaptive_fold(rows, tighten), kind)
        }
        Mode::BDedupHash => hash_totals(increments(flowlog_dedup(rows)), kind),
        Mode::BDedupLocal => hash_totals(local_fold(increments(flowlog_dedup(rows)), add), kind),
        Mode::BPairLocal => hash_totals(local_fold(pair_distinct(rows), add), kind),
        _ => unreachable!("incremental design"),
    }
}

/// Reduces each worker's rows per time before they are exchanged.
fn combine<'scope, T: Timestamp + TotalOrder>(
    rows: VecCollection<'scope, T, Row, Present>,
    kind: Kind,
) -> VecCollection<'scope, T, Row, Present> {
    rows.inner
        .unary_frontier::<CapacityContainerBuilder<Vec<(Row, T, Present)>>, _, _, _>(
            Pipeline,
            "Combine",
            move |_, _| {
                let mut pending = Pending::<T, Delta>::default();
                move |(input, frontier), output| {
                    input.for_each(|capability, data| {
                        for (row, time, _) in data.drain(..) {
                            pending.slot(&capability, &time).add(kind, row);
                        }
                    });
                    for (capability, delta) in pending.ready(frontier) {
                        let time = capability.time().clone();
                        let mut session = output.session(&capability);
                        for (group, bound) in delta.bounds {
                            session.give(((group, bound), time.clone(), Present));
                        }
                        for row in delta.pairs {
                            session.give((row, time.clone(), Present));
                        }
                    }
                }
            },
        )
        .as_collection()
}

/// Exchanges rows by group into hash maps, emitting at each completed time.
fn hash_batch<'scope, T: Timestamp + TotalOrder>(
    rows: VecCollection<'scope, T, Row, Present>,
    kind: Kind,
) -> VecCollection<'scope, T, Row, Present> {
    let pact = Exchange::new(|update: &(Row, T, Present)| update.0.0.hashed());
    rows.inner
        .unary_frontier::<CapacityContainerBuilder<Vec<(Row, T, Present)>>, _, _, _>(
            pact,
            "HashAggregate",
            move |_, _| {
                let mut pending = Pending::<T, Delta>::default();
                let mut state = HashState::default();
                move |(input, frontier), output| {
                    input.for_each(|capability, data| {
                        for (row, time, _) in data.drain(..) {
                            pending.slot(&capability, &time).add(kind, row);
                        }
                    });
                    for (capability, delta) in pending.ready(frontier) {
                        let time = capability.time().clone();
                        let mut session = output.session(&capability);
                        state.absorb(kind, delta, |row| session.give((row, time.clone(), Present)));
                    }
                }
            },
        )
        .as_collection()
}

/// A group's `(sum, count)` contribution.
type Increment = (u32, (i64, i64));

#[inline]
fn add(total: &mut (i64, i64), increment: (i64, i64)) {
    total.0 += increment.0;
    total.1 += increment.1;
}

/// Lifts distinct rows to increments.
fn increments<'scope, T: Timestamp>(
    rows: VecCollection<'scope, T, Row, Present>,
) -> VecCollection<'scope, T, Increment, Present> {
    flowlog_map(rows, "Lift", |(group, value), time, diff| std::iter::once(((group, (value, 1)), time, diff)))
}

/// Groups one activation holds before it sends its partials early.
const LOCAL_GROUPS: usize = 1 << 16;

/// Folds each activation's rows per group and time before they are
/// exchanged, so a worker sends about one partial per group per
/// activation. Holds at most `LOCAL_GROUPS` groups, and nothing across
/// activations: no capability, no frontier wait.
fn local_fold<'scope, T: Timestamp, S: ExchangeData>(
    rows: VecCollection<'scope, T, (u32, S), Present>,
    merge: impl Fn(&mut S, S) + 'static,
) -> VecCollection<'scope, T, (u32, S), Present> {
    rows.inner
        .unary::<CapacityContainerBuilder<Vec<((u32, S), T, Present)>>, _, _, _>(
            Pipeline,
            "LocalFold",
            move |_, _| {
                let mut partials = FxHashMap::<u32, S>::default();
                move |input, output| {
                    input.for_each_time(|capability, data| {
                        let mut session = output.session(&capability);
                        let mut current: Option<T> = None;
                        for ((group, weight), time, _) in data.flat_map(|batch| batch.drain(..)) {
                            let full = partials.len() >= LOCAL_GROUPS;
                            if full || current.as_ref() != Some(&time) {
                                if let Some(done) = current.take() {
                                    session.give_iterator(
                                        partials.drain().map(|(g, s)| ((g, s), done.clone(), Present)),
                                    );
                                }
                                current = Some(time);
                            }
                            match partials.entry(group) {
                                Entry::Occupied(mut entry) => merge(entry.get_mut(), weight),
                                Entry::Vacant(entry) => {
                                    entry.insert(weight);
                                }
                            }
                        }
                        if let Some(done) = current {
                            session.give_iterator(partials.drain().map(|(g, s)| ((g, s), done.clone(), Present)));
                        }
                    });
                }
            },
        )
        .as_collection()
}

/// Rows of a time sampled before its fold decides whether folding pays.
const PROBE: usize = 4096;

/// What an adaptive fold has learned about its latest time.
struct Verdict<T> {
    time: T,
    /// Rows of the time folded so far, and the partials they made.
    rows: usize,
    partials: usize,
    /// The sample did not halve: the time's remaining rows pass unfolded.
    forward: bool,
}

/// As `local_fold`, but each time first folds a `PROBE`-row sample. If the
/// sample does not shrink to half its rows, the rest of that time's rows
/// are forwarded unfolded. Only the latest time's verdict outlives an
/// activation.
fn adaptive_fold<'scope, T: Timestamp, S: ExchangeData>(
    rows: VecCollection<'scope, T, (u32, S), Present>,
    merge: impl Fn(&mut S, S) + 'static,
) -> VecCollection<'scope, T, (u32, S), Present> {
    rows.inner
        .unary::<CapacityContainerBuilder<Vec<((u32, S), T, Present)>>, _, _, _>(
            Pipeline,
            "AdaptiveFold",
            move |_, _| {
                let mut partials = FxHashMap::<u32, S>::default();
                let mut verdict: Option<Verdict<T>> = None;
                move |input, output| {
                    input.for_each_time(|capability, data| {
                        let mut session = output.session(&capability);
                        let mut current: Option<T> = None;
                        for batch in data {
                            for ((group, weight), time, _) in batch.drain(..) {
                                if verdict.as_ref().is_none_or(|v| v.time != time) {
                                    verdict = Some(Verdict { time: time.clone(), rows: 0, partials: 0, forward: false });
                                }
                                let state = verdict.as_mut().expect("just set");
                                if state.forward {
                                    session.give(((group, weight), time, Present));
                                    continue;
                                }
                                state.rows += 1;
                                if state.rows == PROBE && state.partials * 2 > PROBE {
                                    state.forward = true;
                                }
                                let full = partials.len() >= LOCAL_GROUPS;
                                if state.forward || full || current.as_ref() != Some(&time) {
                                    if let Some(done) = current.take() {
                                        session.give_iterator(
                                            partials.drain().map(|(g, s)| ((g, s), done.clone(), Present)),
                                        );
                                    }
                                    if state.forward {
                                        session.give(((group, weight), time, Present));
                                        continue;
                                    }
                                    current = Some(time);
                                }
                                match partials.entry(group) {
                                    Entry::Occupied(mut entry) => merge(entry.get_mut(), weight),
                                    Entry::Vacant(entry) => {
                                        state.partials += 1;
                                        entry.insert(weight);
                                    }
                                }
                            }
                        }
                        if let Some(done) = current {
                            session.give_iterator(partials.drain().map(|(g, s)| ((g, s), done.clone(), Present)));
                        }
                    });
                }
            },
        )
        .as_collection()
}

/// Exchanges rows by the whole pair and keeps each pair's first time, as
/// increments: a parallel hash dedup.
fn pair_distinct<'scope, T: Timestamp + TotalOrder>(
    rows: VecCollection<'scope, T, Row, Present>,
) -> VecCollection<'scope, T, Increment, Present> {
    let pact = Exchange::new(|update: &(Row, T, Present)| update.0.hashed());
    rows.inner
        .unary_frontier::<CapacityContainerBuilder<Vec<(Increment, T, Present)>>, _, _, _>(
            pact,
            "PairDistinct",
            move |_, _| {
                let mut pending = Pending::<T, FxHashSet<Row>>::default();
                let mut seen = FxHashSet::<Row>::default();
                move |(input, frontier), output| {
                    input.for_each(|capability, data| {
                        for (row, time, _) in data.drain(..) {
                            pending.slot(&capability, &time).insert(row);
                        }
                    });
                    for (capability, delta) in pending.ready(frontier) {
                        let time = capability.time().clone();
                        let mut session = output.session(&capability);
                        if seen.is_empty() {
                            for &(group, value) in &delta {
                                session.give(((group, (value, 1)), time.clone(), Present));
                            }
                            seen = delta;
                            continue;
                        }
                        for row in delta {
                            if seen.insert(row) {
                                session.give(((row.0, (row.1, 1)), time.clone(), Present));
                            }
                        }
                    }
                }
            },
        )
        .as_collection()
}

/// Exchanges increments of distinct rows by group into per-group totals.
fn hash_totals<'scope, T: Timestamp + TotalOrder>(
    increments: VecCollection<'scope, T, Increment, Present>,
    kind: Kind,
) -> VecCollection<'scope, T, Row, Present> {
    let pact = Exchange::new(|update: &(Increment, T, Present)| update.0.0.hashed());
    let answer = move |(sum, count): (i64, i64)| if kind == Kind::Sum { sum } else { count };
    increments
        .inner
        .unary_frontier::<CapacityContainerBuilder<Vec<(Row, T, Present)>>, _, _, _>(
            pact,
            "HashTotals",
            move |_, _| {
                let mut pending = Pending::<T, FxHashMap<u32, (i64, i64)>>::default();
                let mut state = FxHashMap::<u32, (i64, i64)>::default();
                move |(input, frontier), output| {
                    input.for_each(|capability, data| {
                        for ((group, increment), time, _) in data.drain(..) {
                            add(pending.slot(&capability, &time).entry(group).or_insert((0, 0)), increment);
                        }
                    });
                    for (capability, delta) in pending.ready(frontier) {
                        let time = capability.time().clone();
                        let mut session = output.session(&capability);
                        if state.is_empty() {
                            state = delta;
                            for (&group, &total) in &state {
                                session.give(((group, answer(total)), time.clone(), Present));
                            }
                            continue;
                        }
                        for (group, increment) in delta {
                            let total = state.entry(group).or_insert((0, 0));
                            let old = (total.1 > 0).then(|| answer(*total));
                            add(total, increment);
                            let new = answer(*total);
                            if old != Some(new) {
                                session.give(((group, new), time.clone(), Present));
                            }
                        }
                    }
                }
            },
        )
        .as_collection()
}

/// One exchange and arrangement by group. At `()` each worker's single
/// batch holds every distinct value once, in order.
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

// =============================================================================
// Incremental designs
// =============================================================================

fn incremental_design<'scope>(
    rows: VecCollection<'scope, u32, Row, i32>,
    parameters: Parameters,
) -> VecCollection<'scope, u32, Row, i32> {
    let kind = parameters.kind;
    match parameters.mode {
        Mode::IRuntime => with_kind!(kind, agg => flowlog_reduce(
            rows, "Reduce", agg, None, |row| row, |g, c: i64| (g, c),
        )),
        Mode::IMain => with_kind!(kind, agg => flowlog_reduce(
            flowlog_dedup(rows), "Reduce", agg, None, |row| row, |g, c: i64| (g, c),
        )),
        Mode::IScan => local_reduce(rows, "Reduce", kind, false),
        Mode::IEndpoint => local_reduce(rows, "Reduce", kind, true),
        Mode::IHier => {
            let buckets = rows.map(|(group, value)| ((group, bucket(value)), value));
            let partial = local_reduce(buckets, "Buckets", kind, true);
            local_reduce(partial.map(|((group, _), value)| (group, value)), "Reduce", kind, true)
        }
        Mode::IWeights => weights_incremental(flowlog_dedup(rows), kind),
        Mode::ICustom => custom_incremental(rows, kind),
        Mode::ILean => lean_incremental(rows, kind),
        _ => unreachable!("batch design"),
    }
}

/// Folds every present value, like the runtime reduce.
fn scan(kind: Kind, input: &[(&i64, i32)]) -> Option<i64> {
    let mut present = input.iter().filter(|(_, count)| *count > 0).map(|(value, _)| **value);
    let first = present.next()?;
    Some(match kind {
        Kind::Min => present.fold(first, i64::min),
        Kind::Max => present.fold(first, i64::max),
        Kind::Sum => present.fold(first, |a, b| a + b),
        Kind::Count => 1 + present.count() as i64,
    })
}

fn local_reduce<'scope, K: ExchangeData + Hashable>(
    rows: VecCollection<'scope, u32, (K, i64), i32>,
    name: &str,
    kind: Kind,
    endpoint: bool,
) -> VecCollection<'scope, u32, (K, i64), i32> {
    rows.arrange_by_key()
        .reduce_abelian::<_, ValBuilder<K, i64, u32, i32>, ValSpine<K, i64, u32, i32>, _, _>(
            name,
            move |_key, input, output| {
                let present = |(value, count): &(&i64, i32)| (*count > 0).then_some(**value);
                let result = match (endpoint, kind) {
                    (true, Kind::Min) => input.iter().find_map(present),
                    (true, Kind::Max) => input.iter().rev().find_map(present),
                    _ => scan(kind, input),
                };
                if let Some(result) = result {
                    output.push((result, 1));
                }
            },
            |buffer, key, updates| {
                buffer.clear();
                buffer.extend(updates.drain(..).map(|(v, t, r)| ((key.clone(), v), t, r)));
            },
        )
        .as_collection(|key, value| (key.clone(), *value))
}

fn weights_incremental<'scope>(
    rows: VecCollection<'scope, u32, Row, i32>,
    kind: Kind,
) -> VecCollection<'scope, u32, Row, i32> {
    match kind {
        Kind::Sum => flowlog_map(rows, "Lift", |(group, value), time, diff: i32| {
            let diff = diff as i64;
            std::iter::once((group, time, (value * diff, diff)))
        })
        .count_total_core::<i32>()
        .map(|(group, (sum, _count))| (group, sum)),
        Kind::Count => flowlog_map(rows, "Lift", |(group, _), time, diff: i32| {
            std::iter::once((group, time, diff as i64))
        })
        .count_total_core::<i32>(),
        Kind::Min | Kind::Max => unreachable!("rejected by parse"),
    }
}

/// Everything an ordered incremental aggregate has seen.
#[derive(Default)]
struct OrderedState {
    /// Min/max: each group's values with their derivation counts.
    values: FxHashMap<u32, BTreeMap<i64, i32>>,
    /// Count/sum: derivation counts per pair, and each group's
    /// `(sum, count)` over its present values.
    counts: FxHashMap<Row, i32>,
    totals: FxHashMap<u32, (i64, i64)>,
}

impl OrderedState {
    /// Applies one completed time's updates and emits changed answers.
    fn apply(&mut self, kind: Kind, updates: &mut Vec<(Row, i32)>, mut emit: impl FnMut(Row, i32)) {
        consolidate(updates);
        let mut start = 0;
        while start < updates.len() {
            let group = updates[start].0.0;
            let end = start + updates[start..].iter().take_while(|((g, _), _)| *g == group).count();
            let changes = &updates[start..end];
            let (old, new) = if kind.extremum() {
                self.extremum(kind, group, changes)
            } else {
                self.additive(kind, group, changes)
            };
            if old != new {
                if let Some(old) = old {
                    emit((group, old), -1);
                }
                if let Some(new) = new {
                    emit((group, new), 1);
                }
            }
            start = end;
        }
    }

    fn extremum(&mut self, kind: Kind, group: u32, changes: &[(Row, i32)]) -> (Option<i64>, Option<i64>) {
        let endpoint = |values: &BTreeMap<i64, i32>| {
            let present = |(value, count): (&i64, &i32)| (*count > 0).then_some(*value);
            match kind {
                Kind::Min => values.iter().find_map(present),
                _ => values.iter().rev().find_map(present),
            }
        };
        let values = self.values.entry(group).or_default();
        let old = endpoint(values);
        for &((_, value), diff) in changes {
            let count = values.entry(value).or_insert(0);
            *count += diff;
            if *count == 0 {
                values.remove(&value);
            }
        }
        let new = endpoint(values);
        if values.is_empty() {
            self.values.remove(&group);
        }
        (old, new)
    }

    fn additive(&mut self, kind: Kind, group: u32, changes: &[(Row, i32)]) -> (Option<i64>, Option<i64>) {
        let answer = |(sum, count): (i64, i64)| if kind == Kind::Sum { sum } else { count };
        let mut total = self.totals.get(&group).copied().unwrap_or((0, 0));
        let old = (total.1 > 0).then(|| answer(total));
        for &(row, diff) in changes {
            let count = self.counts.entry(row).or_insert(0);
            let before = *count > 0;
            *count += diff;
            let after = *count > 0;
            if *count == 0 {
                self.counts.remove(&row);
            }
            match (before, after) {
                (false, true) => total = (total.0 + row.1, total.1 + 1),
                (true, false) => total = (total.0 - row.1, total.1 - 1),
                _ => {}
            }
        }
        if total.1 > 0 {
            self.totals.insert(group, total);
            (old, Some(answer(total)))
        } else {
            self.totals.remove(&group);
            (old, None)
        }
    }
}

/// Everything a lean incremental aggregate has seen: one ordered map per
/// worker instead of one per group.
#[derive(Default)]
struct LeanState {
    /// Derivation counts per pair, ordered by group, then value.
    counts: BTreeMap<Row, i32>,
    /// Count/sum: each group's `(sum, count)` over its present values.
    totals: FxHashMap<u32, (i64, i64)>,
}

impl LeanState {
    fn endpoint(&self, kind: Kind, group: u32) -> Option<i64> {
        let mut range = self.counts.range((group, i64::MIN)..=(group, i64::MAX));
        let present = |(&(_, value), &count): (&Row, &i32)| (count > 0).then_some(value);
        match kind {
            Kind::Min => range.find_map(present),
            _ => range.rev().find_map(present),
        }
    }

    /// Applies one completed time's updates and emits changed answers.
    fn apply(&mut self, kind: Kind, updates: &mut Vec<(Row, i32)>, mut emit: impl FnMut(Row, i32)) {
        consolidate(updates);
        if self.counts.is_empty() {
            self.load(kind, updates, emit);
            return;
        }
        let answer = |(sum, count): (i64, i64)| if kind == Kind::Sum { sum } else { count };
        let mut start = 0;
        while start < updates.len() {
            let group = updates[start].0.0;
            let end = start + updates[start..].iter().take_while(|((g, _), _)| *g == group).count();
            let (old, new) = if kind.extremum() {
                let old = self.endpoint(kind, group);
                for &(row, diff) in &updates[start..end] {
                    let count = self.counts.entry(row).or_insert(0);
                    *count += diff;
                    if *count == 0 {
                        self.counts.remove(&row);
                    }
                }
                (old, self.endpoint(kind, group))
            } else {
                let mut total = self.totals.get(&group).copied().unwrap_or((0, 0));
                let old = (total.1 > 0).then(|| answer(total));
                for &(row, diff) in &updates[start..end] {
                    let count = self.counts.entry(row).or_insert(0);
                    let before = *count > 0;
                    *count += diff;
                    let after = *count > 0;
                    if *count == 0 {
                        self.counts.remove(&row);
                    }
                    match (before, after) {
                        (false, true) => total = (total.0 + row.1, total.1 + 1),
                        (true, false) => total = (total.0 - row.1, total.1 - 1),
                        _ => {}
                    }
                }
                if total.1 > 0 {
                    self.totals.insert(group, total);
                    (old, Some(answer(total)))
                } else {
                    self.totals.remove(&group);
                    (old, None)
                }
            };
            if old != new {
                if let Some(old) = old {
                    emit((group, old), -1);
                }
                if let Some(new) = new {
                    emit((group, new), 1);
                }
            }
            start = end;
        }
    }

    /// The first time: bulk-builds the map from the sorted updates.
    fn load(&mut self, kind: Kind, updates: &mut Vec<(Row, i32)>, mut emit: impl FnMut(Row, i32)) {
        self.counts = updates.drain(..).collect();
        let mut current: Option<(u32, i64, i64)> = None;
        let mut flush = |entry: Option<(u32, i64, i64)>, totals: &mut FxHashMap<u32, (i64, i64)>| {
            if let Some((group, sum, count)) = entry {
                if !kind.extremum() {
                    totals.insert(group, (sum, count));
                }
                let result = if kind == Kind::Count { count } else { sum };
                emit((group, result), 1);
            }
        };
        for (&(group, value), &count) in &self.counts {
            if count <= 0 {
                continue;
            }
            match &mut current {
                Some((g, sum, n)) if *g == group => match kind {
                    // Values ascend within a group: the last is the max.
                    Kind::Min => {}
                    Kind::Max => *sum = value,
                    Kind::Sum | Kind::Count => {
                        *sum += value;
                        *n += 1;
                    }
                },
                _ => {
                    flush(current.take(), &mut self.totals);
                    current = Some((group, value, 1));
                }
            }
        }
        flush(current, &mut self.totals);
    }
}

/// Like `custom_incremental`, with `LeanState`.
fn lean_incremental<'scope>(
    rows: VecCollection<'scope, u32, Row, i32>,
    kind: Kind,
) -> VecCollection<'scope, u32, Row, i32> {
    let pact = Exchange::new(|update: &(Row, u32, i32)| update.0.0.hashed());
    rows.inner
        .unary_frontier::<CapacityContainerBuilder<Vec<(Row, u32, i32)>>, _, _, _>(
            pact,
            "LeanAggregate",
            move |_, _| {
                let mut pending = Pending::<u32, Vec<(Row, i32)>>::default();
                let mut state = LeanState::default();
                move |(input, frontier), output| {
                    input.for_each(|capability, data| {
                        for (row, time, diff) in data.drain(..) {
                            pending.slot(&capability, &time).push((row, diff));
                        }
                    });
                    for (capability, mut updates) in pending.ready(frontier) {
                        let time = *capability.time();
                        let mut session = output.session(&capability);
                        state.apply(kind, &mut updates, |row, diff| session.give((row, time, diff)));
                    }
                }
            },
        )
        .as_collection()
}

/// Exchanges rows by group into ordered per-group state. Valid only for
/// totally ordered times: each completed time is applied in order.
fn custom_incremental<'scope>(
    rows: VecCollection<'scope, u32, Row, i32>,
    kind: Kind,
) -> VecCollection<'scope, u32, Row, i32> {
    let pact = Exchange::new(|update: &(Row, u32, i32)| update.0.0.hashed());
    rows.inner
        .unary_frontier::<CapacityContainerBuilder<Vec<(Row, u32, i32)>>, _, _, _>(
            pact,
            "CustomAggregate",
            move |_, _| {
                let mut pending = Pending::<u32, Vec<(Row, i32)>>::default();
                let mut state = OrderedState::default();
                move |(input, frontier), output| {
                    input.for_each(|capability, data| {
                        for (row, time, diff) in data.drain(..) {
                            pending.slot(&capability, &time).push((row, diff));
                        }
                    });
                    for (capability, mut updates) in pending.ready(frontier) {
                        let time = *capability.time();
                        let mut session = output.session(&capability);
                        state.apply(kind, &mut updates, |row, diff| session.give((row, time, diff)));
                    }
                }
            },
        )
        .as_collection()
}

// =============================================================================
// Driver
// =============================================================================

type Interval = (f64, f64);

fn widen(total: &mut Interval, part: Interval) {
    total.0 = total.0.min(part.0);
    total.1 = total.1.max(part.1);
}

fn run_batch(parameters: Parameters) -> Result<(f64, Vec<(Row, (), Present)>), Box<dyn Error>> {
    let barrier = Arc::new(Barrier::new(parameters.workers));
    let origin = Instant::now();
    let workers = timely::execute(timely::Config::process(parameters.workers), move |worker| {
        let seen = Rc::new(RefCell::new(Vec::new()));
        let probe = Handle::new();
        let mut input = worker.dataflow::<(), _, _>(|scope| {
            let (input, source) = scope.new_collection::<Source, Present>();
            let rows = source.map(|(group, value, _)| (group, value));
            let seen = Rc::clone(&seen);
            batch_design(rows, parameters)
                .inspect(move |update| seen.borrow_mut().push(*update))
                .probe_with(&probe);
            input
        });
        let rows = parameters.initial_rows(worker.index());
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
    Ok((load.1 - load.0, output))
}

type IncrementalRun = (f64, Vec<f64>, Vec<(Row, u32, i32)>);

fn run_incremental(parameters: Parameters) -> Result<IncrementalRun, Box<dyn Error>> {
    let barrier = Arc::new(Barrier::new(parameters.workers));
    let origin = Instant::now();
    let workers = timely::execute(timely::Config::process(parameters.workers), move |worker| {
        let seen = Rc::new(RefCell::new(Vec::new()));
        let probe = Handle::new();
        let mut input = worker.dataflow::<u32, _, _>(|scope| {
            let (input, source) = scope.new_collection::<Source, i32>();
            let rows = source.map(|(group, value, _)| (group, value));
            let seen = Rc::clone(&seen);
            incremental_design(rows, parameters)
                .inspect(move |update| seen.borrow_mut().push(*update))
                .probe_with(&probe);
            input
        });
        let index = worker.index();
        let rows = parameters.initial_rows(index);
        barrier.wait();
        let load_start = origin.elapsed().as_secs_f64();
        for row in rows {
            input.update(row, 1);
        }
        input.advance_to(1);
        input.flush();
        worker.step_while(|| probe.less_than(&1));
        let load = (load_start, origin.elapsed().as_secs_f64());

        let mut epoch = 1;
        let mut phases = Vec::new();
        for phase in parameters.phases() {
            let mut start = 0.0;
            for round in 1..=parameters.warmup + phase.rounds {
                if round == parameters.warmup + 1 {
                    barrier.wait();
                    start = origin.elapsed().as_secs_f64();
                }
                let insert = round % 2 == 1;
                for group in parameters.round_groups(&phase, round) {
                    if group as usize % parameters.workers == index {
                        parameters.for_updates(phase.change, group, insert, |row, diff| {
                            input.update(row, diff)
                        });
                    }
                }
                epoch += 1;
                input.advance_to(epoch);
                input.flush();
                worker.step_while(|| probe.less_than(&epoch));
            }
            phases.push((start, origin.elapsed().as_secs_f64()));
        }
        input.close();
        while worker.step() {}
        (load, phases, seen.take())
    })?;
    let mut load = (f64::INFINITY, 0.0);
    let mut phases: Vec<Interval> = Vec::new();
    let mut output = Vec::new();
    for result in workers.join() {
        let (interval, times, seen) = result?;
        widen(&mut load, interval);
        phases.resize(times.len(), (f64::INFINITY, 0.0));
        for (total, part) in phases.iter_mut().zip(times) {
            widen(total, part);
        }
        output.extend(seen);
    }
    let phases = phases.into_iter().map(|(start, end)| end - start).collect();
    Ok((load.1 - load.0, phases, output))
}

fn parse(args: &[String]) -> Result<Parameters, Box<dyn Error>> {
    if args.len() != 13 {
        return Err("expected: MODE KIND WORKERS GROUPS VALUES DUPLICATES PLACEMENT \
                    WARMUP LAT_TOUCHED LAT_ROUNDS THR_TOUCHED THR_ROUNDS"
            .into());
    }
    let mode = MODES
        .iter()
        .find(|(name, _)| *name == args[1])
        .map(|(_, mode)| *mode)
        .ok_or("unknown mode")?;
    let kind = match args[2].as_str() {
        "min" => Kind::Min,
        "max" => Kind::Max,
        "sum" => Kind::Sum,
        "count" => Kind::Count,
        _ => return Err("unknown aggregation".into()),
    };
    let placement = match args[7].as_str() {
        "local" => Placement::Local,
        "spread" => Placement::Spread,
        _ => return Err("unknown placement".into()),
    };
    let parameters = Parameters {
        mode,
        kind,
        workers: args[3].parse()?,
        groups: args[4].parse()?,
        values: args[5].parse()?,
        duplicates: args[6].parse()?,
        placement,
        warmup: args[8].parse()?,
        latency: (args[9].parse()?, args[10].parse()?),
        throughput: (args[11].parse()?, args[12].parse()?),
    };
    if !mode.supports(kind) {
        return Err("this design does not support this aggregation".into());
    }
    let phase_ok = |(touched, rounds): (u32, u32)| {
        rounds % 2 == 0 && (rounds == 0 || (1..=parameters.groups).contains(&touched))
    };
    if parameters.workers == 0
        || parameters.groups == 0
        || parameters.values < 2
        || parameters.duplicates == 0
        || parameters.duplicates > 255
        || parameters.warmup % 2 == 1
        || !phase_ok(parameters.latency)
        || !phase_ok(parameters.throughput)
        || (mode.incremental() && parameters.latency.1 + parameters.throughput.1 == 0)
    {
        return Err("invalid workload dimensions".into());
    }
    Ok(parameters)
}

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args().collect();
    let parameters = parse(&args)?;
    if parameters.mode.incremental() {
        let (load, seconds, mut actual) = run_incremental(parameters)?;
        let mut expected = parameters.expected_incremental();
        consolidate_updates(&mut actual);
        consolidate_updates(&mut expected);
        if actual != expected {
            return Err(format!("output mismatch: {} vs {} updates", actual.len(), expected.len()).into());
        }
        let phases: Vec<String> = parameters
            .phases()
            .iter()
            .zip(seconds)
            .map(|(phase, seconds)| {
                format!(
                    "\"{}\":{{\"seconds\":{seconds:.9},\"rounds\":{},\"touched\":{}}}",
                    phase.name, phase.rounds, phase.touched
                )
            })
            .collect();
        println!(
            "{{\"load_s\":{load:.9},\"phases\":{{{}}},\"verified\":true,\"checked_updates\":{}}}",
            phases.join(","),
            actual.len()
        );
    } else {
        let (load, mut actual) = run_batch(parameters)?;
        let base = parameters.kind.fold(parameters.values, &[]);
        let mut expected: Vec<(Row, (), Present)> =
            (0..parameters.groups).map(|g| ((g, base), (), Present)).collect();
        let emitted = actual.len();
        consolidate_updates(&mut actual);
        consolidate_updates(&mut expected);
        if actual != expected || emitted != expected.len() {
            return Err(format!("output mismatch: {emitted} vs {} updates", expected.len()).into());
        }
        println!("{{\"load_s\":{load:.9},\"phases\":{{}},\"verified\":true,\"checked_updates\":{emitted}}}");
    }
    Ok(())
}
