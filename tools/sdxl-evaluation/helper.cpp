// Evaluation-only public-C-API bridge. No product backend is installed.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <limits>
#include <mach/mach.h>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <sys/resource.h>
#include <thread>
#include <unistd.h>
#include <vector>
#include "stable-diffusion.h"
#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-alloc.h"
#include "ggml-cpu.h"
#include "json.hpp"
#include "sdxl_reference_schedule.h"
#define STBI_ONLY_PNG
#define STBI_MAX_DIMENSIONS 1024
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

using json = nlohmann::json;
using Clock = std::chrono::steady_clock;
namespace fs = std::filesystem;
static fs::path root;
static FILE* protocol = nullptr;
static std::mutex output_mutex, context_mutex;
static std::mutex library_log_mutex;
static std::atomic<bool> busy{false}, cancelled{false};
static std::atomic<uint64_t> library_logs{0}, emitted_events{0};
static sd_ctx_t* context = nullptr;
static std::string request_id, phase;
static constexpr char vae_rules[] = R"(^(first_stage_model\.|vae\.)=f32)";
static constexpr int edge = 1024;

static void library_log(sd_log_level_t, const char* message, void*) {
    ++library_logs;
    if (!message) return;
    // Evaluation diagnostics go only to the separately captured stderr pipe.
    // Preserve every level during model loading, but bound the process total
    // even if the SDK reports a repeated failure from multiple worker threads.
    static constexpr size_t limit = 1024 * 1024;
    static constexpr char marker[] = "\nGLOWROOM_SDK_LOG_TRUNCATED\n";
    static size_t written = 0;
    static bool truncated = false;
    std::lock_guard<std::mutex> lock(library_log_mutex);
    if (truncated) return;
    const size_t available = limit - (sizeof(marker) - 1) - written;
    const size_t length = strnlen(message, available + 1);
    const size_t amount = std::min(length, available);
    if (amount) { std::fwrite(message, 1, amount, stderr); written += amount; }
    if (length > available) {
        std::fwrite(marker, 1, sizeof(marker) - 1, stderr);
        written += sizeof(marker) - 1;
        truncated = true;
    }
    std::fflush(stderr);
}

static json stats() {
    rusage usage{};
    getrusage(RUSAGE_SELF, &usage);
    task_vm_info_data_t vm{};
    mach_msg_type_number_t count = sizeof(vm) / sizeof(integer_t);
    json result{{"peakRSSBytes", usage.ru_maxrss}};
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&vm), &count) == KERN_SUCCESS) {
        result["residentBytes"] = vm.resident_size;
        result["footprintBytes"] = vm.phys_footprint;
        result["peakFootprintBytes"] = vm.ledger_phys_footprint_peak;
    }
    return result;
}

static void emit(json event) {
    std::lock_guard<std::mutex> lock(output_mutex);
    event["protocol"] = 1;
    const auto line = event.dump();
    if (++emitted_events > 25000 || line.size() > 65536) _exit(3);
    if (std::fwrite(line.data(), 1, line.size(), protocol) != line.size() ||
        std::fputc('\n', protocol) == EOF || std::fflush(protocol) != 0) _exit(3);
}

static void progress(int step, int steps, float seconds, void*) {
    if (cancelled.load()) {
        std::lock_guard<std::mutex> lock(context_mutex);
        if (context) sd_cancel_generation(context, SD_CANCEL_ALL);
    }
    emit({{"event", "progress"}, {"id", request_id}, {"phase", phase}, {"step", step}, {"steps", steps},
          {"stepSeconds", std::isfinite(seconds) ? seconds : 0.0}, {"memory", stats()}});
}

static fs::path safe_path(const std::string& relative) {
    if (relative.empty() || relative.size() > 256 || relative.find('\0') != std::string::npos || fs::path(relative).is_absolute())
        throw std::runtime_error("invalid-path");
    const auto resolved = fs::weakly_canonical(root / relative);
    auto child = resolved.begin();
    for (auto parent = root.begin(); parent != root.end(); ++parent, ++child)
        if (child == resolved.end() || *child != *parent) throw std::runtime_error("invalid-path");
    return resolved;
}

