//! A range join that can seek runs in one arrangement instead of reading
//! whole key groups.
//!
//! [`range_join`](crate::range_join) merges: it reads every right value
//! under a matching key, `O(|L_k| + |R_k| + output)`. That suits batch
//! evaluation, where both sides are large, but not incremental or
//! recursive evaluation, where a small fresh batch meets a large
//! accumulated trace and every round would pay for the whole key group.
//! Seeking instead searches for each left value's run with the cursor's
//! `seek_val`, an exponential search over the sorted batch, for
//! `O(|L_k| * log |R_k| + output)`. Seeking back is the mirror image: it
//! searches the left values whose ranges hold each right value, for
//! `O(|R_k| * log |L_k| + output)`, and serves a small fresh batch on the
//! right. Each unit of work picks one plan from its batch sizes, the choice
//! an optimizer makes between a merge join and an index nested-loop join
//! into either input.
//!
//! Seeking needs somewhere to seek to: `lower(key, left)` names a right
//! value at or below the start of `left`'s run. Seeking back needs
//! `lower_back(key, right)`, a left value at or below the first left value
//! whose range reaches `right`, and ranges that rise with the left values:
//! for each right value, `locate` must answer `Greater`, then `Equal`, then
//! `Less` across a key's left values. Ranges of constant width do; arbitrary
//! intervals do not, and must not seek back. Values must be read as `&V1`
//! and `&V2` (true of vector-backed arrangements, entered or not) so that
//! owned values can serve as probes.

use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::VecDeque;
use std::marker::PhantomData;
use std::rc::Rc;

use differential_dataflow::AsCollection;
use differential_dataflow::Data;
use differential_dataflow::VecCollection;
use differential_dataflow::consolidation::ConsolidatingContainerBuilder;
use differential_dataflow::difference::Multiply;
use differential_dataflow::difference::Semigroup;
use differential_dataflow::lattice::Lattice;
use differential_dataflow::operators::arrange::Arranged;
use differential_dataflow::operators::join::Fresh;
use differential_dataflow::operators::join::JoinTactic;
use differential_dataflow::operators::join::join_with_tactic;
use differential_dataflow::trace::BatchCursor;
use differential_dataflow::trace::BatchKey;
use differential_dataflow::trace::BatchReader;
use differential_dataflow::trace::BatchVal;
use differential_dataflow::trace::Cursor;
use differential_dataflow::trace::Navigable;
use differential_dataflow::trace::TraceReader;
use differential_dataflow::trace::cursor::cursor_list;
use differential_dataflow::trace::implementations::BatchContainer;
use timely::ContainerBuilder;
use timely::container::PushInto;
use timely::progress::Timestamp;

use crate::range_join::RangeIter;
use crate::range_join::load_edits;

/// How a unit of range-join work finds the pairs in range.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Strategy {
    /// Read each matching key group once, as [`range_join`](crate::range_join).
    Merge,
    /// Seek each left value's run in the right batches.
    Seek,
    /// Seek each right value's run in the left batches.
    SeekBack,
    /// Pick the cheapest available plan from the batch sizes.
    Auto,
}

