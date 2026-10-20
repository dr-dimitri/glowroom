// Glowroom evaluation-only native helper. No repository or user photo access.
// A future product build must replace this fixed evaluation root with its own
// app-authorized spool and complete the AI-09 immutable artifact contract.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <iostream>
#include <mach/mach.h>
#include <mutex>
#include <string>
#include <sys/resource.h>
#include <thread>
#include <unistd.h>
#include <vector>
#include "stable-diffusion.h"
#include "pipeline/diffusion_engine.h"
#include "model/vae/vae.hpp"
// Diagnostic shim tied exactly to the pinned SDK definition in stable-diffusion.cpp.
// It only reads runner metadata; it does not change the SDK or model weights.
struct sd_ctx_t { StableDiffusionGGML* sd = nullptr; };
#include "json.hpp"
#define STBI_ONLY_PNG
#define STBI_MAX_DIMENSIONS 1024
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

using json = nlohmann::json;
using Clock = std::chrono::steady_clock;
static std::filesystem::path root;
static FILE* protocol = nullptr;
static std::mutex output_mutex, context_mutex;
static std::atomic<bool> busy{false};
static std::atomic<bool> cancelled{false};
static sd_ctx_t* context = nullptr;
static std::string request_id, phase;
static std::atomic<uint64_t> library_log_count{0};
static std::atomic<unsigned> diagnostic_event_count{0};

static json native_configuration(sd_ctx_t* ctx) {
    json result{{"diagnosticScope", "pinned-sdk-runner-metadata-only"}};
    if (!ctx || !ctx->sd) { result["status"] = "missing-context"; return result; }
    auto& engine = *ctx->sd;
    result["actualBatchedCFG"] = engine.config_->params.batched_cfg;
    result["vaeRuntimeBackend"] = ggml_backend_name(engine.backend_for(SDBackendModule::VAE));
    result["vaeParamsBackend"] = ggml_backend_name(engine.params_backend_for(SDBackendModule::VAE));
    result["diffusionRuntimeBackend"] = ggml_backend_name(engine.backend_for(SDBackendModule::DIFFUSION));
    result["diffusionParamsBackend"] = ggml_backend_name(engine.params_backend_for(SDBackendModule::DIFFUSION));
    if (!engine.first_stage_model) { result["status"] = "vae-runner-not-created"; return result; }
    std::map<std::string, ggml_tensor*> tensors;
    engine.first_stage_model->get_param_tensors(tensors);
    json counts = json::object();
    size_t host_buffers = 0, missing_buffers = 0;
    for (const auto& entry : tensors) {
        const auto* tensor = entry.second;
        if (!tensor) { ++missing_buffers; continue; }
        const std::string type = ggml_type_name(tensor->type);
        counts[type] = counts.value(type, 0) + 1;
        if (!tensor->buffer) ++missing_buffers;
        else if (ggml_backend_buffer_is_host(tensor->buffer)) ++host_buffers;
    }
    result["vaeParameterTensorTypes"] = counts;
    result["vaeParameterTensorCount"] = tensors.size();
    result["vaeHostBufferTensorCount"] = host_buffers;
    result["vaeMissingBufferTensorCount"] = missing_buffers;
    result["status"] = "actual-runner-inspected";
    return result;
}

static json stats() {
    struct rusage usage{};
    getrusage(RUSAGE_SELF, &usage);
    task_vm_info_data_t vm{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    json result{{"peakRSSBytes", usage.ru_maxrss}};
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&vm), &count) == KERN_SUCCESS) {
        result["footprintBytes"] = vm.phys_footprint;
        result["peakFootprintBytes"] = vm.ledger_phys_footprint_peak;
        result["residentBytes"] = vm.resident_size;
    }
    return result;
}

static void emit(json event) {
    std::lock_guard<std::mutex> lock(output_mutex);
    event["protocol"] = 1;
    const std::string line = event.dump();
    std::fwrite(line.data(), 1, line.size(), protocol);
    std::fputc('\n', protocol);
    std::fflush(protocol);
}

static void progress(int step, int steps, float seconds, void*) {
    // Library callbacks run only while this single worker owns the context.
    if (cancelled.load()) {
        std::lock_guard<std::mutex> lock(context_mutex);
        if (context) sd_cancel_generation(context, SD_CANCEL_ALL);
    }
    emit({{"event", "progress"}, {"id", request_id}, {"phase", phase},
          {"step", step}, {"steps", steps},
          {"stepSeconds", std::isfinite(seconds) ? seconds : 0.0}, {"memory", stats()}});
}