static std::vector<uint8_t> read_png(const fs::path& path, bool mask) {
    int width = 0, height = 0, channels = 0;
    if (!fs::is_regular_file(path) || fs::file_size(path) > 8 * 1024 * 1024 ||
        !stbi_info(path.c_str(), &width, &height, &channels) || width != edge || height != edge ||
        (mask ? channels != 1 : (channels != 3 && channels != 4))) throw std::runtime_error("invalid-image");
    const int requested = mask ? 1 : 3;
    std::unique_ptr<stbi_uc, decltype(&stbi_image_free)> bytes(
        stbi_load(path.c_str(), &width, &height, &channels, requested), &stbi_image_free);
    if (!bytes || width != edge || height != edge) throw std::runtime_error("invalid-image");
    // stb discards alpha without matting. RGB remains the declared straight
    // source RGB; the Swift caller retains source alpha for final composition.
    return std::vector<uint8_t>(bytes.get(), bytes.get() + size_t(edge) * edge * requested);
}

struct NativeImages {
    sd_image_t* values = nullptr;
    int count = 0;
    ~NativeImages() { if (values) free_sd_images(values, count); }
};

// An explicit diagnostic changes graph synchronization and is never a timing
// or quality gate. It samples only five pinned-route boundaries, not all values
// or all tiles. No private SDK context or runner layout is accessed.
struct BoundaryDiagnostics {
    bool claimed[5]{}, observed[5]{};
    unsigned encoder_outputs = 0, unet_outputs = 0, decoder_outputs = 0;
    int pending = -1;
    bool nonfinite = false, failed = false;
    json samples = json::array();
    inline static unsigned registrations = 0, unregisters = 0;
    static constexpr const char* labels[5] = {
        "vae-original-encode-first-tile", "vae-masked-encode-first-tile",
        "unet-first-batched-output", "vae-decode-input-after-sdk-scale-first-tile",
        "vae-decode-output-before-clamp-first-tile"};

    BoundaryDiagnostics() { sd_set_backend_eval_callback(callback, this); ++registrations; }
    ~BoundaryDiagnostics() { sd_set_backend_eval_callback(nullptr, nullptr); ++unregisters; }
    BoundaryDiagnostics(const BoundaryDiagnostics&) = delete;
    BoundaryDiagnostics& operator=(const BoundaryDiagnostics&) = delete;

    static bool shape(const ggml_tensor* t, int64_t x, int64_t y, int64_t channels, int64_t batch) {
        return t && t->ne[0] == x && t->ne[1] == y && t->ne[2] == channels && t->ne[3] == batch;
    }

    int select(const ggml_tensor* t) {
        if (!t) return -1;
        if (std::strcmp(ggml_get_name(t), "ggml_runner_final_result_tensor") == 0) {
            if (shape(t, 80, 80, 8, 1)) {
                ++encoder_outputs;
                // The fixed 1024 canvas / 640 tile route executes four tiles
                // for each of the original and masked-image encodes.
                if (encoder_outputs == 1) return 0;
                if (encoder_outputs == 5) return 1;
            } else if (shape(t, 128, 128, 4, 2)) {
                ++unet_outputs;
                if (unet_outputs == 1) {
                    if (encoder_outputs != 8) failed = true;
                    return 2;
                }
            } else if (shape(t, 640, 640, 3, 1)) {
                ++decoder_outputs;
                if (decoder_outputs == 1) return 4;
            }
        }
        // In this pinned SDK the first post_quant_conv scales the decoder's
        // F32 graph input by 1/32 before im2col. Sample that computed SCALE
        // result: it is before the first decoder convolution, not its output.
        if (unet_outputs > 0 && t->op == GGML_OP_SCALE && shape(t, 80, 80, 4, 1) &&
            t->src[0] && (t->src[0]->flags & GGML_TENSOR_FLAG_INPUT) &&
            shape(t->src[0], 80, 80, 4, 1)) return 3;
        return -1;
    }

