import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bench


class BenchmarkTests(unittest.TestCase):
    def test_transaction_metrics_are_medianed_independently(self):
        samples = [
            dict(secs=1.0, load_secs=0.9, update_secs=0.1, per_txn_ms=20.0),
            dict(secs=2.0, load_secs=1.8, update_secs=0.2, per_txn_ms=100.0),
            dict(secs=3.0, load_secs=2.7, update_secs=0.3, per_txn_ms=30.0),
        ]
        for sample in samples:
            sample.update(left_rows=10, right_rows=10, out=5, fingerprint="0123456789abcdef")
        result = bench.summarize("txn-l", "txn", "auto", samples)
        self.assertEqual(result["secs_median"], 2.0)
        self.assertEqual(result["per_txn_ms_median"], 30.0)
        self.assertEqual((result["metric"], result["median"]), ("per_txn_ms", 30.0))
        self.assertEqual((result["minimum"], result["maximum"]), (20.0, 100.0))

    def test_parse_checked_named_metrics(self):
        line = "band auto n=3 w=1 left_rows=3 right_rows=3 out=2 fingerprint=0123456789abcdef secs=0.001234567 check=ok\n"
        result = bench.parse_result(line, "band", "auto", {"n": 3, "w": 1})
        self.assertEqual(result["secs"], 0.001234567)
        self.assertEqual(result["out"], 2)
        for bad in [
            line.replace("check=ok", "check=unchecked"),
            line.replace("check=ok", "check=MISMATCH"),
            line.replace("n=3", "n=4"),
            line.replace("0.001234567", "NaN"),
            line.replace("0.001234567", "-1"),
            line + line,
            line.strip() + " secs=4\n",
        ]:
            with self.assertRaises(ValueError, msg=bad):
                bench.parse_result(bad, "band", "auto", {"n": 3})

    def test_large_integer_parameters_are_compared_exactly(self):
        seed = 2**64 - 1
        line = (f"band auto seed={seed} left_rows=3 right_rows=3 out=2 "
                "fingerprint=0123456789abcdef secs=0.001234567 check=ok\n")
        bench.parse_result(line, "band", "auto", {"seed": seed})
        with self.assertRaises(ValueError):
            bench.parse_result(line, "band", "auto", {"seed": seed - 1})

    def test_affinity_respects_cpuset_and_excludes_smt_siblings(self):
        topology = "# CPU,CORE,SOCKET,NODE\n0,0,0,0\n1,0,0,0\n2,1,0,0\n3,1,0,0\n4,2,1,1\n5,2,1,1"
        self.assertEqual(bench.choose_cpus(topology, {1, 2, 3, 4, 5}, 2), [1, 2])
        self.assertEqual(bench.choose_cpus(topology, {1, 2, 3, 4, 5}, 3), [1, 2, 4])
        with self.assertRaises(ValueError):
            bench.choose_cpus(topology, {0, 1}, 2)

    def test_cases_cover_unfavorable_and_variable_width_inputs(self):
        names = {name for name, _, _ in bench.cases(True)}
        self.assertTrue({"band-empty", "band-dense", "keyed-tiny-groups", "object-conflict",
                         "interval-few-probes", "txn-l", "txn-r", "txn-lr"} <= names)


if __name__ == "__main__":
    unittest.main()
