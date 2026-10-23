#!/bin/bash
set -euo pipefail

# Only the Metal library is extracted; no Python interpreter, extension or
# downloaded code is executed. mlx-swift 0.32.3 vendors exactly MLX v0.32.2:
# 1f8e74e3f12f31365464a6867c6579f0e9b29d85 (not its stale version define).
DESTINATION="${1:?Usage: prepare-mlx-runtime.sh destination-directory}"
mkdir -p "$DESTINATION"
SHADER_SHA=a19618258e2a215d0d0ac3056174a6e066818bb6cdecb50062cc9316076ebe43
LICENSE_SHA=ccfab7ccb2ea306f71531c8ca77bb55507606cd90768b1e32b8b52ab5b48cf01
WHEEL_SHA=3825fff379dbc107dd3413e564a06caeaa24819910ec49c0439e454c06a1b9b8
WHEEL_URL=https://files.pythonhosted.org/packages/f7/ab/ba1952908c5d2a5070cf1cfbfea0161c4751ea62299e2776819810917483/mlx_metal-0.32.2-py3-none-macosx_14_0_arm64.whl
verify() { [[ "$(shasum -a 256 "$1" | awk '{print $1}')" == "$2" ]]; }
if [[ -f "$DESTINATION/mlx.metallib" && -f "$DESTINATION/MLX-LICENSE.txt" ]] && verify "$DESTINATION/mlx.metallib" "$SHADER_SHA" && verify "$DESTINATION/MLX-LICENSE.txt" "$LICENSE_SHA"; then
    exit 0
fi
STAGING="$(mktemp -d "$DESTINATION/.mlx-runtime.XXXXXX")"
trap 'rm -rf -- "$STAGING"' EXIT
curl --fail --location --silent --show-error --retry 2 --connect-timeout 30 --max-time 600 "$WHEEL_URL" -o "$STAGING/runtime.whl"
verify "$STAGING/runtime.whl" "$WHEEL_SHA" || { echo 'MLX runtime archive checksum mismatch' >&2; exit 1; }
unzip -p "$STAGING/runtime.whl" mlx/lib/mlx.metallib > "$STAGING/mlx.metallib"
unzip -p "$STAGING/runtime.whl" mlx_metal-0.32.2.dist-info/licenses/LICENSE > "$STAGING/MLX-LICENSE.txt"
verify "$STAGING/mlx.metallib" "$SHADER_SHA" || { echo 'MLX Metal library checksum mismatch' >&2; exit 1; }
verify "$STAGING/MLX-LICENSE.txt" "$LICENSE_SHA" || { echo 'MLX license checksum mismatch' >&2; exit 1; }
mv "$STAGING/mlx.metallib" "$DESTINATION/mlx.metallib"
mv "$STAGING/MLX-LICENSE.txt" "$DESTINATION/MLX-LICENSE.txt"
