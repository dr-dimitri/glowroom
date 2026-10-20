// Evaluation-only Euler schedule, fixed to the pinned SDXL model configuration.
#ifndef GLOWROOM_SDXL_REFERENCE_SCHEDULE_H
#define GLOWROOM_SDXL_REFERENCE_SCHEDULE_H

#include <array>

namespace glowroom_sdxl {
inline constexpr char schedule_variant[] = "euler-leading-strength099-v1";
inline constexpr int configured_steps = 20;
inline constexpr int actual_steps = 19;

inline constexpr std::array<int, actual_steps> reference_timesteps() {
    return {901, 851, 801, 751, 701, 651, 601, 551, 501, 451,
            401, 351, 301, 251, 201, 151, 101, 51, 1};
}

// scaled_linear betas: linspace(sqrt(.00085), sqrt(.012), 1000)^2;
// alpha_bar is the cumulative product of (1-beta), sigma=sqrt((1-alpha)/alpha).
// Leading spacing for 20 nominal steps gives 951,901,...,1. Strength .99
// retains the final 19 steps. Values were executed from the pinned Diffusers
// scheduler assignments using PyTorch 2.5.0 CPU float32 / NumPy 1.26.4, then
// frozen as round-tripping float constants. Their 80 little-endian float bytes
// have SHA-256 15d8db9843a2258e2ada72425a87902458f29ecdc9a49b3495e9f8b26041adc4.
// This schedule match is not a pixelwise Diffusers equivalence claim; the native
// regression separately bounds SDK float timestep reconstruction error.
inline constexpr std::array<float, actual_steps + 1> reference_sigmas() {
    return {8.390686988830566f, 6.506400108337402f, 5.134433269500732f,
            4.116698265075684f, 3.3477649688720703f, 2.756196975708008f,
            2.2928547859191895f, 1.9234442710876465f, 1.6236929893493652f,
            1.376179575920105f, 1.1682164669036865f, 0.9904093146324158f,
            0.8356532454490662f, 0.6983985900878906f, 0.5740507245063782f,
            0.4583331346511841f, 0.3461872935295105f, 0.22814729809761047f,
            0.04131447896361351f, 0.f};
}
}
#endif
