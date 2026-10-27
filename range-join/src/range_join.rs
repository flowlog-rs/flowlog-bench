//! A range join: an equijoin whose matches under each key are further
//! restricted to one contiguous run of the right-hand arrangement.
//!
//! Arrangements keep each key's values sorted. When a join also carries
//! inequalities between a left column and the *leading* right value column
//! (`l.a < r.0`, `r.0 <= l.b`, ...), the right values that satisfy them for
//! a fixed left value form a single run of that sorted order. The tactic
//! flattens the right key group, then finds each run by exponential search.
//! With one update per value, arbitrary left bounds cost
//! `O(|R_k| + |L_k| * log(|R_k| + 1) + matching_pairs)`. Monotone run starts
//! amortize the searches to a linear scan. Multiple timestamp histories
//! and residual filters add work; final output cardinality alone does not
//! describe that cost.

use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::VecDeque;
use std::marker::PhantomData;
use std::rc::Rc;

use differential_dataflow::AsCollection;
use differential_dataflow::Data;
use differential_dataflow::VecCollection;
use differential_dataflow::consolidation::ConsolidatingContainerBuilder;
use differential_dataflow::consolidation::consolidate;
use differential_dataflow::difference::Multiply;
use differential_dataflow::difference::Semigroup;
use differential_dataflow::lattice::Lattice;
use differential_dataflow::operators::arrange::Arranged;
use differential_dataflow::operators::join::Fresh;
use differential_dataflow::operators::join::JoinTactic;
use differential_dataflow::operators::join::join_with_tactic;
use differential_dataflow::trace::BatchCursor;
use differential_dataflow::trace::BatchReader;
use differential_dataflow::trace::BatchVal;
use differential_dataflow::trace::Cursor;
use differential_dataflow::trace::Navigable;
use differential_dataflow::trace::TraceReader;
use differential_dataflow::trace::cursor::cursor_list;
use differential_dataflow::trace::implementations::containers::BatchContainer;
use timely::ContainerBuilder;
use timely::container::PushInto;
use timely::progress::Timestamp;

use crate::gallop::partition_point_from;

/// Joins two arrangements on their shared key, pairing each left value
/// only with the run of right values that `locate` places inside its range.
///
/// `locate(key, left, right)` reports where `right` sits relative to the
/// range of `left`: `Less` below it, `Equal` inside it, `Greater` above it.
/// For a fixed key and left value it must be monotone over the right values
/// in arrangement order (`Less*`, `Equal*`, `Greater*`). Inequalities that
/// compare the leading right value column against left columns meet this
/// by construction; anything else belongs in `result`, which filters and
/// projects each in-range pair exactly as the closure of `flowlog_join`.
pub fn range_join<'scope, Tr1, Tr2, I, P, L, R1, R2, KC>(
    arranged1: Arranged<'scope, Tr1>,
    arranged2: Arranged<'scope, Tr2>,
    locate: P,
    mut result: L,
) -> VecCollection<'scope, Tr1::Time, I::Item, <R1 as Multiply<R2>>::Output>
where
    Tr1: TraceReader<Batch: Navigable> + 'static,
    Tr2: TraceReader<Batch: Navigable, Time = Tr1::Time> + 'static,
    BatchCursor<Tr1>: Cursor<Diff = R1, Time = Tr1::Time, KeyContainer = KC>,
    BatchCursor<Tr2>: Cursor<Diff = R2, Time = Tr1::Time>,
    KC: BatchContainer,
    for<'a> BatchCursor<Tr1>: Cursor<Key<'a> = KC::ReadItem<'a>>,
    for<'a> BatchCursor<Tr2>: Cursor<Key<'a> = KC::ReadItem<'a>>,
    R1: Multiply<R2, Output: Semigroup + 'static> + Clone,
    I: IntoIterator<Item: Data>,
    P: for<'a> Fn(KC::ReadItem<'a>, BatchVal<'a, Tr1>, BatchVal<'a, Tr2>) -> Ordering + 'static,
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
    let tactic = RangeTactic::<Tr1::Batch, Tr2::Batch, _, _, _>::new(locate, logic);
    join_with_tactic(arranged1, arranged2, tactic).as_collection()
}

