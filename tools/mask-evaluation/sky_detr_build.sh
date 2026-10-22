#!/bin/bash
# Standalone evaluation only; no app or model installation is modified.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="${1:-/private/tmp/glowroom-sky-detr-harness}"
mkdir -p "$BUILD"
/usr/bin/python3 - "$ROOT" "$BUILD" <<'PY'
import hashlib, json, pathlib, re, sys
root, out = map(pathlib.Path, sys.argv[1:])
service_path = root / 'Sources/Glowroom/Imaging/AutomaticMaskService.swift'
store_path = root / 'Sources/Glowroom/Imaging/AutomaticMaskModelStore.swift'
service, store = service_path.read_text(), store_path.read_text()
def declaration(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    for i in range(opening + 1, len(source)):
        depth += (source[i] == '{') - (source[i] == '}')
        if depth == 0:
            return source[start:i+1]
    raise ValueError('Unbalanced declaration: ' + marker)
error = declaration(service, 'enum AutomaticMaskError:')
converter = declaration(service, 'enum AutomaticMaskRasterConverter {')
pixel = declaration(service, 'private static func squarePixelBuffer(').replace('private static func', 'static func', 1)
approved = declaration(store, 'enum SkyMaskApprovedPackage {')
revision = re.search(r'static let revision = "([a-f0-9]+)"', approved).group(1)
files = re.findall(r'\.init\(path: "([^"]+)", bytes: ([\d_]+), sha256: "([a-f0-9]{64})"\)', approved)
assert len(files) == 3 and len(revision) == 40, 'Approved model contract changed; review harness.'
paths = [service_path, store_path, root / 'Sources/Glowroom/Imaging/AutomaticMaskRefiner.swift']
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
literal = lambda value: json.dumps(value, ensure_ascii=True)
rows = ',\n'.join('        .init(path: %s, bytes: %s, sha256: %s)' % (literal(p), n.replace('_',''), literal(h)) for p,n,h in files)
hash_rows = ',\n'.join('        %s: %s' % (literal(p), literal(h)) for p,h in sorted(hashes.items()))
generated = '''// Generated from current production sources; do not edit.
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import GlowroomCore
''' + error + '\n' + converter + '\nenum NativeDETRInput {\n' + pixel + '\n}\n' + '''
enum HarnessSource {
    static let revision = %s
    struct File { let path: String; let bytes: Int64; let sha256: String }
    static let files: [File] = [
%s
    ]
    static let sourceSHA256: [String: String] = [
%s
    ]
}
''' % (literal(revision), rows, hash_rows)
(out / 'ProductionSkyContract.swift').write_text(generated)
PY
# This independent build directory avoids app/test build locks. Compile the
# complete real Core module; no shadow definitions or copied guided filter.
CORE_SOURCES=()
while IFS= read -r file; do CORE_SOURCES+=("$file"); done < <(find "$ROOT/Sources/GlowroomCore" -name '*.swift' -type f | sort)
xcrun swiftc -O -parse-as-library -emit-library -emit-module -module-name GlowroomCore \
  -I "$ROOT/Sources/CSQLite" -module-cache-path "$BUILD/module-cache" \
  "${CORE_SOURCES[@]}" -o "$BUILD/libGlowroomCore.dylib" \
  -emit-module-path "$BUILD/GlowroomCore.swiftmodule"
xcrun swiftc -O -parse-as-library -I "$BUILD" -I "$ROOT/Sources/CSQLite" -L "$BUILD" -lGlowroomCore \
  -Xlinker -rpath -Xlinker "$BUILD" -module-cache-path "$BUILD/module-cache" \
  "$BUILD/ProductionSkyContract.swift" "$ROOT/Sources/Glowroom/Imaging/AutomaticMaskRefiner.swift" \
  "$ROOT/tools/mask-evaluation/sky_detr.swift" -o "$BUILD/sky-detr"
printf '%s\n' "$BUILD/sky-detr"
