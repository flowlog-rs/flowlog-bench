//! Check the tactic directly, independently of the dataflow scheduler:
//! weighted bags, incomparable times, and missing/exhausted batch cursors.

use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::rc::Rc;

use differential_dataflow::consolidation::{ConsolidatingContainerBuilder, consolidate_updates};
use differential_dataflow::operators::join::{Fresh, JoinTactic};
use differential_dataflow::trace::Builder;
use differential_dataflow::trace::description::Description;
use differential_dataflow::trace::implementations::Vector;
use differential_dataflow::trace::implementations::ord_neu::{OrdValBatch, OrdValBuilder};
use rangejoin_toy::range_join::RangeTactic;
use rangejoin_toy::seek_join::{SeekTactic, Strategy};
use timely::container::PushInto;
use timely::order::Product;
use timely::progress::Antichain;

type Time = Product<u64, u64>;
type Value = (i64, i64);
type Update = ((i32, Value), Time, isize);
type Batch = Rc<OrdValBatch<Vector<Update>>>;
type Row = (i32, i64, i64);
type Output = (Row, Time, isize);
type OutputBuilder = ConsolidatingContainerBuilder<Vec<Output>>;

fn batch(mut updates: Vec<Update>) -> Batch {
    consolidate_updates(&mut updates);
    let minimum = Time::new(0, 0);
    Rc::new(OrdValBuilder::<Vector<Update>, Vec<Update>>::seal(
        &mut vec![updates],
        Description::new(
            Antichain::from_elem(minimum),
            Antichain::new(),
            Antichain::from_elem(minimum),
        ),
    ))
}

fn emit(
    k: &i32,
    l: &Value,
    r: &Value,
    time: Time,
    ld: &isize,
    rd: &isize,
    out: &mut OutputBuilder,
) {
    // Project away payloads so distinct pairs can contribute to the same row.
    if r.1 % 3 != 1 {
        out.push_into(((*k, l.0, r.0), time, ld * rd));
    }
}

fn totals(updates: impl IntoIterator<Item = Output>) -> BTreeMap<(Row, Time), isize> {
    let mut result = BTreeMap::new();
    for (row, time, diff) in updates {
        *result.entry((row, time)).or_default() += diff;
    }
    result.retain(|_, diff| *diff != 0);
    result
}

#[test]
fn all_tactics_match_weighted_oracle_at_incomparable_times() {
    let width = 7;
    let update = |k, value, payload, outer, inner, diff| {
        ((k, (value, payload)), Time::new(outer, inner), diff)
    };
    let left = vec![
        vec![
            update(0, -3, -3 + width, 0, 2, 2),
            update(2, 4, 4 + width, 3, 0, 3),
            update(4, 9, 9 + width, 0, 0, -1),
        ],
        vec![],
        vec![
            update(0, -3, -3 + width, 2, 0, -1),
            update(0, 0, width, 1, 5, 3),
            update(2, 4, 4 + width, 0, 1, -1),
        ],
    ];
    let right = vec![
        vec![],
        vec![
            update(0, -3, 0, 2, 0, 3),
            update(0, -2, 0, 0, 3, 2),
            update(0, 4, 0, 1, 1, 1),
            update(1, 2, 0, 0, 0, 1),
            update(2, 11, 0, 0, 0, 4),
        ],
        vec![
            update(0, -2, 0, 0, 0, -1),
            update(0, -2, 2, 4, 1, 2),
            update(0, 7, 1, 0, 0, 5),
            update(2, 5, 0, 0, 4, 3),
            update(5, 12, 0, 0, 0, 1),
        ],
    ];
    for left_fresh in [true, false] {
        let meet = Time::new(1, 1);
        let mut left = left.clone();
        let mut right = right.clone();
        // Respect prep's contract: fresh times are >= meet. The accumulated
        // side retains old and incomparable times that must be advanced.
        for (_, time, _) in if left_fresh { &mut left } else { &mut right }
            .iter_mut()
            .flatten()
        {
            time.outer = time.outer.max(meet.outer);
            time.inner = time.inner.max(meet.inner);
        }
        for lower_closed in [false, true] {
            for upper_closed in [false, true] {
                let mut expected = Vec::new();
                for &((k, (lo, hi)), lt, ld) in left.iter().flatten() {
                    for &((rk, (y, payload)), rt, rd) in right.iter().flatten() {
                        if k == rk
                            && (lo < y || (lower_closed && lo == y))
                            && (y < hi || (upper_closed && y == hi))
                            && payload % 3 != 1
                        {
                            expected.push((
                                (k, lo, y),
                                Time::new(lt.outer.max(rt.outer), lt.inner.max(rt.inner)),
                                ld * rd,
                            ));
                        }
                    }
                }
                let expected = totals(expected);
                assert!(!expected.is_empty());
                for strategy in [
                    None,
                    Some(Strategy::Merge),
                    Some(Strategy::Seek),
                    Some(Strategy::SeekBack),
                    Some(Strategy::Auto),
                ] {
                    let left: Vec<_> = left.iter().cloned().map(batch).collect();
                    let right: Vec<_> = right.iter().cloned().map(batch).collect();
                    let locate = move |_: &i32, l: &Value, r: &Value| {
                        if r.0 < l.0 || (!lower_closed && r.0 == l.0) {
                            Ordering::Less
                        } else if r.0 > l.1 || (!upper_closed && r.0 == l.1) {
                            Ordering::Greater
                        } else {
                            Ordering::Equal
                        }
                    };
                    let fresh = if left_fresh {
                        Fresh::Input0
                    } else {
                        Fresh::Input1
                    };
                    let output = match strategy {
                        None => RangeTactic::<Batch, Batch, _, _, OutputBuilder>::new(locate, emit)
                            .prep(left, right, fresh, meet),
                        Some(strategy) => {
                            SeekTactic::<Batch, Batch, _, _, _, _, OutputBuilder>::new(
                                locate,
                                |_: &i32, l: &Value| (l.0, i64::MIN),
                                Some(move |_: &i32, r: &Value| (r.0 - width - 1, i64::MIN)),
                                strategy,
                                emit,
                            )
                            .prep(left, right, fresh, meet)
                        }
                    };
                    assert_eq!(
                        totals(output.flatten()),
                        expected,
                        "{strategy:?}, left_fresh={left_fresh}, closed=({lower_closed},{upper_closed})",
                    );
                }
            }
        }
    }
}

#[test]
fn empty_batch_lists_produce_no_output() {
    let populated = batch(vec![((0, (1, 8)), Time::new(0, 0), 1)]);
    for (left, right) in [(vec![], vec![populated.clone()]), (vec![populated], vec![])] {
        for strategy in [
            Strategy::Merge,
            Strategy::Seek,
            Strategy::SeekBack,
            Strategy::Auto,
        ] {
            let mut tactic = SeekTactic::<Batch, Batch, _, _, _, _, OutputBuilder>::new(
                |_: &i32, _: &Value, _: &Value| Ordering::Equal,
                |_: &i32, _: &Value| (i64::MIN, i64::MIN),
                Some(|_: &i32, _: &Value| (i64::MIN, i64::MIN)),
                strategy,
                emit,
            );
            assert_eq!(
                tactic
                    .prep(left.clone(), right.clone(), Fresh::Input0, Time::new(0, 0))
                    .flatten()
                    .count(),
                0
            );
        }
    }
}
