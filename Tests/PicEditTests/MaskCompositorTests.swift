import CoreGraphics
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Immutable, color-correct mask composition", .serialized)
struct MaskCompositorTests {
    @Test func zeroAndFullWeightsPreserveCanonicalStraightSamplesAtEveryDepthAndProfile() async throws {
        for bits in [8, 16] {
            for space in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
                let maximum: UInt16 = bits == 8 ? 255 : 65_535
                let base = try image(width: 2, height: 2, bits: bits, space: space, samples: [
                    17, 39, 61, 0, maximum / 2, 31, 79, maximum / 2,
                    maximum, 0, maximum / 3, maximum, 19, 87, maximum, 0
                ])
                let candidate = try image(width: 2, height: 2, bits: bits, space: space, samples: [
                    maximum, 43, 7, 0, 81, maximum / 4, 1, maximum,
                    19, maximum, 0, maximum / 2, maximum / 3, 83, 9, 0
                ])
                let sourceBefore = try samples(base), candidateBefore = try samples(candidate)
                for weight in [UInt8(0), 255] {
                    let output = try await compose(base, candidate, weights: [UInt8](repeating: weight, count: 4))
                    #expect(try samples(output.image) == (weight == 0 ? sourceBefore : candidateBefore))
                    #expect(output.image.bitsPerComponent == bits)
                    #expect(output.image.alphaInfo == .last)
                    #expect(output.image.colorSpace?.name == base.colorSpace?.name)
                }
                #expect(try samples(base) == sourceBefore)
                #expect(try samples(candidate) == candidateBefore)
            }
        }
    }

    @Test func halfMaskMixesLinearLightAndPremultipliedAlphaWithoutTransparentMatte() async throws {
        let black = try image(samples: [0, 0, 0, 255])
        let white = try image(samples: [255, 255, 255, 255])
        let half = try samples(await compose(black, white, weights: [128]).image)
        #expect(half == [188, 188, 188, 255], "Gamma-encoded interpolation would incorrectly produce 128")
        let red = try image(samples: [255, 0, 0, 255])
        let transparentBlue = try image(samples: [0, 0, 255, 0])
        let edge = try samples(await compose(red, transparentBlue, weights: [128]).image)
        #expect(edge == [255, 0, 0, 127], "Invisible blue must not contaminate the visible red edge")
        let transparentRed = try image(samples: [255, 0, 0, 0])
        let green = try image(samples: [0, 255, 0, 255])
        let result = try samples(await compose(transparentRed, green, weights: [64]).image)
        #expect(result == [0, 255, 0, 64], "A soft edge retains straight green instead of acquiring a black matte")
    }

    @Test func premultipliedNativeInputsHaveADefinedStraightComparisonRaster() async throws {
        let base = try image(alpha: .premultipliedLast, samples: [64, 32, 16, 128])
        let candidate = try image(alpha: .premultipliedLast, samples: [0, 64, 0, 128])
        let zero = try samples(await compose(base, candidate, weights: [0]).image)
        let full = try samples(await compose(base, candidate, weights: [255]).image)
        #expect(zero == [128, 64, 32, 128])
        #expect(full == [0, 128, 0, 128])
        #expect(try samples(base) == [64, 32, 16, 128])
    }

    @Test func gradientAndAsymmetricRowsMatchEveryAvailableCoreImageBackend() async throws {
        var compared = 0, unavailable = 0
        for bits in [8, 16] {
            for space in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
                let factor: UInt16 = bits == 8 ? 1 : 257
                let a: [UInt16] = [211, 19, 73, 0, 75, 91, 107, 255, 40, 160, 90, 128,
                                   35, 101, 203, 220, 221, 66, 144, 128, 80, 192, 23, 0].map { $0 * factor }
                let b: [UInt16] = [19, 181, 66, 255, 87, 164, 31, 128, 91, 27, 217, 200,
                                   101, 203, 71, 90, 47, 88, 191, 255, 190, 22, 99, 255].map { $0 * factor }
                let base = try image(width: 3, height: 2, bits: bits, space: space, samples: a)
                let candidate = try image(width: 3, height: 2, bits: bits, space: space, samples: b)
                let weights: [UInt8] = [0, 32, 64, 128, 192, 255]
                let expected = try samples(await compose(base, candidate, weights: weights).image)
                for backend in [MaskCompositor.Backend.coreImage, .softwareCoreImage] {
                    do {
                        let output = try samples(await compose(base, candidate, weights: weights, backend: backend).image)
                        compared += 1
                        // Existing renderer contexts use half-float linear working
                        // buffers. Their conversion error is bounded at 2/255 or
                        // 128/65535; zero-weight pixels still require exact equality.
                        let tolerance = bits == 8 ? 2 : 128
                        #expect(Array(output[0..<4]) == Array(a[0..<4]))
                        for (actual, reference) in zip(output, expected) {
                            #expect(abs(Int(actual) - Int(reference)) <= tolerance)
                        }
                    } catch MaskCompositor.Failure.backendUnavailable {
                        unavailable += 1
                        // Headless machines may expose no usable CI renderer.
                        // The automatic API has an equivalent CPU path below.
                        #expect(try samples(base) == a)
                    }
                }
            }
        }
        print("MaskCompositor: \(compared) Core Image fixture comparisons, \(unavailable) unavailable backend runs.")
    }

    @Test func candidateProfileConversionAndAutomaticFallbackKeepTheOutputContract() async throws {
        let base = try image(width: 2, samples: [71, 29, 191, 0, 97, 116, 46, 150])
        let candidate = try image(width: 2, space: CGColorSpace.displayP3, samples: [171, 79, 94, 255, 83, 147, 51, 200])
        let output = try await compose(base, candidate, weights: [0, 128], backend: .automatic)
        let result = try samples(output.image)
        #expect(Array(result[0..<4]) == [71, 29, 191, 0])
        #expect(result[7] == 175)
        #expect(output.image.colorSpace?.name == CGColorSpace.sRGB)
        #expect(output.image.bitsPerComponent == 8)
    }

    @Test func veryLowAlphaAndMixedProfilesStayWithinSixteenBitTolerance() async throws {
        let base = try image(width: 3, bits: 16, samples: [31_000, 17_000, 47_000, 1,
            18_000, 52_000, 27_000, 7, 59_000, 13_000, 38_000, 63])
        let candidate = try image(width: 3, bits: 16, space: CGColorSpace.displayP3,
            samples: [57_000, 28_000, 11_000, 2, 42_000, 19_000, 61_000, 3, 26_000, 56_000, 14_000, 11])
        let weights: [UInt8] = [127, 89, 192]
        let expected = try samples(await compose(base, candidate, weights: weights).image)
        for backend in [MaskCompositor.Backend.coreImage, .softwareCoreImage] {
            do {
                let actual = try samples(await compose(base, candidate, weights: weights, backend: backend).image)
                for (sample, reference) in zip(actual, expected) { #expect(abs(Int(sample) - Int(reference)) <= 128) }
            } catch MaskCompositor.Failure.backendUnavailable { /* Explicit CPU fallback remains tested. */ }
        }
    }

    @Test func canvasErrorsAndMemoryAdmissionLeaveSourcesUntouched() async throws {
        let base = try image(samples: [31, 73, 109, 0])
        let candidate = try image(samples: [97, 181, 11, 255])
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 1_024))
        let mask = try MaskRaster(size: .init(width: 1, height: 1), bytes: Data([128]))
        await #expect(throws: ArtifactResourceError.capacityExceeded) {
            _ = try await MaskCompositor.compose(base: .init(immutableImage: base), candidate: .init(immutableImage: candidate),
                mask: mask, resources: resources)
        }
        #expect(await resources.state().chargedBytes == 0)
        let wrong = try MaskRaster(size: .init(width: 2, height: 1), bytes: Data([0, 255]))
        await #expect(throws: MaskCompositor.Failure.incompatibleCanvas) {
            _ = try await MaskCompositor.compose(base: .init(immutableImage: base), candidate: .init(immutableImage: candidate),
                mask: wrong, resources: resources)
        }
        #expect(try samples(base) == [31, 73, 109, 0])
    }

    @Test func oneOwnershipCannotUnderchargeTwoDistinctInputAllocations() async throws {
        let resources = ArtifactResourceOwner(limits: try .init())
        let lease = try await resources.acquire(kind: .retainedMemory, bytes: 4, priority: .interactive, retaining: [])
        let memory = try await resources.retain(bytes: 4, from: lease)
        let base = try image(samples: [31, 73, 109, 0])
        let candidate = try image(samples: [97, 181, 11, 255])
        let mask = try MaskRaster(size: .init(width: 1, height: 1), bytes: Data([128]))
        await #expect(throws: ArtifactResourceError.invalidOwnership) {
            _ = try await MaskCompositor.compose(base: .init(immutableImage: base, memoryOwnership: memory),
                candidate: .init(immutableImage: candidate, memoryOwnership: memory), mask: mask, resources: resources)
        }
        let shared = ArtifactRasterInput(immutableImage: base, memoryOwnership: memory)
        let output = try await MaskCompositor.compose(base: shared, candidate: shared, mask: mask, resources: resources)
        #expect(try samples(output.image) == [31, 73, 109, 0])
        withExtendedLifetime(lease) {}
    }

    @Test func automaticAdmissionUsesCPUWhenNativeTextureScratchDoesNotFit() async throws {
        let size = 256, pixels = size * size
        let base = try image(width: size, height: size, samples: [UInt16](repeating: 0, count: pixels * 4))
        let candidate = try image(width: size, height: size, samples: [UInt16](repeating: 255, count: pixels * 4))
        let mask = try MaskRaster(size: .init(width: size, height: size), bytes: Data(repeating: 128, count: pixels))
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 2_000_000))
        let output = try await MaskCompositor.compose(base: .init(immutableImage: base), candidate: .init(immutableImage: candidate),
            mask: mask, resources: resources, backend: .automatic)
        let result = try samples(output.image)
        #expect(result.count == pixels * 4)
        #expect(Array(result.prefix(4)) == [255, 255, 255, 128])
        #expect(Array(result.suffix(4)) == [255, 255, 255, 128])
    }

    @Test func largeCanvasIsRefusedBeforeNativeInputIsRead() async throws {
        let side = 4_096, byteCount = side * side * 4
        let probe = ReadProbe()
        let owner = Unmanaged.passRetained(probe).toOpaque()
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { context, destination, _, count in
                guard let context else { return 0 }
                Unmanaged<ReadProbe>.fromOpaque(context).takeUnretainedValue().record()
                destination.initializeMemory(as: UInt8.self, repeating: 0, count: count)
                return count
            }, releaseInfo: { context in if let context { Unmanaged<ReadProbe>.fromOpaque(context).release() } })
        let provider = try #require(CGDataProvider(directInfo: owner, size: Int64(byteCount), callbacks: &callbacks))
        let source = try #require(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let readsBefore = probe.count
        let mask = try MaskRaster(size: .init(width: side, height: side), bytes: Data(count: side * side))
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 1_048_576))
        await #expect(throws: ArtifactResourceError.capacityExceeded) {
            _ = try await MaskCompositor.compose(base: .init(immutableImage: source), candidate: .init(immutableImage: source),
                mask: mask, resources: resources)
        }
        #expect(probe.count == readsBefore)
        #expect(await resources.state().chargedBytes == 0)
    }

    @Test func cancelledWorkDoesNotPublishAndNativeProviderKeepsOutputCharged() async throws {
        let resources = ArtifactResourceOwner(limits: try .init())
        let base = try image(samples: [17, 93, 201, 0])
        let candidate = try image(samples: [201, 71, 34, 255])
        let mask = try MaskRaster(size: .init(width: 1, height: 1), bytes: Data([128]))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MaskCompositor.compose(base: .init(immutableImage: base), candidate: .init(immutableImage: candidate),
                mask: mask, resources: resources)
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        var output: ArtifactRasterInput? = try await MaskCompositor.compose(base: .init(immutableImage: base),
            candidate: .init(immutableImage: candidate), mask: mask, resources: resources)
        var image: CGImage? = output?.image
        output = nil
        #expect(await resources.state().chargedBytes >= 4)
        #expect(try samples(#require(image)) == [201, 71, 34, 128])
        withExtendedLifetime(image) {}
        image = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await resources.state().chargedBytes != 0 {
            guard ContinuousClock.now < deadline else { Issue.record("compositor output ownership leaked"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func compose(_ base: CGImage, _ candidate: CGImage, weights: [UInt8],
                         backend: MaskCompositor.Backend = .cpu) async throws -> ArtifactRasterInput {
        let mask = try MaskRaster(size: .init(width: base.width, height: base.height), bytes: Data(weights))
        return try await MaskCompositor.compose(base: .init(immutableImage: base), candidate: .init(immutableImage: candidate),
            mask: mask, resources: ArtifactResourceOwner(limits: try .init()), backend: backend)
    }
    private func image(width: Int = 1, height: Int = 1, bits: Int = 8, space: CFString = CGColorSpace.sRGB,
                       alpha: CGImageAlphaInfo = .last,
                       samples: [UInt16]) throws -> CGImage {
        #expect(samples.count == width * height * 4)
        var bytes = Data()
        for sample in samples {
            if bits == 8 { bytes.append(UInt8(sample)) }
            else { bytes.append(UInt8(truncatingIfNeeded: sample >> 8)); bytes.append(UInt8(truncatingIfNeeded: sample)) }
        }
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let colorSpace = try #require(CGColorSpace(name: space))
        let info = CGBitmapInfo(rawValue: alpha.rawValue).union(bits == 16 ? .byteOrder16Big : [])
        return try #require(CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * 4,
            bytesPerRow: width * 4 * (bits / 8), space: colorSpace, bitmapInfo: info,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func samples(_ image: CGImage) throws -> [UInt16] {
        let data = try #require(image.dataProvider?.data) as Data
        if image.bitsPerComponent == 8 { return data.map(UInt16.init) }
        return stride(from: 0, to: data.count, by: 2).map { UInt16(data[$0]) << 8 | UInt16(data[$0 + 1]) }
    }
    private final class ReadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        var count: Int { lock.withLock { reads } }
        func record() { lock.withLock { reads += 1 } }
    }
}