    bool record(ggml_tensor* t, int slot) {
        json item{{"label", labels[slot]}, {"name", ggml_get_name(t)},
                  {"dimensions", {t->ne[0], t->ne[1], t->ne[2], t->ne[3]}},
                  {"type", ggml_type_name(t->type)}, {"bytesRead", 0},
                  {"sampleScope", "equispaced subset; not a full-tensor finite proof"}};
        std::string error;
        size_t elements = 1;
        for (int dimension = 0; dimension < GGML_MAX_DIMS; ++dimension) {
            if (t->ne[dimension] <= 0 || uint64_t(t->ne[dimension]) > std::numeric_limits<size_t>::max() / elements) {
                error = "invalid-dimensions"; break;
            }
            elements *= size_t(t->ne[dimension]);
        }
        if (error.empty() && (elements > size_t(8) * edge * edge || elements > std::numeric_limits<size_t>::max() / sizeof(float)))
            error = "tensor-size-bound";
        if (error.empty() && t->type != GGML_TYPE_F32) error = "not-f32";
        if (error.empty() && !ggml_is_contiguous(t)) error = "not-contiguous";
        if (error.empty() && (!t->data || !(t->view_src ? t->view_src->buffer : t->buffer))) error = "unallocated-tensor";
        if (error.empty() && ggml_nbytes(t) != elements * sizeof(float)) error = "unexpected-byte-size";
        if (!error.empty()) {
            item["error"] = error; failed = true;
        } else {
            const size_t count = std::min(size_t(256), elements);
            unsigned finite = 0, nan = 0, positive_infinity = 0, negative_infinity = 0;
            double minimum = std::numeric_limits<double>::infinity(), maximum = -minimum, sum = 0;
            json first_bad = nullptr;
            for (size_t i = 0; i < count; ++i) {
                const size_t index = count == 1 ? 0 : i * (elements - 1) / (count - 1);
                float value = 0;
                // Exactly four bytes per sample, at most 1024 bytes per tensor.
                ggml_backend_tensor_get(t, &value, index * sizeof(float), sizeof(value));
                if (std::isnan(value)) ++nan;
                else if (std::isinf(value)) { if (std::signbit(value)) ++negative_infinity; else ++positive_infinity; }
                else { ++finite; minimum = std::min(minimum, double(value)); maximum = std::max(maximum, double(value)); sum += value; }
                if (!std::isfinite(value) && first_bad.is_null())
                    first_bad = {{"sampleIndex", i}, {"logicalIndex", index},
                                 {"kind", std::isnan(value) ? "nan" : std::signbit(value) ? "negative-infinity" : "positive-infinity"}};
            }
            item["elements"] = elements; item["sampleCount"] = count; item["bytesRead"] = count * sizeof(float);
            item["finiteSamples"] = finite; item["nanSamples"] = nan;
            item["positiveInfinitySamples"] = positive_infinity; item["negativeInfinitySamples"] = negative_infinity;
            item["finiteMinimum"] = finite ? json(minimum) : json(nullptr);
            item["finiteMaximum"] = finite ? json(maximum) : json(nullptr);
            item["finiteMean"] = finite ? json(sum / finite) : json(nullptr);
            item["firstNonfiniteSample"] = first_bad;
            item["sampledNonfiniteDetected"] = nan + positive_infinity + negative_infinity > 0;
            nonfinite = nonfinite || nan + positive_infinity + negative_infinity > 0;
        }
        observed[slot] = true;
        samples.push_back(item);
        emit({{"event", "tensor-diagnostic"}, {"id", request_id}, {"sample", item}, {"notPerformanceComparable", true}});
        return !nonfinite && !failed;
    }

    static bool callback(ggml_tensor* t, bool ask, void* data) noexcept {
        auto& self = *static_cast<BoundaryDiagnostics*>(data);
        try {
            if (ask) {
                // A failed batched CFG attempt can trigger an SDK serial retry.
                // Stop that graph too, without reading another tensor/sample.
                if (self.nonfinite || self.failed) { self.pending = -1; return true; }
                const int slot = self.select(t);
                if (slot < 0 || self.claimed[slot]) return false;
                self.claimed[slot] = true; self.pending = slot;
                return true;
            }
            const int slot = self.pending; self.pending = -1;
            if (slot < 0 && (self.nonfinite || self.failed)) return false;
            if (slot < 0 || !t) { self.failed = true; return false; }
            return self.record(t, slot);
        } catch (...) { self.failed = true; return false; }
    }

    bool complete() const {
        return !failed && std::all_of(observed, observed + 5, [](bool value) { return value; });
    }
    json summary() const {
        return {{"requested", true}, {"notPerformanceComparable", true}, {"maximumTensorSamples", 5},
                {"maximumValuesPerTensor", 256}, {"maximumBytesPerTensor", 1024}, {"samples", samples},
                {"encoderTileOutputsObserved", encoder_outputs}, {"unetOutputsObserved", unet_outputs},
                {"decoderTileOutputsObserved", decoder_outputs}, {"allExpectedBoundariesObserved", complete()},
                {"sampledNonfiniteDetected", nonfinite}, {"callbackOrBoundaryError", failed},
                {"result", nonfinite ? "nonfinite-sample-detected" : complete() ? "sampled-boundaries-finite-only" : "boundaries-unavailable"},
                {"limitation", "First tiles and first UNet output only; unsampled values, other tiles and later steps remain unverified"},
                {"productGo", false}};
    }
};

