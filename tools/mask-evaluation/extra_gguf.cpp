// Developer-only resident-model benchmark for Acly/vision.cpp BiRefNet F16.
// CPU execution is intentionally serial across photographs to bound memory and
// avoid contention with the other evaluated models. CPU kernels use 4 threads.
// Usage: extra_gguf model.gguf prepared-input-dir output-dir [threads]
#include <visp/vision.h>
#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <sys/resource.h>

using namespace visp;
namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;
static double seconds(Clock::time_point start) {
    return std::chrono::duration<double>(Clock::now() - start).count();
}
static std::string quote(std::string const& text) {
    std::ostringstream out;
    out << '"';
    for (unsigned char ch : text) {
        if (ch == '"' || ch == '\\') out << '\\' << ch;
        else if (ch < 32) out << "\\u" << std::hex << std::setfill('0') << std::setw(4) << int(ch);
        else out << ch;
    }
    out << '"';
    return out.str();
}

int main(int argc, char** argv) {
    try {
        if (argc < 4 || argc > 5) throw std::runtime_error("Usage: extra_gguf model.gguf inputs output [threads]");
        int threads = argc == 5 ? std::stoi(argv[4]) : 4;
        if (threads < 1 || threads > 16) throw std::runtime_error("threads must be 1...16");
        fs::path output(argv[3]);
        if (fs::exists(output)) throw std::runtime_error("Refusing to overwrite existing output directory");
        std::vector<fs::path> inputs;
        for (auto const& item : fs::directory_iterator(argv[2])) {
            if (item.is_regular_file() && item.path().extension() == ".png") inputs.push_back(item.path());
        }
        std::sort(inputs.begin(), inputs.end());
        if (inputs.empty()) throw std::runtime_error("No prepared PNG inputs");
        fs::create_directories(output);
        auto start = Clock::now();
        auto backend = backend_init(backend_type::cpu);
        backend_set_n_threads(backend, threads);
        auto model = birefnet_load_model(argv[1], backend);
        double load = seconds(start);
        std::vector<std::string> records;
        for (size_t index = 0; index < inputs.size(); ++index) {
            // Repeat the first image once with resident weights and graph.
            for (int iteration = 1; iteration <= (index == 0 ? 2 : 1); ++iteration) {
                auto requestStart = Clock::now();
                auto image = image_load(inputs[index].c_str());
                double inputSeconds = seconds(requestStart);
                auto pipelineStart = Clock::now();
                auto mask = birefnet_compute(model, image);
                double pipelineSeconds = seconds(pipelineStart);
                if (mask.format != image_format::alpha_u8 || mask.extent != image.extent)
                    throw std::runtime_error("Unexpected output mask format or extent");
                auto pixels = image_view(mask).as_bytes();
                auto [minimum, maximum] = std::minmax_element(pixels.begin(), pixels.end());
                size_t fractional = 0, foreground = 0;
                for (auto value : pixels) {
                    fractional += value > 0 && value < 255;
                    foreground += value >= 128;
                }
                double requestSeconds = seconds(requestStart);
                std::string id = inputs[index].stem().string();
                auto maskPath = output / (id + "-" + std::to_string(iteration) + "-alpha.png");
                auto outputStart = Clock::now();
                image_save(mask, maskPath.c_str());
                std::ostringstream record;
                record << std::setprecision(9) << "{\"id\":" << quote(id)
                    << ",\"iteration\":" << iteration << ",\"inputSeconds\":" << inputSeconds
                    << ",\"pipelineSeconds\":" << pipelineSeconds
                    << ",\"requestSeconds\":" << requestSeconds
                    << ",\"outputSeconds\":" << seconds(outputStart)
                    << ",\"alphaMinimum\":" << int(*minimum) << ",\"alphaMaximum\":" << int(*maximum)
                    << ",\"foregroundFractionAtHalf\":" << double(foreground) / pixels.size()
                    << ",\"fractionalAlphaFraction\":" << double(fractional) / pixels.size() << "}";
                records.push_back(record.str());
                std::cout << record.str() << std::endl;
            }
        }
        struct rusage usage{};
        getrusage(RUSAGE_SELF, &usage);
        // macOS ru_maxrss is bytes (Linux reports KiB).
#ifdef __APPLE__
        long long rssBytes = usage.ru_maxrss;
#else
        long long rssBytes = usage.ru_maxrss * 1024LL;
#endif
        std::ofstream report(output / "report.json");
        report << "{\"model\":\"BiRefNet standard F16 GGUF (not HR-matting)\","
            << "\"runtime\":\"Acly/vision.cpp\",\"backend\":\"cpu\",\"threads\":" << threads
            << ",\"residentWeightType\":" << quote(ggml_type_name(model.weights.float_type()))
            << ",\"inputSide\":" << model.params.image_size << ",\"loadSeconds\":" << load
            << ",\"peakRSSBytes\":" << rssBytes
            << ",\"timingScope\":\"pipelineSeconds includes resize, normalization, graph setup on first call, inference, restore and uint8 conversion; requestSeconds adds PNG load and output validation; output writes excluded\","
            << "\"records\":[";
        for (size_t index = 0; index < records.size(); ++index) {
            if (index) report << ',';
            report << records[index];
        }
        report << "]}\n";
        if (!report) throw std::runtime_error("Unable to write report");
        return 0;
    } catch (std::exception const& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
