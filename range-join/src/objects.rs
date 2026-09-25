//! DDISASM's supplied object-conflict rule, with synthetic candidates.

use super::{
    Args, Fingerprint, Method, Outcome, Rng, Summary, Tally, Ts, locate_between, mix, points, run,
    tally,
};
use std::cmp::Ordering;
use std::sync::Arc;

use differential_dataflow::difference::Present;
use differential_dataflow::input::Input;
use flowlog_runtime::operators::flowlog_join;
use rangejoin_toy::{range_join, seek_range_join};
use timely::dataflow::operators::Inspect;

impl Fingerprint for [i64; 6] {
    fn fingerprint(&self) -> u64 {
        self.iter().fold(0, |hash, value| mix(hash ^ *value as u64))
    }
}

pub fn objects(args: &Args) -> Outcome {
    let mut rng = Rng(args.seed);
    let addresses = points(args.n.div_ceil(3), args.gap, &mut rng);
    // Multiple types at each address exercise equal leading columns and
    // payload preservation. Variable sizes deliberately produce nested ranges.
    let rows: Arc<Vec<_>> = Arc::new(
        (0..args.n)
            .map(|i| {
                (
                    addresses[i / 3],
                    1 + rng.below((2 * args.width - 1) as u64) as i64,
                    (i % 3) as i64,
                )
            })
            .collect(),
    );
    let expected = args.check.then(|| {
        let mut summary = Summary::default();
        for &(ea1, size1, type1) in rows.iter() {
            let first = rows.partition_point(|&(ea2, _, _)| ea2 <= ea1);
            for &(ea2, size2, type2) in rows[first..]
                .iter()
                .take_while(|&&(ea2, _, _)| ea2 < ea1 + size1)
            {
                summary.add(&[ea1, size1, type1, ea2, size2, type2]);
            }
        }
        summary
    });
    let output = Arc::new(Tally::default());
    let method = args.method;
    let elapsed = run(args.workers, {
        let (rows, output) = (rows.clone(), output.clone());
        move |worker| {
            let (index, peers) = (worker.index(), worker.peers());
            let output = output.clone();
            let mut input = worker.dataflow::<Ts, _, _>(|scope| {
                let (input, candidates) = scope.new_collection::<(i64, i64, i64), Present>();
                let right = candidates.clone().map(|row| ((), row)).arrange_by_key();
                let result =
                    |l: &(i64, i64, i64), r: &(i64, i64, i64)| [l.0, l.1, l.2, r.0, r.1, r.2];
                match method {
                    Method::Arrange => {
                        right.stream.inspect_batch(|_, _| {});
                    }
                    Method::Cross => tally(
                        flowlog_join(right.clone(), right, "cross", move |_, l, r| {
                            (l.0 < r.0 && r.0 < l.0 + l.1).then_some(result(l, r))
                        }),
                        output,
                    ),
                    Method::Nested | Method::Range1 => tally(
                        range_join(
                            right.clone(),
                            right,
                            move |_, l, r| {
                                if method == Method::Range1 && r.0 <= l.0 {
                                    Ordering::Less
                                } else {
                                    Ordering::Equal
                                }
                            },
                            move |_, l, r| (l.0 < r.0 && r.0 < l.0 + l.1).then_some(result(l, r)),
                        ),
                        output,
                    ),
                    Method::Range | Method::CrossShadow | Method::Seek | Method::Auto => {
                        let left = candidates
                            .map(|(ea, size, kind)| ((), (ea, size, kind, ea + size)))
                            .arrange_by_key();
                        let locate = |_: &(), l: &(i64, i64, i64, i64), r: &(i64, i64, i64)| {
                            locate_between(l.0, l.3, r.0)
                        };
                        let result = |_: &(), l: &(i64, i64, i64, i64), r: &(i64, i64, i64)| {
                            Some([l.0, l.1, l.2, r.0, r.1, r.2])
                        };
                        let joined = match method {
                            Method::CrossShadow => {
                                flowlog_join(left, right, "cross-shadow", move |k, l, r| {
                                    if l.0 < r.0 && r.0 < l.3 {
                                        result(k, l, r)
                                    } else {
                                        None
                                    }
                                })
                            }
                            Method::Range => range_join(left, right, locate, result),
                            _ => seek_range_join(
                                left,
                                right,
                                locate,
                                |_, l| (l.0, i64::MIN, i64::MIN),
                                method.strategy(),
                                result,
                            ),
                        };
                        tally(joined, output);
                    }
                    Method::Back => unreachable!("arbitrary object sizes do not support seek back"),
                }
                input
            });
            for &row in rows.iter().skip(index).step_by(peers) {
                input.update(row, Present);
            }
            input.close();
            while worker.step() {}
        }
    });
    Outcome {
        elapsed,
        output: output.summary(),
        expected,
        input_rows: (rows.len(), rows.len()),
        phases: None,
    }
}