// Exercises selection/read bounds and error/abort paths with real CPU tensors;
// no model context, model weights, Metal backend or inference is initialized.
static int diagnostic_self_test() {
    struct Fixture {
        ggml_context* ctx = nullptr;
        ggml_backend_t cpu = nullptr;
        ggml_backend_buffer_t buffer = nullptr;
        ~Fixture() {
            if (buffer) ggml_backend_buffer_free(buffer);
            if (ctx) ggml_free(ctx);
            if (cpu) ggml_backend_free(cpu);
        }
    } fixture;
    auto require = [](bool okay, const char* message) { if (!okay) throw std::runtime_error(message); };
    protocol = stdout; request_id = "diagnostic-self-test";
    try {
        fixture.ctx = ggml_init({128 * 1024, nullptr, true});
        fixture.cpu = ggml_backend_cpu_init();
        require(fixture.ctx && fixture.cpu, "CPU fixture initialization");
        auto* encoder = ggml_new_tensor_4d(fixture.ctx, GGML_TYPE_F32, 80, 80, 8, 1);
        auto* unet = ggml_new_tensor_4d(fixture.ctx, GGML_TYPE_F32, 128, 128, 4, 2);
        auto* input = ggml_new_tensor_4d(fixture.ctx, GGML_TYPE_F32, 80, 80, 4, 1);
        ggml_set_input(input);
        auto* scaled = ggml_scale(fixture.ctx, input, 1.f / 32.f);
        auto* decoder = ggml_new_tensor_4d(fixture.ctx, GGML_TYPE_F32, 640, 640, 3, 1);
        auto* wrong_shape = ggml_new_tensor_4d(fixture.ctx, GGML_TYPE_F32, 2, 2, 2, 1);
        auto* wrong_type = ggml_new_tensor_4d(fixture.ctx, GGML_TYPE_F16, 80, 80, 8, 1);
        for (auto* tensor : {encoder, unet, decoder, wrong_shape, wrong_type})
            ggml_set_name(tensor, "ggml_runner_final_result_tensor");
        fixture.buffer = ggml_backend_alloc_ctx_tensors(fixture.ctx, fixture.cpu);
        require(fixture.buffer != nullptr, "CPU tensor allocation");
        ggml_backend_buffer_clear(fixture.buffer, 0);
        const float low = -2.f, high = 3.f;
        ggml_backend_tensor_set(encoder, &low, 0, sizeof(low));
        ggml_backend_tensor_set(encoder, &high, ggml_nbytes(encoder) - sizeof(high), sizeof(high));
        const auto registered = BoundaryDiagnostics::registrations, unregistered = BoundaryDiagnostics::unregisters;
        {
            BoundaryDiagnostics diagnostics;
            require(!BoundaryDiagnostics::callback(wrong_shape, true, &diagnostics), "wrong shape must be skipped");
            for (unsigned tile = 0; tile < 8; ++tile) {
                const bool selected = BoundaryDiagnostics::callback(encoder, true, &diagnostics);
                require(selected == (tile == 0 || tile == 4), "encode tile selection");
                if (selected) require(BoundaryDiagnostics::callback(encoder, false, &diagnostics), "finite encode sample");
            }
            for (auto* tensor : {unet, scaled, decoder}) {
                require(BoundaryDiagnostics::callback(tensor, true, &diagnostics), "boundary selection");
                require(BoundaryDiagnostics::callback(tensor, false, &diagnostics), "finite boundary sample");
            }
            require(diagnostics.complete() && diagnostics.samples.size() == 5, "exactly five boundaries");
            size_t bytes = 0;
            for (const auto& sample : diagnostics.samples) {
                require(sample.at("sampleCount") == 256 && sample.at("bytesRead") == 1024, "sample byte budget");
                require(sample.at("finiteSamples") == 256, "known finite CPU values");
                bytes += sample.at("bytesRead").get<size_t>();
            }
            require(bytes == 5120 && diagnostics.samples[0].at("finiteMinimum") == -2.f &&
                    diagnostics.samples[0].at("finiteMaximum") == 3.f, "finite sample range and total budget");
            require(!BoundaryDiagnostics::callback(decoder, true, &diagnostics), "no repeat readback");
        }
        require(BoundaryDiagnostics::registrations == registered + 1 &&
                BoundaryDiagnostics::unregisters == unregistered + 1, "RAII unregister call after normal scope");
        const float bad[] = {std::numeric_limits<float>::quiet_NaN(),
                             std::numeric_limits<float>::infinity(), -std::numeric_limits<float>::infinity()};
        for (size_t i = 0; i < 3; ++i) {
            const size_t index = i * (size_t(ggml_nelements(encoder)) - 1) / 255;
            ggml_backend_tensor_set(encoder, &bad[i], index * sizeof(float), sizeof(float));
        }
        {
            BoundaryDiagnostics diagnostics;
            require(BoundaryDiagnostics::callback(encoder, true, &diagnostics), "nonfinite boundary selection");
            require(!BoundaryDiagnostics::callback(encoder, false, &diagnostics), "nonfinite must abort graph");
            const auto& sample = diagnostics.samples.at(0);
            require(sample.at("nanSamples") == 1 && sample.at("positiveInfinitySamples") == 1 &&
                    sample.at("negativeInfinitySamples") == 1 && sample.at("finiteSamples") == 253,
                    "NaN and both infinity counts");
            require(sample.at("firstNonfiniteSample").at("sampleIndex") == 0 &&
                    sample.at("firstNonfiniteSample").at("logicalIndex") == 0, "first nonfinite location");
            require(BoundaryDiagnostics::callback(unet, true, &diagnostics) &&
                    !BoundaryDiagnostics::callback(unet, false, &diagnostics) && diagnostics.samples.size() == 1,
                    "serial retry abort without additional reads");
        }
        {
            BoundaryDiagnostics diagnostics;
            require(BoundaryDiagnostics::callback(wrong_type, true, &diagnostics), "wrong-type boundary identified");
            require(!BoundaryDiagnostics::callback(wrong_type, false, &diagnostics) &&
                    diagnostics.samples.at(0).at("bytesRead") == 0 &&
                    diagnostics.samples.at(0).at("error") == "not-f32", "wrong type never reinterpreted/read");
        }
        const auto before_throw = BoundaryDiagnostics::unregisters;
        try { BoundaryDiagnostics diagnostics; throw std::runtime_error("intentional scope test"); }
        catch (const std::runtime_error&) {}
        require(BoundaryDiagnostics::unregisters == before_throw + 1, "RAII unregister call after exception");
        emit({{"event", "diagnostic-self-test"}, {"status", "success"}, {"publicCPUTensors", true},
              {"modelContextCreated", false}, {"gpuInitialized", false}, {"inferenceExecuted", false},
              {"raiiUnregisterCallsChecked", true}, {"sdkCallbackGetterAvailable", false}});
        return 0;
    } catch (const std::exception& error) {
        emit({{"event", "diagnostic-self-test"}, {"status", "error"}, {"reason", error.what()}}); return 1;
    }
}