static std::filesystem::path safe_path(const std::string& relative) {
    if (relative.empty() || relative.size() > 256 || std::filesystem::path(relative).is_absolute())
        throw std::runtime_error("invalid-path");
    const auto p = std::filesystem::weakly_canonical(root / relative);
    const auto r = std::filesystem::weakly_canonical(root);
    auto ip = p.begin(), ir = r.begin();
    for (; ir != r.end(); ++ir, ++ip)
        if (ip == p.end() || *ip != *ir) throw std::runtime_error("invalid-path");
    return p;
}

static std::vector<uint8_t> read_png(const std::filesystem::path& p, int channels, int& w, int& h) {
    int actual = 0;
    if (!std::filesystem::is_regular_file(p) || std::filesystem::file_size(p) > 8 * 1024 * 1024 ||
        !stbi_info(p.c_str(), &w, &h, &actual) || w <= 0 || h <= 0 || w > 640 || h > 640 ||
        static_cast<uint64_t>(w) * h > 262144 || w % 64 || h % 64)
        throw std::runtime_error("invalid-image");
    auto* data = stbi_load(p.c_str(), &w, &h, &actual, channels);
    if (!data) throw std::runtime_error("invalid-image");
    std::vector<uint8_t> output(data, data + static_cast<size_t>(w) * h * channels);
    stbi_image_free(data);
    return output;
}

