#!/usr/bin/env python3
"""把 bench CSV 汇总成 markdown 表，并在输出主结果前做一致性校验。

支持两种 schema：
  v1（历史）：size_mb / throughput_mbs / discovery_ms（0 表示未执行），无 attempts 列
  v2（当前）：payload_bytes / throughput_mib_s / discovery_status / attempts

校验（先于任何汇总输出）：
  1. 同一 experiment+condition 下，设备/方向/拓扑/起始状态/字节数/软件哈希/deadline 必须一致；
  2. trial_id 不得重复（含跨文件）。
任一不满足：把具体问题写到 stderr，以非零码退出，**不输出任何主结果表**，且不修改原文件。

阶段统计口径：
  - 行级 tcp_ms/handshake_ms 只来自「命中的那条候选」；
  - attempt 级统计解析 attempts 列，失败尝试计入失败数、不计入成功阶段的延迟分位数。

用法：
    python3 scripts/bench-summary.py                 # 读 bench-results/*.csv
    python3 scripts/bench-summary.py a.csv b.csv     # 指定文件
"""
import csv
import glob
import os
import sys
from collections import defaultdict

EXIT_INVALID = 2


def percentile(values, p):
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * p / 100
    low = int(position)
    high = min(low + 1, len(ordered) - 1)
    weight = position - low
    return ordered[low] * (1 - weight) + ordered[high] * weight


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def load(paths):
    rows = []
    for path in paths:
        with open(path, newline="", encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                row["_source"] = os.path.basename(path)
                rows.append(row)
    return rows


def schema_of(row):
    return row.get("schema_version") or "1"


def group_key(row):
    experiment = row.get("experiment_id") or "unknown"
    if schema_of(row) >= "2" and row.get("condition_id"):
        condition = row["condition_id"]
    else:
        condition = f"legacy:{row.get('label', '?')}@{row.get('size_mb', '?')}MiB"
    return experiment, condition


def is_ok(row):
    return str(row.get("ok", "")).lower() == "true"


def throughput(row):
    if schema_of(row) >= "2":
        return number(row.get("throughput_mib_s"))
    return number(row.get("throughput_mbs"))


def parse_attempts(cell):
    """解析 attempts 列：kind|label|dial|hs|status，多条用 ; 分隔。"""
    if not cell:
        return []

    attempts = []
    for part in cell.split(";"):
        fields = part.split("|")
        if len(fields) != 5:
            continue
        attempts.append({
            "kind": fields[0],
            "label": fields[1],
            "dial_ms": number(fields[2]) or 0.0,
            "handshake_ms": number(fields[3]) or 0.0,
            "ok": fields[4] == "ok",
            "error": "" if fields[4] == "ok" else fields[4],
        })
    return attempts


CONFLICT_FIELDS = ("device_id", "direction", "topology", "start_state",
                   "payload_bytes", "software_sha256", "deadline_ms")


def validate(rows):
    """返回问题列表；空列表表示可以汇总。"""
    problems = []

    seen = defaultdict(lambda: defaultdict(set))
    for row in rows:
        key = group_key(row)
        for field in CONFLICT_FIELDS:
            value = row.get(field)
            if value not in (None, ""):
                seen[key][field].add(value)

    for key, fields in sorted(seen.items()):
        for field, values in sorted(fields.items()):
            if len(values) > 1:
                problems.append(
                    f"条件冲突：{key[0]}/{key[1]} 的 {field} 有多个取值 {sorted(values)}；这些行不能合并统计"
                )

    trials = defaultdict(list)
    for row in rows:
        trial_id = row.get("trial_id")
        if trial_id:
            trials[trial_id].append(row.get("_source", "?"))

    for trial_id, sources in sorted(trials.items()):
        if len(sources) > 1:
            problems.append(f"重复 trial_id：{trial_id} 出现在 {sources}")

    return problems


def main():
    paths = sys.argv[1:]
    if not paths:
        root = os.path.join(os.path.dirname(__file__), "..")
        paths = sorted(glob.glob(os.path.join(root, "bench-results", "*.csv")))

    if not paths:
        print("没有找到 CSV。先跑 scripts/bench-matrix.sh。", file=sys.stderr)
        return EXIT_INVALID

    rows = load(paths)
    if not rows:
        print("CSV 是空的。", file=sys.stderr)
        return EXIT_INVALID

    # 先校验：有问题就不输出任何主结果，避免「混合结果 + 告警」同时出现。
    problems = validate(rows)
    if problems:
        print(f"数据校验未通过（{len(problems)} 项），已拒绝输出汇总：", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return EXIT_INVALID

    groups = defaultdict(list)
    for row in rows:
        groups[group_key(row)].append(row)

    print(f"数据来源：{len(paths)} 个文件，{len(rows)} 条记录\n")

    print("## 试次级（成功试次的吞吐与命中候选的阶段耗时）\n")
    print("| 实验 | 条件 | 试次 | 成功 | 吞吐 P50 (MiB/s) | 命中候选 TCP | 命中候选握手 | 传输 |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- |")

    for (experiment, condition) in sorted(groups):
        items = groups[(experiment, condition)]
        ok_rows = [r for r in items if is_ok(r)]

        values = [v for v in (throughput(r) for r in ok_rows) if v is not None]
        throughput_text = f"{percentile(values, 50):.2f}" if values else "—"

        def row_phase(name):
            data = [v for v in (number(r.get(name)) for r in ok_rows) if v is not None]
            return f"{percentile(data, 50):.0f} ms" if data else "—"

        print(
            f"| {experiment} | {condition} | {len(items)} | {len(ok_rows)}/{len(items)} "
            f"| {throughput_text} | {row_phase('tcp_ms')} | {row_phase('handshake_ms')} | {row_phase('transfer_ms')} |"
        )

    # attempt 级统计：失败尝试也要出现在样本里，而不是只剩命中的那条。
    attempt_groups = defaultdict(list)
    for row in rows:
        key = group_key(row)
        for attempt in parse_attempts(row.get("attempts")):
            attempt_groups[(key, attempt["kind"])].append(attempt)

    if attempt_groups:
        print("\n## attempt 级（含失败尝试；延迟分位数只用成功尝试）\n")
        print("| 实验 | 条件 | 链路类型 | 尝试 n | 成功 | 失败 | dial P50(成功) | handshake P50(成功) |")
        print("| --- | --- | --- | --- | --- | --- | --- | --- |")

        by_condition = defaultdict(lambda: defaultdict(list))
        for (key, kind), items in attempt_groups.items():
            by_condition[key][kind] = items

        def attempt_phase(items, field):
            data = [a[field] for a in items if a["ok"] and a[field] is not None]
            return f"{percentile(data, 50):.0f} ms" if data else "—"

        for key in sorted(by_condition):
            all_items = []

            for kind in sorted(by_condition[key]):
                items = by_condition[key][kind]
                ok_items = [a for a in items if a["ok"]]
                all_items.extend(items)

                print(
                    f"| {key[0]} | {key[1]} | {kind} | {len(items)} | {len(ok_items)} | {len(items) - len(ok_items)} "
                    f"| {attempt_phase(items, 'dial_ms')} | {attempt_phase(items, 'handshake_ms')} |"
                )

            # 合计行：一次回退就能看出「这条条件一共试了几次、几次失败」。
            ok_total = sum(1 for a in all_items if a["ok"])
            print(
                f"| {key[0]} | {key[1]} | 合计 | {len(all_items)} | {ok_total} | {len(all_items) - ok_total} "
                f"| {attempt_phase(all_items, 'dial_ms')} | {attempt_phase(all_items, 'handshake_ms')} |"
            )
    else:
        print("\n（没有 attempts 列：v1 历史文件不记录逐次尝试，无法做 attempt 级统计）")

    failures = [r for r in rows if not is_ok(r)]
    if failures:
        by_stage = defaultdict(int)
        for row in failures:
            by_stage[row.get("failure_stage") or "unknown"] += 1

        print("\n失败分布：")
        for stage, count in sorted(by_stage.items(), key=lambda item: -item[1]):
            print(f"  {stage}: {count}")

    print("\n样本量（成功次数，仅供解释用，不是阈值）：")
    for (experiment, condition) in sorted(groups):
        ok_count = sum(1 for r in groups[(experiment, condition)] if is_ok(r))
        total = len(groups[(experiment, condition)])
        print(f"  {experiment}/{condition}: {ok_count}/{total}")

    print("\n解释提示：成功次数决定这些数字能支持多细的结论——样本很少时只适合描述该次运行，"
          "不构成对链路性能的稳定估计；样本较多时也只说明本设备对与本网络条件下的表现。")

    return 0


if __name__ == "__main__":
    sys.exit(main())
