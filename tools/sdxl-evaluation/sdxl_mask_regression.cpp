// Actual pinned SDK CPU interpolation only: no model, weights or GPU context.
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include "core/tensor.hpp"
#include "model.h"
#include "json.hpp"
#ifdef GLOWROOM_SDXL_MASK_PATCHED
#include "pipeline/inpaint_mask.h"
#endif
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#include "stb_image.h"

using json = nlohmann::json;
static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

static size_t protected_cells(const sd::Tensor<float>& tensor) {
    return std::count(tensor.values().begin(), tensor.values().end(), 0.f);
}

static void check_nearest_reference(const sd::Tensor<float>& input,
                                    const sd::Tensor<float>& output) {
    for (int64_t y = 0; y < output.shape()[1]; ++y) {
        for (int64_t x = 0; x < output.shape()[0]; ++x) {
            // PyTorch nearest maps by floor(output * input / output size).
            require(output.index(x, y, 0, 0) ==
                    input.index(x * input.shape()[0] / output.shape()[0],
                                y * input.shape()[1] / output.shape()[1], 0, 0),
                    "nearest coordinate/reference mismatch");
        }
    }
}

static sd::Tensor<float> actual(const sd::Tensor<float>& mask, int width, int height,
                                 int scale, SDVersion version) {
#ifdef GLOWROOM_SDXL_MASK_PATCHED
    return sd::pipeline::prepare_inpaint_latent_mask(mask, width, height, scale, version);
#else
    (void)version;
    return sd::ops::interpolate(mask, {width / scale, height / scale, 1, 1},
                                sd::ops::InterpolateMode::NearestMax);
#endif
}

int main(int argc, char** argv) {
    json report{{"schemaVersion", 1}, {"test", "sdk-sdxl-inpaint-mask-interpolation"},
                {"sdkBaseRevision", "8cd731e7b4667eb8f40a153315b9a7125d09a58d"},
                {"modelContextCreated", false}, {"inferenceExecuted", false},
                {"gpuContextCreated", false}};
#ifdef GLOWROOM_SDXL_MASK_PATCHED
    const bool patched = true;
#else
    const bool patched = false;
#endif
    report["mode"] = patched ? "sdxl-nearest-v1" : "expect-baseline-mask-loss";
    try {
        require(argc == 2, "expected frozen native fixture mask path");
        int width = 0, height = 0, channels = 0;
        require(stbi_info(argv[1], &width, &height, &channels) &&
                width == 512 && height == 512 && channels == 1, "fixture shape/type");
        std::unique_ptr<stbi_uc, decltype(&stbi_image_free)> pixels(
            stbi_load(argv[1], &width, &height, &channels, 1), &stbi_image_free);
        require(pixels != nullptr, "fixture decode failed");
        auto mask = sd::full<float>({1024, 1024, 1, 1}, 1.f);
        // Same integer translation and edge clamp as preprocessingVersion=1.
        // This bounded CPU copy is serial; a pool adds more setup than work.
        for (int y = 0; y < 1024; ++y) {
            const int sy = std::clamp(y - 256, 0, 511);
            for (int x = 0; x < 1024; ++x) {
                const int sx = std::clamp(x - 256, 0, 511);
                mask.index(x, y, 0, 0) = pixels.get()[sy * 512 + sx] >= 128 ? 1.f : 0.f;
            }
        }
        require(protected_cells(mask) == 9357, "native protected fixture pixel count");
        auto baseline = sd::ops::interpolate(mask, {128, 128, 1, 1},
                                             sd::ops::InterpolateMode::NearestMax);
        require(protected_cells(baseline) == 0, "baseline must reproduce complete latent motif loss");
        auto result = actual(mask, 1024, 1024, 8, VERSION_SDXL_INPAINT);
        require(protected_cells(result) == (patched ? 141 : 0), "fixture latent protected count");
        if (patched) check_nearest_reference(mask, result);
        report["fixture05"] = {{"nativeProtectedPixels", 9357}, {"latentCells", 16384},
                               {"baselineProtectedCells", 0},
                               {"actualProtectedCells", protected_cells(result)}};

        // Off-centre single pixels and stripes distinguish floor-nearest,
        // nearest-exact and max-reduction on asymmetric dimensions.
        auto asymmetric = sd::full<float>({40, 24, 1, 1}, 1.f);
        for (const auto& point : {std::pair{0, 0}, {8, 16}, {32, 8}, {17, 9}, {39, 23}})
            asymmetric.index(point.first, point.second, 0, 0) = 0.f;
        for (int x = 0; x < 40; ++x) asymmetric.index(x, 16, 0, 0) = 0.f;
        const auto expected_max = sd::ops::interpolate(asymmetric, {5, 3, 1, 1},
                                                       sd::ops::InterpolateMode::NearestMax);
        const auto selected = actual(asymmetric, 40, 24, 8, VERSION_SDXL_INPAINT);
        if (patched) {
            check_nearest_reference(asymmetric, selected);
            require(protected_cells(selected) == 7, "asymmetric nearest count");
        } else require(selected.values() == expected_max.values(), "baseline max reference");
        for (const auto version : {VERSION_SD1, VERSION_SD1_INPAINT, VERSION_SD2_INPAINT,
                                   VERSION_SDXL, VERSION_FLUX_FILL}) {
            require(actual(asymmetric, 40, 24, 8, version).values() == expected_max.values(),
                    "non-SDXL-inpaint interpolation changed");
        }
        for (float value : {0.f, 1.f}) {
            auto uniform = sd::full<float>({16, 24, 1, 1}, value);
            require(actual(uniform, 16, 24, 8, VERSION_SDXL_INPAINT).values() ==
                    std::vector<float>(6, value), "uniform mask changed");
        }
        report["asymmetricCoordinateReferencePassed"] = true;
        report["otherModelModesUnchanged"] = true;
        report["status"] = "pass";
        std::printf("%s\n", report.dump().c_str());
        return 0;
    } catch (const std::exception& error) {
        report["status"] = "fail"; report["reason"] = error.what();
        std::printf("%s\n", report.dump().c_str());
        return 1;
    }
}
