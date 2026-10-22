import CoreGraphics
import CoreImage
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import ImageIO
import GlowroomCore
import Testing
import UniformTypeIdentifiers
import Vision
@testable import Glowroom

/// Opt-in visual comparison; never check private photographs or derivatives in.
/// Native measurements run serially so competing Vision/CI work cannot distort them.
@Suite("Automatic masks on an explicitly supplied RAW", .serialized)
struct AutomaticMaskQualityTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_MASK_QUALITY_IMAGE"]?.isEmpty == false))
    func compareLegacyAndCurrentBackgroundMask() async throws {
        let environment = ProcessInfo.processInfo.environment
        let sourceURL = URL(fileURLWithPath: try #require(environment["GLOWROOM_MASK_QUALITY_IMAGE"]))
        let packagePath = try #require(environment["GLOWROOM_SUBJECT_MATTING_PACKAGE"].flatMap { $0.isEmpty ? nil : $0 },
            "Set GLOWROOM_SUBJECT_MATTING_PACKAGE to the approved BiRefNet 1920 package; production has no Vision fallback")
        let explicitInstallRoot = environment["GLOWROOM_SUBJECT_MATTING_INSTALL_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
        let repeatsCurrent = environment["GLOWROOM_MASK_QUALITY_REPEAT_CURRENT"] == "1"
        let output = URL(fileURLWithPath: try #require(environment["GLOWROOM_MASK_QUALITY_OUTPUT"],
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
        // Use isolated stores by default: a developer's installed model must
        // never silently change the baseline or be removed by this diagnostic.
        let temporaryStores = URL(fileURLWithPath: "/private/tmp/glowroom-mask-quality-stores-\(UUID().uuidString)",
                                  isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryStores, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryStores) }
        let installRoot = explicitInstallRoot.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? temporaryStores.appendingPathComponent("subject", isDirectory: true)
        // Explicit roots opt into a persistent installer commit; only our UUID
        // scratch directory is removed by defer, never the requested root.
        let budget = AIResourceBudget()
        let subjectStore = SubjectMattingModelStore(directory: installRoot, budget: budget)
        let worker = AutomaticMaskWorker(
            skyModelStore: SkyMaskModelStore(directory: temporaryStores.appendingPathComponent("sky"), budget: budget),
            subjectModelStore: subjectStore, cachesSubjectResults: false)
        let service = AutomaticMaskService(budget: budget, generator: { bitmap, kind, url in
            try await worker.generate(bitmap, kind: kind, sourceURL: url)
        })
        let installationReport: [String: Any]
        do {
            let installStart = ContinuousClock.now
            let installed = try await subjectStore.install(from: URL(fileURLWithPath: packagePath, isDirectory: true))
            let installationMS = milliseconds(installStart.duration(to: .now))
            _ = try SubjectMattingModelStore.verifyInstallation(installed)
            let receiptData = try Data(contentsOf: installed.directory.appendingPathComponent("installation.json"))
            let receipt = try #require(JSONSerialization.jsonObject(with: receiptData) as? [String: Any])
            installationReport = [
                "backend": "BiRefNet-HR-matting", "contract": SubjectMattingModelInterface.contract,
                "source_revision": SubjectMattingModelInterface.sourceRevision,
                "weights_sha256": SubjectMattingModelInterface.weightsSHA256,
                "installation_receipt_sha256": installed.receiptSHA256,
                "installation_ms": installationMS,
                "source_files": receipt["sourceFiles"] ?? [],
                "installation_preserved": explicitInstallRoot != nil
            ]
        }
        let originalHash = try hash(sourceURL)
        let values = try sourceURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let request = PreviewRequest(url: sourceURL, modifiedAt: values.contentModificationDate ?? .distantPast,
            pixelSize: 2_048, fileSize: Int64(values.fileSize ?? 0), allowsEmbeddedPreview: false)
        let decodeStart = ContinuousClock.now
        let source = try await Task.detached { try PreviewDecoder.decode(request) }.value
        let decodeMS = milliseconds(decodeStart.duration(to: .now))
        #expect(max(source.image.width, source.image.height) <= 2_048)
        let regions = qualityRegions()
        func save(_ image: CGImage, _ name: String) throws {
            try png(image, at: output.appendingPathComponent("\(name).png"))
            for region in regions {
                let bounds = region.pixelBounds(width: image.width, height: image.height)
                let crop = try #require(image.cropping(to: bounds))
                try png(crop, at: output.appendingPathComponent("\(name)-roi-\(region.name).png"))
            }
        }
        try save(source.image, "source")

        let legacyStart = ContinuousClock.now
        let legacy = try legacySubject(source.image)
        let legacyMS = milliseconds(legacyStart.duration(to: .now))
        // Keep the pre-matting Vision path independently visible, even when the
        // production worker selects another installed model. These stages run
        // serially so their native inference and memory measurements do not race.
        let visionStart = ContinuousClock.now
        let visionResult = try visionSubject(source.image, maximumDimension: 2_048)
        let vision = visionResult.raster
        let visionMS = milliseconds(visionStart.duration(to: .now))
        let guidedStart = ContinuousClock.now
        let guided = try AutomaticMaskRefiner.refine(vision, guide: visionResult.proxy)
        let guidedMS = milliseconds(guidedStart.duration(to: .now))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.generate(source, kind: .subject, sourceURL: sourceURL)
        }
        var preCancelledRequestRejected = false
        do {
            _ = try await cancelled.value
            Issue.record("An already cancelled request must not publish a subject mask")
        } catch is CancellationError { preCancelledRequestRejected = true }
        #expect(await admittedWorkHasFinished(budget))
        let currentStart = ContinuousClock.now
        let current = try await service.generate(source, kind: .subject, sourceURL: sourceURL)
        let currentMS = milliseconds(currentStart.duration(to: .now))
        var repeatedCurrent: LocalMaskRaster?
        var repeatedCurrentMS: Double?
        var repeatDifference: [String: Any] = [:]
        if repeatsCurrent {
            let repeatStart = ContinuousClock.now
            let repeated = try await service.generate(source, kind: .subject, sourceURL: sourceURL)
            repeatedCurrentMS = milliseconds(repeatStart.duration(to: .now))
            repeatedCurrent = repeated
            #expect(repeated.width == current.width && repeated.height == current.height)
            if repeated.width == current.width && repeated.height == current.height {
                let differences = zip(current.bytes, repeated.bytes).reduce(into: (maximum: 0, total: 0)) { result, pair in
                    let delta = abs(Int(pair.0) - Int(pair.1))
                    result.maximum = max(result.maximum, delta)
                    result.total += delta
                }
                repeatDifference = ["maximum_gray8_delta": differences.maximum,
                                    "mean_gray8_delta": Double(differences.total) / Double(current.bytes.count)]
                #expect(differences.maximum == 0, "Repeated inference on this device must preserve the saved Gray8 selection")
            }
        }
        #expect(await admittedWorkHasFinished(budget))
        let extent = CGRect(x: 0, y: 0, width: source.image.width, height: source.image.height)
        let colorSpace = source.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let session = EditRenderer.Session(cacheIntermediates: false, lowPriority: false)
        let context = session.context
        try save(grayImage(legacy), "legacy-subject-mask")
        try save(grayImage(vision), "raw-vision-subject-mask")
        try save(grayImage(guided), "vision-guided-subject-mask")
        try save(grayImage(current), "current-subject-mask")
        if let repeatedCurrent { try save(grayImage(repeatedCurrent), "current-repeat-subject-mask") }

        // Freeze the previous broad Gaussian edge explicitly: the production
        // renderer's automatic-mask feather policy may change independently.
        let legacyCoverage = CIImage(cgImage: try grayImage(legacy), options: [.colorSpace: NSNull()])
            .clampedToExtent().transformed(by: .init(scaleX: extent.width / CGFloat(legacy.width),
                                                     y: extent.height / CGFloat(legacy.height)))
            .cropped(to: extent).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.025 * min(extent.width, extent.height) * 0.5])
            .cropped(to: extent).applyingFilter("CIColorInvert")
        try save(materialize(legacyCoverage, context: context, extent: extent, colorSpace: colorSpace),
                 "legacy-background-coverage")
        // Match the screenshot's exposure-only stress case, then also inspect
        // a less extreme adjustment without introducing a contrast variable.
        let correction = LocalAdjustmentSettings(exposure: -5, contrast: 0)
        let moderateCorrection = LocalAdjustmentSettings(exposure: -2, contrast: 0)
        var renderCorrections: [String: [String: Double]] = [:]
        func recordCorrection(_ basename: String, settings: LocalAdjustmentSettings, feather: Double) {
            let values = ["exposure": settings.exposure, "contrast": settings.contrast, "feather": feather]
            renderCorrections["\(basename).png"] = values
            for region in regions { renderCorrections["\(basename)-roi-\(region.name).png"] = values }
        }
        let legacyRenderStart = ContinuousClock.now
        let base = CIImage(cgImage: source.image)
        let candidate = try EditRenderer.manualAdjustments(base, settings: correction.editSettings,
            extent: extent, scale: max(0.25, Double(max(source.image.width, source.image.height)) / 1_600))
        let before = candidate.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: legacyCoverage
        ])
        let legacyRendered = try materialize(before, context: context, extent: extent, colorSpace: colorSpace)
        let legacyRenderMS = milliseconds(legacyRenderStart.duration(to: .now))
        try save(legacyRendered, "legacy-background-darkened")
        recordCorrection("legacy-background-darkened", settings: correction, feather: 0.5)

        var renderMS: [String: Double] = [:]
        var comparisons = [("raw-vision", vision), ("vision-guided", guided), ("current", current)]
        if let repeatedCurrent { comparisons.append(("current-repeat", repeatedCurrent)) }
        for (name, raster) in comparisons {
            for feather in name == "current" ? [0.0, 0.5] : [0.0] {
                let suffix = feather == 0 ? "default" : "feather-0.5"
                let mask = try LocalAdjustmentMask(shape: .subject(raster), isInverted: true, feather: feather)
                var edits = EditSettings.neutral
                edits.localAdjustments = [try .init(name: "Background quality probe", mask: mask, settings: correction)]
                let start = ContinuousClock.now
                let rendered = try EditRenderer.render(source, settings: edits, session: session)
                renderMS["\(name)-\(suffix)"] = milliseconds(start.duration(to: .now))
                #expect(rendered.image.width == source.image.width && rendered.image.height == source.image.height)
                let basename = "\(name)-background-darkened-\(suffix)"
                try save(rendered.image, basename)
                recordCorrection(basename, settings: correction, feather: feather)
                let coverage = try LocalAdjustmentRenderer.maskImage(mask, extent: extent)
                try save(materialize(coverage, context: context, extent: extent, colorSpace: colorSpace),
                         "\(name)-background-coverage-\(suffix)")
            }
            if name == "vision-guided" || name == "current" {
                let mask = try LocalAdjustmentMask(shape: .subject(raster), isInverted: true, feather: 0)
                var edits = EditSettings.neutral
                edits.localAdjustments = [try .init(name: "Background quality probe", mask: mask, settings: moderateCorrection)]
                let start = ContinuousClock.now
                let rendered = try EditRenderer.render(source, settings: edits, session: session)
                renderMS["\(name)-exposure-minus-2"] = milliseconds(start.duration(to: .now))
                let basename = "\(name)-background-darkened-exposure-minus-2"
                try save(rendered.image, basename)
                recordCorrection(basename, settings: moderateCorrection, feather: 0)
            }
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
            "raw_vision_mask_width": vision.width, "raw_vision_mask_height": vision.height,
            "current_mask_width": current.width, "current_mask_height": current.height,
            "legacy_generation_ms": legacyMS, "current_generation_ms": currentMS,
            "current_backend": installationReport,
            "current_pre_cancelled_request_rejected": preCancelledRequestRejected,
            "current_repeat_generation_ms": repeatedCurrentMS.map { $0 as Any } ?? NSNull(),
            "current_repeat_difference": repeatDifference,
            "raw_vision_generation_ms": visionMS, "vision_guided_refinement_ms": guidedMS,
            "generation_order": ["legacy-vision-1024", "raw-vision-2048", "vision-guided-refinement", "current-production"]
                + (repeatsCurrent ? ["current-production-repeat"] : []),
            "legacy_render_ms": legacyRenderMS, "render_ms": renderMS,
            "render_corrections_by_filename": renderCorrections,
            "roi_coordinate_convention": "Top-left normalized coordinates on the oriented source; crops retain native pixels and are not enlarged.",
            "regions": regions.map { ["name": $0.name, "x": $0.bounds.minX, "y": $0.bounds.minY,
                                        "width": $0.bounds.width, "height": $0.bounds.height] as [String: Any] },
            "exposure": correction.exposure, "contrast": correction.contrast,
            "legacy_feather": 0.5, "current_default_feather": 0, "process_peak_rss_bytes": peakRSS,
            "scope": "One supplied RAW at 2048 px; no ground-truth matte and no objective Lightroom parity score. Legacy reproduces Vision revision 1 at 1024 px, a bilinear 512 px mask and the former broad Gaussian feather. Raw Vision revision 1 at 2048 px and that matte with RGB guided refinement are separate pre-matting baselines. Current uses the reported backend and an explicitly selected or isolated model store, through the normal AI admission service. Timings exclude PNG writes; stages follow generation_order. OS, Vision and GPU caches are not flushed; installation itself loads the model for validation before the first inference. Optional first/repeat inference measurements are not cold-cache versus resident-warm-weight timings: production releases model weights after each request. RSS covers the whole test process including installation. The fixed crops target fine right-edge needles and interior background gaps in IMG_8724.CR3, not labeled quantitative ground truth."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"), options: .atomic)
        print("Automatic mask quality diagnostic: \(output.path); legacy \(legacyMS) ms, current \(currentMS) ms; peak RSS \(peakRSS) bytes")
    }

    /// Deliberately independent of production size defaults to retain a stable baseline.
    private func legacySubject(_ image: CGImage) throws -> LocalMaskRaster {
        try visionSubject(image, maximumDimension: 1_024, legacyDownsample: true).raster
    }

    private func visionSubject(_ image: CGImage, maximumDimension: Int,
                               legacyDownsample: Bool = false) throws -> (raster: LocalMaskRaster, proxy: CGImage) {
        let scale = min(1, Double(maximumDimension) / Double(max(image.width, image.height)))
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
        let proxy = try #require(context.makeImage())
        let handler = VNImageRequestHandler(cgImage: proxy, orientation: .up, options: [:])
        try handler.perform([request])
        let observation = try #require(request.results?.first)
        #expect(!observation.allInstances.isEmpty)
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        let raster = try legacyDownsample ? legacyRaster(buffer) : AutomaticMaskRasterConverter.raster(buffer)
        return (raster, proxy)
    }

    private struct QualityRegion {
        let name: String
        let bounds: CGRect

        func pixelBounds(width: Int, height: Int) -> CGRect {
            // CGImage crops use top-left image pixel coordinates. No CI y flip
            // is needed here; the full images have already been materialized.
            CGRect(x: bounds.minX * Double(width), y: bounds.minY * Double(height),
                   width: bounds.width * Double(width), height: bounds.height * Double(height))
                .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func qualityRegions() -> [QualityRegion] {
        [QualityRegion(name: "right-needles", bounds: CGRect(x: 0.52, y: 0.08, width: 0.14, height: 0.42)),
         QualityRegion(name: "interior-gaps", bounds: CGRect(x: 0.34, y: 0.12, width: 0.15, height: 0.36))]
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

    private func admittedWorkHasFinished(_ budget: AIResourceBudget) async -> Bool {
        for await state in await budget.stateUpdates() {
            return state.activeInferences == 0 && state.waitingInferences == 0 && state.residentModelBytes == 0
        }
        return false
    }
}
