import CoreGraphics
import CoreImage
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import ImageIO
import PicEditCore
import Testing
import UniformTypeIdentifiers
import Vision
@testable import PicEdit

/// Opt-in visual comparison; never check private photographs or derivatives in.
/// Native measurements run serially so competing Vision/CI work cannot distort them.
@Suite("Automatic masks on an explicitly supplied RAW", .serialized)
struct AutomaticMaskQualityTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PICEDIT_MASK_QUALITY_IMAGE"]?.isEmpty == false))
    func compareLegacyAndCurrentBackgroundMask() async throws {
        let environment = ProcessInfo.processInfo.environment
        let sourceURL = URL(fileURLWithPath: try #require(environment["PICEDIT_MASK_QUALITY_IMAGE"]))
        let output = URL(fileURLWithPath: try #require(environment["PICEDIT_MASK_QUALITY_OUTPUT"],
            "Set an explicit temporary output directory for mask diagnostics"), isDirectory: true).standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let resolvedOutput = output.resolvingSymlinksInPath().path
        let validOutput = ["/private/tmp/", "/tmp/", "/" + temporaryRoot + "/"].contains { resolvedOutput.hasPrefix($0) }
        #expect(validOutput, "RAW derivatives must go to temporary storage")
        guard validOutput else { return }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let imageSource = try #require(CGImageSourceCreateWithURL(sourceURL as CFURL, nil))
        let type = try #require(CGImageSourceGetType(imageSource)) as String
        #expect(PreviewDecoder.isCameraRAWTypeIdentifier(type), "Supply the actual camera RAW")
        guard PreviewDecoder.isCameraRAWTypeIdentifier(type) else { return }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let originalHash = try hash(sourceURL)
        let values = try sourceURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let request = PreviewRequest(url: sourceURL, modifiedAt: values.contentModificationDate ?? .distantPast,
            pixelSize: 2_048, fileSize: Int64(values.fileSize ?? 0), allowsEmbeddedPreview: false)
        let decodeStart = ContinuousClock.now
        let source = try await Task.detached { try PreviewDecoder.decode(request) }.value
        let decodeMS = milliseconds(decodeStart.duration(to: .now))
        #expect(max(source.image.width, source.image.height) <= 2_048)
        try png(source.image, at: output.appendingPathComponent("source.png"))

        let legacyStart = ContinuousClock.now
        let legacy = try legacySubject(source.image)
        let legacyMS = milliseconds(legacyStart.duration(to: .now))
        let currentStart = ContinuousClock.now
        let current = try await AutomaticMaskWorker.shared.generate(source, kind: .subject, sourceURL: sourceURL)
        let currentMS = milliseconds(currentStart.duration(to: .now))
        let extent = CGRect(x: 0, y: 0, width: source.image.width, height: source.image.height)
        let colorSpace = source.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let session = EditRenderer.Session(cacheIntermediates: false, lowPriority: false)
        let context = session.context
        try png(grayImage(legacy), at: output.appendingPathComponent("legacy-subject-mask.png"))
        try png(grayImage(current), at: output.appendingPathComponent("current-subject-mask.png"))

        // Freeze the previous broad Gaussian edge explicitly: the production
        // renderer's automatic-mask feather policy may change independently.
        let legacyCoverage = CIImage(cgImage: try grayImage(legacy), options: [.colorSpace: NSNull()])
            .clampedToExtent().transformed(by: .init(scaleX: extent.width / CGFloat(legacy.width),
                                                     y: extent.height / CGFloat(legacy.height)))
            .cropped(to: extent).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.025 * min(extent.width, extent.height) * 0.5])
            .cropped(to: extent).applyingFilter("CIColorInvert")
        try png(materialize(legacyCoverage, context: context, extent: extent, colorSpace: colorSpace),
                at: output.appendingPathComponent("legacy-background-coverage.png"))
        let correction = LocalAdjustmentSettings(exposure: -4.57, contrast: -68)
        let legacyRenderStart = ContinuousClock.now
        let base = CIImage(cgImage: source.image)
        let candidate = try EditRenderer.manualAdjustments(base, settings: correction.editSettings,
            extent: extent, scale: max(0.25, Double(max(source.image.width, source.image.height)) / 1_600))
        let before = candidate.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: legacyCoverage
        ])
        let legacyRendered = try materialize(before, context: context, extent: extent, colorSpace: colorSpace)
        let legacyRenderMS = milliseconds(legacyRenderStart.duration(to: .now))
        try png(legacyRendered, at: output.appendingPathComponent("legacy-background-darkened.png"))

        var renderMS: [String: Double] = [:]
        for feather in [0.0, 0.5] {
            let suffix = feather == 0 ? "default" : "feather-0.5"
            let mask = try LocalAdjustmentMask(shape: .subject(current), isInverted: true, feather: feather)
            var edits = EditSettings.neutral
            edits.localAdjustments = [try .init(name: "Background quality probe", mask: mask, settings: correction)]
            let start = ContinuousClock.now
            let rendered = try EditRenderer.render(source, settings: edits, session: session)
            renderMS[suffix] = milliseconds(start.duration(to: .now))
            #expect(rendered.image.width == source.image.width && rendered.image.height == source.image.height)
            try png(rendered.image, at: output.appendingPathComponent("current-background-darkened-\(suffix).png"))
            let coverage = try LocalAdjustmentRenderer.maskImage(mask, extent: extent)
            try png(materialize(coverage, context: context, extent: extent, colorSpace: colorSpace),
                    at: output.appendingPathComponent("current-background-coverage-\(suffix).png"))
        }
        #expect(try hash(sourceURL) == originalHash, "Original RAW must remain byte-for-byte unchanged")
        var usage = rusage()
        let peakRSS = getrusage(RUSAGE_SELF, &usage) == 0 ? Int64(usage.ru_maxrss) : -1
        let report: [String: Any] = [
            "source_sha256": originalHash, "source_type": type,
            "width": source.image.width, "height": source.image.height,
            "source_bits_per_component": source.image.bitsPerComponent,
            "source_profile": source.image.colorSpace?.name as String? ?? "unknown",
            "embedded_preview_allowed": false, "raw_decode_ms": decodeMS,
            "legacy_vision_proxy_max_dimension": 1_024,
            "legacy_mask_width": legacy.width, "legacy_mask_height": legacy.height,
            "current_mask_width": current.width, "current_mask_height": current.height,
            "legacy_generation_ms": legacyMS, "current_generation_ms": currentMS,
            "legacy_render_ms": legacyRenderMS, "current_render_ms": renderMS,
            "exposure": correction.exposure, "contrast": correction.contrast,
            "legacy_feather": 0.5, "current_default_feather": 0, "process_peak_rss_bytes": peakRSS,
            "scope": "One supplied RAW at 2048 px; no ground-truth matte and no objective Lightroom parity score. Legacy reproduces Vision revision 1 at 1024 px, a bilinear 512 px mask and the former broad Gaussian feather. Timings exclude PNG writes. Generation is first invocation of each path, in legacy/current order; OS, Vision and GPU caches are not flushed. RSS covers the whole test process."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"), options: .atomic)
        print("Automatic mask quality diagnostic: \(output.path); legacy \(legacyMS) ms, current \(currentMS) ms; peak RSS \(peakRSS) bytes")
    }

    /// Deliberately independent of production size defaults to retain a stable baseline.
    private func legacySubject(_ image: CGImage) throws -> LocalMaskRaster {
        let scale = min(1, 1_024.0 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let request = VNGenerateForegroundInstanceMaskRequest()
        request.revision = VNGenerateForegroundInstanceMaskRequestRevision1
        request.preferBackgroundProcessing = true
        let handler = VNImageRequestHandler(cgImage: try #require(context.makeImage()), orientation: .up, options: [:])
        try handler.perform([request])
        let observation = try #require(request.results?.first)
        #expect(!observation.allInstances.isEmpty)
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        return try legacyRaster(buffer)
    }

    private func legacyRaster(_ buffer: CVPixelBuffer) throws -> LocalMaskRaster {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_OneComponent32Float || format == kCVPixelFormatType_OneComponent8 else {
            throw AutomaticMaskError.invalidMask
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let scale = min(1, 512.0 / Double(max(width, height)))
        let outWidth = max(1, Int((Double(width) * scale).rounded()))
        let outHeight = max(1, Int((Double(height) * scale).rounded()))
        func value(_ x: Int, _ y: Int) throws -> Double {
            let row = base.advanced(by: y * stride)
            let value = format == kCVPixelFormatType_OneComponent32Float
                ? Double(row.assumingMemoryBound(to: Float.self)[x])
                : Double(row.assumingMemoryBound(to: UInt8.self)[x]) / 255
            guard value.isFinite else { throw AutomaticMaskError.invalidMask }
            return min(1, max(0, value))
        }
        var bytes = Data(count: outWidth * outHeight)
        for y in 0..<outHeight {
            try Task.checkCancellation()
            let py = min(Double(height - 1), max(0, (Double(y) + 0.5) * Double(height) / Double(outHeight) - 0.5))
            let y0 = Int(py), y1 = min(y0 + 1, height - 1), fy = py - Double(y0)
            for x in 0..<outWidth {
                let px = min(Double(width - 1), max(0, (Double(x) + 0.5) * Double(width) / Double(outWidth) - 0.5))
                let x0 = Int(px), x1 = min(x0 + 1, width - 1), fx = px - Double(x0)
                let a = try value(x0, y0) * (1 - fx) + value(x1, y0) * fx
                let b = try value(x0, y1) * (1 - fx) + value(x1, y1) * fx
                bytes[y * outWidth + x] = UInt8((255 * (a * (1 - fy) + b * fy)).rounded())
            }
        }
        return try .init(width: outWidth, height: outHeight, bytes: bytes)
    }

    private func grayImage(_ raster: LocalMaskRaster) throws -> CGImage {
        let provider = try #require(CGDataProvider(data: raster.bytes as CFData))
        return try #require(CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: raster.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }

    private func materialize(_ image: CIImage, context: CIContext, extent: CGRect, colorSpace: CGColorSpace) throws -> CGImage {
        try #require(context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: colorSpace, deferred: false))
    }

    private func png(_ image: CGImage, at url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}
