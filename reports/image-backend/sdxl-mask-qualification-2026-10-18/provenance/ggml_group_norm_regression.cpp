// Actual public GGML CPU/Metal graphs, without model files or SDK contexts.
// Pinned baseline: ggml d25b121ce1d6ae0c7e62ad080460d9fc1e46dd93.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>
#include "ggml.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "ggml-metal.h"
#include "json.hpp"

using json = nlohmann::json;
static constexpr int width = 7, height = 5, channels = 64, groups = 32;
static constexpr size_t values_per_batch = size_t(width) * height * channels;
static constexpr uint32_t sentinel_bits = 0x7fc12345U;
static constexpr double tolerance = 1e-4;
static_assert(sizeof(float) == sizeof(uint32_t) && std::numeric_limits<float>::is_iec559,
              "the regression sentinel requires IEEE-754 F32");

struct Backend {
    ggml_backend_t value = nullptr;
    ~Backend() { if (value) ggml_backend_free(value); }
};

struct Graph {
    ggml_context* context = nullptr;
    ggml_backend_buffer_t buffer = nullptr;
    ~Graph() {
        if (buffer) ggml_backend_buffer_free(buffer);
        if (context) ggml_free(context);
    }
};

static std::vector<float> compute(ggml_backend_t backend, int batches) {
    if (batches < 1 || batches > 3) throw std::runtime_error("fixture-batch-bound");
    const size_t count = values_per_batch * size_t(batches);
    if (count * sizeof(float) > 32 * 1024) throw std::runtime_error("fixture-byte-bound");
    Graph owner;
    owner.context = ggml_init({64 * 1024, nullptr, true});
    if (!owner.context) throw std::runtime_error("graph-context-allocation-failed");
    auto* input = ggml_new_tensor_4d(owner.context, GGML_TYPE_F32, width, height, channels, batches);
    auto* output = ggml_group_norm(owner.context, input, groups, 1e-6f);
    ggml_set_input(input); ggml_set_output(output);
    if (!ggml_backend_supports_op(backend, output)) throw std::runtime_error("group-norm-operation-unavailable");
    auto* graph = ggml_new_graph_custom(owner.context, 16, false);
    ggml_build_forward_expand(graph, output);
    owner.buffer = ggml_backend_alloc_ctx_tensors(owner.context, backend);
    if (!owner.buffer) throw std::runtime_error("backend-buffer-allocation-failed");
    if (!ggml_is_contiguous(input) || !ggml_is_contiguous(output) ||
        ggml_nbytes(input) != count * sizeof(float) || ggml_nbytes(output) != count * sizeof(float))
        throw std::runtime_error("fixture-tensor-layout-unexpected");

    std::vector<float> source(count), result(count);
    for (int batch = 0; batch < batches; ++batch) {
        for (size_t i = 0; i < values_per_batch; ++i) {
            // Different, non-affine patterns make accidental batch reuse fail.
            source[size_t(batch) * values_per_batch + i] =
                float(int((i * 17 + size_t(batch) * 29) % 101) - 50) / 17.f +
                float(batch) * 0.7f + float((i / (width * height)) % 8) * 0.02f;
        }
    }
    float sentinel;
    std::memcpy(&sentinel, &sentinel_bits, sizeof(sentinel));
    std::fill(result.begin(), result.end(), sentinel);
    ggml_backend_tensor_set(input, source.data(), 0, source.size() * sizeof(float));
    ggml_backend_tensor_set(output, result.data(), 0, result.size() * sizeof(float));
    const auto status = ggml_backend_graph_compute(backend, graph);
    ggml_backend_synchronize(backend);
    if (status != GGML_STATUS_SUCCESS) throw std::runtime_error("backend-graph-compute-failed");
    ggml_backend_tensor_get(output, result.data(), 0, result.size() * sizeof(float));
    return result;
}