/// [`range_join`](crate::range_join) that may seek, per `strategy`, but
/// not seek back.
///
/// `locate` and `result` have the same contract as for `range_join`.
/// `lower(key, left)` must not exceed the first right value that `locate`
/// does not place below `left`'s range.
pub fn seek_range_join<'scope, Tr1, Tr2, I, P, F, L, R1, R2, KC, V1, V2>(
    arranged1: Arranged<'scope, Tr1>,
    arranged2: Arranged<'scope, Tr2>,
    locate: P,
    lower: F,
    strategy: Strategy,
    result: L,
) -> VecCollection<'scope, Tr1::Time, I::Item, <R1 as Multiply<R2>>::Output>
where
    Tr1: TraceReader<Batch: Navigable> + 'static,
    Tr2: TraceReader<Batch: Navigable, Time = Tr1::Time> + 'static,
    BatchCursor<Tr1>: Cursor<Diff = R1, Time = Tr1::Time, KeyContainer = KC>,
    BatchCursor<Tr2>: Cursor<Diff = R2, Time = Tr1::Time>,
    KC: BatchContainer,
    for<'a> BatchCursor<Tr1>: Cursor<Key<'a> = KC::ReadItem<'a>, Val<'a> = &'a V1>,
    for<'a> BatchCursor<Tr2>: Cursor<Key<'a> = KC::ReadItem<'a>, Val<'a> = &'a V2>,
    V1: 'static,
    V2: 'static,
    R1: Multiply<R2, Output: Semigroup + 'static> + Clone,
    I: IntoIterator<Item: Data>,
    P: for<'a> Fn(KC::ReadItem<'a>, BatchVal<'a, Tr1>, BatchVal<'a, Tr2>) -> Ordering + 'static,
    F: for<'a> Fn(KC::ReadItem<'a>, BatchVal<'a, Tr1>) -> V2 + 'static,
    L: FnMut(KC::ReadItem<'_>, BatchVal<'_, Tr1>, BatchVal<'_, Tr2>) -> I + 'static,
{
    assert!(strategy != Strategy::SeekBack, "seeking back needs `lower_back`");
    join(arranged1, arranged2, locate, lower, None::<NoLowerBack<Tr1, Tr2, V1>>, strategy, result)
}

/// The type of the `lower_back` that [`seek_range_join`] never has.
type NoLowerBack<Tr1, Tr2, V1> = for<'a> fn(BatchKey<'a, Tr1>, BatchVal<'a, Tr2>) -> V1;

/// [`seek_range_join`] that may also seek back.
///
/// `lower_back(key, right)` must not exceed the first left value that
/// `locate` does not place wholly below `right`, and `locate` must answer
/// `Greater`, then `Equal`, then `Less` across each key's left values.
#[allow(clippy::too_many_arguments)]
pub fn seek_range_join_both<'scope, Tr1, Tr2, I, P, F, G, L, R1, R2, KC, V1, V2>(
    arranged1: Arranged<'scope, Tr1>,
    arranged2: Arranged<'scope, Tr2>,
    locate: P,
    lower: F,
    lower_back: G,
    strategy: Strategy,
    result: L,
) -> VecCollection<'scope, Tr1::Time, I::Item, <R1 as Multiply<R2>>::Output>
where
    Tr1: TraceReader<Batch: Navigable> + 'static,
    Tr2: TraceReader<Batch: Navigable, Time = Tr1::Time> + 'static,
    BatchCursor<Tr1>: Cursor<Diff = R1, Time = Tr1::Time, KeyContainer = KC>,
    BatchCursor<Tr2>: Cursor<Diff = R2, Time = Tr1::Time>,
    KC: BatchContainer,
    for<'a> BatchCursor<Tr1>: Cursor<Key<'a> = KC::ReadItem<'a>, Val<'a> = &'a V1>,
    for<'a> BatchCursor<Tr2>: Cursor<Key<'a> = KC::ReadItem<'a>, Val<'a> = &'a V2>,
    V1: 'static,
    V2: 'static,
    R1: Multiply<R2, Output: Semigroup + 'static> + Clone,
    I: IntoIterator<Item: Data>,
    P: for<'a> Fn(KC::ReadItem<'a>, BatchVal<'a, Tr1>, BatchVal<'a, Tr2>) -> Ordering + 'static,
    F: for<'a> Fn(KC::ReadItem<'a>, BatchVal<'a, Tr1>) -> V2 + 'static,
    G: for<'a> Fn(KC::ReadItem<'a>, BatchVal<'a, Tr2>) -> V1 + 'static,
    L: FnMut(KC::ReadItem<'_>, BatchVal<'_, Tr1>, BatchVal<'_, Tr2>) -> I + 'static,
{
    join(arranged1, arranged2, locate, lower, Some(lower_back), strategy, result)
}

#[allow(clippy::too_many_arguments)]
fn join<'scope, Tr1, Tr2, I, P, F, G, L, R1, R2, KC, V1, V2>(
    arranged1: Arranged<'scope, Tr1>,
    arranged2: Arranged<'scope, Tr2>,
    locate: P,
    lower: F,
    lower_back: Option<G>,
    strategy: Strategy,
    mut result: L,
) -> VecCollection<'scope, Tr1::Time, I::Item, <R1 as Multiply<R2>>::Output>
where
    Tr1: TraceReader<Batch: Navigable> + 'static,
    Tr2: TraceReader<Batch: Navigable, Time = Tr1::Time> + 'static,
    BatchCursor<Tr1>: Cursor<Diff = R1, Time = Tr1::Time, KeyContainer = KC>,
    BatchCursor<Tr2>: Cursor<Diff = R2, Time = Tr1::Time>,
    KC: BatchContainer,
    for<'a> BatchCursor<Tr1>: Cursor<Key<'a> = KC::ReadItem<'a>, Val<'a> = &'a V1>,
    for<'a> BatchCursor<Tr2>: Cursor<Key<'a> = KC::ReadItem<'a>, Val<'a> = &'a V2>,
    V1: 'static,
    V2: 'static,
    R1: Multiply<R2, Output: Semigroup + 'static> + Clone,
    I: IntoIterator<Item: Data>,
    P: for<'a> Fn(KC::ReadItem<'a>, BatchVal<'a, Tr1>, BatchVal<'a, Tr2>) -> Ordering + 'static,
    F: for<'a> Fn(KC::ReadItem<'a>, BatchVal<'a, Tr1>) -> V2 + 'static,
    G: for<'a> Fn(BatchKey<'a, Tr1>, BatchVal<'a, Tr2>) -> V1 + 'static,
    L: FnMut(KC::ReadItem<'_>, BatchVal<'_, Tr1>, BatchVal<'_, Tr2>) -> I + 'static,
{
    let logic = move |key: KC::ReadItem<'_>,
                      left: BatchVal<'_, Tr1>,
                      right: BatchVal<'_, Tr2>,
                      time: Tr1::Time,
                      left_diff: &R1,
                      right_diff: &R2,
                      output: &mut ConsolidatingContainerBuilder<Vec<_>>| {
        let diff = left_diff.clone().multiply(right_diff);
        for datum in result(key, left, right) {
            output.push_into((datum, time.clone(), diff.clone()));
        }
    };
    let tactic = SeekTactic::<Tr1::Batch, Tr2::Batch, _, _, _, _, _>::new(locate, lower, lower_back, strategy, logic);
    join_with_tactic(arranged1, arranged2, tactic).as_collection()
}

/// The [`JoinTactic`] behind [`seek_range_join`] and [`seek_range_join_both`].
pub struct SeekTactic<B0, B1, P, F, G, L, CB> {
    locate: Rc<P>,
    lower: Rc<F>,
    lower_back: Option<Rc<G>>,
    strategy: Strategy,
    logic: Rc<RefCell<L>>,
    _marker: PhantomData<(B0, B1, CB)>,
}

impl<B0, B1, P, F, G, L, CB> SeekTactic<B0, B1, P, F, G, L, CB> {
    /// A tactic that applies `logic` to every pair `locate` puts in range,
    /// seeking back only if given `lower_back`.
    pub fn new(locate: P, lower: F, lower_back: Option<G>, strategy: Strategy, logic: L) -> Self {
        assert!(
            strategy != Strategy::SeekBack || lower_back.is_some(),
            "seeking back needs `lower_back`"
        );
        SeekTactic {
            locate: Rc::new(locate),
            lower: Rc::new(lower),
            lower_back: lower_back.map(Rc::new),
            strategy,
            logic: Rc::new(RefCell::new(logic)),
            _marker: PhantomData,
        }
    }
}

impl<B0, B1, V1, V2, P, F, G, L, CB> JoinTactic<B0, B1, CB::Container> for SeekTactic<B0, B1, P, F, G, L, CB>
where
    B0: BatchReader + Navigable + 'static,
    B1: BatchReader<Time = B0::Time> + Navigable + 'static,
    B0::Cursor: for<'a> Cursor<Val<'a> = &'a V1, Time = B0::Time>,
    B1::Cursor: for<'a> Cursor<Key<'a> = <B0::Cursor as Cursor>::Key<'a>, Val<'a> = &'a V2, Time = B0::Time>,
    V1: 'static,
    V2: 'static,
    CB: ContainerBuilder<Container: Default> + 'static,
    P: for<'a> Fn(
            <B0::Cursor as Cursor>::Key<'a>,
            <B0::Cursor as Cursor>::Val<'a>,
            <B1::Cursor as Cursor>::Val<'a>,
        ) -> Ordering
        + 'static,
    F: for<'a> Fn(<B0::Cursor as Cursor>::Key<'a>, <B0::Cursor as Cursor>::Val<'a>) -> V2 + 'static,
    G: for<'a> Fn(<B0::Cursor as Cursor>::Key<'a>, <B1::Cursor as Cursor>::Val<'a>) -> V1 + 'static,
    L: for<'a> FnMut(
            <B0::Cursor as Cursor>::Key<'a>,
            <B0::Cursor as Cursor>::Val<'a>,
            <B1::Cursor as Cursor>::Val<'a>,
            B0::Time,
            &<B0::Cursor as Cursor>::Diff,
            &<B1::Cursor as Cursor>::Diff,
            &mut CB,
        ) + 'static,
{
    fn prep(
        &mut self,
        input0: Vec<B0>,
        input1: Vec<B1>,
        fresh: Fresh,
        meet: B0::Time,
    ) -> Box<dyn Iterator<Item = CB::Container>> {
        let plan = match self.strategy {
            Strategy::Auto => {
                let left: usize = input0.iter().map(BatchReader::len).sum();
                let right: usize = input1.iter().map(BatchReader::len).sum();
                // A merge reads both sides; a seek searches every batch on
                // the other side once per value on its own side.
                let search = |len: usize, batches: usize| (usize::BITS - len.leading_zeros()) as usize * batches;
                let merge = left + right;
                let seek = left.saturating_mul(search(right, input1.len()));
                let back = match self.lower_back {
                    Some(_) => right.saturating_mul(search(left, input0.len())),
                    None => usize::MAX,
                };
                if merge <= seek.min(back) {
                    Strategy::Merge
                } else if seek <= back {
                    Strategy::Seek
                } else {
                    Strategy::SeekBack
                }
            }
            fixed => fixed,
        };
        let (locate, logic) = (Rc::clone(&self.locate), Rc::clone(&self.logic));
        let lower_back = match plan {
            Strategy::Seek => None,
            Strategy::SeekBack => self.lower_back.clone(),
            _ => {
                let (left, right) = (cursor_list(input0), cursor_list(input1));
                return Box::new(RangeIter::new(left, right, fresh, meet, locate, logic));
            }
        };
        let (advance1, advance2) = match fresh {
            Fresh::Input0 => (false, true),
            Fresh::Input1 => (true, false),
        };
        Box::new(SeekIter {
            cursors1: input0.iter().map(Navigable::cursor).collect(),
            batches1: input0,
            cursors2: input1.iter().map(Navigable::cursor).collect(),
            batches2: input1,
            outer: 0,
            meet,
            advance1,
            advance2,
            locate,
            lower: Rc::clone(&self.lower),
            lower_back,
            logic,
            builder: CB::default(),
            ready: VecDeque::new(),
            edits1: Vec::new(),
            edits2: Vec::new(),
            done: false,
        })
    }
}

