#!/usr/bin/env python3
"""bench-summary.py 的 CLI 回归测试（仅标准库）。

运行：
    python3 scripts/test_bench_summary.py
"""
import csv
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "bench-summary.py")

HEADER = [
    "schema_version", "experiment_id", "batch_id", "condition_id", "trial_id", "device_id",
    "timestamp", "label", "note", "mode", "direction", "topology", "start_state", "upgrade",
    "payload_bytes", "size_mib", "target", "local_addr", "remote_addr",
    "discovery_status", "discovery_ms", "tcp_ms", "handshake_ms", "negotiate_ms",
    "transfer_ms", "total_ms", "deadline_ms", "failure_stage", "ok", "error",
    "attempts", "upgrade_attempts", "peer_caps_count", "peer_port", "final_link", "upgraded",
    "throughput_mib_s", "throughput_mbit_s", "software_sha256",
]


def make_row(**overrides):
    row = {
        "schema_version": "2",
        "experiment_id": "exp1",
        "batch_id": "b1",
        "condition_id": "to-x-1048576B-noup-mac_win-lan-connected",
        "trial_id": "t1",
        "device_id": "dev1",
        "timestamp": "2026-11-02T23:00:00+08:00",
        "label": "x",
        "note": "",
        "mode": "to",
        "direction": "mac_win",
        "topology": "lan",
        "start_state": "connected",
        "upgrade": "false",
        "payload_bytes": "1048576",
        "size_mib": "1.00",
        "target": "10.0.0.1:9001",
        "local_addr": "10.0.0.2:5000",
        "remote_addr": "10.0.0.1:9001",
        "discovery_status": "not_run",
        "discovery_ms": "",
        "tcp_ms": "1.0",
        "handshake_ms": "2.0",
        "negotiate_ms": "",
        "transfer_ms": "10.0",
        "total_ms": "13.0",
        "deadline_ms": "180000",
        "failure_stage": "",
        "ok": "true",
        "error": "",
        "attempts": "direct|10.0.0.1:9001|1|2|ok",
        "upgrade_attempts": "",
        "peer_caps_count": "0",
        "peer_port": "0",
        "final_link": "direct",
        "upgraded": "false",
        "throughput_mib_s": "100.0",
        "throughput_mbit_s": "838.86",
        "software_sha256": "abc123",
    }
    row.update(overrides)
    return row


def write_csv(path, rows):
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=HEADER)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def run_summary(*paths):
    return subprocess.run(
        [sys.executable, SCRIPT, *paths],
        capture_output=True,
        text=True,
    )


class SummaryCliTest(unittest.TestCase):
    def test_conflict_blocks_output(self):
        """同一 condition 下字节数不同：必须拒绝输出，不能先出表再告警。"""
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "conflict.csv")
            write_csv(path, [
                make_row(trial_id="t1", payload_bytes="1"),
                make_row(trial_id="t2", payload_bytes="1000"),
            ])

            result = run_summary(path)

            self.assertNotEqual(result.returncode, 0, "条件冲突必须非零退出")
            self.assertIn("payload_bytes", result.stderr)
            self.assertIn("条件冲突", result.stderr)
            self.assertNotIn("## 试次级", result.stdout, "校验失败时不能输出主结果表")

    def test_duplicate_trial_id_blocks_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            first = os.path.join(tmp, "a.csv")
            second = os.path.join(tmp, "b.csv")
            write_csv(first, [make_row(trial_id="dup-1", batch_id="b1")])
            write_csv(second, [make_row(trial_id="dup-1", batch_id="b2")])

            result = run_summary(first, second)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("重复 trial_id", result.stderr)
            self.assertNotIn("## 试次级", result.stdout)

    def test_clean_file_outputs_tables(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "clean.csv")
            write_csv(path, [
                make_row(trial_id="t1", ok="true"),
                make_row(trial_id="t2", ok="false", failure_stage="tcp", error="refused",
                         attempts="direct|10.0.0.1:9001|1|0|refused"),
            ])

            result = run_summary(path)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("## 试次级", result.stdout)
            self.assertIn("失败分布", result.stdout)

    def test_attempt_level_counts_failures(self):
        """失败尝试必须进入 attempt 级统计，而不是只剩命中的那条。"""
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "fallback.csv")
            write_csv(path, [make_row(
                trial_id="t1",
                attempts="direct|10.0.0.9:9001|1|0|refused;discovered|10.0.0.1:9001|3|4|ok",
                tcp_ms="3.0",
                handshake_ms="4.0",
            )])

            result = run_summary(path)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("attempt 级", result.stdout)
            self.assertIn("| 合计 | 2 | 1 | 1 |", result.stdout,
                          "合计行应显示 2 次尝试、1 成功、1 失败")


if __name__ == "__main__":
    unittest.main(verbosity=2)
