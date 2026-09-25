//! Exponential search over a partitioned slice.

/// Returns the partition point of `items` under `before`, searching
/// outward from `hint`.
///
/// `before` must hold on a prefix of `items` and fail on the rest, as for
/// [`slice::partition_point`]. The cost is logarithmic in the distance
/// between `hint` and the answer, so queries whose answers drift
/// monotonically cost a merge rather than a binary search each.
pub fn partition_point_from<X>(
    items: &[X],
    hint: usize,
    mut before: impl FnMut(&X) -> bool,
) -> usize {
    let len = items.len();
    let hint = hint.min(len);
    let (lo, hi) = if hint < len && before(&items[hint]) {
        // Everything through `hint` passes, so the answer lies beyond it.
        let mut lo = hint + 1;
        let mut step = 1;
        loop {
            let probe = hint + step;
            if probe >= len {
                break (lo, len);
            }
            if !before(&items[probe]) {
                break (lo, probe);
            }
            lo = probe + 1;
            step *= 2;
        }
    } else {
        // `hint` fails (or is the end), so the answer lies at or before it.
        let mut hi = hint;
        let mut step = 1;
        loop {
            if hi == 0 {
                break (0, 0);
            }
            let probe = hint.saturating_sub(step);
            if before(&items[probe]) {
                break (probe + 1, hi);
            }
            hi = probe;
            step *= 2;
        }
    };
    lo + items[lo..hi].partition_point(before)
}

#[cfg(test)]
mod tests {
    use super::partition_point_from;

    #[test]
    fn matches_partition_point_for_every_hint() {
        for len in 0..40 {
            for split in 0..=len {
                let items: Vec<usize> = (0..len).collect();
                let expected = items.partition_point(|&x| x < split);
                for hint in 0..=len + 3 {
                    let mut probes = 0;
                    let found = partition_point_from(&items, hint, |&x| {
                        probes += 1;
                        x < split
                    });
                    assert_eq!(found, expected, "len={len} split={split} hint={hint}");
                    // Galloping plus a bounded binary search stays logarithmic.
                    assert!(probes <= 4 * (usize::BITS - len.leading_zeros()) as usize + 2);
                }
            }
        }
    }
}