/// One deferred unit of range-join work that seeks runs batch by batch: in
/// the right batches for each left value or, given `lower_back`, in the
/// left batches for each right value.
///
/// Each batch keeps its own cursor. A `CursorList` would merge them, but its
/// `seek_val` also moves the cursors parked at other keys, skipping values
/// they have yet to reach (and panicking on exhausted ones).
struct SeekIter<T, B0: Navigable, B1: Navigable, P, F, G, L, CB: ContainerBuilder> {
    cursors1: Vec<B0::Cursor>,
    batches1: Vec<B0>,
    cursors2: Vec<B1::Cursor>,
    batches2: Vec<B1>,
    /// The batch, on the side being read, whose keys are being visited.
    outer: usize,
    meet: T,
    advance1: bool,
    advance2: bool,
    locate: Rc<P>,
    lower: Rc<F>,
    lower_back: Option<Rc<G>>,
    logic: Rc<RefCell<L>>,
    builder: CB,
    ready: VecDeque<CB::Container>,
    edits1: Vec<(T, <B0::Cursor as Cursor>::Diff)>,
    edits2: Vec<(T, <B1::Cursor as Cursor>::Diff)>,
    done: bool,
}

impl<T, V1, V2, B0, B1, P, F, G, L, CB> SeekIter<T, B0, B1, P, F, G, L, CB>
where
    T: Timestamp + Lattice,
    B0: Navigable<Cursor: for<'a> Cursor<Val<'a> = &'a V1, Time = T>>,
    B1: Navigable<Cursor: for<'a> Cursor<Key<'a> = <B0::Cursor as Cursor>::Key<'a>, Val<'a> = &'a V2, Time = T>>,
    V1: 'static,
    V2: 'static,
    CB: ContainerBuilder,
    P: for<'a> Fn(
        <B0::Cursor as Cursor>::Key<'a>,
        <B0::Cursor as Cursor>::Val<'a>,
        <B1::Cursor as Cursor>::Val<'a>,
    ) -> Ordering,
    F: for<'a> Fn(<B0::Cursor as Cursor>::Key<'a>, <B0::Cursor as Cursor>::Val<'a>) -> V2,
    G: for<'a> Fn(<B0::Cursor as Cursor>::Key<'a>, <B1::Cursor as Cursor>::Val<'a>) -> V1,
    L: for<'a> FnMut(
        <B0::Cursor as Cursor>::Key<'a>,
        <B0::Cursor as Cursor>::Val<'a>,
        <B1::Cursor as Cursor>::Val<'a>,
        T,
        &<B0::Cursor as Cursor>::Diff,
        &<B1::Cursor as Cursor>::Diff,
        &mut CB,
    ),
{
    /// Joins the left values under the next key of the current left batch
    /// with the runs they seek in the right batches. Returns `false` once
    /// every left batch is spent.
    fn seek_runs(&mut self) -> bool {
        let (cursors2, batches2) = (&mut self.cursors2, &self.batches2);
        let Some(cursor1) = self.cursors1.get_mut(self.outer) else { return false };
        let batch1 = &self.batches1[self.outer];
        let Some(key) = cursor1.get_key(batch1) else {
            self.outer += 1;
            for (cursor2, batch2) in cursors2.iter_mut().zip(batches2) {
                cursor2.rewind_keys(batch2);
            }
            return true;
        };
        for (cursor2, batch2) in cursors2.iter_mut().zip(batches2) {
            cursor2.seek_key(batch2, key);
        }
        let meet1 = self.advance1.then_some(&self.meet);
        let meet2 = self.advance2.then_some(&self.meet);
        let (locate, lower) = (&*self.locate, &*self.lower);
        let mut logic = self.logic.borrow_mut();
        while let Some(val1) = cursor1.get_val(batch1) {
            load_edits(cursor1, batch1, meet1, &mut self.edits1);
            if !self.edits1.is_empty() {
                let probe = lower(key, val1);
                for (cursor2, batch2) in cursors2.iter_mut().zip(batches2) {
                    if cursor2.get_key(batch2) != Some(key) {
                        continue;
                    }
                    // Seeks only move forward: restart from the key's first
                    // value unless the cursor is below the run.
                    if cursor2.get_val(batch2).is_none_or(|val2| locate(key, val1, val2) != Ordering::Less) {
                        cursor2.rewind_vals(batch2);
                    }
                    cursor2.seek_val(batch2, &probe);
                    while let Some(val2) = cursor2.get_val(batch2) {
                        match locate(key, val1, val2) {
                            Ordering::Less => {}
                            Ordering::Equal => {
                                load_edits(cursor2, batch2, meet2, &mut self.edits2);
                                for (time2, diff2) in self.edits2.iter() {
                                    for (time1, diff1) in self.edits1.iter() {
                                        logic(key, val1, val2, time1.join(time2), diff1, diff2, &mut self.builder);
                                    }
                                }
                            }
                            Ordering::Greater => break,
                        }
                        cursor2.step_val(batch2);
                    }
                }
            }
            cursor1.step_val(batch1);
        }
        cursor1.step_key(batch1);
        true
    }

    /// The mirror image of [`seek_runs`](Self::seek_runs): joins the right
    /// values under the next key of the current right batch with the runs
    /// they seek in the left batches.
    fn seek_runs_back(&mut self) -> bool {
        let (cursors1, batches1) = (&mut self.cursors1, &self.batches1);
        let Some(cursor2) = self.cursors2.get_mut(self.outer) else { return false };
        let batch2 = &self.batches2[self.outer];
        let Some(key) = cursor2.get_key(batch2) else {
            self.outer += 1;
            for (cursor1, batch1) in cursors1.iter_mut().zip(batches1) {
                cursor1.rewind_keys(batch1);
            }
            return true;
        };
        for (cursor1, batch1) in cursors1.iter_mut().zip(batches1) {
            cursor1.seek_key(batch1, key);
        }
        let meet1 = self.advance1.then_some(&self.meet);
        let meet2 = self.advance2.then_some(&self.meet);
        let locate = &*self.locate;
        let lower_back = self.lower_back.as_deref().expect("seeking back needs `lower_back`");
        let mut logic = self.logic.borrow_mut();
        while let Some(val2) = cursor2.get_val(batch2) {
            load_edits(cursor2, batch2, meet2, &mut self.edits2);
            if !self.edits2.is_empty() {
                let probe = lower_back(key, val2);
                for (cursor1, batch1) in cursors1.iter_mut().zip(batches1) {
                    if cursor1.get_key(batch1) != Some(key) {
                        continue;
                    }
                    if cursor1.get_val(batch1).is_none_or(|val1| locate(key, val1, val2) != Ordering::Greater) {
                        cursor1.rewind_vals(batch1);
                    }
                    cursor1.seek_val(batch1, &probe);
                    while let Some(val1) = cursor1.get_val(batch1) {
                        match locate(key, val1, val2) {
                            Ordering::Greater => {}
                            Ordering::Equal => {
                                load_edits(cursor1, batch1, meet1, &mut self.edits1);
                                for (time1, diff1) in self.edits1.iter() {
                                    for (time2, diff2) in self.edits2.iter() {
                                        logic(key, val1, val2, time1.join(time2), diff1, diff2, &mut self.builder);
                                    }
                                }
                            }
                            Ordering::Less => break,
                        }
                        cursor1.step_val(batch1);
                    }
                }
            }
            cursor2.step_val(batch2);
        }
        cursor2.step_key(batch2);
        true
    }
}