static json requested_configuration() {
    return {{"model", "model-q8_0.gguf"}, {"weightType", "auto-filetypes-with-SDK-layer-overrides"}, {"conversionType", "q8_0"},
            {"tensorTypeRules", vae_rules}, {"backend", "metal,te=cpu,vae=metal"},
            {"paramsBackend", "diffusion=metal,te=disk,vae=metal"}, {"maxManagedVRAMGiB", 5},
            {"autoFit", false}, {"eagerLoad", false}, {"mmap", false}, {"batchedCFG", true}, {"latentMaskInterpolation", "nearest-v1"},
            {"flashAttention", "auto"}, {"linearScale", 0}, {"attentionScale", 0}, {"hostThreads", 4},
            {"modelCanvas", {edge, edge}}, {"steps", glowroom_sdxl::configured_steps},
            {"effectiveSteps", glowroom_sdxl::actual_steps}, {"strength", 0.99}, {"cfg", 8},
            {"sampler", "euler"}, {"scheduler", glowroom_sdxl::schedule_variant},
            {"customSigmas", glowroom_sdxl::reference_sigmas()},
            {"referenceTimesteps", glowroom_sdxl::reference_timesteps()}, {"rng", "cpu"},
            {"vaeTiling", {{"enabled", true}, {"tilePixels", {640, 640}}, {"overlap", 0.5}}},
            {"inspectionScope", "configuration describes requested public API parameters; optional diagnostic is reported separately; no private runner access"}};
}

