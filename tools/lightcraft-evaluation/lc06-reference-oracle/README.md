# LC-06 original-function oracle

`vectors.json` freezes **40 opaque Rec.2020 cases** from Lightcraft commit
`f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15`. The generator reads Git objects at
that exact commit without changing the checkout and verifies every source
file's SHA256. It extracts the original `detail_scale`, `nr_radius`, `nr_params`,
`apply_nr`, `log_lum`, `guided`, `guided_coeffs`, and `guided_apply` function
bodies and the original Gaussian/resampling modules. It does not call the Swift
adapter or reproduce its formula in Python.

The LC-03 storage shim supplies simple Rust arrays and serial row scheduling;
the arithmetic, clamped borders and 32-row Gaussian bands remain original.
A minimal settings struct supplies only the fields those original functions
read. `nr_detail`, `nr_color_detail`, and `nr_color_smoothness` are fixed at 50.
Profiling is disabled. No `nr_contrast` behavior is invented.

The cases cover both controls at 0/20/60/100 and scales 1, 1/2, 1/8, 1/50,
including radius variance fading and the original minimum-blend cutoff.
Mixed signed/extended RGB, near-black samples, black, color edges, a 35-row
image crossing the Gaussian band boundary, a negative 1×1 image, and 1×N/N×1
images exercise original pixel behavior. Each case records input, original
parameters and output. Chroma's `max(Y,1e-6)` divisor and final nonnegative
Rec.2020 clamp are retained, including near-black darkening. Luma uses full
`guided`, never `guided_fast`.

The original chroma operation is not safe for arbitrarily negative luminance:
the 1×1 Rec.2020 input `[-0.2,-0.1,-0.05]` at color amount 60 produces
`[24661.002,12330.501,6165.2505]`. Its positive divisor floor is followed by
multiplication with the original negative Y. This is retained as an explicit
upstream limitation, not silently corrected by clipping the input. Signed
single channels with positive Y follow a different path and can clip to zero.

Swift tests allow absolute Float32 error `5e-6` plus relative error `2e-6`
per component. Relative error is needed for the source's large chromaticity
ratios around black; it is not an image-quality acceptance threshold.
The explicit sRGB/Rec.2020 bridge, coverage-normalized alpha handling,
exact canonical zero branch and unknown-sampling policy are Glowroom
adaptations tested separately. The source's epsilon scale² is used only when
input area averaging is explicitly known. Unknown sampling preserves native
epsilon while retaining geometric radius/blend scaling.

Optional regeneration (Python, `rustc`, local Lightcraft Git checkout):

```sh
python3 tools/lightcraft-evaluation/lc06-reference-oracle/generate.py /path/to/lightcraft
python3 tools/lightcraft-evaluation/lc06-reference-oracle/generate.py /path/to/lightcraft --write
```

Without `--write` the tool must reproduce the committed JSON exactly. Rust
source/binary files exist only in an automatically removed temporary directory.
Normal Glowroom builds and Swift tests require neither Rust nor Lightcraft.
See [third-party notices](../THIRD-PARTY-NOTICES.txt) and the preserved
[MIT license](../licenses/lightcraft/LICENSE-MIT).
