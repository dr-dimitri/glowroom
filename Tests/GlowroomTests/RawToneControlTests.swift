import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import GlowroomCore
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Glowroom

/// Private, opt-in RAW diagnostics. Serial rendering bounds memory and avoids
/// competing native work; Core Image/Core ML retain their own parallel backends.
@Suite("Tone controls on an explicitly supplied RAW", .serialized)
struct RawToneControlTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_TONE_TEST_RAW"]?.isEmpty == false
        && ProcessInfo.processInfo.environment["GLOWROOM_TONE_TEST_OUTPUT"]?.isEmpty == false))
    func compareGlobalAndBackgroundToneControls() async throws {
        let environment = ProcessInfo.processInfo.environment
        let sourceURL = URL(fileURLWithPath: try #require(environment["GLOWROOM_TONE_TEST_RAW"]))
        let requestedOutput = URL(fileURLWithPath: try #require(environment["GLOWROOM_TONE_TEST_OUTPUT"]),
                                  isDirectory: true).standardizedFileURL
        // Foundation can resolve existing /private/tmp to /tmp while retaining
        // /private/tmp for a nonexistent child. Resolve the existing parent
        // first so both sides of the containment check use the same spelling.
        let outputParent = requestedOutput.deletingLastPathComponent().resolvingSymlinksInPath()
        var parentIsDirectory: ObjCBool = false
        try #require(FileManager.default.fileExists(atPath: outputParent.path, isDirectory: &parentIsDirectory)
            && parentIsDirectory.boolValue, "Output's parent directory must already exist")
        let output = outputParent.appendingPathComponent(requestedOutput.lastPathComponent, isDirectory: true)
        // Require a fresh temporary destination; never overwrite existing
        // diagnostics or put private derivatives in the repository.
        let temporaryRoots = [URL(fileURLWithPath: "/private/tmp", isDirectory: true),
                              FileManager.default.temporaryDirectory]
        let isTemporary = temporaryRoots.contains {
            output.path.hasPrefix("/" + $0.resolvingSymlinksInPath().path.trimmingCharacters(in:
                CharacterSet(charactersIn: "/")) + "/")
        }
        try #require(isTemporary, "Use a new directory under /private/tmp or the system temporary directory")
        try #require(!FileManager.default.fileExists(atPath: output.path), "Output directory must not exist")
        let imageSource = try #require(CGImageSourceCreateWithURL(sourceURL as CFURL, nil))
        let sourceType = try #require(CGImageSourceGetType(imageSource)) as String
        try #require(PreviewDecoder.isCameraRAWTypeIdentifier(sourceType), "Supply an actual camera RAW")
        let sourceHash = try hash(sourceURL)
        let properties = try sourceURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let request = PreviewRequest(url: sourceURL, modifiedAt: properties.contentModificationDate ?? .distantPast,
            pixelSize: 2_048, fileSize: Int64(properties.fileSize ?? 0), allowsEmbeddedPreview: false)
        let source = try await Task.detached { try PreviewDecoder.decode(request) }.value

        let frozen: FrozenMask
        if let maskPath = environment["GLOWROOM_TONE_TEST_MASK"], !maskPath.isEmpty {
            frozen = try JSONDecoder().decode(FrozenMask.self, from: Data(contentsOf: URL(fileURLWithPath: maskPath)))
            try #require(frozen.sourceSHA256 == sourceHash, "Frozen mask belongs to a different RAW")
            try #require(frozen.sourceWidth == source.image.width && frozen.sourceHeight == source.image.height,
                         "Frozen mask requires the same oriented RAW decode dimensions")
        } else {
            // Inspect and use the normal installed backend; this diagnostic
            // neither installs models nor changes the application's stores.
            let installation = try #require(await SubjectMattingModelStore.shared.installedModel(),
                "Set up the approved BiRefNet model before generating a new diagnostic mask")
            let raster = try await AutomaticMaskService.shared.generate(source, kind: .subject, sourceURL: sourceURL)
            frozen = FrozenMask(sourceSHA256: sourceHash, sourceWidth: source.image.width,
                sourceHeight: source.image.height,
                backend: "BiRefNet-HR-matting; receipt " + installation.receiptSHA256,
                subject: raster)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(frozen).write(to: output.appendingPathComponent("frozen-mask.json"), options: .atomic)

        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: true)
        let extent = CGRect(x: 0, y: 0, width: source.image.width, height: source.image.height)
        let linearSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let encodedSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let background = try LocalAdjustmentMask(shape: .subject(frozen.subject), isInverted: true, feather: 0)
        let coverageImage = try LocalAdjustmentRenderer.maskImage(background, extent: extent)
        var coverage = [Float](repeating: 0, count: source.image.width * source.image.height)
        session.context.render(coverageImage, toBitmap: &coverage, rowBytes: source.image.width * MemoryLayout<Float>.stride,
            bounds: extent, format: .Rf, colorSpace: nil)
        let maskImage = try #require(session.context.createCGImage(coverageImage, from: extent,
            format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()))
        try png(maskImage, at: output.appendingPathComponent("background-coverage.png"))
        let reference = pixels(source.image, context: session.context, colorSpace: linearSpace)
        var measurements: [String: Any] = [:]
        func save(_ image: CGImage, name: String) throws {
            try png(image, at: output.appendingPathComponent(name + ".png"))
            let values = pixels(image, context: session.context, colorSpace: linearSpace)
            var measurement = statistics(values, reference: reference, coverage: coverage)
            measurement["bits_per_component"] = image.bitsPerComponent
            measurement["color_space"] = image.colorSpace?.name as String? ?? "unknown"
            measurements[name] = measurement
        }
        try save(source.image, name: "source")
        try #require(coverage.contains { $0 >= 0.99 }, "This RAW has no strongly selected background")

        let fullMask = try LocalAdjustmentMask(shape: .subject(LocalMaskRaster(width: 1, height: 1,
            bytes: Data([255]))), feather: 0)
        let controls: [(String, WritableKeyPath<LocalAdjustmentSettings, Double>, Double)] = [
            ("exposure", \.exposure, 5), ("contrast", \.contrast, 100),
            ("highlights", \.highlights, 100), ("shadows", \.shadows, 100),
            ("whites", \.whites, 100), ("blacks", \.blacks, 100)
        ]
        var parity: [String: Double] = [:]
        var encodedParity: [String: Int] = [:]
        func render(_ settings: LocalAdjustmentSettings, mask: LocalAdjustmentMask) throws -> CGImage {
            var edits = EditSettings()
            edits.localAdjustments = [try LocalAdjustment(name: "Diagnostic", mask: mask, settings: settings)]
            return try EditRenderer.render(source, settings: edits, session: session).image
        }
        func compare(_ settings: LocalAdjustmentSettings, name: String) throws {
            try autoreleasepool {
                let global = try EditRenderer.render(source, settings: settings.editSettings, session: session).image
                try save(global, name: name + "-global")
                let local = try render(settings, mask: background)
                try save(local, name: name + "-background-100")
                let full = try render(settings, mask: fullMask)
                let a = pixels(global, context: session.context, colorSpace: linearSpace)
                let b = pixels(full, context: session.context, colorSpace: linearSpace)
                let maximum = zip(a, b).reduce(0.0) { max($0, abs(Double($1.0 - $1.1))) }
                parity[name] = maximum
                let encodedGlobal = encodedPixels(global, context: session.context, colorSpace: encodedSpace)
                let encodedFull = encodedPixels(full, context: session.context, colorSpace: encodedSpace)
                let encodedMaximum = zip(encodedGlobal, encodedFull).reduce(0) {
                    max($0, abs(Int($1.0) - Int($1.1)))
                }
                encodedParity[name] = encodedMaximum
                // Assert in the delivered SDR code-value domain: one 8-bit
                // step near white is much larger in linear light than near
                // black. Keep the linear difference as a diagnostic metric.
                #expect(encodedMaximum <= 2,
                        "A full-strength full-image mask must match the global control within two sRGB 8-bit code values")
                if name == "all-min" { try save(full, name: "all-min-full-mask-100") }
            }
        }
        for (name, keyPath, maximum) in controls {
            for sign in [-1.0, 1.0] {
                try Task.checkCancellation()
                var settings = LocalAdjustmentSettings.neutral
                settings[keyPath: keyPath] = sign * maximum
                try compare(settings, name: name + (sign < 0 ? "-min" : "-max"))
            }
        }
        // Exercise the interaction reported on this RAW, independently of
        // contrast and the other tone controls. Reuse the same decode/mask.
        for (name, keyPath) in [("highlights", \LocalAdjustmentSettings.highlights),
                                ("whites", \LocalAdjustmentSettings.whites)] {
            for sign in [-1.0, 1.0] {
                var settings = LocalAdjustmentSettings(exposure: -5)
                settings[keyPath: keyPath] = sign * 100
                try compare(settings, name: "exposure-min-" + name + (sign < 0 ? "-min" : "-max"))
            }
        }
        let minimum = LocalAdjustmentSettings(exposure: -5, contrast: -100, highlights: -100,
                                              shadows: -100, whites: -100, blacks: -100)
        try compare(minimum, name: "all-min")
        var partial = background
        partial.opacity = 0.77
        try save(render(minimum, mask: partial), name: "all-min-background-077")
        #expect(try hash(sourceURL) == sourceHash, "The original RAW must remain unchanged")
        let report: [String: Any] = [
            "source_sha256": sourceHash, "source_type": sourceType,
            "width": source.image.width, "height": source.image.height,
            "embedded_preview_allowed": false, "mask_backend": frozen.backend,
            "mask_reused": environment["GLOWROOM_TONE_TEST_MASK"]?.isEmpty == false,
            "mask_feather": 0, "measurements": measurements,
            "full_mask_global_max_absolute_linear_rgba_difference": parity,
            "full_mask_global_max_absolute_srgb_rgba8_code_difference": encodedParity,
            "full_mask_global_srgb_rgba8_code_difference_limit": 2,
            "scope": "One explicit RAW at 2048 px, decoded once. Every control starts from the same neutral source; background coverage is the inverted frozen subject mask. Statistics use linear sRGB luminance Y (0.2126 R + 0.7152 G + 0.0722 B), selected coverage >= 0.99, unselected coverage <= 0.01 before opacity. Full-mask/global parity is asserted after explicit conversion to sRGB RGBA8, allowing at most two code values; linear differences remain reported without a fixed linear threshold. PNGs preserve rendered color profiles, recorded alongside their component precision. This is a visual diagnostic and full-mask/global parity check, not a universal brightness or segmentation-quality assertion. Reuse frozen-mask.json via GLOWROOM_TONE_TEST_MASK for before/after runs."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"), options: .atomic)
        print("RAW tone diagnostic: \(output.path)")
    }

    private struct FrozenMask: Codable {
        let sourceSHA256: String
        let sourceWidth: Int
        let sourceHeight: Int
        let backend: String
        let subject: LocalMaskRaster
    }

    private func pixels(_ image: CGImage, context: CIContext, colorSpace: CGColorSpace) -> [Float] {
        var values = [Float](repeating: 0, count: image.width * image.height * 4)
        context.render(CIImage(cgImage: image), toBitmap: &values,
            rowBytes: image.width * 4 * MemoryLayout<Float>.stride,
            bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBAf, colorSpace: colorSpace)
        return values
    }

    private func encodedPixels(_ image: CGImage, context: CIContext, colorSpace: CGColorSpace) -> [UInt8] {
        var values = [UInt8](repeating: 0, count: image.width * image.height * 4)
        context.render(CIImage(cgImage: image), toBitmap: &values, rowBytes: image.width * 4,
            bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA8, colorSpace: colorSpace)
        return values
    }

    private func statistics(_ values: [Float], reference: [Float], coverage: [Float]) -> [String: Any] {
        var selectedCount = 0, unselectedCount = 0
        var selectedY = 0.0, unselectedY = 0.0, unselectedMaximumDifference = 0.0
        for index in coverage.indices {
            let offset = index * 4
            let y = 0.2126 * Double(values[offset]) + 0.7152 * Double(values[offset + 1])
                + 0.0722 * Double(values[offset + 2])
            if coverage[index] >= 0.99 { selectedCount += 1; selectedY += y }
            if coverage[index] <= 0.01 {
                unselectedCount += 1; unselectedY += y
                for channel in 0..<3 {
                    unselectedMaximumDifference = max(unselectedMaximumDifference,
                        abs(Double(values[offset + channel] - reference[offset + channel])))
                }
            }
        }
        return ["selected_pixel_count": selectedCount,
                "selected_mean_linear_Y": selectedCount > 0 ? selectedY / Double(selectedCount) as Any : NSNull(),
                "unselected_pixel_count": unselectedCount,
                "unselected_mean_linear_Y": unselectedCount > 0 ? unselectedY / Double(unselectedCount) as Any : NSNull(),
                "unselected_max_absolute_linear_RGB_change": unselectedMaximumDifference]
    }

    private func png(_ image: CGImage, at url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }

    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
}