/// The [`JoinTactic`] behind [`range_join`].
///
/// It mirrors differential's cursor tactic (merge the two key streams,
/// consolidate each value's history, advance the accumulated side to
/// `meet`) and differs only in which value pairs it visits.
pub struct RangeTactic<B0, B1, P, L, CB> {
    locate: Rc<P>,
    logic: Rc<RefCell<L>>,
    _marker: PhantomData<(B0, B1, CB)>,
}

impl<B0, B1, P, L, CB> RangeTactic<B0, B1, P, L, CB> {
    /// A tactic that applies `logic` to every pair `locate` puts in range.
    pub fn new(locate: P, logic: L) -> Self {
        RangeTactic {
            locate: Rc::new(locate),
            logic: Rc::new(RefCell::new(logic)),
            _marker: PhantomData,
        }
    }
}

impl<B0, B1, P, L, CB> JoinTactic<B0, B1, CB::Container> for RangeTactic<B0, B1, P, L, CB>
where
    B0: BatchReader + Navigable + 'static,
    B1: BatchReader<Time = B0::Time> + Navigable + 'static,
    B0::Cursor: Cursor<Time = B0::Time>,
    B1::Cursor: for<'a> Cursor<Key<'a> = <B0::Cursor as Cursor>::Key<'a>, Time = B0::Time>,
    CB: ContainerBuilder<Container: Default> + 'static,
    P: for<'a> Fn(
            <B0::Cursor as Cursor>::Key<'a>,
            <B0::Cursor as Cursor>::Val<'a>,
            <B1::Cursor as Cursor>::Val<'a>,
        ) -> Ordering
        + 'static,
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
        let (cursor1, storage1) = cursor_list(input0);
        let (cursor2, storage2) = cursor_list(input1);
        Box::new(RangeIter::new(
            (cursor1, storage1),
            (cursor2, storage2),
            fresh,
            meet,
            Rc::clone(&self.locate),
            Rc::clone(&self.logic),
        ))
    }
}

/// One deferred unit of range-join work, yielding output containers.
pub(crate) struct RangeIter<T, C1, C2, P, L, CB>
where
    T: Timestamp + Lattice,
    C1: Cursor<Time = T>,
    C2: for<'a> Cursor<Key<'a> = C1::Key<'a>, Time = T>,
    CB: ContainerBuilder,
{
    cursor1: C1,
    storage1: C1::Storage,
    cursor2: C2,
    storage2: C2::Storage,
    meet: T,
    advance1: bool,
    advance2: bool,
    locate: Rc<P>,
    logic: Rc<RefCell<L>>,
    builder: CB,
    ready: VecDeque<CB::Container>,
    edits1: Vec<(T, C1::Diff)>,
    edits2: Vec<(T, C2::Diff)>,
    done: bool,
}

impl<T, C1, C2, P, L, CB> RangeIter<T, C1, C2, P, L, CB>
where
    T: Timestamp + Lattice,
    C1: Cursor<Time = T>,
    C2: for<'a> Cursor<Key<'a> = C1::Key<'a>, Time = T>,
    CB: ContainerBuilder,
{
    /// Joins the batches behind `input1` and `input2`, advancing the
    /// accumulated (non-`fresh`) side's times by `meet`.
    pub(crate) fn new(
        input1: (C1, C1::Storage),
        input2: (C2, C2::Storage),
        fresh: Fresh,
        meet: T,
        locate: Rc<P>,
        logic: Rc<RefCell<L>>,
    ) -> Self {
        let (advance1, advance2) = match fresh {
            Fresh::Input0 => (false, true),
            Fresh::Input1 => (true, false),
        };
        RangeIter {
            cursor1: input1.0,
            storage1: input1.1,
            cursor2: input2.0,
            storage2: input2.1,
            meet,
            advance1,
            advance2,
            locate,
            logic,
            builder: CB::default(),
            ready: VecDeque::new(),
            edits1: Vec::new(),
            edits2: Vec::new(),
            done: false,
        }
    }
}

