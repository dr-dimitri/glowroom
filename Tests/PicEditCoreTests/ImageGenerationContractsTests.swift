import Foundation
import Testing
@testable import PicEditCore

@Suite("Image generation operation and native output contracts")
struct ImageGenerationContractsTests {
    @Test func operationClaimsAreIndependentAndOmittedClaimsStayUnverified() throws {
        let descriptor = try ImageGenerationBackendDescriptor(identity: .init(providerID: "test-only"),
            operations: [.imageToImage: .supported, .inpaint: .unsupported], residentMemoryBytes: 1, maximumOutputPixels: 6)
        #expect(descriptor.status(for: .imageToImage) == .supported)
        #expect(descriptor.status(for: .inpaint) == .unsupported)
        #expect(descriptor.status(for: .backgroundEdit) == .unverified)
        #expect(descriptor.status(for: .outpaint) == .unverified)
        #expect(Set(ImageGenerationOperation.allCases).count == 5)
    }

    @Test func invalidParameterAndDescriptorBoundsRejectInsteadOfClamping() throws {
        #expect(throws: ImageGenerationError.invalidRequest) { try ImageGenerationParameters(steps: 0) }
        #expect(throws: ImageGenerationError.invalidRequest) { try ImageGenerationParameters(guidanceScale: .infinity) }
        #expect(throws: ImageGenerationError.invalidRequest) { try ImageGenerationParameters(strength: -.leastNonzeroMagnitude) }
        #expect(throws: ImageGenerationError.invalidRequest) {
            try ImageGenerationBackendDescriptor(identity: .init(providerID: "test-only"),
                operations: [:], residentMemoryBytes: -1, maximumOutputPixels: 6)
        }
    }

    @Test func nativeOutputRechecksDimensionsProfileAlphaAndEveryJobTokenComponent() throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let job = try makeJob(fixture)
        let descriptor = try ImageGenerationBackendDescriptor(identity: .init(providerID: "test-only"),
            operations: [.inpaint: .supported], residentMemoryBytes: 1, maximumOutputPixels: 6)
        let good = try ImageGenerationOutput(immutableRaster: job.request.input, token: job.request.token)
        try good.validate(for: job, descriptor: descriptor)
        #expect(good.fingerprint == job.request.renderedInput)
        for image in [fixture.image(width: 2), fixture.image(p3: true), fixture.image(alpha: false), fixture.image(bits: 16)] {
            let output = try ImageGenerationOutput(immutableRaster: .init(immutableImage: image), token: job.request.token)
            #expect(throws: ImageGenerationError.invalidOutput) { try output.validate(for: job, descriptor: descriptor) }
        }
        for invalid in [fixture.image(gray: true), fixture.image(premultiplied: true)] {
            #expect(throws: ImageGenerationError.invalidOutput) {
                try ImageGenerationOutput(immutableRaster: .init(immutableImage: invalid), token: job.request.token)
            }
        }
        let newer = try makeJob(fixture)
        let stale = try ImageGenerationOutput(immutableRaster: job.request.input, token: newer.request.token)
        #expect(throws: ImageGenerationError.staleInput) { try stale.validate(for: job, descriptor: descriptor) }
    }

    @Test func emptyPromptNonmaskedOperationAndChangedInpaintCanvasAreRejected() throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let job = try makeJob(fixture)
        for operation in [ImageGenerationOperation.textToImage, .imageToImage, .outpaint] {
            #expect(throws: ImageGenerationError.invalidRequest) {
                try ImageGenerationJob(request: job.request, operation: operation, placement: job.placement,
                    prompt: "test", parameters: .init(), seed: 1)
            }
        }
        #expect(throws: ImageGenerationError.invalidRequest) {
            try ImageGenerationJob(request: job.request, operation: .inpaint, placement: job.placement,
                prompt: " \n", parameters: .init(), seed: 1)
        }
        #expect(throws: ImageGenerationError.invalidRequest) {
            try ImageGenerationJob(request: job.request, operation: .inpaint,
                placement: .init(inputSize: job.placement.inputSize, outputSize: .init(width: 5, height: 4), inputOriginX: 1, inputOriginY: 1),
                prompt: "test", parameters: .init(), seed: 1)
        }
    }

    private func makeJob(_ fixture: ArtifactTestFixture) throws -> ImageGenerationJob {
        let size = try ArtifactPixelSize(width: 3, height: 2)
        let mask = try FrozenGenerationMask.capture(document: .init(canvasSize: size), modelSize: size)
        let snapshot = AIEditingSnapshot(assetID: "synthetic", source: .original(.init(
            fileURL: fixture.directory.appendingPathComponent("original.bin"), modifiedAt: .distantPast, fileSize: 3)),
            settings: .neutral, token: .init(editSessionID: UUID(), editGeneration: 1, selectionSessionID: UUID(), selectionGeneration: 1))
        return try ImageGenerationJob(request: .init(snapshot: snapshot, immutableInput: .init(immutableImage: fixture.image()), mask: mask),
            operation: .inpaint, placement: .init(inputSize: size, outputSize: size, inputOriginX: 0, inputOriginY: 0),
            prompt: "Remove the synthetic object", parameters: .init(), seed: 7)
    }
}