static void perform(const json& command) {
    const auto start = Clock::now();
    json outcome{{"event", "completed"}, {"id", request_id}, {"operation", phase}};
    try {
        if (phase == "load") {
            const auto backend = command.value("backend", std::string("metal"));
            if (backend != "metal" && backend != "cpu") throw std::runtime_error("invalid-backend");
            {
                std::lock_guard<std::mutex> lock(context_mutex);
                if (context) throw std::runtime_error("already-loaded");
            }
            const std::string model = (root / "model").string();
            sd_ctx_params_t p; sd_ctx_params_init(&p);
            p.model_path = model.c_str(); p.n_threads = 4; p.wtype = SD_TYPE_F16;
            if (backend != "metal") throw std::runtime_error("invalid-backend");
            p.backend = "metal,vae=cpu"; p.params_backend = "metal,vae=cpu"; p.auto_fit = false;
            p.tensor_type_rules = R"(^(first_stage_model\.|vae\.)=f32)";
            p.eager_load = true; p.conditioning_cache_size = 4;
            p.batched_cfg = false;
            p.flash_attn_mode = "auto";
            p.linear_scale = 0.0078125f; p.attn_scale = 0.0078125f;
            p.rng_type = CPU_RNG; p.sampler_rng_type = CPU_RNG;
            auto* loaded = new_sd_ctx(&p);
            if (!loaded) throw std::runtime_error("model-load-failed");
            const std::string kind = sd_get_model_version_name(loaded);
            if (kind.find("Inpaint") == std::string::npos && kind.find("INPAINT") == std::string::npos && kind.find("inpaint") == std::string::npos) {
                free_sd_ctx(loaded); throw std::runtime_error("wrong-model-capability");
            }
            { std::lock_guard<std::mutex> lock(context_mutex); context = loaded; }
            outcome["backend"] = backend; outcome["modelKind"] = kind;
            outcome["configuration"] = "metal-diffusion-cpu-vae-partial-f32-flash-auto-scale-1over128-float-diagnostic-unbatched";
            outcome["flashAttentionMode"] = "auto";
            outcome["linearScale"] = 0.0078125; outcome["attentionScale"] = 0.0078125;
            outcome["nativeConfiguration"] = native_configuration(loaded);
            outcome["configurationSHA256"] = "a356133c9769b71a55fff3a43b706942df1c477cf757075055549a394a1c2450";
        } else if (phase == "generate") {
            sd_ctx_t* active;
            { std::lock_guard<std::mutex> lock(context_mutex); active = context; }
            if (!active) throw std::runtime_error("not-loaded");
            const auto prompt = command.at("prompt").get<std::string>();
            const auto negative = command.value("negativePrompt", std::string());
            if (prompt.empty() || prompt.size() > 2048 || negative.size() > 2048)
                throw std::runtime_error("invalid-prompt");
            int width, height, mw, mh;
            auto source = read_png(safe_path(command.at("source").get<std::string>()), 4, width, height);
            auto mask = read_png(safe_path(command.at("mask").get<std::string>()), 1, mw, mh);
            if (mw != width || mh != height) throw std::runtime_error("invalid-mask");
            std::vector<uint8_t> rgb(static_cast<size_t>(width) * height * 3);
            for (size_t i = 0; i < static_cast<size_t>(width) * height; ++i) {
                const unsigned a = source[i * 4 + 3];
                for (unsigned c = 0; c < 3; ++c)
                    rgb[i * 3 + c] = static_cast<uint8_t>((source[i * 4 + c] * a + 255 * (255 - a) + 127) / 255);
                mask[i] = mask[i] >= 128 ? 255 : 0;
            }
            const auto output = safe_path(command.at("output").get<std::string>());
            if (output.parent_path() != safe_path("outputs")) throw std::runtime_error("invalid-output-path");
            std::filesystem::create_directories(output.parent_path());
            sd_img_gen_params_t p; sd_img_gen_params_init(&p);
            p.prompt = prompt.c_str(); p.negative_prompt = negative.c_str();
            p.init_image = {static_cast<uint32_t>(width), static_cast<uint32_t>(height), 3, rgb.data()};
            p.mask_image = {static_cast<uint32_t>(width), static_cast<uint32_t>(height), 1, mask.data()};
            p.width = width; p.height = height; p.batch_count = 1; p.strength = 1.0f;
            p.seed = command.value("seed", int64_t(4281));
            p.sample_params.sample_steps = 25;
            p.sample_params.guidance.txt_cfg = 7.5f;
            p.sample_params.sample_method = EULER_SAMPLE_METHOD;
            p.sample_params.scheduler = DISCRETE_SCHEDULER;
            sd_image_t* images = nullptr; int image_count = 0;
            if (cancelled.load()) throw std::runtime_error("cancelled");
            const bool success = generate_image(active, &p, &images, &image_count);
            bool valid = success && images && image_count == 1 && images[0].data &&
                images[0].width == width && images[0].height == height && images[0].channel == 3;
            outcome["nativeConfiguration"] = native_configuration(active);
            if (valid) {
                std::vector<uint8_t> observed((1 << 24) / 8, 0);
                int minimum[3] = {255, 255, 255};
                int maximum[3] = {0, 0, 0};
                uint32_t colors = 0;
                for (size_t i = 0; i < static_cast<size_t>(width) * height; ++i) {
                    const auto* px = images[0].data + i * 3;
                    for (int c = 0; c < 3; ++c) {
                        minimum[c] = std::min(minimum[c], static_cast<int>(px[c]));
                        maximum[c] = std::max(maximum[c], static_cast<int>(px[c]));
                    }
                    const uint32_t color = (uint32_t(px[0]) << 16) | (uint32_t(px[1]) << 8) | px[2];
                    const uint8_t bit = uint8_t(1u << (color & 7));
                    if (!(observed[color >> 3] & bit)) {
                        observed[color >> 3] |= bit;
                        ++colors;
                    }
                }
                outcome["nativeRGBMinimum"] = {minimum[0], minimum[1], minimum[2]};
                outcome["nativeRGBMaximum"] = {maximum[0], maximum[1], maximum[2]};
                outcome["nativeDistinctRGBColors"] = colors;
                outcome["floatDiagnostics"] = "not-exposed-by-public-uint8-c-api";
            }
            if (valid && !cancelled.load())
                valid = stbi_write_png(output.c_str(), width, height, 3, images[0].data, width * 3) != 0;
            if (images) free_sd_images(images, image_count);
            if (cancelled.load()) throw std::runtime_error("cancelled");
            if (!valid) throw std::runtime_error("invalid-model-output");
            outcome["width"] = width; outcome["height"] = height; outcome["channels"] = 3;
        } else if (phase == "unload") {
            sd_ctx_t* loaded;
            { std::lock_guard<std::mutex> lock(context_mutex); loaded = context; context = nullptr; }
            if (loaded) free_sd_ctx(loaded);
        } else throw std::runtime_error("invalid-operation");
        outcome["status"] = "success";
    } catch (const std::exception& e) {
        // Every explicit exception above uses a fixed local code. Never forward
        // third-party exception text, which may contain paths or model content.
        static const std::vector<std::string> known = {"invalid-backend", "already-loaded", "model-load-failed", "wrong-model-capability", "not-loaded", "invalid-prompt", "invalid-path", "invalid-image", "invalid-mask", "invalid-output-path", "cancelled", "invalid-model-output", "invalid-operation", "diagnostic-nonfinite-tensor", "diagnostic-step-bound-exceeded", "diagnostic-empty-unet-output", "diagnostic-unexpected-unet-branch", "diagnostic-batch-not-disabled", "diagnostic-guidance-mismatch"};
        const std::string code = e.what();
        outcome["status"] = "error";
        outcome["code"] = std::find(known.begin(), known.end(), code) != known.end() ? code : "internal-error";
    } catch (...) { outcome["status"] = "error"; outcome["code"] = "internal-error"; }
    outcome["seconds"] = std::chrono::duration<double>(Clock::now() - start).count();
    outcome["memory"] = stats(); outcome["libraryLogCount"] = library_log_count.load();
    busy.store(false);
    emit(outcome);
}

