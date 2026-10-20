import CoreGraphics
import Foundation
import ImageIO
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Image generation reproducible fixtures and golden geometry")
struct ImageGenerationGeometryTests {
    @Test func sixSelfAuthoredFixturesHaveStableNativeInputsMasksAndJobBindings() throws {
        let fixtures = try ImageGenerationFixtures.make(), repeated = try ImageGenerationFixtures.make()
        #expect(fixtures.count == 6)
        #expect(Set(fixtures.map(\.id)).count == 6)
        for (fixture, second) in zip(fixtures, repeated) {
            #expect(fixture.rgba == second.rgba)
            #expect(fixture.mask.document == second.mask.document)
            #expect(fixture.mask.raster == second.mask.raster)
            #expect(fixture.mask.binding == second.mask.binding)
            let request = try fixture.request()
            #expect(request.token == (try second.request()).token)
            let prepared = try ImageGenerationPreprocessing.prepare(request)
            #expect(prepared.input.image.width == fixture.mask.binding.transform.modelSize.width)
            #expect(prepared.input.image.height == fixture.mask.binding.transform.modelSize.height)
            #expect(prepared.mask == (try fixture.mask.modelRaster()))
            #expect(prepared.mask.bytes.contains(0))
            #expect(prepared.mask.bytes.contains(255))
            // The padded outpainting fixture deliberately describes model
            // preprocessing, not a proven product extension adapter.
            if fixture.operation != "outpaint" {
                let operation = try #require(ImageGenerationOperation(rawValue: fixture.operation))
                let job = try ImageGenerationJob(request: request, operation: operation,
                    placement: .init(inputSize: fixture.mask.raster.size, outputSize: fixture.mask.raster.size,
                                     inputOriginX: 0, inputOriginY: 0), prompt: fixture.prompt,
                    parameters: .init(), seed: 42)
                #expect(job.request.token == request.token)
            }
        }
        let translucent = fixtures[3]
        #expect(stride(from: 3, to: translucent.rgba.count, by: 4).allSatisfy { [UInt8(0), 128].contains(translucent.rgba[$0]) })
        let padded = fixtures[5], content = try #require(padded.preservedContent)
        #expect(padded.mask.raster.size.width != padded.mask.raster.size.height)
        for y in 0..<padded.mask.raster.size.height { for x in 0..<padded.mask.raster.size.width {
            let preserved = (content.x..<content.x + content.size.width).contains(x)
                && (content.y..<content.y + content.size.height).contains(y)
            let offset = y * padded.mask.raster.size.width + x
            #expect(padded.mask.raster.bytes[offset] == (preserved ? 0 : 255))
            #expect(padded.rgba[offset * 4 + 3] == (preserved ? 255 : 0))
        } }
    }

