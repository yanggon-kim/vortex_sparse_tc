#!/bin/bash
# Sparse-vs-dense apples-to-apples sweep.
#
# 2 NT × 3 dtype × 2 (M=N) × 3 K × 2 apps = 72 runs.
# Per cell: KERNEL_LATENCY, PERF cycles, PERF instrs, K-loop instr count.
#
# Output: 00_workspace/03_data/sparse_vs_dense_sweep.csv
# Per-(app,NT,dtype) kernel.dump snapshots: 00_workspace/03_data/raw/sparse_vs_dense/

set -u
set -o pipefail

ROOT=/home/yanggon/00_tensor_core/01_sparse_rtlsim/vortex_tinevp_patch_1
BUILD=$ROOT/build
OUTDIR=$ROOT/00_workspace/03_data
LOGDIR=$OUTDIR/raw/sparse_vs_dense
DUMPDIR=$LOGDIR/dumps
CSV=$OUTDIR/sparse_vs_dense_sweep.csv

mkdir -p "$LOGDIR" "$DUMPDIR"

NTS=(8 32)
TYPES=("int4:int32" "int8:int32" "fp16:fp32")
SHAPES=("32:32" "64:64")
KS=(64 128 256)
APPS=("sgemm_tcu" "sgemm_tcu_sp")

echo "app,NT,dtype,M,N,K,kernel_latency,perf_cycles,perf_instrs,kloop_instrs,status,walltime_s" > "$CSV"

cd "$BUILD"
# shellcheck source=/dev/null
source ./ci/toolchain_env.sh

# Compute K-loop instruction count from kernel.dump.
# Strategy: scan <kernel_main>:..(blank line). Find the LAST backward branch
# (b<cond> rs1, rs2, target). The K-loop body length is the number of
# instructions from `target` PC to the branch PC inclusive.
kloop_instrs() {
  local dump=$1
  awk '
    /<kernel_main>:/        { in_kmain = 1; next }
    in_kmain && /^[[:space:]]*$/   { in_kmain = 0 }
    in_kmain && /^[0-9a-f]+:/ {
      # Strip trailing colon from PC
      pc_str = $1
      sub(":", "", pc_str)
      pc = strtonum("0x" pc_str)
      # Match: b<cond> rs1, rs2, 0x<target>
      if (match($0, /[[:space:]]b[a-z]+[[:space:]]+[a-z0-9]+,[[:space:]]*[a-z0-9]+,[[:space:]]*0x([0-9a-f]+)/, m)) {
        tgt = strtonum("0x" m[1])
        if (tgt < pc) { branch_pc = pc; branch_tgt = tgt }
      }
    }
    END {
      if (branch_pc && branch_tgt)
        print int((branch_pc - branch_tgt) / 4 + 1)
      else
        print 0
    }
  ' "$dump"
}

for NT in "${NTS[@]}"; do
  echo "================================"
  echo "[NT=$NT] Rebuild simx libsimx with TCU_LDMETA_ENABLE"
  echo "================================"
  RT_CFG="-DEXT_TCU_ENABLE -DTCU_SPARSE_ENABLE -DTCU_LDMETA_ENABLE -DNUM_THREADS=$NT"
  # Force a clean simx rebuild for consistent NT
  find "$BUILD/runtime/obj" -name "*.o" -delete 2>/dev/null || true
  find "$BUILD/runtime" -name "libsimx.so" -delete 2>/dev/null || true
  find "$BUILD/runtime" -name "simx_config.stamp" -delete 2>/dev/null || true
  CONFIGS="$RT_CFG" DESTDIR="$BUILD/runtime" \
    make -C "$BUILD/sim/simx" "$BUILD/runtime/libsimx.so" -s >/dev/null 2>&1

  for ts in "${TYPES[@]}"; do
    ITYPE=${ts%%:*}
    OTYPE=${ts##*:}
    KCFG="-DEXT_TCU_ENABLE -DTCU_SPARSE_ENABLE -DTCU_LDMETA_ENABLE \
          -DITYPE=$ITYPE -DOTYPE=$OTYPE -DNUM_THREADS=$NT"

    for app in "${APPS[@]}"; do
      echo "  [NT=$NT $ITYPE $app] Build kernel"
      make -C "$BUILD/tests/regression/$app" clean -s >/dev/null 2>&1
      CONFIGS="$KCFG" make -C "$BUILD/tests/regression/$app" -s >/dev/null 2>&1

      # Snapshot kernel.dump and compute K-loop instr count once per
      # (app, NT, dtype) — independent of M/N/K.
      dump_dst="$DUMPDIR/${app}_NT${NT}_${ITYPE}.dump"
      cp "$BUILD/tests/regression/$app/kernel.dump" "$dump_dst" 2>/dev/null || true
      KLOOP=$(kloop_instrs "$dump_dst")

      for shape in "${SHAPES[@]}"; do
        M=${shape%%:*}
        N=${shape##*:}
        for K in "${KS[@]}"; do
          log="$LOGDIR/${app}_NT${NT}_${ITYPE}_M${M}_N${N}_K${K}.log"
          t0=$(date +%s)
          # CONFIGS must include ITYPE/OTYPE so the kernel.elf and host
          # binary are rebuilt for the right dtype. The same CONFIGS is
          # also passed to the runtime/simx rebuild — that's safe because
          # the runtime sources don't define ITYPE/OTYPE.
          CONFIGS="$KCFG" \
          OPTS="-m$M -n$N -k$K" \
          timeout 600 make -C "$BUILD/tests/regression/$app" run-simx \
            > "$log" 2>&1
          rc=$?
          t1=$(date +%s)
          walltime=$((t1 - t0))

          kl=$(grep -oP 'KERNEL_LATENCY:\s*\K[0-9]+' "$log" | tail -1)
          pcyc=$(grep -oP 'PERF: instrs=\d+, cycles=\K[0-9]+' "$log" | tail -1)
          pins=$(grep -oP 'PERF: instrs=\K[0-9]+' "$log" | tail -1)
          if grep -q "PASSED!" "$log"; then status="PASSED"
          elif grep -q "FAILED!" "$log"; then status="FAILED"
          elif [[ $rc -eq 0 ]]; then status="OK_UNKNOWN"
          else status="ERROR_rc=$rc"
          fi

          echo "$app,$NT,$ITYPE,$M,$N,$K,${kl:-},${pcyc:-},${pins:-},$KLOOP,$status,$walltime" >> "$CSV"
          echo "    $app NT=$NT $ITYPE M=$M N=$N K=$K → KL=${kl:-?} cyc=${pcyc:-?} ins=${pins:-?} kloop=$KLOOP status=$status (${walltime}s)"
        done
      done
    done
  done
done

echo
echo "Sweep complete. CSV: $CSV"
echo "Dumps: $DUMPDIR"
