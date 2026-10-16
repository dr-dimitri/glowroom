import CoreGraphics
import Darwin
import Foundation
import PicEditCore

// Reproducible scheduling/rendering workload; no originals or catalog files are
// opened. The synthetic decoder supplies one immutable 2400x1600 bitmap. Cold
// and warm refer only to its rendered-preview cache, not OS or GPU shader caches.
final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var decodes = 0
    private var renders = 0
    func decoded() { lock.lock(); decodes += 1; lock.unlock() }
    func rendered() { lock.lock(); renders += 1; lock.unlock() }
    func values() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (decodes, renders) }
}

@main struct Benchmark {
    static func main() async throws {
        log("Synthetic editing benchmark: no RAW decoding or disk-cache I/O; cold/warm means rendered-preview cache only.")
        log("The synthetic decoder is invoked once before both slider bursts and returns a generated bitmap; no ImageIO decoding is measured.")
        log("Peak RSS is cumulative process memory; final latency includes the existing 45 ms debounce.")
        let counts = Counts()
        let bitmap = try fixture()
        let originals = ImagePreviewPipeline(decoder: { _ in counts.decoded(); return bitmap })
        let edits = AdjustedPreviewPipeline(renderer: { source, settings in
            counts.rendered()
            return try EditRenderer.render(source, settings: settings)
        })
        let request = PreviewRequest(url: URL(fileURLWithPath: "/synthetic-gradient"), modifiedAt: .distantPast,
                                     pixelSize: 2_400, allowsEmbeddedPreview: false)
        let source = try await originals.image(for: request, priority: .selected)
        for label in ["cold-render-cache", "warm-render-cache"] {
            log("Starting \(label) 2400x1600, 24 slider events at 10 ms, 45 ms UI debounce")
            let before = counts.values()
            let start = ContinuousClock.now
            var lastEvent = start
            var tasks: [Task<PreviewBitmap, Error>] = []
            for step in 1...24 {
                tasks.last?.cancel()
                var settings = EditSettings.neutral
                settings.exposure = Double(step) / 10
                settings.autoToneAmount = 20
                settings.texture = 25
                settings.clarity = 15
                settings.colorNoiseReduction = 20
                let renderSettings = settings
                lastEvent = .now
                tasks.append(Task {
                    try await Task.sleep(for: .milliseconds(45))
                    return try await edits.image(source, request: request, settings: renderSettings, priority: .selected)
                })
                if step < 24 { try await Task.sleep(for: .milliseconds(10)) }
            }
            guard let final = tasks.last else { return }
            let output = try await final.value
            let completed = ContinuousClock.now
            for task in tasks.dropLast() { _ = try? await task.value }
            let after = counts.values()
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            log("\(label): final latency=\(lastEvent.duration(to: completed)), total=\(start.duration(to: completed)), decodes this burst=\(after.0 - before.0), renders=\(after.1 - before.1), total decodes=\(after.0), peak RSS bytes=\(usage.ru_maxrss), output=\(output.image.width)x\(output.image.height)")
        }
    }

    static func log(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }

    static func fixture() throws -> PreviewBitmap {
        let width = 2_400, height = 1_600
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else {
            throw EditRenderError.unavailable
        }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                pixels[index] = UInt8(x * 255 / width)
                pixels[index + 1] = UInt8(y * 255 / height)
                pixels[index + 2] = UInt8((x + y) * 255 / (width + height))
                pixels[index + 3] = 255
            }
        }
        guard let image = context.makeImage() else { throw EditRenderError.unavailable }
        return PreviewBitmap(image: image)
    }
}
