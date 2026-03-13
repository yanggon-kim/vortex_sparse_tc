#!/bin/bash
# NT sweep: sparse vs dense TCU performance across NT=2,4,8,16,32,64
# Outputs CSV with cycle counts and speedup for each (NT, Type, M, N, K) combo.

set -uo pipefail

export TOOLDIR=/opt
BUILD_DIR="/home/yanggon/00_tensor_core/01_sparse_rtlsim/vortex_sparse_tc/build"
cd "$BUILD_DIR"
source ./ci/toolchain_env.sh

OUTPUT="/home/yanggon/00_tensor_core/01_sparse_rtlsim/vortex_sparse_tc/00_workspace/data/nt_sweep_sparse_vs_dense.csv"
LOGDIR="/tmp/nt_sweep_logs_$$"
mkdir -p "$LOGDIR"

TIMEOUT_SEC=600

# CSV header
echo "NT,Type,M,N,K,Dense_Cycles,Dense_Status,Sparse_Cycles,Sparse_Status,Speedup" > "$OUTPUT"

# All (M,N,K) combos from original sweep
SIZES=(
    "8,8,32"
    "16,16,32"
    "16,16,64"
    "32,32,64"
    "32,32,128"
    "32,32,256"
    "32,32,512"
    "32,32,1024"
    "32,32,2048"
    "32,32,4096"
    "64,64,64"
    "64,64,256"
    "64,64,512"
    "64,64,1024"
    "64,64,2048"
    "64,64,4096"
    "128,128,512"
    "128,128,1024"
    "128,128,2048"
    "128,128,4096"
)

# Get tile dimensions: prints "tileM tileN tileK_reg"
get_tiles() {
    python3 -c "
import math
NT=$1
tc = NT * 8
lg = int(math.log2(tc))
en = lg // 2; em = lg - en
M = 1 << em; N = 1 << en
K_reg = tc // max(M, N)
print(M, N, K_reg)
"
}

# Element-level tileK = tileK_reg * i_ratio
tileK_elem() {
    local K_REG=$1 ITYPE=$2
    case $ITYPE in
        fp16) echo $((K_REG * 2)) ;;
        int8) echo $((K_REG * 4)) ;;
        int4) echo $((K_REG * 8)) ;;
    esac
}

# Run one test, echo "cycles,status"
run_test() {
    local APP=$1 M=$2 N=$3 K=$4 LOGFILE=$5
    local out
    out=$(timeout $TIMEOUT_SEC make -C tests/regression/$APP run-rtlsim OPTS="-m$M -n$N -k$K" 2>&1) || true
    echo "$out" > "$LOGFILE"

    local status="FAILED"
    if echo "$out" | grep -q "PASSED!"; then
        status="PASSED"
    fi
    # Check timeout (exit code 124)
    if echo "$out" | grep -qi "timeout\|Killed"; then
        status="TIMEOUT"
    fi

    local cycles="N/A"
    local cyc_line
    cyc_line=$(echo "$out" | grep "cycles=" | tail -1) || true
    if [ -n "$cyc_line" ]; then
        cycles=$(echo "$cyc_line" | sed 's/.*cycles=\([0-9]*\).*/\1/')
    fi
    echo "${cycles},${status}"
}