impl<T, C1, C2, P, L, CB> Iterator for RangeIter<T, C1, C2, P, L, CB>
where
    T: Timestamp + Lattice,
    C1: Cursor<Time = T>,
    C2: for<'a> Cursor<Key<'a> = C1::Key<'a>, Time = T>,
    CB: ContainerBuilder<Container: Default>,
    P: for<'a> Fn(C1::Key<'a>, C1::Val<'a>, C2::Val<'a>) -> Ordering,
    L: for<'a> FnMut(C1::Key<'a>, C1::Val<'a>, C2::Val<'a>, T, &C1::Diff, &C2::Diff, &mut CB),
{
    type Item = CB::Container;

    /// Plays the join forward one key at a time until a container is ready.
    fn next(&mut self) -> Option<CB::Container> {
        if let Some(container) = self.ready.pop_front() {
            return Some(container);
        }
        if self.done {
            return None;
        }

        let meet1 = self.advance1.then_some(&self.meet);
        let meet2 = self.advance2.then_some(&self.meet);
        let storage1 = &self.storage1;
        let storage2 = &self.storage2;
        let cursor1 = &mut self.cursor1;
        let cursor2 = &mut self.cursor2;
        let edits1 = &mut self.edits1;
        let edits2 = &mut self.edits2;
        let builder = &mut self.builder;
        let ready = &mut self.ready;
        let locate = &*self.locate;
        let mut logic = self.logic.borrow_mut();
        let logic = &mut *logic;

        // The current key's right edits, consolidated per value and laid
        // out flat in value order, so a run is one contiguous slice.
        let mut flat2: Vec<(C2::Val<'_>, T, C2::Diff)> = Vec::new();
        let mut exhausted = false;

        while ready.is_empty() {
            match (cursor1.get_key(storage1), cursor2.get_key(storage2)) {
                (Some(key1), Some(key2)) => match key1.cmp(&key2) {
                    Ordering::Less => cursor1.seek_key(storage1, key2),
                    Ordering::Greater => cursor2.seek_key(storage2, key1),
                    Ordering::Equal => {
                        load_flat(cursor2, storage2, meet2, &mut flat2, edits2);
                        // Where the previous left value's run began; runs of
                        // sorted left values usually start at or after it.
                        let mut hint = 0;
                        while !flat2.is_empty()
                            && let Some(val1) = cursor1.get_val(storage1)
                        {
                            load_edits(cursor1, storage1, meet1, edits1);
                            if !edits1.is_empty() {
                                let start = partition_point_from(&flat2, hint, |edit| {
                                    locate(key1, val1, edit.0) == Ordering::Less
                                });
                                let end = partition_point_from(&flat2, start, |edit| {
                                    locate(key1, val1, edit.0) != Ordering::Greater
                                });
                                hint = start;
                                for (val2, time2, diff2) in &flat2[start..end] {
                                    for (time1, diff1) in edits1.iter() {
                                        logic(
                                            key1,
                                            val1,
                                            *val2,
                                            time1.join(time2),
                                            diff1,
                                            diff2,
                                            builder,
                                        );
                                    }
                                }
                            }
                            cursor1.step_val(storage1);
                        }
                        cursor1.step_key(storage1);
                        cursor2.step_key(storage2);
                        flat2.clear();
                        while let Some(container) = builder.extract() {
                            ready.push_back(std::mem::take(container));
                        }
                    }
                },
                _ => {
                    exhausted = true;
                    break;
                }
            }
        }

        if exhausted {
            self.done = true;
            while let Some(container) = builder.finish() {
                ready.push_back(std::mem::take(container));
            }
        }
        ready.pop_front()
    }
}

/// Appends the edits at the cursor's key to `flat`, consolidating each
/// value's edits (advanced by `meet`, if any) so cancelled values vanish.
fn load_flat<'a, C: Cursor>(
    cursor: &mut C,
    storage: &'a C::Storage,
    meet: Option<&C::Time>,
    flat: &mut Vec<(C::Val<'a>, C::Time, C::Diff)>,
    scratch: &mut Vec<(C::Time, C::Diff)>,
) {
    while let Some(val) = cursor.get_val(storage) {
        load_edits(cursor, storage, meet, scratch);
        flat.extend(scratch.drain(..).map(|(time, diff)| (val, time, diff)));
        cursor.step_val(storage);
    }
}

/// Replaces `edits` with the consolidated edits of the cursor's value.
pub(crate) fn load_edits<C: Cursor>(
    cursor: &mut C,
    storage: &C::Storage,
    meet: Option<&C::Time>,
    edits: &mut Vec<(C::Time, C::Diff)>,
) {
    edits.clear();
    cursor.map_times(storage, |time, diff| {
        let mut time = C::owned_time(time);
        if let Some(meet) = meet {
            time.join_assign(meet);
        }
        edits.push((time, C::owned_diff(diff)));
    });
    consolidate(edits);
}
