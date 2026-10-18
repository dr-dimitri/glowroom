// Real pinned SDK scheduler/SamplePlan and CPU tensors; no model weights.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <string>
#include "ggml-cpu.h"
#include "json.hpp"
#include "model/vae/vae.hpp"
#include "pipeline/diffusion_engine.h"
#include "pipeline/request.h"
#include "runtime/denoiser.hpp"
#include "sdxl_reference_schedule.h"

using json = nlohmann::json;
static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

// This is the pinned image.cpp ordinary strength branch. The builder verifies
// its source text before compiling this test; this probe does not execute the
// full private VAE/image preparation function. Actual prediction logs must
// separately confirm the effective step count on the image path.
static std::vector<float> image_strength_slice(const std::vector<float>& sigmas,
                                               int sample_steps, float strength) {
    size_t t_enc = static_cast<size_t>(sample_steps * strength);
    if (t_enc == static_cast<size_t>(sample_steps)) t_enc--;
    return {sigmas.begin() + sample_steps - t_enc - 1, sigmas.end()};
}

int main(int argc, char** argv) {
    json report{{"schemaVersion", 1}, {"test", "sdk-sdxl-reference-euler-schedule"},
                {"sdkBaseRevision", "8cd731e7b4667eb8f40a153315b9a7125d09a58d"},
                {"modelWeightsLoaded", false}, {"inferenceExecuted", false},
                {"vaeEncodeExecuted", false}, {"gpuContextCreated", false},
                {"strengthSliceCheck", "source-matched expression; private image preparation not executed"}};
    try {
        const bool baseline = argc == 2 && std::string(argv[1]) == "--expect-baseline-mismatch";
        require(argc == 1 || baseline, "invalid arguments");
        report["mode"] = baseline ? "expect-baseline-mismatch" : picedit_sdxl::schedule_variant;
        std::unique_ptr<ggml_backend, decltype(&ggml_backend_free)> cpu(
            ggml_backend_cpu_init(), &ggml_backend_free);
        require(cpu != nullptr, "CPU backend missing");
        StableDiffusionGGML sdk;
        sdk.version = VERSION_SDXL_INPAINT;
        // SDK FakeVAE supplies only the scale-factor metadata needed by the
        // actual GenerationRequest constructor. It never encodes an image.
        sdk.first_stage_model = std::make_shared<FakeVAE>(sdk.version, cpu.get());
        sdk.refresh_compvis_denoiser_sigmas();
        report["sdkEngineObjectCreated"] = true;
        report["sdkMetadataOnlyFakeVAECreated"] = true;
        report["cpuBackendCreated"] = true;
        sd_img_gen_params_t parameters;
        sd_img_gen_params_init(&parameters);
        parameters.width = 1024; parameters.height = 1024;
        parameters.seed = 1234; parameters.strength = 0.99f;
        parameters.sample_params.sample_method = EULER_SAMPLE_METHOD;
        parameters.sample_params.scheduler = DISCRETE_SCHEDULER;
        parameters.sample_params.sample_steps = picedit_sdxl::configured_steps;
        parameters.sample_params.eta = 0.f;
        parameters.sample_params.guidance.txt_cfg = 8.f;
        auto sigmas = picedit_sdxl::reference_sigmas();
        if (!baseline) {
            parameters.sample_params.custom_sigmas = sigmas.data();
            parameters.sample_params.custom_sigmas_count = static_cast<int>(sigmas.size());
        }
        sd::pipeline::GenerationRequest request(&sdk, &parameters);
        sd::pipeline::SamplePlan plan(&sdk, &parameters, request);
        const auto effective = image_strength_slice(plan.sigmas, plan.sample_steps, request.strength);
        const auto timesteps = picedit_sdxl::reference_timesteps();
        report["planSampleSteps"] = plan.sample_steps;
        report["effectiveSampleSteps"] = effective.size() - 1;
        report["effectiveSigmas"] = effective;
        report["firstReconstructedTimestep"] = sdk.denoiser->sigma_to_t(effective.front());
        if (baseline) {
            require(plan.sample_steps == 20 && effective.size() == 21,
                    "baseline must reproduce 20 actual steps at strength .99");
            require(std::abs(sdk.denoiser->sigma_to_t(effective.front()) - 999.f) < 0.001f,
                    "baseline must start at timestep 999");
            require(effective.front() > sigmas.front() + 6.f,
                    "baseline first sigma must differ materially from the leading reference");
            report["baselineMismatchReproduced"] = true;
        } else {
            require(plan.sample_steps == picedit_sdxl::actual_steps && plan.total_steps == 19,
                    "actual SDK custom schedule did not set 19 steps");
            require(plan.sigmas == std::vector<float>(sigmas.begin(), sigmas.end()),
                    "actual SDK custom schedule values changed");
            require(effective == plan.sigmas, "strength .99 unexpectedly trimmed the custom schedule again");
            require(effective.back() == 0.f, "terminal sigma must be exactly zero");
            double product = 1.;
            std::array<double, TIMESTEPS> reference{};
            for (int i = 0; i < TIMESTEPS; ++i) {
                const double beta_root = std::sqrt(.00085) +
                    (std::sqrt(.012) - std::sqrt(.00085)) * i / (TIMESTEPS - 1);
                product *= 1. - beta_root * beta_root;
                reference[i] = std::sqrt((1. - product) / product);
            }
            float max_error = 0.f;
            for (size_t i = 0; i < timesteps.size(); ++i) {
                require(std::abs(sigmas[i] - reference[timesteps[i]]) < 0.00001,
                        "frozen float sigma exceeds independent double-precision tolerance");
                require(sigmas[i] > sigmas[i + 1] && std::isfinite(sigmas[i]),
                        "nonfinite or nondecreasing schedule");
                const float error = std::abs(sdk.denoiser->sigma_to_t(sigmas[i]) - timesteps[i]);
                max_error = std::max(max_error, error);
                require(error < 0.002f, "SDK float timestep reconstruction exceeds frozen tolerance");
                const auto scaling = sdk.denoiser->get_scalings(sigmas[i]);
                require(scaling[0] == 1.f && scaling[1] == -sigmas[i], "epsilon scalings changed");
                require(std::abs(scaling[2] - 1.f / std::sqrt(sigmas[i] * sigmas[i] + 1.f)) < 1e-7f,
                        "Euler model-input scaling changed");
            }
            report["maxSDKTimestepReconstructionError"] = max_error;
            report["timestepTolerance"] = 0.002;
            report["actualSDKCustomScheduleSelectionPassed"] = true;
            report["sourceMatchedStrengthSlicePassed"] = true;
            report["independentSigmaDerivationPassed"] = true;
            report["doublePrecisionSigmaTolerance"] = 0.00001;
            report["pixelwiseDiffusersEquivalenceClaimed"] = false;
        }
        report["status"] = "pass";
        std::printf("%s\n", report.dump().c_str());
        return 0;
    } catch (const std::exception& error) {
        report["status"] = "fail"; report["reason"] = error.what();
        std::printf("%s\n", report.dump().c_str());
        return 1;
    }
}