int main(int argc, char** argv) {
    // The evaluation caller authorizes one explicit, existing spool directory.
    // This helper is never installed as a product backend or selected by user photos.
    if (argc != 2 || !std::filesystem::path(argv[1]).is_absolute()) {
        std::fputs("usage: evaluation-helper-current <absolute-evaluation-root>\n", stderr);
        return 2;
    }
    std::error_code root_error;
    root = std::filesystem::canonical(argv[1], root_error);
    if (root_error || !std::filesystem::is_directory(root)) {
        std::fputs("invalid-evaluation-root\n", stderr);
        return 2;
    }
    const int output = dup(STDOUT_FILENO);
    protocol = fdopen(output, "w");
    if (!protocol || dup2(STDERR_FILENO, STDOUT_FILENO) < 0) return 2;
    sd_set_log_callback([](enum sd_log_level_t, const char* message, void*) {
        ++library_log_count;
        if (!message) return;
        const std::string text(message);
        const std::string marker = "GLOWROOM_FLOAT_DIAGNOSTIC ";
        const auto found = text.find(marker);
        if (found == std::string::npos) return;
        const auto begin = text.find('{', found + marker.size());
        const auto end = text.find('}', begin);
        if (begin == std::string::npos || end == std::string::npos || end - begin > 2048) return;
        try {
            auto statistics = json::parse(text.substr(begin, end - begin + 1));
            const unsigned number = diagnostic_event_count.fetch_add(1);
            const bool is_error = statistics.value("status", std::string("invalid")) != "finite";
            if (number < 512 || is_error) {
                emit({{"event", "float-diagnostic"}, {"id", request_id}, {"phase", phase}, {"statistics", statistics}});
            } else if (number == 512) {
                emit({{"event", "float-diagnostic-truncated"}, {"id", request_id}, {"normalEventLimit", 512}});
            }
        } catch (...) { emit({{"event", "float-diagnostic-invalid"}, {"id", request_id}}); }
    }, nullptr);
    sd_set_progress_callback(progress, nullptr);
    emit({{"event", "ready"}, {"helperVersion", "glowroom-inpainting-eval-current-1"}, {"memory", stats()}});
    std::thread worker;
    for (;;) {
        std::string line; char ch;
        while (std::cin.get(ch) && ch != '\n') {
            if (line.size() >= 65536) return 2;
            line += ch;
        }
        if (line.empty() && !std::cin) break;
        try {
            auto command = json::parse(line);
            const auto op = command.at("operation").get<std::string>();
            const auto id = command.value("id", std::string("none"));
            if (id.size() > 64) throw std::runtime_error("invalid-id");
            if (op == "cancel") {
                cancelled.store(true);
                std::lock_guard<std::mutex> lock(context_mutex);
                if (context) sd_cancel_generation(context, SD_CANCEL_ALL);
                emit({{"event", "cancel-requested"}, {"id", id}, {"contextExists", context != nullptr}});
                continue;
            }
            if (op == "shutdown") break;
            if (op == "stats") { emit({{"event", "stats"}, {"id", id}, {"memory", stats()}}); continue; }
            if (op != "load" && op != "generate" && op != "unload") throw std::runtime_error("invalid-operation");
            if (busy.load()) { emit({{"event", "rejected"}, {"id", id}, {"code", "busy"}}); continue; }
            if (worker.joinable()) worker.join();
            request_id = id; phase = op; diagnostic_event_count.store(0); cancelled.store(false); busy.store(true);
            worker = std::thread(perform, command);
        } catch (...) { emit({{"event", "rejected"}, {"code", "invalid-command"}}); }
    }
    {
        std::lock_guard<std::mutex> lock(context_mutex);
        cancelled.store(true);
        if (context && busy.load()) sd_cancel_generation(context, SD_CANCEL_ALL);
    }
    if (worker.joinable()) worker.join();
    if (context) free_sd_ctx(context);
    return 0;
}
