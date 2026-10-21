# Optional Rust mask-resampling experiment

This dependency-free crate is a measurement prototype for issue #44. Glowroom
does not link, bundle, sign, load or require it in a production build. Only the
explicitly selected editing developer harness can load its absolute library path.
The ordinary Swift path remains available for every benchmark and app operation.

## Reproduction

The prototype pins Rust/Cargo **1.99.1**, edition 2024, with no third-party crates.
`Cargo.lock` is checked in. `rust-toolchain.toml` selects that version when using
rustup from this directory; the wrapper additionally checks the actual compiler
and Cargo versions, including installations without rustup.

```sh
# Builds the actual release app target, then the optional prototype; runs serially.
GLOWROOM_MASK_RUST=1 scripts/benchmark-masks.sh \
  --width 4096 --height 4096 --mask-fixture many-mixed \
  --mask-workload active --iterations 20

# Build/test the prototype separately; use a distinct directory from active work.
CARGO_TARGET_DIR=/private/tmp/glowroom-mask-rust cargo test \
  --manifest-path tools/mask-performance/Cargo.toml --locked --offline
CARGO_TARGET_DIR=/private/tmp/glowroom-mask-rust cargo build \
  --manifest-path tools/mask-performance/Cargo.toml --release --locked --offline

# Supply an existing library without rebuilding it. Record its compiler separately.
GLOWROOM_MASK_RUST_LIBRARY=/private/tmp/glowroom-mask-rust/release/libglowroom_mask_performance.dylib \
  scripts/benchmark-masks.sh --width 1024 --height 1024 --iterations 20
```

The prototype builds for the active compiler's host architecture only. It has no
universal binary, app link, bundle, signing or distribution path. Those would be
additional integration obligations if future measurements justified shipping it.
The repository's MIT license applies; there are no additional dependency licenses.

## Comparison and timing

The harness compares three implementations using the same generated native
Gray8 documents and sizes:

1. Full Swift rasterization plus the original scalar resampler, which recomputes
   horizontal sampling coordinates for each pixel.
2. Incremental Swift rasterization plus optimized Swift resampling, which computes
   one horizontal sampling table per invocation.
3. The same incremental Swift worker, replacing only resampling with this Rust
   kernel. Rust uses the same sampling-table algorithm as optimized Swift.

The first comparison includes an algorithm change. The second comparison isolates
the remaining implementation/language difference more closely; Rust must not be
credited with the benefit of introducing the sampling table or incremental raster.
Neither implementation enables fast math or changes rounding/operation order.

The complete synchronous Swift→Rust→Swift resampling call includes Swift output
allocation, borrowed input/output pointers, Rust sampling-table allocation,
cancellation callbacks and the returned `MaskRaster` wrapper. There is no JSON,
file exchange or explicit full-input copy. The same worker performs native
rasterization, canonical SHA-256 and overlay creation around all three variants;
whole-action timings include those phases. `dlopen`/symbol lookup happen once
before timing. Identity-size resampling returns the input directly in all variants;
such a sample contains no Rust kernel work.

Variants run sequentially with rotating order, a separate excluded warmup and a
fresh worker primed with the same initial document for each sequence. JSONL emits
raw samples, phase times, process CPU time, p50/p95 and throughput. Peak RSS covers
the entire comparison process, including untimed exact verification and all
variants; it is not a per-kernel allocation measurement. Native profiling and
uninstrumented acceptance runs must be reported separately.

The harness requires exact native raster bytes and SHA-256, preview bytes and
overlay bytes. Additional tiny, nonsquare, single-pixel and upsampling cases check
the Swift/Rust sampling contract. Cargo tests exercise center rounding, padded
strides, invalid lengths/shapes, overlap and cancellation before/after partial work.

The canonical native-mask worker and the currently visible local-mask editor are
different paths. A gain in this prototype does not establish a gain in the visible
editor, which directly rasterizes a capped mask and need not resample native data.
Production selection criteria and final results belong in
[the performance report](../../docs/PERFORMANCE.md).

## C ABI and buffer contract

The versioned declaration is in [mask_resample.h](mask_resample.h).
`glowroom_mask_resample_v1` accepts immutable `UInt8` source and exclusively owned
mutable destination pointers, explicit buffer lengths, widths, heights and byte
strides. Pixels are scalar Gray8 in top-left row order; no color conversion or
premultiplication occurs. It samples full-input pixel centers using bilinear
interpolation, clamps to the outer source centers and rounds nonnegative values
to the nearest integer, with halfway values away from zero. This prototype does
not implement crops; cropped production behavior remains in Swift.

Each dimension must be 1…16,384 and each image may contain at most 16,777,216
pixels. Strides must be at least their respective widths and lengths must cover
`height * stride`, including padding. Checked arithmetic rejects overflow. The
caller must provide valid readable/writable memory for the full advertised
length, retain ownership for the entire synchronous call and ensure the buffers
do not overlap. Padding bytes in the destination are preserved.

The kernel borrows both buffers, retains no pointers and allocates only a bounded
horizontal-coordinate table. It has no global mutable state or worker pool.
Independent calls are thread-safe with disjoint destinations and immutable source
buffers; each call executes on its caller's existing admitted worker.

Return values are:

| Code | Meaning | Caller action |
|---|---|---|
| 0 | Complete success | Publish the destination. |
| 1 | Invalid shape, pointer, length, stride or overlap | Discard the destination. |
| 2 | Cancellation callback returned nonzero | Discard the partial destination. |
| 3 | Caught Rust panic | Discard the partial destination. |

The optional C callback receives a caller-owned context pointer. It must remain
valid until return and must not throw or unwind across C. The kernel checks it at
least every sixteen output rows and after completion. The Swift wrapper checks
the same cancellation token before and after FFI and maps code 2 to
`CancellationError`. A callback token error is treated as cancellation; no partial
result becomes a worker cache basis or UI result.

The release profile retains unwinding and `catch_unwind` contains catchable Rust
panics at the boundary. Invalid foreign memory and process-level allocation
failure cannot be recovered through this return-code contract. Swift always
passes managed, valid buffers; validation tests use only valid backing storage
even when exercising rejected sizes and overlap.
