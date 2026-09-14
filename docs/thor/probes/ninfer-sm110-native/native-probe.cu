#include <cuda_runtime.h>
#include <cuda_bf16.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <vector>
#include "flashinfer/gemm/cutlass_gemm_configs.h"
#include "flashinfer/gemm/fp4_gemm_template_sm100.h"

namespace flashinfer::gemm {
INSTANTIATE_FP4_GEMM_KERNEL_LAUNCHER(__nv_bfloat16, 128, 128, 256, 1, 1, 1, _1SM)
using ProbeGemm = DeviceGemmFp4GemmSm100___nv_bfloat16_128_128_256_1_1_1_1SM::Gemm;
}

static void check(cudaError_t status) {
  if (status != cudaSuccess) throw std::runtime_error(cudaGetErrorString(status));
}
struct Buffer {
  void* p = nullptr;
  explicit Buffer(size_t n) { if (n) check(cudaMalloc(&p, n)); }
  ~Buffer() { if (p) cudaFree(p); }
  Buffer(const Buffer&) = delete;
  Buffer& operator=(const Buffer&) = delete;
};
constexpr int N = 5120, K = 17408;
constexpr float alpha = 0.75f;
static size_t sf_offset(int row, int k) {
  return size_t((row / 128) * (K / 64) + k / 64) * 512 +
         (row % 32) * 16 + ((row % 128) / 32) * 4 + (k / 16) % 4;
}
static uint32_t mix(uint32_t v) {
  v ^= v >> 16; v *= 0x7feb352dU; v ^= v >> 15; v *= 0x846ca68bU; return v ^ (v >> 16);
}
static double fp4(uint8_t v) {
  const double magnitude[] = {0, .5, 1, 1.5, 2, 3, 4, 6};
  return (v & 8 ? -1 : 1) * magnitude[v & 7];
}
static double fp8(uint8_t v) {
  int e = (v >> 3) & 15, f = v & 7;
  return e == 0 ? std::ldexp(double(f), -9) : std::ldexp(1.0 + double(f) / 8, e - 7);
}
static double bf16(uint16_t bits) {
  uint32_t fbits = uint32_t(bits) << 16;
  float v; std::memcpy(&v, &fbits, sizeof(v)); return v;
}
static void fill(std::vector<uint8_t>& codes, std::vector<uint8_t>& scales, int rows, uint32_t seed) {
  for (size_t i = 0; i < codes.size(); ++i) codes[i] = uint8_t(mix(uint32_t(i) ^ seed));
  for (int r = 0; r < rows; ++r)
    for (int k = 0; k < K; k += 16)
      scales[sf_offset(r, k)] = uint8_t(0x18 + (mix(uint32_t(r * (K / 16) + k / 16) ^ seed) % 32));
}
static double value(const std::vector<uint8_t>& codes, const std::vector<uint8_t>& scales, int row, int k) {
  uint8_t b = codes[size_t(row) * (K / 2) + k / 2];
  return fp4(k & 1 ? b >> 4 : b & 15) * fp8(scales[sf_offset(row, k)]);
}
static size_t launch(void* d, const void* a, const void* b, const void* sa, const void* sb,
                     const float* global, int m, char* work, size_t bytes) {
  return flashinfer::gemm::genericFp4GemmKernelLauncher<__nv_bfloat16,
      cute::Int<128>, cute::Int<128>, cute::Int<256>, cute::Int<1>, cute::Int<1>, cute::Int<1>,
      flashinfer::gemm::_1SM>(d, a, b, sa, sb, global, m, N, K, 1,
          flashinfer::gemm::CutlassGemmConfig{}, work, bytes, nullptr, nullptr);
}
template<class Layout> static size_t verify_layout(const Layout& layout, int rows) {
  size_t checked = 0;
  for (int r = 0; r < rows; ++r) {
    for (int k = 0; k < K; ++k) {
      auto observed = size_t(layout(cute::make_coord(r, k, 0)));
      auto expected = sf_offset(r, k);
      if (observed != expected) throw std::runtime_error("scale layout mismatch row=" +
          std::to_string(r) + " k=" + std::to_string(k) + " got=" + std::to_string(observed) +
          " expected=" + std::to_string(expected));
      ++checked;
    }
  }
  return checked;
}
static std::vector<int> sample_indices(int extent, int count) {
  std::vector<int> out;
  for (int i = 0; i < std::min(extent, count); ++i)
    out.push_back(i * (extent - 1) / (std::min(extent, count) - 1 == 0 ? 1 : std::min(extent, count) - 1));
  return out;
}
int main() try {
  cudaDeviceProp prop{}; check(cudaGetDeviceProperties(&prop, 0));
  int driver, runtime; check(cudaDriverGetVersion(&driver)); check(cudaRuntimeGetVersion(&runtime));
  std::cout << std::setprecision(10) << "{\"kind\":\"environment\",\"device\":\"" << prop.name
      << "\",\"sm\":" << prop.major * 10 + prop.minor << ",\"driver\":" << driver
      << ",\"runtime\":" << runtime << ",\"flashinfer\":\"0.6.17/a0a6b019b9b27d49d209f85d028a1ae5a9b347d7\"" << ",\"note\":\"native GEMM only; prepacked NVFP4 A/B; excludes BF16 quantization and residual addition\"}" << std::endl;
  if (prop.major != 11) throw std::runtime_error("probe expected SM110 Thor");
  using Config = flashinfer::gemm::ProbeGemm::GemmKernel::CollectiveMainloop::Sm1xxBlkScaledConfig;
  std::vector<uint8_t> b(size_t(N) * K / 2), sb(size_t(N) * K / 16);
  fill(b, sb, N, 0xc492d512);
  Buffer db(b.size()), dsb(sb.size()), dg(sizeof(float)), flush(256ULL << 20);
  check(cudaMemcpy(db.p, b.data(), b.size(), cudaMemcpyHostToDevice));
  check(cudaMemcpy(dsb.p, sb.data(), sb.size(), cudaMemcpyHostToDevice));
  check(cudaMemcpy(dg.p, &alpha, sizeof(alpha), cudaMemcpyHostToDevice));
  cudaEvent_t start, end; check(cudaEventCreate(&start)); check(cudaEventCreate(&end));
  size_t b_checked = verify_layout(Config::tile_atom_to_shape_SFB(cute::make_shape(128, N, K, 1)), N);
  std::cout << "{\"kind\":\"weight_layout\",\"checked_coordinates\":" << b_checked << ",\"pass\":true}" << std::endl;
  int total_failures = 0;
  for (int m : {1, 8, 16, 17, 32, 64, 127, 129, 256, 1024}) {
    int padded_m = (m + 127) / 128 * 128;
    auto layout = Config::tile_atom_to_shape_SFA(cute::make_shape(m, N, K, 1));
    size_t a_checked = verify_layout(layout, padded_m);
    std::vector<uint8_t> a(size_t(m) * K / 2), sa(size_t(padded_m) * K / 16, 0);
    fill(a, sa, m, 0xf27a8173);
    Buffer da(a.size()), dsa(sa.size()), dd(size_t(m) * N * sizeof(uint16_t));
    check(cudaMemcpy(da.p, a.data(), a.size(), cudaMemcpyHostToDevice));
    check(cudaMemcpy(dsa.p, sa.data(), sa.size(), cudaMemcpyHostToDevice));
    auto bytes = launch(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, m, nullptr, 0);
    Buffer work(bytes);
    auto run = [&] { launch(dd.p, da.p, db.p, dsa.p, dsb.p, static_cast<const float*>(dg.p), m, static_cast<char*>(work.p), bytes); };
    run(); check(cudaDeviceSynchronize());
    std::vector<uint16_t> out(size_t(m) * N);
    check(cudaMemcpy(out.data(), dd.p, out.size() * sizeof(uint16_t), cudaMemcpyDeviceToHost));
    int failures = 0, samples = 0;
    double max_abs = 0, max_ratio = 0;
    for (int r : sample_indices(m, 16)) for (int c : sample_indices(N, 32)) {
      double ref = 0, sum_abs = 0;
      for (int k = 0; k < K; ++k) {
        double term = value(a, sa, r, k) * value(b, sb, c, k);
        ref += term; sum_abs += std::abs(term);
      }
      ref *= alpha; sum_abs *= alpha;
      double actual = bf16(out[size_t(r) * N + c]);
      double error = std::abs(actual - ref);
      // BF16 half-ULP envelope plus FP32 reduction error; no relative-error exception at cancellation.
      double tolerance = std::abs(ref) * 0.00390625 + sum_abs * 0.000002 + 0.000001;
      max_abs = std::max(max_abs, error); max_ratio = std::max(max_ratio, error / tolerance);
      if (!std::isfinite(actual) || error > tolerance) {
        if (failures < 5) std::cerr << "oracle failure m=" << m << " row=" << r << " col=" << c << " ref=" << ref << " actual=" << actual << " tolerance=" << tolerance << '\n';
        ++failures;
      }
      ++samples;
    }
    for (auto v : out) if (!std::isfinite(bf16(v))) ++failures;
    for (int i = 0; i < 10; ++i) run();
    check(cudaDeviceSynchronize());
    std::vector<float> warm, cold;
    for (bool is_cold : {false, true}) for (int i = 0; i < 30; ++i) {
      if (is_cold) check(cudaMemsetAsync(flush.p, i + 1, 256ULL << 20));
      check(cudaEventRecord(start)); run(); check(cudaEventRecord(end)); check(cudaEventSynchronize(end));
      float elapsed; check(cudaEventElapsedTime(&elapsed, start, end));
      (is_cold ? cold : warm).push_back(elapsed);
    }
    std::sort(warm.begin(), warm.end()); std::sort(cold.begin(), cold.end());
    std::cout << "{\"kind\":\"result\",\"m\":" << m << ",\"n\":" << N << ",\"k\":" << K
      << ",\"alpha\":" << alpha << ",\"layout_checked_coordinates\":" << a_checked
      << ",\"oracle_samples\":" << samples << ",\"failures\":" << failures
      << ",\"max_abs_error\":" << max_abs << ",\"max_error_tolerance_ratio\":" << max_ratio
      << ",\"workspace_bytes\":" << bytes << ",\"warm_median_ms\":" << (warm[14] + warm[15]) / 2
      << ",\"cold_median_ms\":" << (cold[14] + cold[15]) / 2 << ",\"repeat\":30}" << std::endl;
    total_failures += failures;
  }
  check(cudaEventDestroy(start)); check(cudaEventDestroy(end));
  return total_failures ? 1 : 0;
} catch (const std::exception& e) { std::cerr << "fatal: " << e.what() << std::endl; return 2; }
