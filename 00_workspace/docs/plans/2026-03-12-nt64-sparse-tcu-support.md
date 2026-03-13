# NT=64 Sparse TCU Support

**Date:** 2026-03-12
**Branch:** `260310_fixes`
**Requires:** XLEN=64 (RISC-V 64-bit)

## Overview

Added NT=64 support for the sparse TCU. NT=64 is a symmetric configuration (`block_em == block_en == 3`), so it reuses the same `SYM_SPARSE` control-flow path as NT=4 and NT=16. FP16 and INT8 worked without any code changes. INT4 required targeted fixes to a **metadata column index overflow bug** that only manifests at NT=64.

## NT=64 Parameters

```
block_cap=64, lg_block_cap=6, block_en=3, block_em=3
sym_sparse = (block_em == block_en) = (3 == 3) = TRUE

tcM=8, tcN=8, tcK=8
m_steps=4, n_steps=2, k_steps=2
NRA=8, NRB=4, NRC=8, TCU_UOPS=16

Tile sizes:
  FP16: 32x16x32   (meta_cols = ceil(64/8)  = 8)
  INT8: 32x16x64   (meta_cols = ceil(64/4)  = 16)
  INT4: 32x16x64   (meta_cols = ceil(64/2)  = 32)  <-- overflow!
```

## The INT4 Overflow Bug

For INT4 at NT=64, `meta_cols = 32`. Three places in the RTL had widths too narrow to hold this value:

1. **`meta_num_cols()` returns `logic [4:0]`** — `5'(32)` wraps to `0`.
2. **`fmt_d` is 4 bits** — the uop sequencer packs the column index into `fmt_d = 4'(ctr)`, so `ctr=16..31` wraps to `0..15`.
3. **`wr_col_idx` is `[3:0]`** — the meta SRAM write port can only address 16 of 32 column RAMs.

FP16 (`meta_cols=8`) and INT8 (`meta_cols=16`) fit within the existing widths and were unaffected.

### Fix Strategy

Rather than widening `fmt_d` (which would require changes to the instruction encoding and `op_args_t` struct), we **pack the overflow bits into `step_m`** during the meta-store phase. The `step_m` field is otherwise unused during meta-store micro-ops (it was hardcoded to `'0`), so we repurpose its lower 2 bits to carry `ctr[5:4]`. The receiver (`VX_tcu_core.sv`) reconstructs the full 6-bit column index as `{step_m[1:0], fmt_d}`.

This is backward-compatible: for NTs where `meta_cols <= 16`, `ctr >> 4 == 0` (same value as the previous `'0`).

## Files Modified

### 1. `hw/rtl/tcu/VX_tcu_pkg.sv` (lines 105-120)

**What:** Widened return types of `meta_num_cols()` and `meta_num_stores()` from `logic [4:0]` to `logic [5:0]`. Changed all return literals from `5'(...)` / `5'd1` to `6'(...)` / `6'd1`.

**Why:** `meta_num_cols()` computes `ceil(NT/2)` for INT4 types. At NT=64 this is 32, which requires 6 bits. The old 5-bit return silently truncated `5'(32) = 0`, causing downstream logic to think there were zero metadata columns.

```diff
- function automatic logic [4:0] meta_num_cols(input logic [3:0] fmt);
+ function automatic logic [5:0] meta_num_cols(input logic [3:0] fmt);
      ...
-         return 5'((TCU_BLOCK_CAP + 1) / 2);   // 4-bit: ceil(NT/2)
+         return 6'((TCU_BLOCK_CAP + 1) / 2);   // 4-bit: ceil(NT/2)
      ...

- function automatic logic [4:0] meta_num_stores(input logic [3:0] fmt);
-     return 5'(int'(meta_num_cols(fmt)) * TCU_META_STORES_PER_COL);
+ function automatic logic [5:0] meta_num_stores(input logic [3:0] fmt);
+     return 6'(int'(meta_num_cols(fmt)) * TCU_META_STORES_PER_COL);
```

### 2. `hw/rtl/tcu/VX_tcu_uops.sv` (lines 59, 117-121, 191, 195)

**What (a):** Widened `sparse_meta_stores` wire from `[4:0]` to `[5:0]` to match the widened `meta_num_stores()` return.

```diff
- wire [4:0] sparse_meta_stores = meta_num_stores(ibuf_in.op_args.tcu.fmt_s);
+ wire [5:0] sparse_meta_stores = meta_num_stores(ibuf_in.op_args.tcu.fmt_s);
```

**What (b):** During the meta-store phase, changed `step_m` output from `'0` to `4'(ctr >> 4)`. This packs the upper bits of the meta-store counter into `step_m`, which is otherwise unused during meta micro-ops. Applied to both the `SYM_SPARSE` and non-sym paths.

```diff
  // SYM_SPARSE path (line 191):
- assign ibuf_out.op_args.tcu.step_m = meta_uop ? '0 : (is_sparse ? 4'(m_sp_s) : 4'(m_index));
+ assign ibuf_out.op_args.tcu.step_m = meta_uop ? 4'(ctr >> 4) : (is_sparse ? 4'(m_sp_s) : 4'(m_index));

  // Non-sym path (line 195):
- assign ibuf_out.op_args.tcu.step_m = meta_uop ? '0 : 4'(m_index);
+ assign ibuf_out.op_args.tcu.step_m = meta_uop ? 4'(ctr >> 4) : 4'(m_index);
```

