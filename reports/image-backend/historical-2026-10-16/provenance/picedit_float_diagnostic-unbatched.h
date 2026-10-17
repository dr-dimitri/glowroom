// Evaluation-only aggregate statistics. No pixel/tensor arrays are logged.
// This header is used solely by two separate instrumented source copies.
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iomanip>
#include <limits>
#include <sstream>
#include "core/tensor.hpp"
#include "core/util.h"

static inline bool picedit_float_diagnostic(const char* stage, const sd::Tensor<float>& tensor, int denoise_call = 0) {
    constexpr int64_t maximum_elements = 4 * 1024 * 1024;
    const int64_t count = tensor.numel();
    if (count <= 0 || count > maximum_elements) {
        LOG_INFO("PICEDIT_FLOAT_DIAGNOSTIC {\"stage\":\"%s\",\"elementCount\":%lld,\"status\":\"invalid-tensor-bound\"}", stage, static_cast<long long>(count));
        return false;
    }
    uint64_t finite = 0, nan = 0, positive_inf = 0, negative_inf = 0, zeros = 0;
    float minimum = std::numeric_limits<float>::infinity();
    float maximum = -std::numeric_limits<float>::infinity();
    const float* values = tensor.data();
    for (int64_t i = 0; i < count; ++i) {
        const float value = values[i];
        if (std::isnan(value)) ++nan;
        else if (std::isinf(value)) { if (value > 0) ++positive_inf; else ++negative_inf; }
        else {
            ++finite;
            if (value == 0.f) ++zeros;
            minimum = std::min(minimum, value);
            maximum = std::max(maximum, value);
        }
    }
    std::ostringstream out;
    out << std::setprecision(17)
        << "PICEDIT_FLOAT_DIAGNOSTIC {\"denoiseCall\":" << denoise_call << ",\"stage\":\"" << stage
        << "\",\"elementCount\":" << count << ",\"finiteCount\":" << finite
        << ",\"nanCount\":" << nan << ",\"positiveInfCount\":" << positive_inf
        << ",\"negativeInfCount\":" << negative_inf << ",\"zeroCount\":" << zeros
        << ",\"finiteMinimum\":";
    if (finite) out << minimum; else out << "null";
    out << ",\"finiteMaximum\":";
    if (finite) out << maximum; else out << "null";
    out << ",\"shape\":[";
    for (size_t i = 0; i < tensor.shape().size(); ++i) {
        if (i) out << ',';
        out << tensor.shape()[i];
    }
    out << "],\"status\":\"" << ((nan || positive_inf || negative_inf) ? "nonfinite" : "finite") << "\"}";
    LOG_INFO("%s", out.str().c_str());
    return !(nan || positive_inf || negative_inf);
}

// Diagnostic only: compare the SDK's actual CFG output with an independent
// double-precision expression. Eight float epsilons bound normal F32 rounding
// in subtract/multiply/add, scaled to the actual operands. No result is altered.
static inline bool picedit_cfg_diagnostic(const sd::Tensor<float>& positive,
                                         const sd::Tensor<float>& negative,
                                         const sd::Tensor<float>& guided,
                                         float scale, int denoise_call) {
    if (positive.empty() || positive.shape() != negative.shape() || positive.shape() != guided.shape() ||
        positive.numel() > 4 * 1024 * 1024 || !std::isfinite(scale)) return false;
    uint64_t violations = 0, distinct_branch_elements = 0;
    const bool branch_storage_aliased = positive.data() == negative.data();
    double maximum_error = 0.0, maximum_bound = 0.0, maximum_branch_difference = 0.0;
    for (int64_t i = 0; i < positive.numel(); ++i) {
        const double p = positive[i], n = negative[i], actual = guided[i];
        const double expected = n + static_cast<double>(scale) * (p - n);
        if (p != n) ++distinct_branch_elements;
        maximum_branch_difference = std::max(maximum_branch_difference, std::abs(p - n));
        const double bound = 8.0 * std::numeric_limits<float>::epsilon() *
            (std::abs(n) + std::abs(static_cast<double>(scale)) * (std::abs(p) + std::abs(n)) + 1.0);
        const double error = std::abs(actual - expected);
        if (!std::isfinite(actual) || !std::isfinite(expected) || error > bound) ++violations;
        if (std::isfinite(error)) maximum_error = std::max(maximum_error, error);
        maximum_bound = std::max(maximum_bound, bound);
    }
    std::ostringstream out;
    out << std::setprecision(17)
        << "PICEDIT_FLOAT_DIAGNOSTIC {\"stage\":\"actual-cfg-reference-check\",\"denoiseCall\":" << denoise_call
        << ",\"elementCount\":" << positive.numel() << ",\"cfgScale\":" << scale
        << ",\"maximumAbsoluteError\":" << maximum_error << ",\"maximumAllowedError\":" << maximum_bound
        << ",\"violations\":" << violations
        << ",\"distinctBranchElements\":" << distinct_branch_elements
        << ",\"maximumBranchDifference\":" << maximum_branch_difference
        << ",\"branchStorageAliased\":" << (branch_storage_aliased ? "true" : "false")
        << ",\"status\":\"" << ((violations || branch_storage_aliased) ? "guidance-mismatch" : "finite") << "\"}";
    LOG_INFO("%s", out.str().c_str());
    return violations == 0 && !branch_storage_aliased;
}