static void perform(const json& command) {
    const auto began = Clock::now();
    json outcome{{"event", "completed"}, {"id", request_id}, {"operation", phase}};
    fs::path temporary, published;
    std::unique_ptr<BoundaryDiagnostics> diagnostics;
    try {
        if (phase == "load") {
            { std::lock_guard<std::mutex> lock(context_mutex);
              if (context) throw std::runtime_error("already-loaded"); }
            const std::string model = safe_path("model-q8_0.gguf").string();
            if (!fs::is_regular_file(model)) throw std::runtime_error("missing-model");
            sd_ctx_params_t params; sd_ctx_params_init(&params);
            params.model_path = model.c_str(); params.n_threads = 4; params.wtype = SD_TYPE_COUNT;
            params.backend = "metal,te=cpu,vae=metal";
            params.params_backend = "diffusion=metal,te=disk,vae=metal";
            params.auto_fit = false; params.eager_load = false; params.enable_mmap = false;
            params.max_vram = "5"; params.tensor_type_rules = vae_rules;
            params.batched_cfg = true; params.flash_attn_mode = "auto";
            params.rng_type = CPU_RNG; params.sampler_rng_type = CPU_RNG;
            auto* loaded = new_sd_ctx(&params);
            if (!loaded) throw std::runtime_error("model-load-failed");
            const char* kind = sd_get_model_version_name(loaded);
            if (!kind || std::string(kind) != "SDXL Inpaint") {
                free_sd_ctx(loaded); throw std::runtime_error("wrong-model-capability");
            }
            { std::lock_guard<std::mutex> lock(context_mutex);
              if (cancelled.load()) { free_sd_ctx(loaded); throw std::runtime_error("cancelled"); }
              context = loaded; }
            outcome["modelKind"] = kind;
            outcome["requestedConfiguration"] = requested_configuration();
        } else if (phase == "generate") {
            sd_ctx_t* active;
            { std::lock_guard<std::mutex> lock(context_mutex); active = context; }
            if (!active) throw std::runtime_error("not-loaded");
            const auto prompt = command.at("prompt").get<std::string>();
            const auto negative = command.value("negativePrompt", std::string());
            if (prompt.empty() || prompt.size() > 2048 || negative.size() > 2048 ||
                prompt.find('\0') != std::string::npos || negative.find('\0') != std::string::npos)
                throw std::runtime_error("invalid-prompt");
            const auto& seed_json = command.at("seed");
            if (!seed_json.is_number_integer() || (seed_json.is_number_unsigned() &&
                seed_json.get<uint64_t>() > std::numeric_limits<uint32_t>::max())) throw std::runtime_error("invalid-seed");
            const int64_t seed = seed_json.get<int64_t>();
            if (seed < 0 || uint64_t(seed) > std::numeric_limits<uint32_t>::max()) throw std::runtime_error("invalid-seed");
            auto rgb = read_png(safe_path(command.at("source").get<std::string>()), false);
            auto mask = read_png(safe_path(command.at("mask").get<std::string>()), true);
            for (auto& value : mask) value = value >= 128 ? 255 : 0;
            const auto output = safe_path(command.at("output").get<std::string>());
            if (output.parent_path() != safe_path("outputs") || output.filename().empty() || fs::exists(output))
                throw std::runtime_error("invalid-output-path");
            fs::create_directories(output.parent_path());
            sd_img_gen_params_t params; sd_img_gen_params_init(&params);
            params.prompt = prompt.c_str(); params.negative_prompt = negative.c_str(); params.seed = seed;
            params.width = edge; params.height = edge; params.batch_count = 1; params.strength = 0.99f;
            params.init_image = {edge, edge, 3, rgb.data()}; params.mask_image = {edge, edge, 1, mask.data()};
            params.sample_params.sample_steps = 20; params.sample_params.guidance.txt_cfg = 8.0f;
            params.sample_params.sample_method = EULER_SAMPLE_METHOD; params.sample_params.scheduler = DISCRETE_SCHEDULER;
            // The pinned model declares leading spacing and offset 1. The
            // public custom schedule already selects strength 0.99's 19 steps;
            // the SDK's subsequent strength selection leaves this array intact.
            // Keep this small local array alive until synchronous generation ends.
            auto sigmas = glowroom_sdxl::reference_sigmas();
            params.sample_params.custom_sigmas = sigmas.data();
            params.sample_params.custom_sigmas_count = static_cast<int>(sigmas.size());
            params.vae_tiling_params.enabled = true;
            params.vae_tiling_params.tile_size_w = 640; params.vae_tiling_params.tile_size_h = 640;
            params.vae_tiling_params.target_overlap = 0.5f;
            NativeImages images;
            if (command.value("numericDiagnostic", false)) diagnostics = std::make_unique<BoundaryDiagnostics>();
            if (cancelled.load()) throw std::runtime_error("cancelled");
            const bool success = generate_image(active, &params, &images.values, &images.count);
            if (cancelled.load()) throw std::runtime_error("cancelled");
            if (diagnostics && diagnostics->nonfinite) throw std::runtime_error("diagnostic-nonfinite-sample");
            if (diagnostics && !diagnostics->complete()) throw std::runtime_error("diagnostic-boundaries-unavailable");
            if (!success || !images.values || images.count != 1 || !images.values[0].data ||
                images.values[0].width != edge || images.values[0].height != edge || images.values[0].channel != 3)
                throw std::runtime_error("invalid-model-output");
            // A private output name plus link(2) publishes without overwriting.
            // The inference caller owns this explicit spool, not arbitrary photos.
            std::string pattern = (output.parent_path() / ".sdxl-output-XXXXXX").string();
            std::vector<char> name(pattern.begin(), pattern.end()); name.push_back('\0');
            const int descriptor = mkstemp(name.data());
            if (descriptor < 0) throw std::runtime_error("output-write-failed");
            close(descriptor); temporary = name.data();
            if (!stbi_write_png(temporary.c_str(), edge, edge, 3, images.values[0].data, edge * 3))
                throw std::runtime_error("output-write-failed");
            if (cancelled.load()) throw std::runtime_error("cancelled");
            if (link(temporary.c_str(), output.c_str()) != 0) throw std::runtime_error("output-write-failed");
            published = output;
            if (cancelled.load()) throw std::runtime_error("cancelled");
            outcome["width"] = edge; outcome["height"] = edge; outcome["channels"] = 3; outcome["seed"] = seed;
            outcome["floatDiagnostics"] = diagnostics ? "bounded-public-graph-callback-samples" : "not-requested-rgb8-does-not-prove-finite-floats";
        } else if (phase == "unload") {
            sd_ctx_t* loaded;
            { std::lock_guard<std::mutex> lock(context_mutex); loaded = context; context = nullptr; }
            if (loaded) free_sd_ctx(loaded);
        } else throw std::runtime_error("invalid-operation");
        outcome["status"] = "success";
    } catch (const std::exception& error) {
        static const std::vector<std::string> known = {"already-loaded", "missing-model", "model-load-failed",
            "wrong-model-capability", "cancelled", "not-loaded", "invalid-prompt", "invalid-seed", "invalid-path",
            "invalid-image", "invalid-output-path", "invalid-model-output", "output-write-failed", "invalid-operation",
            "diagnostic-nonfinite-sample", "diagnostic-boundaries-unavailable"};
        const std::string code = error.what();
        outcome["status"] = "error";
        outcome["code"] = std::find(known.begin(), known.end(), code) == known.end() ? "internal-error" : code;
        if (!published.empty()) { std::error_code ignored; fs::remove(published, ignored); }
    } catch (...) {
        outcome["status"] = "error"; outcome["code"] = "internal-error";
        if (!published.empty()) { std::error_code ignored; fs::remove(published, ignored); }
    }
    if (diagnostics) { outcome["numericDiagnostics"] = diagnostics->summary(); diagnostics.reset(); }
    if (!temporary.empty()) { std::error_code ignored; fs::remove(temporary, ignored); }
    outcome["seconds"] = std::chrono::duration<double>(Clock::now() - began).count();
    outcome["memory"] = stats(); outcome["libraryLogCount"] = library_logs.load();
    busy.store(false);
    emit(outcome);
}