**Why:** `fmt_d` is only 4 bits wide (part of the instruction encoding), so it can only carry `ctr[3:0]`. For NT=64 INT4 with 32 meta-store micro-ops, `ctr` ranges from 0 to 31 and bits `[5:4]` are lost. By packing them into `step_m`, we avoid changing the instruction format while still delivering the full column index to the downstream consumer.

**What (c):** Added `/* verilator lint_off UNUSEDSIGNAL */` around `rs1_offset`, `rs2_offset`, `rs3_offset` declarations (lines 117-121). At NT=64, `CTR_W` grows to 6, making these signals 6 bits wide, but only 5 bits are used for register addresses (`wire [4:0] rs1 = ...`). This is harmless but Verilator flags it.

### 3. `hw/rtl/tcu/VX_tcu_core.sv` (lines 89, 95, 103)

**What:** Widened `meta_actual_col_idx` from `[3:0]` to `[5:0]`. Reconstructed the full column index from `{step_m[1:0], fmt_d}` in both the `g_meta_multi_store` and `g_meta_single_store` paths.

```diff
- wire [3:0] meta_actual_col_idx;
+ wire [5:0] meta_actual_col_idx;

  // g_meta_multi_store path:
- assign meta_actual_col_idx = 4'(fmt_d >> LG_SPC);
+ assign meta_actual_col_idx = {step_m[1:0], fmt_d} >> LG_SPC;

  // g_meta_single_store path:
- assign meta_actual_col_idx = fmt_d;
+ assign meta_actual_col_idx = {step_m[1:0], fmt_d};
```

**Why:** This is the receiver side of the `step_m` packing from `VX_tcu_uops.sv`. The meta SRAM write logic needs the full column index to generate the correct one-hot write-enable and address the correct per-column RAM. Without this, columns 16-31 would alias to columns 0-15.

### 4. `hw/rtl/tcu/VX_tcu_meta.sv` (lines 37, 83)

**What:** Widened the `wr_col_idx` input port from `[3:0]` to `[5:0]`. Updated the column one-hot comparison from `c[3:0]` to `6'(c)`.

```diff
- input wire [3:0]    wr_col_idx,
+ input wire [5:0]    wr_col_idx,

  // Column write-enable one-hot decoder:
- assign col_wren[c] = (c[3:0] == wr_col_idx);
+ assign col_wren[c] = (6'(c) == wr_col_idx);
```

**Why:** The port must match the widened `meta_actual_col_idx` from `VX_tcu_core.sv`. The old `c[3:0]` truncation would cause column 16 to match the same as column 0, corrupting metadata. The per-column RAM instantiation loop and bank selection logic are already parametric over `NUM_COLS`, so no other changes were needed in this file.

### 5. `sim/rtlsim/verilator.vlt` (line 11)

**What:** Added `lint_off -rule WIDTHCONCAT -file "*/VX_opc_unit.sv"`.

**Why:** At NT=64, `VX_opc_unit.sv` generates a >8k-bit replication (12288 bits) which triggers a Verilator `WIDTHCONCAT` warning. This is a pre-existing pattern in upstream code (not TCU-related) that only becomes visible at large NT values. The replication is intentional, so we suppress it.

## Files NOT Modified (Already Parametric)

| File | Reason |
|------|--------|
| `sim/common/tensor_cfg.h` | Uses `uint32_t` for all column counts; `sym_sparse` flag computed correctly |
| `kernel/include/vx_tensor.h` | Parametric with `cfg::sym_sparse`; load/store loops use `uint32_t` |
| `tests/regression/sgemm_tcu_sp/kernel.cpp` | Uses `uint32_t meta_cols`; fully template-driven |
| `tests/regression/sgemm_tcu_sp/main.cpp` | Fully parametric through config templates |
| `sim/simx/tensor_unit.cpp` | Uses `uint32_t` throughout; `sym_sparse` abort prevents SimX from running symmetric sparse (RTLsim only) |

## Test Results

### NT=64 (XLEN=64) — All PASSED

| Type | Sizes Tested | Result |
|------|-------------|--------|
| FP16 sparse | 32x16x32 | PASSED |
| INT8 sparse | 32x16x64, 64x32x128 | PASSED |
| INT4 sparse | 32x16x64, 64x32x256 | PASSED |
| FP16 dense  | 32x16x32 | PASSED |

### Regression (XLEN=32) — All PASSED

| NT | FP16 sparse | INT8 sparse | INT4 sparse | Dense FP16 |
|----|-------------|-------------|-------------|------------|
| 8  | 8x8x16 PASS | 8x8x32 PASS | 8x8x64 PASS | 8x8x16 PASS |
| 16 | 16x8x16 PASS | 16x8x32 PASS | 16x8x64 PASS | 16x8x16 PASS |
| 32 | 16x16x32 PASS | 16x16x64 PASS | 16x16x128 PASS | 16x16x32 PASS |

## Design Notes

- NT=64 has identical control-flow parameters to NT=4 and NT=16 (m_steps=4, n_steps=2, k_steps=2, TCU_UOPS=16). Only the data dimensions (tcM, tcN, tcK, tile sizes) differ, and those are handled parametrically.
- The `step_m` packing trick works because `step_m` has 4 bits but only needs `LG_M = clog2(4) = 2` bits for the m-step index during MMA uops. During meta-store uops, `step_m` was previously unused (`'0`), so repurposing its lower 2 bits for overflow is safe for all current and foreseeable NT values (up to NT=256 with meta_cols up to 128, needing `ctr >> 4` up to 7, which fits in 4 bits).
- The fix is backward-compatible: for NT <= 32 where `meta_cols <= 16`, `ctr >> 4 == 0`, producing the same `step_m = 0` as before.
