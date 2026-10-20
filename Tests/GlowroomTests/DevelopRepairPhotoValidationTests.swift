import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import GlowroomCore
import Testing
import UniformTypeIdentifiers
@testable import Glowroom

/// Explicit local photograph diagnostic. Neither the RAW nor its derivatives
/// belong in the repository. Cases run serially to make GPU timings comparable
/// and to keep only one pair of 2400 px pixel buffers alive at a time.
@Suite("Repair on an explicitly supplied yew photograph", .serialized)
struct DevelopRepairPhotoValidationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_REPAIR_PHOTO"]?.isEmpty == false))
    func removePaintedBerriesWebAndBranch() async throws {
        let environment = ProcessInfo.processInfo.environment
        let sourceURL = URL(fileURLWithPath: try #require(environment["GLOWROOM_REPAIR_PHOTO"])).standardizedFileURL
        let output = URL(fileURLWithPath: try #require(environment["GLOWROOM_REPAIR_PHOTO_OUTPUT"],
            "Set an explicit temporary directory for photograph diagnostics"), isDirectory: true).standardizedFileURL
        let resolvedOutput = output.resolvingSymlinksInPath().path
        let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let temporaryRoots = ["/private/tmp/", "/tmp/", "/" + temporaryRoot + "/"]
        #expect(temporaryRoots.contains { resolvedOutput.hasPrefix($0) }, "Photo derivatives must stay in temporary storage")
        guard temporaryRoots.contains(where: { resolvedOutput.hasPrefix($0) }) else { return }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let originalHash = try hash(sourceURL)
        defer {
            do { #expect(try hash(sourceURL) == originalHash, "The supplied original must remain byte-for-byte unchanged") }
            catch { Issue.record(error, "Could not verify the supplied original after the diagnostic") }
        }
        let values = try sourceURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let imageSource = try #require(CGImageSourceCreateWithURL(sourceURL as CFURL, nil))
        let identifier = try #require(CGImageSourceGetType(imageSource)) as String
        #expect(PreviewDecoder.isCameraRAWTypeIdentifier(identifier), "Supply the actual camera RAW, rather than an exported JPEG")
        guard PreviewDecoder.isCameraRAWTypeIdentifier(identifier) else { return }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let request = PreviewRequest(url: sourceURL, modifiedAt: values.contentModificationDate ?? .distantPast,
            pixelSize: 2_400, fileSize: Int64(values.fileSize ?? 0), allowsEmbeddedPreview: false)
        let pipeline = ImagePreviewPipeline(diskCache: nil)
        let decodeStart = ContinuousClock.now
        let source = try await pipeline.image(for: request, priority: .selected)
        let decodeMS = milliseconds(decodeStart.duration(to: .now))
        let reused = try await pipeline.image(for: request, priority: .selected)
        #expect(reused.image === source.image, "All selections must reuse the same decoded RAW basis")
        #expect(max(source.image.width, source.image.height) <= 2_400)
        try png(source.image, to: output.appendingPathComponent("before.png"))

        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: false)
        let analyzer = DevelopRepairAnalyzer()
        let before = try rgba(source.image)
        let extent = CGRect(x: 0, y: 0, width: source.image.width, height: source.image.height)
        var reports: [[String: Any]] = []
        for selection in try selections() {
            var choices: [(name: String, suffix: String, point: LocalMaskPoint, analysisMS: Double)] = []
            for alternative in 0..<3 {
                let analysisStart = ContinuousClock.now
                let donor = try await analyzer.source(for: source, path: selection.path, radius: selection.radius,
                    excluding: choices.map(\.point))
                choices.append((alternative == 0 ? "auto" : "alt\(alternative)",
                    alternative == 0 ? "" : "-alt\(alternative)", donor, milliseconds(analysisStart.duration(to: .now))))
            }
            choices.append(("manual", "-manual", selection.manualSource, 0))
            let target = try #require(selection.path.first)
            let crop = cropBounds(selection, width: source.image.width, height: source.image.height)
            try png(try #require(source.image.cropping(to: crop)),
                to: output.appendingPathComponent(selection.name + "-before-crop.png"))
            for choice in choices {
                for mode in [DevelopRetouchMode.heal, .clone] {
                    let stroke = try DevelopRetouchStroke(mode: mode, source: choice.point, target: target,
                        radius: selection.radius, feather: selection.feather, path: selection.path)
                    let coverage = try DevelopRetouchMaskRenderer.coverage(for: stroke, extent: extent)
                    let mask = try #require(session.context.createCGImage(coverage, from: extent,
                        format: .L8, colorSpace: CGColorSpaceCreateDeviceGray(), deferred: false))
                    let maskBytes = try gray(mask)
                    let start = ContinuousClock.now
                    let result = try EditRenderer.render(source,
                        settings: .init(developGeometry: .init(retouchStrokes: [stroke])), session: session)
                    let renderMS = milliseconds(start.duration(to: .now))
                    #expect(result.image.width == source.image.width && result.image.height == source.image.height)
                    let after = try rgba(result.image)
                    let comparison = compare(before: before, after: after, mask: maskBytes)
                    #expect(comparison.outsideMaximumDelta <= 1,
                        "Unselected pixels must survive the color-space roundtrip within one 8-bit level")
                    #expect(comparison.alphaChanges == 0, "Repair must preserve the source alpha")
                    #expect(comparison.selectedChangedPixels > 0, "The painted target must actually change")
                    let prefix = selection.name + "-" + mode.rawValue + choice.suffix
                    try png(result.image, to: output.appendingPathComponent(prefix + ".png"))
                    try png(try #require(result.image.cropping(to: crop)),
                        to: output.appendingPathComponent(prefix + "-crop.png"))
                    try png(mask, to: output.appendingPathComponent(prefix + "-mask.png"))
                    reports.append([
                        "selection": selection.name, "mode": mode.rawValue, "source_choice": choice.name,
                        "path": selection.path.map { ["x": $0.x, "y": $0.y] },
                        "radius_shorter_edge": selection.radius, "feather": selection.feather,
                        "source": ["x": choice.point.x, "y": choice.point.y], "analysis_ms": choice.analysisMS,
                        "render_ms": renderMS, "selected_changed_pixels": comparison.selectedChangedPixels,
                        "outside_mask_max_rgb_delta_8bit_srgb": comparison.outsideMaximumDelta,
                        "outside_mask_changed_pixels": comparison.outsideChangedPixels,
                        "alpha_changed_pixels": comparison.alphaChanges,
                        "selected_mean_rgb_delta_8bit_srgb": comparison.selectedMeanDelta,
                        "crop": ["x": crop.minX, "y": crop.minY, "width": crop.width, "height": crop.height]
                    ])
                }
            }
        }
        let report: [String: Any] = [
            "source_filename": sourceURL.lastPathComponent, "source_sha256": originalHash,
            "source_type": identifier, "width": source.image.width, "height": source.image.height,
            "profile": source.image.colorSpace?.name as String? ?? "unknown",
            "embedded_camera_preview_allowed": false, "cold_decode_ms": decodeMS,
            "cases": reports,
            "scope": "Local 2400 px RAW preview diagnostic using manually painted selections, three automatic production donors and one manually chosen donor per selection. PNG crops require visual review: changed target pixels alone do not prove convincing removal. Timings are process-local, exclude PNG writing and are not a general performance claim. Pixel comparisons use 8-bit sRGB with at most one level of conversion rounding outside the rendered mask."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"), options: .atomic)
        print("Local repair photo diagnostic: \(output.path); \(reports.count) renders; original SHA-256 \(originalHash)")
    }

    private struct Selection {
        let name: String
        let path: [LocalMaskPoint]
        let radius: Double
        let feather: Double
        let manualSource: LocalMaskPoint
    }

    /// Top-left normalized coordinates on the oriented IMG_8724.CR3 preview.
    private func selections() throws -> [Selection] {
        func branchPoint(_ x: Double, _ y: Double) throws -> LocalMaskPoint {
            try LocalMaskPoint(x: (554 + x) / 2_400, y: (1_059 + y) / 1_600)
        }
        return try [
            Selection(name: "berry-upper", path: [.init(x: 0.481, y: 0.1875)], radius: 0.024, feather: 0.25,
                manualSource: .init(x: 0.395, y: 0.1875)),
            Selection(name: "berry-lower", path: [.init(x: 0.361, y: 0.710)], radius: 0.024, feather: 0.25,
                manualSource: .init(x: 0.32, y: 0.64)),
            Selection(name: "spider-web", path: [
                .init(x: 0.300, y: 0.274), .init(x: 0.295, y: 0.320),
                .init(x: 0.290, y: 0.375), .init(x: 0.284, y: 0.430),
                .init(x: 0.2775, y: 0.490), .init(x: 0.271, y: 0.540)
            ], radius: 0.005, feather: 0.65, manualSource: .init(x: 0.288, y: 0.274)),
            Selection(name: "brown-branch", path: [
                branchPoint(69, 24), branchPoint(105, 103), branchPoint(41, 80),
                branchPoint(105, 103), branchPoint(119, 32), branchPoint(105, 103),
                branchPoint(140, 158), branchPoint(78, 173), branchPoint(140, 158), branchPoint(178, 200)
            ], radius: 0.010, feather: 0.4, manualSource: .init(x: 0.235, y: 0.677))
        ]
    }

    private func cropBounds(_ selection: Selection, width: Int, height: Int) -> CGRect {
        let margin = max(70, selection.radius * Double(min(width, height)) * 3)
        let xs = selection.path.map { $0.x * Double(width) }, ys = selection.path.map { $0.y * Double(height) }
        return CGRect(x: xs.min()! - margin, y: ys.min()! - margin,
            width: xs.max()! - xs.min()! + margin * 2, height: ys.max()! - ys.min()! + margin * 2)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }

    private struct Comparison {
        var outsideMaximumDelta = 0
        var outsideChangedPixels = 0
        var selectedChangedPixels = 0
        var alphaChanges = 0
        var selectedMeanDelta = 0.0
    }

    private func compare(before: [UInt8], after: [UInt8], mask: [UInt8]) -> Comparison {
        var result = Comparison(), selectedCount = 0
        var selectedDelta = 0
        for index in mask.indices {
            let offset = index * 4
            let red = abs(Int(after[offset]) - Int(before[offset]))
            let green = abs(Int(after[offset + 1]) - Int(before[offset + 1]))
            let blue = abs(Int(after[offset + 2]) - Int(before[offset + 2]))
            let maximum = max(red, green, blue)
            if mask[index] == 0 {
                result.outsideMaximumDelta = max(result.outsideMaximumDelta, maximum)
                if maximum > 0 { result.outsideChangedPixels += 1 }
            } else {
                selectedCount += 1
                selectedDelta += red + green + blue
                if maximum > 1 { result.selectedChangedPixels += 1 }
            }
            if before[offset + 3] != after[offset + 3] { result.alphaChanges += 1 }
        }
        result.selectedMeanDelta = Double(selectedDelta) / Double(max(1, selectedCount) * 3)
        return result
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
    }

    private func gray(_ image: CGImage) throws -> [UInt8] {
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        return (0..<image.height).flatMap { y in
            Array(UnsafeBufferPointer(start: bytes + y * image.bytesPerRow, count: image.width))
        }
    }

    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    private func milliseconds(_ value: Duration) -> Double {
        Double(value.components.seconds) * 1_000 + Double(value.components.attoseconds) / 1_000_000_000_000_000
    }

    private func png(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
