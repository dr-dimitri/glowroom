import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Local subject matting coverage")
struct SubjectMattingInferenceTests {
    @Test func cacheSharesOneImmutableImageAndInvalidatesForAnotherImageOrModel() throws {
        func image() throws -> CGImage {
            try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: CGDataProvider(data: Data([50, 100, 150, 255]) as CFData)!,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        }
        let first = try image(), second = try image()
        let raster = try LocalMaskRaster(width: 1, height: 1, bytes: Data([128]))
        var cache = SubjectMattingResultCache()
        cache.store(raster, for: PreviewBitmap(image: first), modelID: "first-model")
        #expect(cache.value(for: first, modelID: "first-model") == raster)
        #expect(cache.value(for: second, modelID: "first-model") == nil)
        #expect(cache.value(for: first, modelID: "replacement-model") == nil)
        cache.store(raster, for: PreviewBitmap(image: second), modelID: "first-model")
        #expect(cache.value(for: first, modelID: "first-model") == nil)
        cache.clear()
        #expect(cache.value(for: second, modelID: "first-model") == nil)
    }

    @Test func approvedPackagePinsGraphWeightsAndManifestBeforeCompilation() throws {
        let files = try SubjectMattingModelInterface.approvedFiles()
        #expect(files.count == 3)
        #expect(files.reduce(Int64(0)) { $0 + $1.bytes } == 477_196_412)
        try SubjectMattingModelInterface.validateApprovedFiles(files)
        #expect(throws: SubjectMattingError.invalidModel) {
            try SubjectMattingModelInterface.validateApprovedFiles(Array(files.dropLast()))
        }
        let forged = files.map { SemanticManifestFile(path: $0.path, bytes: $0.bytes,
            sha256: String(repeating: "0", count: 64)) }
        #expect(throws: SubjectMattingError.invalidModel) {
            try SubjectMattingModelInterface.validateApprovedFiles(forged)
        }
        let legacy = try SubjectMattingModelInterface.legacyFiles()
        #expect(Set(files) != Set(legacy))
        #expect(throws: SubjectMattingError.invalidModel) {
            try SubjectMattingModelInterface.validateApprovedFiles(legacy)
        }
    }

    @Test func productionInputUses1920PixelsAndRejectsLegacy2048Output() throws {
        let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data([255, 0, 0, 255]) as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = try SubjectMattingInference.inputBuffer(image)
        #expect(CVPixelBufferGetWidth(input) == 1_920)
        #expect(CVPixelBufferGetHeight(input) == 1_920)
        let legacy = try MLMultiArray(shape: [1, 1, 2_048, 2_048], dataType: .float32)
        #expect(throws: SubjectMattingError.invalidModel) {
            try SubjectMattingInference.raster(legacy, outputSize: (1, 1))
        }
    }

    @Test func native1920CoverageRetainsThe2048SavedRasterBudget() throws {
        let side = SubjectMattingModelInterface.side
        let values = try MLMultiArray(shape: [1, 1, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        values.dataPointer.assumingMemoryBound(to: Float.self).initialize(repeating: 0.5, count: side * side)
        let output = AutomaticMaskRasterConverter.outputSize(width: 6_000, height: 4_000)
        let raster = try SubjectMattingInference.raster(values, outputSize: output)
        #expect(raster.width == 2_048 && raster.height == 1_365)
        #expect(raster.bytes.count == 2_048 * 1_365)
        #expect(raster.bytes.allSatisfy { $0 == 128 })
    }

    @Test func fractionalCoverageRetainsRowsAndRestoresNonSquareAspect() throws {
        let values = try MLMultiArray(shape: [1, 1, 2, 2], dataType: .float32)
        for (i, value) in [0.0, 0.5, 1.0, 0.25].enumerated() { values[i] = NSNumber(value: value) }
        let raster = try SubjectMattingInference.raster(values, side: 2, outputSize: (4, 2))
        #expect(raster.bytes == Data([0, 32, 96, 128, 255, 207, 112, 64]))
        #expect(raster.width == 4 && raster.height == 2)
        let background = raster.bytes.map { 255 - $0 }
        #expect(zip(raster.bytes, background).allSatisfy { Int($0) + Int($1) == 255 })
    }

    @Test func paddedNativeOutputIgnoresPaddingAndClampsCoverage() throws {
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        storage.initialize(repeating: .nan, count: 8)
        storage[0] = -0.1; storage[1] = 0.5; storage[4] = 1.1; storage[5] = 0.25
        let values = try MLMultiArray(dataPointer: storage, shape: [1, 1, 2, 2], dataType: .float32,
            strides: [8, 8, 4, 1], deallocator: { $0.assumingMemoryBound(to: Float.self).deallocate() })
        let raster = try SubjectMattingInference.raster(values, side: 2, outputSize: (2, 2))
        #expect(raster.bytes == Data([0, 128, 255, 64]))
    }

    @Test func nonFinitePixelsCannotDisappearThroughDownsampling() throws {
        let values = try MLMultiArray(shape: [1, 1, 4, 4], dataType: .float32)
        for i in 0..<16 { values[i] = 0.5 }
        values[0] = NSNumber(value: Float.infinity)
        #expect(throws: SubjectMattingError.invalidModel) {
            try SubjectMattingInference.raster(values, side: 4, outputSize: (1, 1))
        }
        let wrongType = try MLMultiArray(shape: [1, 1, 2, 2], dataType: .double)
        #expect(throws: SubjectMattingError.invalidModel) {
            try SubjectMattingInference.raster(wrongType, side: 2, outputSize: (2, 2))
        }
        #expect(throws: SubjectMattingError.invalidModel) {
            try SubjectMattingInference.raster(values, side: 4, outputSize: (0, 1))
        }
    }

    @Test func inputKeepsWholeOrientedImageInSRGBAndDefinesTransparentBacking() throws {
        let bytes = Data([255, 0, 0, 255, 0, 255, 0, 255,
                          0, 0, 255, 255, 0, 0, 0, 0])
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let buffer = try SubjectMattingInference.inputBuffer(image, side: 2)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        #expect(Array(UnsafeBufferPointer(start: base, count: 3)) == [0, 0, 255])
        #expect(Array(UnsafeBufferPointer(start: base + 4, count: 3)) == [0, 255, 0])
        #expect(Array(UnsafeBufferPointer(start: base + row, count: 3)) == [255, 0, 0])
        #expect(Array(UnsafeBufferPointer(start: base + row + 4, count: 3)) == [0, 0, 0])
    }

    @Test func canceledConversionDoesNotReturnAPartialMask() async throws {
        let task = Task {
            let values = try MLMultiArray(shape: [1, 1, 2, 2], dataType: .float32)
            withUnsafeCurrentTask { $0?.cancel() }
            return try SubjectMattingInference.raster(values, side: 2, outputSize: (2, 2))
        }
        do { _ = try await task.value; Issue.record("Canceled mask was returned") }
        catch { #expect(error is CancellationError) }
    }
}