static int convert_model() {
    const auto destination = safe_path("model-q8_0.gguf");
    if (fs::exists(destination)) throw std::runtime_error("converted-model-already-exists");
    const auto source = safe_path("inputs/source-model");
    if (!fs::is_directory(source)) throw std::runtime_error("missing-source-model");
    const auto stage = root / (".sdxl-convert-" + std::to_string(getpid()));
    if (!fs::create_directory(stage)) throw std::runtime_error("conversion-stage-exists");
    const auto temporary = stage / "model-q8_0.gguf";
    const auto began = Clock::now();
    try {
        if (!convert_with_components(source.c_str(), nullptr, nullptr, nullptr, nullptr, nullptr,
                temporary.c_str(), SD_TYPE_Q8_0, vae_rules, true, 2, nullptr, 0) ||
            !fs::is_regular_file(temporary) || fs::file_size(temporary) == 0)
            throw std::runtime_error("conversion-failed");
        if (link(temporary.c_str(), destination.c_str()) != 0) throw std::runtime_error("conversion-publication-failed");
        fs::remove_all(stage);
        emit({{"event", "converted"}, {"status", "success"}, {"output", "model-q8_0.gguf"},
              {"seconds", std::chrono::duration<double>(Clock::now() - began).count()},
              {"bytes", fs::file_size(destination)}, {"conversionType", "q8_0"}, {"tensorTypeRules", vae_rules},
              {"threads", 2}, {"memory", stats()}, {"inferenceExecuted", false}});
        return 0;
    } catch (...) { std::error_code ignored; fs::remove_all(stage, ignored); throw; }
}