# Process one NT value
process_nt() {
    local NT=$1
    echo ""
    echo "=========================================="
    echo " NT=$NT"
    echo "=========================================="

    local TILE_M TILE_N TILE_K_REG
    read TILE_M TILE_N TILE_K_REG <<< $(get_tiles $NT)
    echo "Tiles: M=$TILE_M, N=$TILE_N, K_reg=$TILE_K_REG"

    # Build sparse RTL (supports both dense and sparse instructions)
    local SPARSE_RTL_OK=1
    echo "Building sparse RTL for NT=$NT..."
    if CONFIGS="-DNUM_THREADS=$NT -DEXT_TCU_ENABLE -DTCU_TYPE_DPI -DTCU_SPARSE_ENABLE" \
       make -C runtime/rtlsim > "$LOGDIR/rtl_sparse_nt${NT}.log" 2>&1; then
        echo "  Sparse RTL built OK"
    else
        echo "  Sparse RTL FAILED — building dense-only RTL"
        SPARSE_RTL_OK=0
        CONFIGS="-DNUM_THREADS=$NT -DEXT_TCU_ENABLE -DTCU_TYPE_DPI" \
            make -C runtime/rtlsim > "$LOGDIR/rtl_dense_nt${NT}.log" 2>&1
        echo "  Dense RTL built OK"
    fi

    for TYPE_PAIR in "fp16:fp32" "int8:int32" "int4:int32"; do
        IFS=':' read -r ITYPE OTYPE <<< "$TYPE_PAIR"
        local TK
        TK=$(tileK_elem $TILE_K_REG $ITYPE)
        echo ""
        echo "--- NT=$NT $ITYPE (tileK=$TK) ---"

        # Build dense test binary
        make -C tests/regression/sgemm_tcu clean > /dev/null 2>&1 || true
        local DENSE_BUILD_OK=1
        if ! CONFIGS="-DNUM_THREADS=$NT -DITYPE=$ITYPE -DOTYPE=$OTYPE" \
             make -C tests/regression/sgemm_tcu > "$LOGDIR/build_dense_nt${NT}_${ITYPE}.log" 2>&1; then
            echo "  Dense test build FAILED — skipping $ITYPE"
            DENSE_BUILD_OK=0
        fi

        # Build sparse test binary
        local SPARSE_BUILD_OK=$SPARSE_RTL_OK
        if [ $SPARSE_RTL_OK -eq 1 ]; then
            make -C tests/regression/sgemm_tcu_sp clean > /dev/null 2>&1 || true
            if ! CONFIGS="-DNUM_THREADS=$NT -DITYPE=$ITYPE -DOTYPE=$OTYPE" \
                 make -C tests/regression/sgemm_tcu_sp > "$LOGDIR/build_sparse_nt${NT}_${ITYPE}.log" 2>&1; then
                echo "  Sparse test build FAILED"
                SPARSE_BUILD_OK=0
            fi
        fi

        if [ $DENSE_BUILD_OK -eq 0 ] && [ $SPARSE_BUILD_OK -eq 0 ]; then
            continue
        fi

        for SIZE in "${SIZES[@]}"; do
            IFS=',' read -r M N K <<< "$SIZE"

            # Tile compatibility check
            if [ $((M % TILE_M)) -ne 0 ] || [ $((N % TILE_N)) -ne 0 ] || [ $((K % TK)) -ne 0 ]; then
                continue
            fi

            # Run dense
            local d_cyc="N/A" d_st="N/A"
            if [ $DENSE_BUILD_OK -eq 1 ]; then
                local dense_result
                dense_result=$(run_test sgemm_tcu $M $N $K \
                    "$LOGDIR/run_dense_nt${NT}_${ITYPE}_${M}x${N}x${K}.log")
                IFS=',' read -r d_cyc d_st <<< "$dense_result"
            fi

            # Run sparse
            local s_cyc="N/A" s_st="N/A"
            if [ $SPARSE_BUILD_OK -eq 1 ]; then
                local sparse_result
                sparse_result=$(run_test sgemm_tcu_sp $M $N $K \
                    "$LOGDIR/run_sparse_nt${NT}_${ITYPE}_${M}x${N}x${K}.log")
                IFS=',' read -r s_cyc s_st <<< "$sparse_result"
            fi

            # Compute speedup
            local speedup="N/A"
            if [ "$d_cyc" != "N/A" ] && [ "$s_cyc" != "N/A" ] && [ "$s_cyc" != "0" ]; then
                speedup=$(python3 -c "print(f'{$d_cyc/$s_cyc:.2f}x')")
            fi

            echo "  ${M}x${N}x${K}: dense=${d_cyc}(${d_st}) sparse=${s_cyc}(${s_st}) ${speedup}"
            echo "$NT,$ITYPE,$M,$N,$K,$d_cyc,$d_st,$s_cyc,$s_st,$speedup" >> "$OUTPUT"
        done
    done
}

# =============================================
# XLEN=32: NT=2, 4, 8, 16, 32
# =============================================
echo "=== Configuring XLEN=32 ==="
../configure --xlen=32 --tooldir=/opt > /dev/null 2>&1
make -C hw clean > /dev/null 2>&1
make -C hw config > /dev/null 2>&1
make -C kernel clean > /dev/null 2>&1
make -C kernel > /dev/null 2>&1

for NT in 2 4 8 16 32; do
    process_nt $NT
done

# =============================================
# XLEN=64: NT=64
# =============================================
echo ""
echo "=== Configuring XLEN=64 ==="
../configure --xlen=64 --tooldir=/opt > /dev/null 2>&1
make -C hw clean > /dev/null 2>&1
make -C hw config > /dev/null 2>&1
make -C kernel clean > /dev/null 2>&1
make -C kernel > /dev/null 2>&1

process_nt 64

echo ""
echo "=========================================="
echo " SWEEP COMPLETE"
echo " Results: $OUTPUT"
echo " Logs:    $LOGDIR"
echo "=========================================="
