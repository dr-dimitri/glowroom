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
#include "json.hpp"
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
    static constexpr char marker[] = "\nPICEDIT_SDK_LOG_TRUNCATED\n";
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

static json requested_configuration() {
    return {{"model", "model-q8_0.gguf"}, {"weightType", "preserve-converted-types"}, {"conversionType", "q8_0"},
            {"tensorTypeRules", vae_rules}, {"backend", "metal,te=cpu,vae=metal"},
            {"paramsBackend", "diffusion=metal,te=disk,vae=metal"}, {"maxManagedVRAMGiB", 5},
            {"autoFit", false}, {"eagerLoad", false}, {"mmap", false}, {"batchedCFG", true},
            {"flashAttention", "auto"}, {"linearScale", 0}, {"attentionScale", 0}, {"hostThreads", 4},
            {"modelCanvas", {edge, edge}}, {"steps", 20}, {"strength", 0.99}, {"cfg", 8},
            {"sampler", "euler"}, {"scheduler", "discrete"}, {"rng", "cpu"},
            {"vaeTiling", {{"enabled", true}, {"tilePixels", {512, 512}}, {"overlap", 0.5}}},
            {"inspectionScope", "requested public API parameters; no private runner or float-tensor inspection"}};
}

static void perform(const json& command) {
    const auto began = Clock::now();
    json outcome{{"event", "completed"}, {"id", request_id}, {"operation", phase}};
    fs::path temporary, published;
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
            params.vae_tiling_params.enabled = true;
            params.vae_tiling_params.tile_size_w = 512; params.vae_tiling_params.tile_size_h = 512;
            params.vae_tiling_params.target_overlap = 0.5f;
            NativeImages images;
            if (cancelled.load()) throw std::runtime_error("cancelled");
            const bool success = generate_image(active, &params, &images.values, &images.count);
            if (cancelled.load()) throw std::runtime_error("cancelled");
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
            outcome["floatDiagnostics"] = "not-exposed-by-public-rgb8-api";
        } else if (phase == "unload") {
            sd_ctx_t* loaded;
            { std::lock_guard<std::mutex> lock(context_mutex); loaded = context; context = nullptr; }
            if (loaded) free_sd_ctx(loaded);
        } else throw std::runtime_error("invalid-operation");
        outcome["status"] = "success";
    } catch (const std::exception& error) {
        static const std::vector<std::string> known = {"already-loaded", "missing-model", "model-load-failed",
            "wrong-model-capability", "cancelled", "not-loaded", "invalid-prompt", "invalid-seed", "invalid-path",
            "invalid-image", "invalid-output-path", "invalid-model-output", "output-write-failed", "invalid-operation"};
        const std::string code = error.what();
        outcome["status"] = "error";
        outcome["code"] = std::find(known.begin(), known.end(), code) == known.end() ? "internal-error" : code;
        if (!published.empty()) { std::error_code ignored; fs::remove(published, ignored); }
    } catch (...) {
        outcome["status"] = "error"; outcome["code"] = "internal-error";
        if (!published.empty()) { std::error_code ignored; fs::remove(published, ignored); }
    }
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
    emit({{"event", "ready"}, {"helperVersion", "picedit-sdxl-evaluation-1"}, {"memory", stats()}});
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
