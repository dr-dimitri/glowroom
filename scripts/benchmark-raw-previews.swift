import Foundation
import CoreGraphics
import ImageIO
import Darwin

// Compile: xcrun swiftc -O -parse-as-library scripts/benchmark-raw-previews.swift -o /tmp/glowroom-raw-benchmark
// Run: /tmp/glowroom-raw-benchmark --iterations 3 --sizes 640,2400 /path/to/local.CR3 ...
// Only explicit files are read. Cloud placeholders (SF_DATALESS) are skipped.
@main
struct RAWPreviewBenchmark {
    enum Mode: String, CaseIterable {
        case forced = "forced-full-image"
        case embedded = "embedded-only"
        case ifAbsent = "embedded-if-absent"
    }

    struct Measurement {
        let milliseconds: Double
        let image: CGImage?
    }

    static func main() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var iterations = 3
        var sizes = [640, 2_400]
        var paths: [String] = []
        var bookmarkCatalog: URL?
        while let argument = arguments.first {
            arguments.removeFirst()
            if argument == "--iterations", let value = arguments.first, let number = Int(value), (1...20).contains(number) {
                iterations = number
                arguments.removeFirst()
            } else if argument == "--sizes", let value = arguments.first {
                let values = value.split(separator: ",").compactMap { Int($0) }.filter { (64...4_096).contains($0) }
                guard !values.isEmpty else { throw failure("Sizes must be integers in 64...4096") }
                sizes = values
                arguments.removeFirst()
            } else if argument == "--bookmark-catalog", let value = arguments.first {
                bookmarkCatalog = URL(fileURLWithPath: value)
                arguments.removeFirst()
            } else if argument.hasPrefix("--") {
                throw failure("Usage: benchmark-raw-previews [--iterations 3] [--sizes 640,2400] [--bookmark-catalog catalog.json] local.CR3 ...")
            } else {
                paths.append(argument)
            }
        }
        guard !paths.isEmpty else { throw failure("Supply one or more explicit local image paths.") }
        var scopes: [URL] = []
        if let bookmarkCatalog {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: bookmarkCatalog)) as? [String: Any]
            for folder in object?["folders"] as? [[String: Any]] ?? [] {
                guard let encoded = folder["bookmarkData"] as? String, let data = Data(base64Encoded: encoded),
                      let path = folder["url"] as? String, let original = URL(string: path),
                      paths.contains(where: { $0.hasPrefix(original.path + "/") }) else { continue }
                var stale = false
                if let scope = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale), scope.startAccessingSecurityScopedResource() {
                    scopes.append(scope)
                }
            }
        }
        defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
        print("Fresh ImageIO source per decode; medians use warm filesystem caches, no image cache. Milliseconds include an sRGB render to force deferred decoding.")
        var measuredFiles = 0
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var status = stat()
            guard lstat(url.path, &status) == 0 else { print("\(url.lastPathComponent): unavailable; skipped"); continue }
            guard (status.st_flags & UInt32(SF_DATALESS)) == 0 else { print("\(url.lastPathComponent): cloud placeholder; skipped without opening"); continue }
            guard (status.st_mode & S_IFMT) == S_IFREG else { print("\(url.lastPathComponent): not a regular file; skipped"); continue }
            let metadataOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, metadataOptions),
                  CGImageSourceGetType(source) != nil,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, metadataOptions) as? [CFString: Any] else {
                print("\(url.lastPathComponent): unreadable or unsupported; no timing recorded")
                continue
            }
            measuredFiles += 1
            print("\n\(url.lastPathComponent) | type=\(CGImageSourceGetType(source).map { $0 as String } ?? "unknown") | source=\(properties[kCGImagePropertyPixelWidth] ?? "?")×\(properties[kCGImagePropertyPixelHeight] ?? "?") | EXIF-orientation=\(properties[kCGImagePropertyOrientation] ?? "?") | bytes=\(status.st_size)")
            for size in sizes {
                var measurements: [Mode: [Measurement]] = [:]
                for iteration in 0..<iterations {
                    // Rotate order so a single strategy does not always get cold I/O.
                    let modes = Array(Mode.allCases.dropFirst(iteration % Mode.allCases.count)) + Array(Mode.allCases.prefix(iteration % Mode.allCases.count))
                    for mode in modes {
                        let measurement = autoreleasepool { measure(url: url, size: size, mode: mode) }
                        measurements[mode, default: []].append(measurement)
                    }
                }
                for mode in Mode.allCases {
                    let results = measurements[mode] ?? []
                    let successful = results.filter { $0.image != nil }
                    let values = successful.map(\.milliseconds).sorted()
                    guard !values.isEmpty else {
                        print("  \(size) px | \(mode.rawValue) | no image (0/\(results.count) successful decodes); no timing recorded")
                        continue
                    }
                    let median = values[values.count / 2]
                    let imageDescription = successful.last?.image.map { image in
                        let name = image.colorSpace?.name.map { $0 as String } ?? "unnamed"
                        return "\(image.width)×\(image.height), \(image.bitsPerComponent)-bit, \(name), mean-sRGB=\(meanColor(image))"
                    } ?? "NO IMAGE"
                    print(String(format: "  %4d px | %-23@ | median %8.2f ms | %d/%d decoded | samples %@ | %@", size, mode.rawValue as NSString, median, successful.count, results.count, values.map { String(format: "%.2f", $0) }.joined(separator: ",") as NSString, imageDescription as NSString))
                }
            }
        }
        if measuredFiles == 0 {
            fputs("No readable local images were measured. Check access permissions; no speedup can be inferred.\n", stderr)
            exit(2)
        }
    }

    static func measure(url: URL, size: Int, mode: Mode) -> Measurement {
        let start = CFAbsoluteTimeGetCurrent()
        let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: true
        ]
        switch mode {
        case .forced: options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        case .embedded: break
        case .ifAbsent: options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        }
        let image = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
        if let image { _ = meanColor(image) }
        return Measurement(milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1_000, image: image)
    }

    static func meanColor(_ image: CGImage) -> String {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return (0..<3).map { channel in
            String(format: "%.1f", Double(stride(from: channel, to: pixels.count, by: 4).reduce(0) { $0 + Int(pixels[$1]) }) / Double(side * side))
        }.joined(separator: "/")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "GlowroomRAWBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