int main(int argc, char** argv) {
    const bool baseline = argc == 2 && std::strcmp(argv[1], "--expect-baseline-bug") == 0;
    json report{{"schemaVersion", 1}, {"test", "public-ggml-metal-group-norm-batch"},
                {"ggmlBaseRevision", "d25b121ce1d6ae0c7e62ad080460d9fc1e46dd93"},
                {"mode", baseline ? "expect-baseline-bug" : "all-batches-must-pass"},
                {"absoluteTolerance", tolerance}, {"maximumValuesPerBackendCase", values_per_batch * 3},
                {"maximumBytesPerBackendCase", values_per_batch * 3 * sizeof(float)},
                {"cpuBackendAvailable", false}, {"metalBackendAvailable", false},
                {"modelContextCreated", false}, {"inferenceExecuted", false}, {"cases", json::array()}};
    auto finish = [&](const char* status, const char* reason, int code) {
        report["status"] = status;
        if (reason) report["reason"] = reason;
        std::printf("%s\n", report.dump().c_str());
        return code;
    };
    if (argc != 1 && !baseline) return finish("environment-error", "invalid-arguments", 2);
    // Keep SDK/Metal diagnostics off the single JSON result line on stdout.
    ggml_log_set([](ggml_log_level, const char* text, void*) { if (text) std::fputs(text, stderr); }, nullptr);
    try {
        Backend cpu, metal;
        cpu.value = ggml_backend_cpu_init();
        report["cpuBackendAvailable"] = cpu.value != nullptr;
        if (!cpu.value) return finish("environment-error", "cpu-backend-unavailable", 2);
        ggml_backend_cpu_set_n_threads(cpu.value, 2);
        report["cpuBackend"] = ggml_backend_name(cpu.value);
        metal.value = ggml_backend_metal_init();
        report["metalBackendAvailable"] = metal.value != nullptr;
        if (!metal.value || !ggml_backend_is_metal(metal.value))
            return finish("environment-error", "metal-backend-unavailable", 2);
        report["metalBackend"] = ggml_backend_name(metal.value);
        if (auto* device = ggml_backend_get_device(metal.value))
            report["metalDevice"] = ggml_backend_dev_description(device);

        bool all_passed = true, baseline_reproduced = true;
        for (const int batches : {1, 2, 3}) {
            const auto reference = compute(cpu.value, batches);
            const auto actual = compute(metal.value, batches);
            json test{{"dimensions", {width, height, channels, batches}}, {"numValues", reference.size()},
                      {"groups", groups}, {"batches", json::array()}};
            bool case_passed = true, case_baseline = true;
            for (int batch = 0; batch < batches; ++batch) {
                size_t finite = 0, nonfinite = 0, untouched = 0;
                double maximum_error = 0;
                for (size_t i = 0; i < values_per_batch; ++i) {
                    const size_t index = size_t(batch) * values_per_batch + i;
                    if (!std::isfinite(reference[index]))
                        throw std::runtime_error("cpu-reference-nonfinite");
                    uint32_t bits;
                    std::memcpy(&bits, &actual[index], sizeof(bits));
                    untouched += bits == sentinel_bits;
                    if (!std::isfinite(actual[index])) ++nonfinite;
                    else { ++finite; maximum_error = std::max(maximum_error, std::abs(double(actual[index]) - reference[index])); }
                }
                const bool matched = finite == values_per_batch && maximum_error <= tolerance;
                const bool expected_baseline = batch == 0 ? matched : untouched == values_per_batch;
                case_passed = case_passed && matched;
                case_baseline = case_baseline && expected_baseline;
                test["batches"].push_back({{"index", batch}, {"numValues", values_per_batch},
                    {"cpuFinite", true}, {"metalFiniteValues", finite}, {"metalNonfiniteValues", nonfinite},
                    {"unchangedNaNSentinelValues", untouched},
                    {"maximumAbsoluteErrorOfFiniteValues", finite ? json(maximum_error) : json(nullptr)},
                    {"allValuesFiniteAndMatched", matched}});
            }
            test["allBatchesPassed"] = case_passed;
            test["status"] = case_passed ? "pass" : case_baseline ? "baseline-batch-write-bug" : "regression-failure";
            report["cases"].push_back(test);
            all_passed = all_passed && case_passed;
            baseline_reproduced = baseline_reproduced && case_baseline && (batches == 1 || !case_passed);
        }
        report["allBatchesPassed"] = all_passed;
        report["expectedBaselineBugReproduced"] = baseline_reproduced;
        if (baseline)
            return finish(baseline_reproduced ? "pass" : "regression-failure",
                          baseline_reproduced ? nullptr : "expected-baseline-bug-not-reproduced", baseline_reproduced ? 0 : 1);
        return finish(all_passed ? "pass" : "regression-failure",
                      all_passed ? nullptr : "metal-group-norm-differs-from-cpu", all_passed ? 0 : 1);
    } catch (const std::exception& error) {
        return finish("environment-error", error.what(), 2);
    }
}