impl<T, V1, V2, B0, B1, P, F, G, L, CB> Iterator for SeekIter<T, B0, B1, P, F, G, L, CB>
where
    T: Timestamp + Lattice,
    B0: Navigable<Cursor: for<'a> Cursor<Val<'a> = &'a V1, Time = T>>,
    B1: Navigable<Cursor: for<'a> Cursor<Key<'a> = <B0::Cursor as Cursor>::Key<'a>, Val<'a> = &'a V2, Time = T>>,
    V1: 'static,
    V2: 'static,
    CB: ContainerBuilder<Container: Default>,
    P: for<'a> Fn(
        <B0::Cursor as Cursor>::Key<'a>,
        <B0::Cursor as Cursor>::Val<'a>,
        <B1::Cursor as Cursor>::Val<'a>,
    ) -> Ordering,
    F: for<'a> Fn(<B0::Cursor as Cursor>::Key<'a>, <B0::Cursor as Cursor>::Val<'a>) -> V2,
    G: for<'a> Fn(<B0::Cursor as Cursor>::Key<'a>, <B1::Cursor as Cursor>::Val<'a>) -> V1,
    L: for<'a> FnMut(
        <B0::Cursor as Cursor>::Key<'a>,
        <B0::Cursor as Cursor>::Val<'a>,
        <B1::Cursor as Cursor>::Val<'a>,
        T,
        &<B0::Cursor as Cursor>::Diff,
        &<B1::Cursor as Cursor>::Diff,
        &mut CB,
    ),
{
    type Item = CB::Container;

    /// Plays the join forward one key at a time until a container is ready.
    fn next(&mut self) -> Option<CB::Container> {
        loop {
            if let Some(container) = self.ready.pop_front() {
                return Some(container);
            }
            if self.done {
                return None;
            }
            let more = if self.lower_back.is_some() { self.seek_runs_back() } else { self.seek_runs() };
            if more {
                while let Some(container) = self.builder.extract() {
                    self.ready.push_back(std::mem::take(container));
                }
            } else {
                self.done = true;
                while let Some(container) = self.builder.finish() {
                    self.ready.push_back(std::mem::take(container));
                }
            }
        }
    }
}
