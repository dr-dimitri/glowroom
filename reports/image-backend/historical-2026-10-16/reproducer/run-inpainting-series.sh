#!/bin/sh
# Opt-in launcher. Merely preparing/chmodding this file compiles/runs nothing.
set -eu
if [ "$#" -eq 0 ] || [ "$1" != "--run" ]; then
    printf '%s\n' 'PREPARED ONLY. Authorized exclusive window required.'
    printf '%s\n' 'Usage: run-inpainting-series.sh --run --window ROOT-LEASE --mode full|coverage --phase all|series|cancel --max-total-seconds 2400'
    printf '%s\n' 'This opt-in command will compile the Swift CLI, then run real local models. No downloads/network.'
    exit 0
fi
picedit_series_window=''
picedit_series_previous=''
for picedit_series_argument in "$@"; do
    if [ "$picedit_series_previous" = '--window' ]; then
        picedit_series_window="$picedit_series_argument"
    fi
    picedit_series_previous="$picedit_series_argument"
done
case "$picedit_series_window" in
    ''|--*) printf '%s\n' 'Explicit Root window ID is required before any compiler starts.' >&2; exit 2 ;;
esac
picedit_series_root=/private/tmp/picedit-inpainting-gate
picedit_series_stamp=$(date -u +%Y%m%d-%H%M%S)-$$
picedit_series_build="$picedit_series_root/series-build/$picedit_series_stamp"
mkdir -p "$picedit_series_build"
picedit_series_log="$picedit_series_build/swift-build.log"
/Library/Developer/CommandLineTools/usr/bin/swiftc \
    -O -swift-version 5 -target arm64-apple-macos14.0 \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk \
    -module-cache-path "$picedit_series_build/module-cache" \
    -framework Foundation -framework CoreImage -framework CoreGraphics -framework CryptoKit \
    "$picedit_series_root/evaluate-inpainting-series.swift" \
    -o "$picedit_series_build/evaluate-inpainting-series" > "$picedit_series_log" 2>&1 || {
        printf '%s\n' "Swift compile failed. Preserved diagnostic log: $picedit_series_log" >&2
        exit 1
    }
exec "$picedit_series_build/evaluate-inpainting-series" "$@"