    @Test func goldenAsymmetricGridAndMaskUseTheSameCropCentersAndTopLeftRows() throws {
        let native = try ArtifactPixelSize(width: 8, height: 6)
        let crop = try ArtifactPixelRect(x: 2, y: 1, size: .init(width: 4, height: 4))
        let model = try ArtifactPixelSize(width: 2, height: 2)
        let frozen = try frozenMask(size: native, model: model, crop: crop)
        let input = try ImageGenerationFixtures.goldenGrid(size: native)
        let request = try generationRequest(input: input, mask: frozen)
        let prepared = try ImageGenerationPreprocessing.prepare(request)
        #expect(try pixels(prepared.input.image) == Data([
            40, 24, 34, 255, 72, 24, 48, 255,
            40, 56, 56, 255, 72, 56, 70, 255
        ]))
        // A single white native pixel at (2,1) lies in the crop's upper-left
        // 2x2 sampling footprint. Bilinear coverage rounds 255/4 to 64.
        #expect(prepared.mask.bytes == Data([64, 0, 0, 0]))
        let redCarriesMask = try image(size: native, samples: (0..<native.width * native.height).flatMap { offset in
            [UInt16(frozen.raster.bytes[offset]), UInt16(offset % native.width * 16), UInt16(offset / native.width * 16), 255]
        })
        let aligned = try ImageGenerationPreprocessing.prepare(generationRequest(input: .init(immutableImage: redCarriesMask), mask: frozen))
        let alignedBytes = try pixels(aligned.input.image)
        #expect(Data(stride(from: 0, to: alignedBytes.count, by: 4).map { alignedBytes[$0] }) == aligned.mask.bytes)
        #expect(alignedBytes == Data([64, 40, 24, 255, 0, 72, 24, 255, 0, 40, 56, 255, 0, 72, 56, 255]))
        // Mathematical inverse coordinates remain exact even when pixel
        // reconstruction is lossy because the chosen model is smaller.
        for point in [try MaskPoint(x: 2.5, y: 1.5), try MaskPoint(x: 5.5, y: 4.5)] {
            let restored = try prepared.transform.canvasPoint(from: prepared.transform.modelPoint(from: point))
            #expect(abs(restored.x - point.x) < 1e-12)
            #expect(abs(restored.y - point.y) < 1e-12)
        }
    }

    @Test func nativeModelNativeBijectionRestoresCropAndLeavesEveryOutsideByteUntouched() throws {
        let native = try ArtifactPixelSize(width: 8, height: 6)
        let crop = try ArtifactPixelRect(x: 2, y: 1, size: .init(width: 4, height: 4))
        let input = try ImageGenerationFixtures.goldenGrid(size: native), before = try pixels(input.image)
        let frozen = try frozenMask(size: native, model: crop.size, crop: crop)
        let prepared = try ImageGenerationPreprocessing.prepare(generationRequest(input: input, mask: frozen))
        let restored = try ImageGenerationPreprocessing.restore(prepared.input, onto: input, transform: prepared.transform)
        #expect(try pixels(restored.image) == before)
        let replacement = try image(size: crop.size, samples: [UInt16](repeating: 71, count: 4 * 4 * 4))
        let changed = try pixels(ImageGenerationPreprocessing.restore(.init(immutableImage: replacement),
            onto: input, transform: prepared.transform).image)
        for y in 0..<native.height { for x in 0..<native.width {
            let start = (y * native.width + x) * 4
            let inside = (crop.x..<crop.x + crop.size.width).contains(x) && (crop.y..<crop.y + crop.size.height).contains(y)
            #expect(changed[start..<start + 4] == (inside ? Data(repeating: 71, count: 4)[...] : before[start..<start + 4]))
        } }
        #expect(try pixels(input.image) == before)
    }

    @Test func preprocessingIsByteDeterministicAtBothDepthsAndProfilesAndRejectsImplicitDistortion() throws {
        let native = try ArtifactPixelSize(width: 8, height: 6)
        let crop = try ArtifactPixelRect(x: 2, y: 1, size: .init(width: 4, height: 4))
        let model = try ArtifactPixelSize(width: 2, height: 2)
        let frozen = try frozenMask(size: native, model: model, crop: crop)
        for bits in [8, 16] { for profile in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            let multiplier: UInt16 = bits == 8 ? 1 : 257
            let samples = (0..<native.width * native.height).flatMap { offset -> [UInt16] in
                [UInt16(frozen.raster.bytes[offset]) * multiplier, UInt16(offset % native.width * 16) * multiplier,
                 UInt16(offset / native.width * 16) * multiplier, UInt16(128) * multiplier]
            }
            let raster = try image(size: native, bits: bits, profile: profile, samples: samples)
            let request = try generationRequest(input: .init(immutableImage: raster), mask: frozen)
            let a = try ImageGenerationPreprocessing.prepare(request), b = try ImageGenerationPreprocessing.prepare(request)
            #expect(try pixels(a.input.image) == pixels(b.input.image))
            #expect(a.mask == b.mask)
            #expect(a.input.image.bitsPerComponent == bits)
            #expect(a.input.image.colorSpace?.name == raster.colorSpace?.name)
            #expect(a.input.image.alphaInfo == .last)
            let inverse = try ImageGenerationPreprocessing.restore(a.input, onto: .init(immutableImage: raster), transform: a.transform)
            #expect(inverse.image.bitsPerComponent == bits)
            #expect(inverse.image.colorSpace?.name == raster.colorSpace?.name)
        } }
        let distorted = try frozenMask(size: native, model: .init(width: 4, height: 3), crop: crop)
        let input = try ImageGenerationFixtures.goldenGrid(size: native)
        #expect(throws: ArtifactContractError.self) {
            try ImageGenerationPreprocessing.prepare(generationRequest(input: input, mask: distorted))
        }
        let invalidSize = try ImageGenerationFixtures.goldenGrid(size: .init(width: 3, height: 3))
        #expect(throws: ArtifactContractError.self) {
            try ImageGenerationPreprocessing.restore(invalidSize, onto: input, transform: frozen.binding.transform)
        }
    }

    @Test func writtenFixtureManifestExplicitlyContainsNoModelResult() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glowroom-image-fixtures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptors = try ImageGenerationFixtures.write(to: directory)
        #expect(descriptors.count == 6)
        for descriptor in descriptors {
            #expect(descriptor.modelResultFile == nil)
            #expect(descriptor.purpose.contains("no generated model result"))
            for relative in [descriptor.inputFile, descriptor.replacementMaskFile, descriptor.maskDocumentFile] {
                #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative).path))
            }
            let source = try #require(CGImageSourceCreateWithURL(directory.appendingPathComponent(descriptor.inputFile) as CFURL, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(decoded.width == descriptor.transform.canvasSize.width)
            #expect(decoded.height == descriptor.transform.canvasSize.height)
            let maskSource = try #require(CGImageSourceCreateWithURL(directory.appendingPathComponent(descriptor.replacementMaskFile) as CFURL, nil))
            let mask = try #require(CGImageSourceCreateImageAtIndex(maskSource, 0, nil))
            #expect(mask.bitsPerPixel == 8)
            #expect(mask.alphaInfo == .none)
        }
    }

    @Test func cancellationCannotPublishPreprocessingOrAlterImmutableNativeInput() async throws {
        let fixture = try #require(ImageGenerationFixtures.make().first)
        let request = try fixture.request(), before = try pixels(fixture.input.image)
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ImageGenerationPreprocessing.prepare(request)
        }
        await #expect(throws: CancellationError.self) { _ = try await work.value }
        #expect(try pixels(fixture.input.image) == before)
        #expect(fixture.mask.raster == (try MaskRasterizer.rasterize(fixture.mask.document)))
    }

    private func frozenMask(size: ArtifactPixelSize, model: ArtifactPixelSize,
                            crop: ArtifactPixelRect? = nil) throws -> FrozenGenerationMask {
        let stroke = try MaskStroke(points: [.init(x: 2.5, y: 1.5)], radius: 0.6)
        return try .capture(document: .init(canvasSize: size, strokes: [stroke]), modelSize: model, crop: crop)
    }
    private func generationRequest(input: ArtifactRasterInput, mask: FrozenGenerationMask) throws -> GenerationRequest {
        let snapshot = AIEditingSnapshot(assetID: "golden-grid", source: .original(.init(
            fileURL: URL(fileURLWithPath: "/glowroom-contract-fixtures/golden-grid/input.png"),
            modifiedAt: Date(timeIntervalSince1970: 0), fileSize: 1)), settings: .neutral,
            token: .init(editSessionID: UUID(), editGeneration: 1, selectionSessionID: UUID(), selectionGeneration: 1))
        return try .init(snapshot: snapshot, immutableInput: input, mask: mask)
    }
    private func image(size: ArtifactPixelSize, bits: Int = 8, profile: CFString = CGColorSpace.sRGB,
                       samples: [UInt16]) throws -> CGImage {
        var bytes = Data()
        for sample in samples {
            if bits == 8 { bytes.append(UInt8(sample)) }
            else { bytes.append(UInt8(truncatingIfNeeded: sample >> 8)); bytes.append(UInt8(truncatingIfNeeded: sample)) }
        }
        let provider = try #require(CGDataProvider(data: bytes as CFData)), space = try #require(CGColorSpace(name: profile))
        return try #require(CGImage(width: size.width, height: size.height, bitsPerComponent: bits, bitsPerPixel: bits * 4,
            bytesPerRow: size.width * 4 * (bits / 8), space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(bits == 16 ? .byteOrder16Big : []),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func pixels(_ image: CGImage) throws -> Data {
        let bytes = try #require(image.dataProvider?.data) as Data, rowBytes = image.width * 4 * (image.bitsPerComponent / 8)
        var packed = Data()
        for y in 0..<image.height { packed.append(bytes[y * image.bytesPerRow..<y * image.bytesPerRow + rowBytes]) }
        return packed
    }
}