int main(int argc, char** argv) {
    if (argc == 2 && std::strcmp(argv[1], "--diagnostic-self-test") == 0) return diagnostic_self_test();
    const bool converting = argc == 3 && std::string(argv[1]) == "--convert";
    if ((!converting && argc != 2) || !fs::path(argv[converting ? 2 : 1]).is_absolute()) {
        std::fputs("usage: sdxl-helper [--convert] <absolute-evaluation-root>\n", stderr); return 2;
    }
    std::error_code error;
    root = fs::canonical(argv[converting ? 2 : 1], error);
    if (error || root == root.root_path() || !fs::is_directory(root)) return 2;
    const int output = dup(STDOUT_FILENO);
    protocol = fdopen(output, "w");
    if (!protocol || dup2(STDERR_FILENO, STDOUT_FILENO) < 0) return 2;
    sd_set_log_callback(library_log, nullptr);
    if (converting) {
        try { return convert_model(); }
        catch (...) { emit({{"event", "converted"}, {"status", "error"}, {"code", "conversion-failed"}, {"memory", stats()}}); return 2; }
    }
    sd_set_progress_callback(progress, nullptr);
    emit({{"event", "ready"}, {"helperVersion", "glowroom-sdxl-evaluation-1"}, {"memory", stats()}});
    std::thread worker;
    unsigned commands = 0;
    for (;;) {
        std::string line; char character;
        while (std::cin.get(character) && character != '\n') {
            if (line.size() >= 65536) _exit(2);
            line += character;
        }
        if (line.empty() && !std::cin) break;
        if (++commands > 25000) break;
        try {
            const auto command = json::parse(line);
            const auto operation = command.at("operation").get<std::string>();
            const auto id = command.value("id", std::string("none"));
            if (id.empty() || id.size() > 64 || id.find('\0') != std::string::npos) throw std::runtime_error("invalid-id");
            if (operation == "shutdown") break;
            if (operation == "stats") { emit({{"event", "stats"}, {"id", id}, {"memory", stats()}}); continue; }
            if (operation == "cancel") {
                std::lock_guard<std::mutex> lock(context_mutex);
                cancelled.store(true);
                if (context && busy.load()) sd_cancel_generation(context, SD_CANCEL_ALL);
                emit({{"event", "cancel-requested"}, {"id", id}, {"contextExists", context != nullptr}});
                continue;
            }
            if (operation != "load" && operation != "generate" && operation != "unload") throw std::runtime_error("invalid-operation");
            if (busy.load()) { emit({{"event", "rejected"}, {"id", id}, {"code", "busy"}}); continue; }
            if (worker.joinable()) worker.join();
            request_id = id; phase = operation; cancelled.store(false); busy.store(true);
            worker = std::thread(perform, command);
        } catch (...) { emit({{"event", "rejected"}, {"code", "invalid-command"}}); }
    }
    { std::lock_guard<std::mutex> lock(context_mutex);
      cancelled.store(true);
      if (context && busy.load()) sd_cancel_generation(context, SD_CANCEL_ALL); }
    if (worker.joinable()) worker.join();
    if (context) free_sd_ctx(context);
    return 0;
}
