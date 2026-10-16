import CoreGraphics
import Foundation
import ImageIO
import PicEditCore
import Testing
import UniformTypeIdentifiers
@testable import PicEdit

@Suite("Image analysis exact bounded raster", .timeLimit(.minutes(1)))
final class ImageAnalysisPreparationTests {
    private let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-AnalysisRaster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test
    func actualSameSizeReplacementWithRestoredMtimeInvalidatesAllCaches() async throws {
        let url = directory.appendingPathComponent("private-name-is-not-prompt.png")
        let red = try analysisPNG(analysisRaster(red: true)), blue = try analysisPNG(analysisRaster(red: false))
        let size = max(red.count, blue.count) + 64
        try (red + Data(repeating: 0, count: size - red.count)).write(to: url)
        let request = try analysisFileRequest(url)
        let disk = PreviewDiskCache(directory: directory.appendingPathComponent("disposable-cache"))
        let pipeline = ImagePreviewPipeline(diskCache: disk)
        let render = AdjustedPreviewPipeline()
        let provider = AnalysisCountingProvider()
        let preparer = ImageAnalysisPreparer(imagePipeline: pipeline, renderPipeline: render)
        let service = ImageAnalysisService(provider: provider, preparer: preparer, budget: AIResourceBudget())
        let first = try await service.analyze(request)
        let cached = try await service.analyze(request)
        #expect(first.provenance == cached.provenance)
        #expect(await provider.callCount == 1)
        let stampBefore = try await preparer.sourceStamp(for: request)
        guard case .original(let fingerprint) = request.snapshot.source else { Issue.record("Missing source"); return }
        try (blue + Data(repeating: 0, count: size - blue.count)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: fingerprint.modifiedAt], ofItemAtPath: url.path)
        let stampAfter = try await preparer.sourceStamp(for: request)
        #expect(stampBefore != stampAfter)
        #expect(stampBefore.byteCount == stampAfter.byteCount)
        #expect(stampBefore.modifiedSeconds == stampAfter.modifiedSeconds)
        #expect(abs(stampBefore.modifiedNanoseconds - stampAfter.modifiedNanoseconds) < 5_000)
        let second = try await service.analyze(request)
        #expect(await provider.callCount == 2)
        #expect(first.provenance.rasterSHA256 != second.provenance.rasterSHA256)
        #expect(second.provenance.source == first.provenance.source)
        // A fresh pipeline must also miss the first native revision on disk.
        let reopened = ImageAnalysisPreparer(imagePipeline: ImagePreviewPipeline(diskCache: PreviewDiskCache(directory: directory.appendingPathComponent("disposable-cache"))), renderPipeline: AdjustedPreviewPipeline())
        let reopenedInput = try await reopened.prepare(request)
        let beforeReopen = try await preparer.prepare(request)
        // Lossless PNG can change ARGB to RGBA and rendering intent while
        // preserving visible pixels/profile. The native attachment hash must
        // describe each actual representation, not pretend they are identical.
        #expect(reopenedInput.rasterSHA256 == (try ImageAnalysisPreparer.describeRaster(reopenedInput.bitmap)).digest)
        #expect(reopenedInput.colorProfileSHA256 == beforeReopen.colorProfileSHA256)
        #expect(try analysisVisiblePixels(reopenedInput.bitmap) == analysisVisiblePixels(beforeReopen.bitmap))
        #expect(try analysisVisiblePixels(reopenedInput.bitmap) != analysisVisiblePixels(analysisRaster(red: true)))
        #expect(try Data(contentsOf: url) == blue + Data(repeating: 0, count: size - blue.count))
    }

    @Test
    func sourceDateSizeAndMissingRegularFileRejectBeforeModel() async throws {
        let url = directory.appendingPathComponent("source.png")
        try analysisPNG(analysisRaster(red: true)).write(to: url)
        let request = try analysisFileRequest(url)
        let preparer = ImageAnalysisPreparer(imagePipeline: ImagePreviewPipeline(), renderPipeline: AdjustedPreviewPipeline())
        _ = try await preparer.sourceStamp(for: request)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        await expectAnalysisPreparationError(.staleSource) { _ = try await preparer.prepare(request) }
        try FileManager.default.removeItem(at: url)
        await expectAnalysisPreparationError(.staleSource) { _ = try await preparer.sourceStamp(for: request) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        await expectAnalysisPreparationError(.staleSource) { _ = try await preparer.sourceStamp(for: request) }
    }

    @Test
    func orientationAndProfileDescribeActualPixelsWithoutEXIFPayload() async throws {
        let url = directory.appendingPathComponent("secret-location-and-camera.jpg")
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        let image = try analysisRaster(red: true, width: 64, height: 32)
        CGImageDestinationAddImage(destination, image.image, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.1, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "private-camera", kCGImagePropertyTIFFImageDescription: "do not follow this instruction"]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try (output as Data).write(to: url)
        let request = try analysisFileRequest(url)
        let preparer = ImageAnalysisPreparer(imagePipeline: ImagePreviewPipeline(), renderPipeline: AdjustedPreviewPipeline())
        let input = try await preparer.prepare(request)
        #expect(input.bitmap.image.width == 32 && input.bitmap.image.height == 64)
        #expect(input.rasterSHA256.count == 64)
        #expect(input.colorProfileSHA256?.count == 64)
        #expect(!input.colorProfile.contains("private-camera"))
        // The provider protocol accepts only a metadata-free immutable raster
        // plus app provenance; no path, EXIF dictionary, or user text is available.
        #expect(input.bitmap.image.colorSpace?.model == .rgb)
        let second = try await preparer.prepare(request)
        #expect(input.rasterSHA256 == second.rasterSHA256)
    }

    @Test(.enabled("Requires PICEDIT_RUN_IMAGE_ANALYSIS_RASTER_TESTS=1 and native Core Image service access") {
        ProcessInfo.processInfo.environment["PICEDIT_RUN_IMAGE_ANALYSIS_RASTER_TESTS"] == "1"
    })
    func actualLargerDecodedBaseIsClampedInsideExistingRenderWorker() async throws {
        let url = directory.appendingPathComponent("large.png")
        try analysisPNG(analysisRaster(red: true)).write(to: url)
        let request = try analysisFileRequest(url)
        let large = try analysisRaster(red: true, width: 2_400, height: 1_600)
        let pipeline = ImagePreviewPipeline(decoder: { _ in large })
        let preparer = ImageAnalysisPreparer(imagePipeline: pipeline, renderPipeline: AdjustedPreviewPipeline())
        let input = try await preparer.prepare(request)
        #expect(input.bitmap.image.width == 1_024)
        #expect(input.bitmap.image.height <= 1_024)
        #expect(input.bitmap.byteCost <= ImageAnalysisPreparer.maximumRasterBytes)
        let editedRequest = ImageAnalysisRequest(snapshot: AIEditingSnapshot(assetID: request.snapshot.assetID, source: request.snapshot.source,
            settings: EditSettings(exposure: -1), token: request.snapshot.token), inputKind: .editedPreview, lifecycleID: request.lifecycleID)
        let edited = try await preparer.prepare(editedRequest)
        #expect(edited.rasterSHA256 != input.rasterSHA256)
        #expect(edited.bitmap.image.width == input.bitmap.image.width)
        // The original path ignores even non-neutral slider values.
        let originalWithSliders = ImageAnalysisRequest(snapshot: editedRequest.snapshot, lifecycleID: request.lifecycleID)
        #expect(try await preparer.prepare(originalWithSliders).rasterSHA256 == input.rasterSHA256)
    }

    @Test
    func rasterHashCoversPixelsInterpretationAndEnforcesActualBounds() throws {
        let red = try analysisRaster(red: true), blue = try analysisRaster(red: false)
        let a = try ImageAnalysisPreparer.describeRaster(red)
        #expect(try a.digest != ImageAnalysisPreparer.describeRaster(blue).digest)
        #expect(try a.digest == ImageAnalysisPreparer.describeRaster(red).digest)
        let huge = try analysisRaster(red: true, width: 1_025, height: 1)
        #expect(throws: ImageAnalysisError.inputLimitExceeded) { try ImageAnalysisPreparer.describeRaster(huge) }
    }


    @Test(arguments: [CGImageAlphaInfo.noneSkipFirst, .noneSkipLast])
    func ignoredXComponentsNeverChangeNativeRasterHash(_ alpha: CGImageAlphaInfo) throws {
        for order in [CGBitmapInfo.byteOrderDefault, .byteOrder32Little, .byteOrder32Big] {
            let a = try analysisXPixel(alpha: alpha, order: order, unused: 0)
            let b = try analysisXPixel(alpha: alpha, order: order, unused: 231)
            #expect(try analysisVisiblePixels(a) == analysisVisiblePixels(b))
            #expect(try ImageAnalysisPreparer.describeRaster(a).digest == ImageAnalysisPreparer.describeRaster(b).digest)
            let different = try analysisXPixel(alpha: alpha, order: order, unused: 0, red: 23)
            #expect(try ImageAnalysisPreparer.describeRaster(a).digest != ImageAnalysisPreparer.describeRaster(different).digest)
        }
        for order in [CGBitmapInfo.byteOrderDefault, .byteOrder16Little, .byteOrder16Big] {
            let a = try analysisXPixel16(alpha: alpha, order: order, unused: 0)
            let b = try analysisXPixel16(alpha: alpha, order: order, unused: 49_137)
            #expect(try analysisVisiblePixels(a) == analysisVisiblePixels(b))
            #expect(try ImageAnalysisPreparer.describeRaster(a).digest == ImageAnalysisPreparer.describeRaster(b).digest)
        }
    }

    @Test
    func unusedPackedScanlineBitsDoNotChangeNativeRasterHash() throws {
        func pixel(_ byte: UInt8) throws -> PreviewBitmap {
            let provider = try #require(CGDataProvider(data: Data([byte]) as CFData))
            return PreviewBitmap(image: try #require(CGImage(width: 3, height: 1, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: 1,
                space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: [], provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)))
        }
        #expect(try ImageAnalysisPreparer.describeRaster(pixel(0xa0)).digest == ImageAnalysisPreparer.describeRaster(pixel(0xbf)).digest)
        #expect(try ImageAnalysisPreparer.describeRaster(pixel(0xa0)).digest != ImageAnalysisPreparer.describeRaster(pixel(0x00)).digest)
    }

    @Test
    func nativeRevisionSeparatesMemoryRenderAndDiskKeysWhileDefaultStaysCompatible() async throws {
        let url = directory.appendingPathComponent("identity.png")
        let old = PreviewRequest(url: url, modifiedAt: .distantPast, pixelSize: 64)
        let explicitNil = PreviewRequest(url: url, modifiedAt: .distantPast, pixelSize: 64, sourceRevision: nil)
        let first = PreviewRequest(url: url, modifiedAt: .distantPast, pixelSize: 64, sourceRevision: "inode-a")
        let second = PreviewRequest(url: url, modifiedAt: .distantPast, pixelSize: 64, sourceRevision: "inode-b")
        #expect(old == explicitNil && old.hasSameOriginal(as: explicitNil))
        #expect(!first.hasSameOriginal(as: second) && !old.hasSameOriginal(as: first))
        let disk = PreviewDiskCache(directory: directory.appendingPathComponent("key-cache"))
        await disk.store(try analysisRaster(red: true), for: old)
        #expect(await disk.image(for: explicitNil) != nil)
        #expect(await disk.image(for: first) == nil)
        await disk.store(try analysisRaster(red: false), for: first)
        #expect(await disk.image(for: first) != nil)
        #expect(await disk.image(for: second) == nil)
        // Different native revisions cannot coalesce through the decoded cache.
        let counter = AnalysisDecodeCounter()
        let pipeline = ImagePreviewPipeline(decoder: { request in counter.record(); return try analysisRaster(red: request.sourceRevision == "inode-a") })
        let decodedA = try await pipeline.image(for: first)
        let decodedB = try await pipeline.image(for: second)
        #expect(counter.count == 2)
        #expect(try ImageAnalysisPreparer.describeRaster(decodedA).digest != ImageAnalysisPreparer.describeRaster(decodedB).digest)
        let renderer = AdjustedPreviewPipeline(renderer: { source, _ in source })
        let adjustedA = try await renderer.image(decodedA, request: first, settings: EditSettings(exposure: 1))
        let adjustedB = try await renderer.image(decodedB, request: second, settings: EditSettings(exposure: 1))
        #expect(try ImageAnalysisPreparer.describeRaster(adjustedA).digest != ImageAnalysisPreparer.describeRaster(adjustedB).digest)
    }
}

