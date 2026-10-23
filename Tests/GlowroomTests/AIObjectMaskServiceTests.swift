import CoreGraphics
import Foundation
import GlowroomCore
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Glowroom

@Suite("AI object masks in shared source coordinates", .timeLimit(.minutes(1)))
struct AIObjectMaskServiceTests {
    @Test func proposalCreatesNeutralSharedMatteInFullSourceCoordinates() async throws {
        let preparer = try ObjectMaskTestPreparer()
        let budget = AIResourceBudget()
        let service = AIObjectMaskService(budget: budget, preparer: preparer, infer: { _, prompt, _ in
            #expect(prompt.contains("Blumenstrauß"))
            return try JSONEncoder().encode(Self.box())
        }, segment: { bitmap in
            #expect(bitmap.image.width == 12 && bitmap.image.height == 5)
            for await state in await budget.stateUpdates() {
                #expect(state.activeInferences == 0, "Qwen must release admission before subject inference")
                break
            }
            var bytes = Data(count: bitmap.image.width * bitmap.image.height)
            bytes[2 * bitmap.image.width + 2] = 255
            bytes[2 * bitmap.image.width + 3] = 127
            return try LocalMaskRaster(width: bitmap.image.width, height: bitmap.image.height, bytes: bytes)
        })
        var settings = EditSettings(exposure: 0.7)
        let repair = try DevelopRetouchStroke(source: LocalMaskPoint(x: 0.1, y: 0.1),
            target: LocalMaskPoint(x: 0.5, y: 0.5), radius: 0.1)
        let redEye = try DevelopRedEyeCorrection(center: LocalMaskPoint(x: 0.3, y: 0.3), radiusX: 0.02, radiusY: 0.02)
        settings.developGeometry = DevelopGeometry(crop: try DevelopCropRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5),
            quarterTurns: 1, straightenAngle: 5, flipHorizontal: true, flipVertical: true,
            retouchStrokes: [repair], redEyeCorrections: [redEye])
        let snapshot = Self.snapshot(settings: settings)
        let result = try await service.propose(snapshot: snapshot, instruction: "Maskiere den Blumenstrauß")
        let request = try #require(await preparer.request)
        #expect(request.snapshot.source == snapshot.source && request.snapshot.token == snapshot.token)
        #expect(request.snapshot.settings.exposure == settings.exposure)
        #expect(request.snapshot.settings.developGeometry == DevelopGeometry(retouchStrokes: [repair], redEyeCorrections: [redEye]))
        #expect(result.layer.settings == .neutral && result.layer.mask.feather == 0)
        #expect(result.layer.name == "Blumenstrauß" && result.preview != nil)
        #expect(result.sourceStamp == preparer.stamp)
        guard case .subject(let raster) = result.layer.mask.shape else { Issue.record("Expected persisted raster"); return }
        #expect(raster.width == 20 && raster.height == 10)
        #expect(raster.bytes[2 * raster.width + 3] == 255)
        #expect(raster.bytes[2 * raster.width + 4] == 127, "Keep learned fractional alpha")
        #expect(raster.bytes[8 * raster.width + 3] == 0, "Top-left coordinates must not be vertically flipped")
        #expect(raster.bytes[2 * raster.width + 10] == 0, "The location box is never itself the saved selection")
        #expect(raster.bytes[2 * raster.width + 16] == 0)
        let encoded = try JSONEncoder().encode(result.layer)
        #expect(try JSONDecoder().decode(LocalAdjustment.self, from: encoded) == result.layer)
    }

    @Test func invalidOrStaleResultNeverReturnsLayerAndReleasesBudget() async throws {
        for stale in [false, true] {
            let preparer = try ObjectMaskTestPreparer(changesStamp: stale)
            let budget = AIResourceBudget()
            let service = AIObjectMaskService(budget: budget, preparer: preparer, infer: { _, _, _ in
                stale ? try JSONEncoder().encode(Self.box()) : Data(#"{"summary":"x","name":"x","box":[]}"#.utf8)
            }, segment: { bitmap in
                Issue.record("Invalid or changed source must stop before matting")
                return try Self.opaqueMatte(bitmap)
            })
            if stale {
                await #expect(throws: AIDevelopmentError.staleContext) {
                    _ = try await service.propose(snapshot: Self.snapshot(), instruction: "Blume")
                }
            } else {
                await #expect(throws: AIObjectMaskError.invalidResponse) {
                    _ = try await service.propose(snapshot: Self.snapshot(), instruction: "Blume")
                }
            }
            let lease = try await budget.acquireLocalInference(residentBytes: 5 * 1_024 * 1_024 * 1_024)
            await budget.release(lease)
        }
    }

    @Test func sourceChangeDuringMattingRejectsFrozenLayer() async throws {
        let preparer = try ObjectMaskTestPreparer()
        let service = AIObjectMaskService(preparer: preparer, infer: { _, _, _ in
            try JSONEncoder().encode(Self.box())
        }, segment: { bitmap in
            await preparer.changeSource()
            return try Self.opaqueMatte(bitmap)
        })
        await #expect(throws: AIDevelopmentError.staleContext) {
            _ = try await service.propose(snapshot: Self.snapshot(), instruction: "Blume")
        }
    }

    @Test func missingModelAndEmptyMatteNeverFallBackToBox() async throws {
        let missing = AIObjectMaskService(preparer: try ObjectMaskTestPreparer(), infer: { _, _, _ in
            try JSONEncoder().encode(Self.box())
        }, segment: { _ in throw SubjectMattingError.modelNotInstalled })
        await #expect(throws: SubjectMattingError.modelNotInstalled) {
            _ = try await missing.propose(snapshot: Self.snapshot(), instruction: "Blume")
        }
        let empty = AIObjectMaskService(preparer: try ObjectMaskTestPreparer(), infer: { _, _, _ in
            try JSONEncoder().encode(Self.box())
        }, segment: { bitmap in
            try LocalMaskRaster(width: bitmap.image.width, height: bitmap.image.height,
                bytes: Data(count: bitmap.image.width * bitmap.image.height))
        })
        await #expect(throws: AIObjectMaskError.emptyMask) {
            _ = try await empty.propose(snapshot: Self.snapshot(), instruction: "Blume")
        }
    }

    @Test func masksAtCountLimitRejectBeforePreparation() async throws {
        var settings = EditSettings.neutral
        let layer = try LocalAdjustment(name: "x", mask: LocalAdjustmentMask(shape: .subject(
            LocalMaskRaster(width: 1, height: 1, bytes: Data([255])))))
        settings.localAdjustments = (0..<16).map { _ in var value = layer; value.id = UUID(); return value }
        let preparer = try ObjectMaskTestPreparer()
        let service = AIObjectMaskService(preparer: preparer, infer: { _, _, _ in
            Issue.record("Inference must not start at the count limit"); return Data()
        }, segment: { try Self.opaqueMatte($0) })
        await #expect(throws: AIObjectMaskError.maskLimit) {
            _ = try await service.propose(snapshot: Self.snapshot(settings: settings), instruction: "Blume")
        }
        #expect(await preparer.request == nil)
    }

    @Test func aggregateRasterLimitRejectsNewLayer() async throws {
        let raster = try LocalMaskRaster(width: 2_048, height: 2_048,
            bytes: Data(repeating: 255, count: 2_048 * 2_048))
        var settings = EditSettings.neutral
        settings.localAdjustments = try (0..<4).map { index in
            try LocalAdjustment(name: "Maske \(index)", mask: LocalAdjustmentMask(shape: .subject(raster)))
        }
        _ = try EditingSnapshot(settings: settings)
        let service = AIObjectMaskService(preparer: try ObjectMaskTestPreparer(), infer: { _, _, _ in
            try JSONEncoder().encode(Self.box())
        }, segment: { try Self.opaqueMatte($0) })
        await #expect(throws: AIObjectMaskError.maskLimit) {
            _ = try await service.propose(snapshot: Self.snapshot(settings: settings), instruction: "Blume")
        }
    }

    @Test func cancellationRetainsQwenLeaseUntilNativeReturn() async throws {
        let entered = TestAsyncLatch(), release = TestAsyncLatch()
        defer { release.releaseAll() }
        let budget = AIResourceBudget()
        let service = AIObjectMaskService(budget: budget, preparer: try ObjectMaskTestPreparer(), infer: { _, _, _ in
            entered.releaseAll(); await release.wait()
            return try JSONEncoder().encode(Self.box())
        }, segment: { bitmap in
            Issue.record("Canceled Qwen must not start matting")
            return try Self.opaqueMatte(bitmap)
        })
        let task = Task { try await service.propose(snapshot: Self.snapshot(), instruction: "Blume") }
        await entered.wait(); task.cancel()
        for await state in await budget.stateUpdates() {
            #expect(state.activeInferences == 1 && state.residentModelBytes == 5 * 1_024 * 1_024 * 1_024)
            break
        }
        release.releaseAll()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        for await state in await budget.stateUpdates() {
            #expect(state.activeInferences == 0 && state.residentModelBytes == 0)
            break
        }
    }

    @Test func cancellationRetainsMattingLeaseUntilNativeReturnAfterHandoff() async throws {
        let entered = TestAsyncLatch(), release = TestAsyncLatch()
        defer { release.releaseAll() }
        let budget = AIResourceBudget()
        let matting = AutomaticMaskService(budget: budget, generator: { bitmap, kind, _ in
            #expect(kind == .subject)
            entered.releaseAll(); await release.wait()
            return try Self.opaqueMatte(bitmap)
        })
        let service = AIObjectMaskService(budget: budget, preparer: try ObjectMaskTestPreparer(), infer: { _, _, _ in
            try JSONEncoder().encode(Self.box())
        }, segment: { try await matting.generate($0, kind: .subject) })
        let task = Task { try await service.propose(snapshot: Self.snapshot(), instruction: "Blume") }
        await entered.wait(); task.cancel()
        for await state in await budget.stateUpdates() {
            #expect(state.activeInferences == 1 && state.residentModelBytes == 6 * 1_024 * 1_024 * 1_024)
            break
        }
        release.releaseAll()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        for await state in await budget.stateUpdates() {
            #expect(state.activeInferences == 0 && state.residentModelBytes == 0)
            break
        }
    }

    @Test func projectionKeepsMatteOriginHolesAndFractionalCoverage() throws {
        let matte = try LocalMaskRaster(width: 2, height: 2, bytes: Data([0, 128, 255, 64]))
        let raster = try AIObjectMaskProjection.project(matte, from: CGRect(x: 10, y: 20, width: 2, height: 2), width: 100, height: 100)
        #expect(raster.bytes[20 * 100 + 10] == 0)
        #expect(raster.bytes[20 * 100 + 11] == 128)
        #expect(raster.bytes[21 * 100 + 10] == 255)
        #expect(raster.bytes[21 * 100 + 11] == 64)
        #expect(raster.bytes[22 * 100 + 10] == 0 && raster.bytes[79 * 100 + 10] == 0)
        let bounded = try AIObjectMaskProjection.project(matte,
            from: CGRect(x: 0, y: 0, width: 8_000, height: 4_000), width: 8_000, height: 4_000)
        #expect(bounded.width == 1_024 && bounded.height == 512)
        #expect(bounded.bytes[100 * 1_024 + 800] > 0 && bounded.bytes[100 * 1_024 + 800] < 255)
    }

    @Test func cropPaddingIsRelativeToBoxAndClampedAtImageEdges() async throws {
        let bitmap = await (try ObjectMaskTestPreparer()).bitmap
        let crop = try AIObjectMaskProjection.crop(bitmap, bounds: DevelopCropRect(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(crop.rect == CGRect(x: 0, y: 0, width: 11, height: 6))
    }

    @Test func cancelledProjectionDoesNotProduceMask() async throws {
        let entered = TestAsyncLatch(), start = TestAsyncLatch()
        let task = Task.detached {
            entered.releaseAll(); await start.wait()
            return try AIObjectMaskProjection.project(LocalMaskRaster(width: 1, height: 1, bytes: Data([255])),
                from: CGRect(x: 0, y: 0, width: 1_024, height: 1_024), width: 1_024, height: 1_024)
        }
        await entered.wait(); task.cancel(); start.releaseAll()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    private static func box() throws -> AIObjectMaskProposal {
        try AIObjectMaskProposal(summary: "Blumenstrauß lokalisiert.", name: "Blumenstrauß", box: [100, 100, 600, 400])
    }

    private static func opaqueMatte(_ bitmap: PreviewBitmap) throws -> LocalMaskRaster {
        try LocalMaskRaster(width: bitmap.image.width, height: bitmap.image.height,
            bytes: Data(repeating: 255, count: bitmap.image.width * bitmap.image.height))
    }

    private static func snapshot(settings: EditSettings = .neutral) -> AIEditingSnapshot {
        AIEditingSnapshot(assetID: "object-mask-test", source: .original(.init(
            fileURL: URL(fileURLWithPath: "/tmp/object-mask-test.png"), modifiedAt: .distantPast, fileSize: 1)),
            settings: settings, token: .init(editSessionID: UUID(), editGeneration: 0,
                selectionSessionID: UUID(), selectionGeneration: 0))
    }
}

private actor ObjectMaskTestPreparer: ImageAnalysisPreparing {
    nonisolated let stamp = ImageAnalysisSourceStamp(device: 1, inode: 2, byteCount: 1,
        modifiedSeconds: 0, modifiedNanoseconds: 0, changedSeconds: 0, changedNanoseconds: 0)
    let bitmap: PreviewBitmap
    var changesStamp: Bool
    private(set) var request: ImageAnalysisRequest?
    init(changesStamp: Bool = false) throws {
        self.changesStamp = changesStamp
        let context = try #require(CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8,
            bytesPerRow: 80, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        bitmap = PreviewBitmap(image: try #require(context.makeImage()))
    }
    func changeSource() { changesStamp = true }
    func sourceStamp(for request: ImageAnalysisRequest) async throws -> ImageAnalysisSourceStamp {
        changesStamp ? ImageAnalysisSourceStamp(device: 1, inode: 3, byteCount: 1,
            modifiedSeconds: 0, modifiedNanoseconds: 0, changedSeconds: 0, changedNanoseconds: 0) : stamp
    }
    func prepare(_ request: ImageAnalysisRequest) async throws -> PreparedImageAnalysisInput {
        self.request = request
        return PreparedImageAnalysisInput(bitmap: bitmap, sourceStamp: stamp,
            rasterSHA256: "test", colorProfile: "sRGB", colorProfileSHA256: nil)
    }
}

@Suite("AI object mask native product route")
struct AIObjectMaskNativeTests {
    @Test(.enabled(if: ["GLOWROOM_QWEN_MODEL_PATH", "GLOWROOM_QWEN_MASK_TEST_IMAGE", "GLOWROOM_QWEN_MASK_TEST_OUTPUT"]
        .allSatisfy { ProcessInfo.processInfo.environment[$0]?.isEmpty == false }), .timeLimit(.minutes(3)))
    func installedQwenCreatesReviewArtifactsForExplicitLocalPhoto() async throws {
        let environment = ProcessInfo.processInfo.environment
        let modelPath = try #require(environment["GLOWROOM_QWEN_MODEL_PATH"])
        let imagePath = try #require(environment["GLOWROOM_QWEN_MASK_TEST_IMAGE"])
        let outputPath = try #require(environment["GLOWROOM_QWEN_MASK_TEST_OUTPUT"])
        try #require([modelPath, imagePath, outputPath].allSatisfy { $0.hasPrefix("/") }, "Use explicit absolute paths")
        let imageURL = URL(fileURLWithPath: imagePath)
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        // An explicitly new directory and exclusive file writes protect earlier
        // evaluation results. Private fixture paths are supplied only at runtime.
        try #require(!FileManager.default.fileExists(atPath: outputURL.path), "The output directory must be new")
        let originalBytes = try Data(contentsOf: imageURL)
        defer { #expect((try? Data(contentsOf: imageURL)) == originalBytes, "The original photo must remain byte-identical") }
        let attributes = try FileManager.default.attributesOfItem(atPath: imageURL.path)
        let modifiedAt = try #require(attributes[.modificationDate] as? Date)
        let byteCount = try #require(attributes[.size] as? NSNumber).int64Value
        let snapshot = AIEditingSnapshot(assetID: "explicit-local-object-mask-product-test",
            source: .original(.init(fileURL: imageURL, modifiedAt: modifiedAt, fileSize: byteCount)),
            settings: .neutral, token: .init(editSessionID: UUID(), editGeneration: 0,
                selectionSessionID: UUID(), selectionGeneration: 0))
        let capture = ObjectMaskNativeResponseCapture()
        let service = AIObjectMaskService(infer: { image, prompt, schema in
            let data = try await QwenDevelopmentBackend().propose(modelDirectory: URL(fileURLWithPath: modelPath),
                image: image, prompt: prompt, schema: schema, suppressesWhitespaceRuns: true)
            await capture.record(data)
            return data
        })
        let instruction = environment["GLOWROOM_QWEN_MASK_TEST_INSTRUCTION"]
            ?? "Maskiere den gelben Blumenstrauß im Vordergrund."
        let response = try await service.propose(snapshot: snapshot, instruction: instruction)
        let preview = try #require(response.preview)
        let responseBytes = try #require(await capture.data)
        #expect(response.layer.settings == .neutral)
        try #require(try Data(contentsOf: imageURL) == originalBytes)
        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, preview.image, nil)
        try #require(CGImageDestinationFinalize(destination))
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: false)
        try (png as Data).write(to: outputURL.appendingPathComponent("response.preview.png"), options: .withoutOverwriting)
        try responseBytes.write(to: outputURL.appendingPathComponent("response.json"), options: .withoutOverwriting)
        try ArtifactJSONCodec.encode(response.layer).write(to: outputURL.appendingPathComponent("Layer.json"), options: .withoutOverwriting)
        print("Qwen local object mask review artifacts: \(outputURL.path)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_QWEN_MODEL_PATH"] != nil), .timeLimit(.minutes(3)))
    func installedQwenLocatesAsymmetricSyntheticObject() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["GLOWROOM_QWEN_MODEL_PATH"])
        let width = 256, height = 192
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { storage in
            let bytes = storage.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let dx = (Double(x) / Double(width) - 0.7) / 0.15
                    let dy = (Double(y) / Double(height) - 0.3) / 0.18
                    let oval = dx * dx + dy * dy < 1
                    let square = (25..<80).contains(x) && (115..<165).contains(y)
                    let offset = (y * width + x) * 4
                    bytes[offset] = oval ? 220 : square ? 30 : 220
                    bytes[offset + 1] = oval ? 35 : square ? 160 : 220
                    bytes[offset + 2] = oval ? 35 : square ? 70 : 220
                    bytes[offset + 3] = 255
                }
            }
        }
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let budget = AIResourceBudget.shared
        let lease = try await budget.acquireLocalInference(residentBytes: 5 * 1_024 * 1_024 * 1_024)
        let data: Data
        do {
            data = try await QwenDevelopmentBackend().propose(modelDirectory: URL(fileURLWithPath: path),
                image: image, prompt: AIObjectMaskProposal.prompt(instruction: "Maskiere ausschließlich das rote Oval rechts oben. Der grüne Bereich gehört nicht dazu."),
                schema: AIObjectMaskProposal.schema, suppressesWhitespaceRuns: true)
            await budget.release(lease)
        } catch { await budget.release(lease); throw error }
        print("Qwen object mask smoke: \(String(decoding: data, as: UTF8.self))")
        let proposal = try AIObjectMaskProposal.decode(data)
        let found = proposal.box
        let expected = [550, 120, 850, 480]
        let intersection = max(0, min(found[2], expected[2]) - max(found[0], expected[0]))
            * max(0, min(found[3], expected[3]) - max(found[1], expected[1]))
        let area = (found[2] - found[0]) * (found[3] - found[1])
        let expectedArea = (expected[2] - expected[0]) * (expected[3] - expected[1])
        let iou = Double(intersection) / Double(area + expectedArea - intersection)
        #expect(iou >= 0.6, "The red oval bounding box must overlap its known location, not merely one inside point")
        #expect(found[0] < 700 && found[2] > 700 && found[1] < 300 && found[3] > 300)
        #expect(found[0] > 310 || found[3] < 590, "Exclude the unrelated lower-left green object")
    }
}

private actor ObjectMaskNativeResponseCapture {
    private(set) var data: Data?
    func record(_ data: Data) { self.data = data }
}
