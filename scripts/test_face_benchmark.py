import json
import math
from pathlib import Path
import unittest

from face_benchmark import constrained_graph, greedy, pair_counts, quantiles, verified


class FaceBenchmarkMathTests(unittest.TestCase):
    def test_quantile_interpolation(self):
        self.assertEqual(quantiles([4, 1, 2, 3])["p50"], 2.5)
        self.assertAlmostEqual(quantiles([4, 1, 2, 3])["p95"], 3.85)
        self.assertIsNone(quantiles([])["p95"])

    def test_pair_counts(self):
        matrix = [[1, 0.3, 0.8], [0.3, 1, 0.1], [0.8, 0.1, 1]]
        result = pair_counts(matrix, ["a", "a", "b"], threshold=0.45)
        self.assertEqual(result, {"same_pairs": 1, "different_pairs": 2, "false_merges": 1, "false_splits": 1})

    def test_ambiguity_creates_new_root(self):
        matrix = [[1, 0.1, 0.7], [0.1, 1, 0.68], [0.7, 0.68, 1]]
        self.assertEqual(len(set(greedy(matrix, 0.45, [0, 1, 2]))), 3)
        matrix[1][2] = matrix[2][1] = 0.4
        self.assertEqual(greedy(matrix, 0.45, [0, 1, 2]), [0, 1, 0])

    def test_complete_link_rejects_bridge_and_manual_constraint(self):
        matrix = [[1, 0.8, 0.3], [0.8, 1, 0.7], [0.3, 0.7, 1]]
        graph = constrained_graph(matrix, 0.45)
        self.assertEqual(graph[0], graph[1])
        self.assertNotEqual(graph[0], graph[2])
        constrained = constrained_graph(matrix, 0.45, cannot_link=[(0, 1)])
        self.assertNotEqual(constrained[0], constrained[1])

    def test_committed_reports_consistent(self):
        root = Path(__file__).resolve().parents[1]
        reports = sorted((root / "face-inference/benchmarks").glob("*.json"))
        self.assertEqual(len(reports), 3)
        self.assertEqual({json.loads(path.read_text())["model"] for path in reports}, {"sface", "arcface", "adaface"})
        crop_hashes = []
        for path in reports:
            report = json.loads(path.read_text())
            crop_hashes.append(report["alignment"]["crop_sha256"])
            for key in ("base_six", "expanded"):
                group = report[key]
                n = group["images"]
                self.assertEqual(len(group["pairs"]), n * (n - 1) // 2)
                self.assertTrue(all(math.isfinite(p["cosine"]) and -1 <= p["cosine"] <= 1 for p in group["pairs"]))
                self.assertEqual(
                    group["same_identity_cosine"]["count"] + group["different_identity_cosine"]["count"],
                    len(group["pairs"]),
                )
                for row in group["sweep"]:
                    threshold = row["threshold"]
                    merges = sum(not p["same_identity"] and p["cosine"] >= threshold for p in group["pairs"])
                    splits = sum(p["same_identity"] and p["cosine"] < threshold for p in group["pairs"])
                    self.assertEqual(row["pair_classification"]["false_merges"], merges)
                    self.assertEqual(row["pair_classification"]["false_splits"], splits)
            self.assertEqual(report["runtime"]["threads"], 1)
            self.assertGreater(report["latency"]["feature_warmed_ms"]["count"], 100)
            self.assertEqual(sum(v["status"] == "ok" for v in report["codec_variants"]), 17)
            self.assertEqual(len(report["same_crop_transformations"]), report["expanded"]["images"] * 5)
        self.assertTrue(all(hashes == crop_hashes[0] for hashes in crop_hashes))

    def test_checksum_rejects_mismatch(self):
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            verified(Path(__file__), "0" * 64)


if __name__ == "__main__":
    unittest.main()
