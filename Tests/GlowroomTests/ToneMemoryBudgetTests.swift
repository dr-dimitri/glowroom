import CoreGraphics
import Foundation
import GlowroomCore
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Glowroom

@Suite("Float tone working-memory admission")
struct ToneMemoryBudgetTests {
    @Test func floatLocalPlanesExpandWithoutDuplicatingGray8Backing() throws {
        let raster = try LocalMaskRaster(width: 2, height: 2, bytes: Data(repeating: 255, count: 4))
        let layer = try LocalAdjustment(name: "Float local", mask: .init(shape: .subject(raster), feather: 0),
            settings: .init(exposure: 1, texture: 20, clarity: 30, temperature: 5_500))
        let legacy = try #require(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: [layer], width: 64, height: 48))
        let precise = try #require(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: [layer], width: 64, height: 48,
            toneProcessingVersion: .consistentV2))
        #expect(legacy == 64 * 48 * 64 + 4)
        #expect(precise == 64 * 48 * 128 + 4)
        let repeated = try #require(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: [layer], width: 64, height: 48,
            additionalRenderCount: 2, toneProcessingVersion: .consistentV2))
        #expect(repeated == precise * 3)
        var dormant = layer
        dormant.isEnabled = false
        #expect(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: [dormant], width: 64, height: 48,
            toneProcessingVersion: .consistentV2) == 0)
        #expect(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: [layer], width: Int.max, height: Int.max,
            toneProcessingVersion: .consistentV2) == nil)
    }

    @Test func tightCombinedBudgetSelectsSmallerFloatProxyBeforeAllocation() throws {
        let layer = try LocalAdjustment(name: "Local", mask: .init(shape: .radial(center: .init(x: 0.5, y: 0.5),
            radiusX: 0.2, radiusY: 0.3, rotation: 0), feather: 0), settings: .init(exposure: 1))
        let budget: UInt64 = 1_000_000
        let legacy = try LocalAdjustmentRenderer.previewSize(width: 256, height: 256, adjustments: [layer],
            outputBytesPerPixel: 32, totalMemoryBudget: budget)
        let extra = LocalAdjustmentRenderer.additionalToneWorkingBytesPerPixel(version: .consistentV2)
        let precise = try LocalAdjustmentRenderer.previewSize(width: 256, height: 256, adjustments: [layer],
            outputBytesPerPixel: 32, totalMemoryBudget: budget, globalBytesPerPixel: extra,
            toneProcessingVersion: .consistentV2)
        #expect(LocalAdjustmentRenderer.additionalToneWorkingBytesPerPixel(version: .legacyV1) == 0)
        #expect(extra == 32)
        #expect(precise.width < legacy.width && precise.height < legacy.height)
        let local = try #require(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: [layer],
            width: precise.width, height: precise.height, toneProcessingVersion: .consistentV2))
        #expect(local + UInt64(precise.width * precise.height) * (32 + extra) <= budget)
        #expect(throws: EditRenderError.insufficientMaskMemory) {
            try LocalAdjustmentRenderer.previewSize(width: 256, height: 256, adjustments: [layer],
                outputBytesPerPixel: 32, totalMemoryBudget: 1, globalBytesPerPixel: extra,
                toneProcessingVersion: .consistentV2)
        }
    }

    @Test(arguments: [false, true])
    func artifactPreviewAdmitsFloatResizeBeforeEnteringItsExistingWorker(legacyWithLevels: Bool) async throws {
        let image = try image(width: 128, height: 96)
        // Active Levels requires 884,736 planned bytes even at the minimum
        // 64×48 proxy, including its retained input/output and previous frame.
        // This leaves 918,750 after LRU headroom, while full resolution still
        // exceeds the budget and must select the existing adaptive proxy.
        let byteLimit: Int64 = 1_050_000
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: byteLimit))
        var phase: ArtifactResourceLease? = try await resources.acquire(kind: .retainedMemory,
            bytes: Int64(image.bytesPerRow * image.height) * 2, priority: .interactive, retaining: [])
        let memory = try await resources.retain(bytes: Int64(image.bytesPerRow * image.height) * 2, from: #require(phase))
        let source = try PreviewBitmap(image: image).retainingArtifactMemory(memory, owner: resources)
        phase = nil
        try await waitForTestState("float source phase released", state: { await resources.state() }) {
            $0.chargedBytes == Int64(image.bytesPerRow * image.height) * 2
        }
        let request = PreviewRequest(url: URL(fileURLWithPath: "/synthetic/float-budget.png"), modifiedAt: .distantPast,
            pixelSize: 512, allowsEmbeddedPreview: false)
        let calls = TestStateSignal(0)
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, renderer: { bitmap, _ in
            calls.update { $0 += 1 }
            return bitmap
        })
        var settings = EditSettings(exposure: 0.5, toneProcessingVersion: legacyWithLevels ? .legacyV1 : .consistentV2)
        if legacyWithLevels { settings.levels.master.gamma = 1.2 }
        let result = try await pipeline.image(source, request: request, settings: settings)
        #expect(settings.toneProcessingVersion == (legacyWithLevels ? .legacyV1 : .consistentV2))
        #expect(calls.value == 1)
        #expect(result.image.width < 128 && result.image.height < 96)
        #expect(result.image.bitsPerComponent == 32, "The resized V2 basis must retain Float precision")
        #expect(await pipeline.state().runningSelected == 0)
        #expect(await resources.state().chargedBytes <= byteLimit)
    }

    @Test(arguments: [false, true])
    func floatExportRejectsBeforeReplacingTheTargetWhileLegacyBudgetStaysUnchanged(legacyWithLevels: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tone-memory-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let writer = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try image(width: 64, height: 48), nil)
        #expect(CGImageDestinationFinalize(writer))
        let original = try Data(contentsOf: source)
        let exporter = JPEGExporter(memoryBudget: 250_000)
        _ = try await exporter.export(.init(sourceURL: source, destinationURL: directory.appendingPathComponent("legacy.jpg"),
            settings: EditSettings(exposure: 0.5), options: .init()))
        let target = directory.appendingPathComponent("existing.jpg")
        let sentinel = Data("Keep the existing result".utf8)
        try sentinel.write(to: target)
        var precise = EditSettings(exposure: 0.5, toneProcessingVersion: legacyWithLevels ? .legacyV1 : .consistentV2)
        if legacyWithLevels { precise.levels.master.gamma = 1.2 }
        await #expect(throws: JPEGExportError.insufficientMemory) {
            try await exporter.export(.init(sourceURL: source, destinationURL: target,
                settings: precise, options: .init(), overwriteExisting: true))
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: target) == sentinel)
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let bytes = Data(repeating: 160, count: width * height * 4)
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
