#!/usr/bin/env python3
"""Join sparse and dense rows from sparse_vs_dense_sweep.csv and produce
a delta table (sparse - dense). Highlight any cell where any metric is
>= 0 (i.e., sparse is no better than dense — a regression).

Outputs:
- sparse_vs_dense_deltas.csv
- sparse_vs_dense_results.md
"""

import csv
import os
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
SWEEP_CSV = HERE / "sparse_vs_dense_sweep.csv"
DELTA_CSV = HERE / "sparse_vs_dense_deltas.csv"
REPORT_MD = HERE / "sparse_vs_dense_results.md"

METRICS = ["kernel_latency", "perf_cycles", "perf_instrs", "kloop_instrs"]


def load_sweep(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            for k in METRICS:
                v = r.get(k, "")
                r[k] = int(v) if v else None
            rows.append(r)
    return rows


def join(rows):
    by_key = defaultdict(dict)
    for r in rows:
        key = (r["NT"], r["dtype"], r["M"], r["N"], r["K"])
        app = r["app"]
        side = "dense" if app == "sgemm_tcu" else "sparse"
        by_key[key][side] = r
    return by_key


def write_delta_csv(joined, path):
    fieldnames = ["NT", "dtype", "M", "N", "K"]
    for m in METRICS:
        fieldnames += [f"{m}_dense", f"{m}_sparse", f"{m}_delta"]
    fieldnames += ["regression"]

    out = []
    for key, sides in sorted(joined.items()):
        d = sides.get("dense", {})
        s = sides.get("sparse", {})
        nt, dtype, M, N, K = key
        row = {"NT": nt, "dtype": dtype, "M": M, "N": N, "K": K}
        regress = False
        for m in METRICS:
            dv = d.get(m)
            sv = s.get(m)
            row[f"{m}_dense"] = dv
            row[f"{m}_sparse"] = sv
            if dv is None or sv is None:
                row[f"{m}_delta"] = None
            else:
                delta = sv - dv
                row[f"{m}_delta"] = delta
                if delta >= 0:
                    regress = True
        row["regression"] = "YES" if regress else "no"
        out.append(row)

    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in out:
            w.writerow(r)
    return out


def write_report(deltas, path):
    regressions = [r for r in deltas if r["regression"] == "YES"]

    with open(path, "w") as f:
        f.write("# Sparse vs Dense Sweep — Results\n\n")
        f.write(f"Total cells: {len(deltas)}. ")
        f.write(f"Regressions (any metric where sparse ≥ dense): "
                f"**{len(regressions)}**\n\n")

        f.write("## Per-cell deltas (sparse − dense; negative = sparse wins)\n\n")
        f.write("| NT | dtype | M | N | K |  KL_d |  KL_s |  ΔKL |  cyc_d |  cyc_s |  Δcyc |  ins_d |  ins_s |  Δins | kl_d | kl_s | Δkl | regression |\n")
        f.write("|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|\n")
        for r in deltas:
            def fmt(v): return "—" if v is None else str(v)
            line = (f"| {r['NT']} | {r['dtype']} | {r['M']} | {r['N']} | {r['K']} |"
                    f" {fmt(r['kernel_latency_dense'])} | {fmt(r['kernel_latency_sparse'])} | {fmt(r['kernel_latency_delta'])} |"
                    f" {fmt(r['perf_cycles_dense'])} | {fmt(r['perf_cycles_sparse'])} | {fmt(r['perf_cycles_delta'])} |"
                    f" {fmt(r['perf_instrs_dense'])} | {fmt(r['perf_instrs_sparse'])} | {fmt(r['perf_instrs_delta'])} |"
                    f" {fmt(r['kloop_instrs_dense'])} | {fmt(r['kloop_instrs_sparse'])} | {fmt(r['kloop_instrs_delta'])} |"
                    f" **{r['regression']}** |\n")
            f.write(line)

        if regressions:
            f.write("\n## Regression cells\n\n")
            for r in regressions:
                f.write(f"- NT={r['NT']} dtype={r['dtype']} "
                        f"M={r['M']} N={r['N']} K={r['K']}: ")
                bad_metrics = []
                for m in METRICS:
                    dv = r[f"{m}_delta"]
                    if dv is not None and dv >= 0:
                        bad_metrics.append(f"{m} Δ={dv}")
                f.write(", ".join(bad_metrics) + "\n")
        else:
            f.write("\n## Result\n\nSparse wins on every metric in every cell. ✅\n")


def main():
    if not SWEEP_CSV.exists():
        print(f"ERROR: {SWEEP_CSV} not found. Run run_sparse_vs_dense_sweep.sh first.",
              file=sys.stderr)
        sys.exit(1)

    rows = load_sweep(SWEEP_CSV)
    joined = join(rows)
    deltas = write_delta_csv(joined, DELTA_CSV)
    write_report(deltas, REPORT_MD)
    print(f"Wrote {DELTA_CSV}")
    print(f"Wrote {REPORT_MD}")
    regressions = [r for r in deltas if r["regression"] == "YES"]
    if regressions:
        print(f"\n{len(regressions)} regression cell(s):")
        for r in regressions:
            print(f"  NT={r['NT']} dtype={r['dtype']} "
                  f"M={r['M']} N={r['N']} K={r['K']}")
        sys.exit(2)
    else:
        print("\nAll cells: sparse < dense on every metric ✅")


if __name__ == "__main__":
    main()
