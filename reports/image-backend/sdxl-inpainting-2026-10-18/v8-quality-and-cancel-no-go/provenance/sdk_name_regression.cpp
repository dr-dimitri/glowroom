// Runs the actual pinned SDK conversion/detection against tiny metadata only.
// No weight file, GPU, model context, conversion job or inference is created.
#include <cstdio>
#include <stdexcept>
#include <string>
#include "model_loader.h"
#include "name_conversion.h"

static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

static void add(ModelLoader& loader, const std::string& name, int64_t first, int64_t second = 1,
                int64_t third = 1, int64_t fourth = 1) {
    TensorStorage tensor;
    tensor.name = name;
    tensor.type = GGML_TYPE_F16;
    tensor.n_dims = (third != 1 || fourth != 1) ? 4 : 2;
    tensor.ne[0] = first; tensor.ne[1] = second; tensor.ne[2] = third; tensor.ne[3] = fourth;
    loader.get_tensor_storage_map().emplace(name, std::move(tensor));
}

static ModelLoader fixture(int channels, bool second_encoder) {
    ModelLoader loader;
    add(loader, "unet.conv_in.weight", 3, 3, channels, 320);
    add(loader, "unet.down_blocks.0.resnets.0.conv1.weight", 3, 3, 320, 320);
    add(loader, "unet.mid_block.resnets.1.conv1.weight", 3, 3, 1280, 1280);
    add(loader, "unet.mid_block.attentions.0.transformer_blocks.0.attn1.to_q.weight", 1280, 1280);
    add(loader, "te.text_model.embeddings.token_embedding.weight", 768, 49408);
    if (second_encoder) add(loader, "te.1.text_model.embeddings.token_embedding.weight", 1280, 49408);
    return loader;
}

static void round_trip(int channels, bool second_encoder, SDVersion expected) {
    auto original = fixture(channels, second_encoder);
    require(original.get_sd_version() == expected, "raw fixture architecture detection");
    ModelLoader converted;
    for (const auto& entry : original.get_tensor_storage_map()) {
        auto tensor = entry.second;
        tensor.name = convert_tensor_name(tensor.name, original.get_sd_version());
        const auto name = tensor.name;
        converted.get_tensor_storage_map().emplace(name, std::move(tensor));
    }
    require(converted.get_sd_version() == expected, "architecture changes after SDK name conversion");
    const auto& input = converted.get_tensor_storage_map().at("model.diffusion_model.input_blocks.0.0.weight");
    require(input.ne[0] == 3 && input.ne[1] == 3 && input.ne[2] == channels && input.ne[3] == 320,
            "input tensor architecture was changed");
    const auto& tensors = converted.get_tensor_storage_map();
    require(tensors.count("cond_stage_model.transformer.text_model.embeddings.token_embedding.weight") == 1,
            "first encoder namespace");
    require(tensors.count("cond_stage_model.1.transformer.text_model.embeddings.token_embedding.weight") ==
                (second_encoder ? 1U : 0U), "second encoder namespace");
    require(tensors.count("cond_stage_model.transformer.1.text_model.embeddings.token_embedding.weight") == 0,
            "invalid nested encoder namespace");
}

int main() {
    try {
        require(convert_tensor_name("te.1.text_model.embeddings.position_embedding.weight", VERSION_SDXL_INPAINT) ==
                    "cond_stage_model.1.transformer.text_model.embeddings.position_embedding.weight", "second encoder alias");
        require(convert_tensor_name("te.text_model.embeddings.position_embedding.weight", VERSION_SDXL_INPAINT) ==
                    "cond_stage_model.transformer.text_model.embeddings.position_embedding.weight", "first encoder alias");
        require(convert_tensor_name("te.1.text_projection.weight", VERSION_SDXL_INPAINT) ==
                    "cond_stage_model.1.transformer.text_model.text_projection", "second encoder projection");
        for (const auto* name : {"cond_stage_model.transformer.text_model.embeddings.position_embedding.weight",
                                 "cond_stage_model.1.transformer.text_model.embeddings.position_embedding.weight"}) {
            require(convert_tensor_name(name, VERSION_SDXL_INPAINT) == name, "canonical encoder name changes");
        }
        round_trip(9, true, VERSION_SDXL_INPAINT);
        round_trip(4, true, VERSION_SDXL);
        round_trip(9, false, VERSION_SD1_INPAINT);
        std::puts("PASS actual SDK: Diffusers encoder aliases, canonical names, SDXL 4/9-channel and SD1 inpaint metadata");
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "FAIL SDK name regression: %s\n", error.what());
        return 1;
    }
}
