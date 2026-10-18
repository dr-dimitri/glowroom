// Actual pinned SDK CPU tensor primitives; no backend, weights or image encode.
#include <algorithm>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include "core/tensor.hpp"
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#include "stb_image.h"

static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
static size_t protected_cells(const sd::Tensor<float>& tensor) {
    return std::count(tensor.values().begin(), tensor.values().end(), 0.f);
}
// This expression is verified against the pinned diffusion_engine.cpp by the
// runner. The actual tensor operations below come directly from the SDK header.
static bool applies_denoise_mask(const sd::Tensor<float>& denoise_mask) {
    return !denoise_mask.empty() &&
           std::any_of(denoise_mask.values().begin(), denoise_mask.values().end(),
                       [](float value) { return value != 1.f; });
}
int main(int argc, char** argv) {
    try {
        require(argc == 2, "expected frozen native fixture mask path");
        int width = 0, height = 0, channels = 0;
        require(stbi_info(argv[1], &width, &height, &channels) &&
                width == 512 && height == 512 && channels == 1, "fixture shape/type");
        std::unique_ptr<stbi_uc, decltype(&stbi_image_free)> pixels(
            stbi_load(argv[1], &width, &height, &channels, 1), &stbi_image_free);
        require(pixels != nullptr, "fixture decode failed");
        auto mask = sd::full<float>({1024, 1024, 1, 1}, 1.f);
        // One small serial CPU copy avoids thread-pool overhead. These are the
        // existing preprocessingVersion=1 integer translation/edge clamps.
        for (int y = 0; y < 1024; ++y) {
            for (int x = 0; x < 1024; ++x) {
                mask.index(x, y, 0, 0) = pixels.get()[std::clamp(y - 256, 0, 511) * 512 +
                                                     std::clamp(x - 256, 0, 511)] >= 128 ? 1.f : 0.f;
            }
        }
        // V9's SDXL selector uses Nearest, then the existing image pipeline
        // max-pools only the denoise mask after copying the conditioning mask.
        auto nearest = sd::ops::interpolate(mask, {128, 128, 1, 1}, sd::ops::InterpolateMode::Nearest);
        const auto denoise = sd::ops::max_pool_2d(nearest, {3, 3}, {1, 1}, {1, 1});
        require(protected_cells(mask) == 9357, "native protected count");
        require(protected_cells(nearest) == 141, "V9 nearest protected count");
        require(protected_cells(denoise) == 0 && !applies_denoise_mask(denoise),
                "fixture05 must reproduce an already-disabled original-latent blend");
        // Positive control prevents an always-false selector from proving the
        // no-op. A wider protected area survives the same real SDK operation.
        auto wide = sd::full<float>({16, 16, 1, 1}, 1.f);
        for (int y = 4; y < 12; ++y)
            for (int x = 4; x < 12; ++x) wide.index(x, y, 0, 0) = 0.f;
        const auto wide_denoise = sd::ops::max_pool_2d(wide, {3, 3}, {1, 1}, {1, 1});
        require(protected_cells(wide_denoise) == 36 && applies_denoise_mask(wide_denoise),
                "wide-mask positive control failed");
        require(!applies_denoise_mask(sd::Tensor<float>()), "empty mask must not blend");
        std::printf("{\"schemaVersion\":1,\"test\":\"v9-fixture05-denoise-blend-noop\","
                    "\"status\":\"pass\",\"nativeProtectedPixels\":%zu,\"nearestProtectedCells\":%zu,"
                    "\"denoiseProtectedCellsAfterSDKMaxPool\":%zu,\"applyDenoiseMask\":false,"
                    "\"wideMaskPositiveControlProtectedCells\":%zu,\"wideMaskAppliesDenoiseMask\":true,"
                    "\"actualPinnedSDKTensorPrimitives\":true,\"modelWeightsLoaded\":false,"
                    "\"inferenceExecuted\":false,\"gpuContextCreated\":false}\n",
                    protected_cells(mask), protected_cells(nearest), protected_cells(denoise),
                    protected_cells(wide_denoise));
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "denoise-mask probe failed: %s\n", error.what());
        return 1;
    }
}
