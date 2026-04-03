#include "common.h"
#include <vx_spawn2.h>
#include <vx_tensor.h>
#include <vx_intrinsics.h>

namespace vt = vortex::tensor;
using ctx = vt::wmma_context<NUM_THREADS, vt::ITYPE, vt::OTYPE>;

extern "C" void kernel_main(kernel_arg_t* __UNIFORM__ arg) {
  auto pA = reinterpret_cast<ctx::input_t *>(arg->A_addr);
  auto pB = reinterpret_cast<ctx::input_t *>(arg->B_addr);
  auto pC = reinterpret_cast<ctx::output_t *>(arg->C_addr);

  uint32_t M = arg->M;
  uint32_t N = arg->N;
  uint32_t K = arg->K;

  ctx::fragment_a   fragA;
  ctx::fragment_b   fragB;
  ctx::fragment_acc fragC;

  // calculate tile row & column based on block index
  uint32_t tile_row = blockIdx.y * ctx::tileM;
  uint32_t tile_col = blockIdx.x * ctx::tileN;

  // Initialize accumulator tile to zero
  ctx::fill_fragment(fragC, 0);

  uint32_t start_cycles = csr_read(VX_CSR_MCYCLE);

  if constexpr (vt::ITYPE::bits >= 8) {
    // Tiled col-major B: tiles of tileN×tileK, ldm=tileK
    auto pTileB = pB + blockIdx.x * K * ctx::tileN;
    for (int i = 0; i < K; i += ctx::tileK) {
      auto pTileA = pA + tile_row * K + i;
      ctx::load_matrix_sync(fragA, pTileA, K);
      ctx::load_matrix_sync<vt::col_major>(fragB, pTileB, ctx::tileK);
      ctx::mma_sync(fragC, fragA, fragB, fragC);
      pTileB += ctx::tileN * ctx::tileK;
    }
  } else {
    // Sub-byte: regular col-major B with ldm=K
    for (int i = 0; i < K; i += ctx::tileK) {
      auto pTileA = pA + tile_row * K + i;
      ctx::load_matrix_sync(fragA, pTileA, K);
      auto pTileB = pB + tile_col * K + i;
      ctx::load_matrix_sync<vt::col_major>(fragB, pTileB, K);
      ctx::mma_sync(fragC, fragA, fragB, fragC);
    }
  }

  // Store the computed C tile
  auto pTileC = pC + tile_row * N + tile_col;
  ctx::store_matrix_sync(pTileC, fragC, N);

  uint32_t end_cycles = csr_read(VX_CSR_MCYCLE);

  // Write per-block cycle count
  auto pCycles = reinterpret_cast<uint32_t*>(arg->cycles_addr);
  uint32_t block_id = blockIdx.y * arg->grid_dim[0] + blockIdx.x;
  pCycles[block_id] = end_cycles - start_cycles;
}