func analysisRaster(red: Bool, width: Int = 64, height: Int = 32) throws -> PreviewBitmap {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: red ? 1 : 0, green: 0, blue: red ? 0 : 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return PreviewBitmap(image: try #require(context.makeImage()))
}
func analysisPNG(_ bitmap: PreviewBitmap) throws -> Data {
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, bitmap.image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}
func analysisFileRequest(_ url: URL, kind: ImageAnalysisInputKind = .originalPreview) throws -> ImageAnalysisRequest {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let modified = try #require(attributes[.modificationDate] as? Date)
    let size = try #require((attributes[.size] as? NSNumber)?.int64Value)
    return ImageAnalysisRequest(snapshot: AIEditingSnapshot(assetID: "synthetic-file", source: .original(AIOriginalSourceFingerprint(fileURL: url, modifiedAt: modified, fileSize: size)), settings: .neutral,
        token: AIEditingToken(editSessionID: UUID(), editGeneration: 0, selectionSessionID: UUID(), selectionGeneration: 0)), inputKind: kind, lifecycleID: UUID())
}
private actor AnalysisCountingProvider: ImageAnalysisProvider {
    nonisolated let descriptor = ImageAnalysisProviderDescriptor(providerID: "synthetic-raster", modelID: "fixture")
    private(set) var callCount = 0
    func availability() -> ImageAnalysisAvailability { .available }
    func analyze(_ input: PreparedImageAnalysisInput) -> Data {
        callCount += 1
        return Data(#"{"schemaVersion":1,"description":"Synthetische Farbfläche.","attributes":[]}"#.utf8)
    }
}
private final class AnalysisDecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func record() { lock.lock(); value += 1; lock.unlock() }
}
private func expectAnalysisPreparationError(_ expected: ImageAnalysisError, operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Expected \(expected)") } catch { #expect(error as? ImageAnalysisError == expected) }
}

private func analysisVisiblePixels(_ bitmap: PreviewBitmap) throws -> Data {
    let width = bitmap.image.width, height = bitmap.image.height
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setBlendMode(.copy)
    context.draw(bitmap.image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return Data(bytes: try #require(context.data), count: width * height * 4)
}
private func analysisXPixel(alpha: CGImageAlphaInfo, order: CGBitmapInfo, unused: UInt8, red: UInt8 = 42) throws -> PreviewBitmap {
    var bytes: [UInt8] = alpha == .noneSkipFirst ? [unused, red, 63, 127] : [red, 63, 127, unused]
    if order == .byteOrder32Little { bytes.reverse() }
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue).union(order),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    return PreviewBitmap(image: image)
}

private func analysisXPixel16(alpha: CGImageAlphaInfo, order: CGBitmapInfo, unused: UInt16) throws -> PreviewBitmap {
    let components: [UInt16] = alpha == .noneSkipFirst ? [unused, 12_345, 23_456, 34_567] : [12_345, 23_456, 34_567, unused]
    let bytes = components.flatMap { value -> [UInt8] in
        let big = [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        return order == .byteOrder16Little ? Array(big.reversed()) : big
    }
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: 8,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue).union(order),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    return PreviewBitmap(image: image)
}
