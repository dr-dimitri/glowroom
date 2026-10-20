import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import GlowroomCore
import Testing
import Vision
@testable import Glowroom

@Suite("Automatic local masks", .timeLimit(.minutes(2)))
struct AutomaticMaskTests {
    @Test func floatMaskKeepsTopLeftRowsClampsCoverageAndIgnoresStridePadding() throws {
        let buffer = try floatBuffer(width: 3, height: 2)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for (y, row) in [[Float(-0.1), 0, 0.5], [Float(1), 1.1, 0.25]].enumerated() {
            for (x, value) in row.enumerated() { base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)[x] = value }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let raster = try AutomaticMaskRasterConverter.raster(buffer)
        #expect(raster.width == 3 && raster.height == 2)
        #expect(raster.bytes == Data([0, 0, 128, 255, 255, 64]))
        CVPixelBufferLockBaseAddress(buffer, [])
        base.assumingMemoryBound(to: Float.self)[0] = .nan
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(throws: AutomaticMaskError.invalidMask) { try AutomaticMaskRasterConverter.raster(buffer) }
        #expect(AutomaticMaskRasterConverter.outputSize(width: 6_000, height: 4_000).width == 2_048)
        #expect(AutomaticMaskRasterConverter.outputSize(width: 6_000, height: 4_000).height == 1_365)
    }

    @Test func semanticClassMapUsesOnlyRequestedClassAndRetainsFullNonSquareCanvas() throws {
        let classes = try MLMultiArray(shape: [448, 448], dataType: .int32)
        for y in 0..<448 { for x in 0..<448 { classes[y * 448 + x] = NSNumber(value: y < 224 && x < 112 ? 73 : 1) } }
        let raster = try AutomaticMaskRasterConverter.skyRaster(classes, skyClass: 73, outputSize: (512, 256))
        #expect(raster.width == 512 && raster.height == 256)
        #expect(raster.bytes[20 * 512 + 20] == 255)
        #expect(raster.bytes[20 * 512 + 500] == 0)
        #expect(raster.bytes[240 * 512 + 20] == 0)
        let bad = try MLMultiArray(shape: [1, 448, 448], dataType: .int32)
        #expect(throws: AutomaticMaskError.invalidModel) {
            try AutomaticMaskRasterConverter.skyRaster(bad, skyClass: 73, outputSize: (32, 16))
        }
    }

    @Test func cancellationRetainsSharedLeaseUntilNativeWorkActuallyReturns() async throws {
        let entered = TestStateSignal(0)
        let latch = TestAsyncLatch()
        defer { latch.releaseAll() }
        let budget = AIResourceBudget()
        let service = AutomaticMaskService(budget: budget) { _, _, _ in
            entered.update { $0 += 1 }
            await latch.wait() // A native provider may ignore task cancellation.
            return try LocalMaskRaster(width: 1, height: 1, bytes: Data([255]))
        }
        let bitmap = try fixture()
        let first = Task { try await service.generate(bitmap, kind: .subject) }
        try await entered.wait("first native mask", until: { $0 == 1 })
        first.cancel()
        let next = Task { try await service.generate(bitmap, kind: .sky) }
        try await waitForTestState("queued mask inference", state: {
            var updates = await budget.stateUpdates().makeAsyncIterator()
            return await updates.next()?.waitingInferences ?? -1
        }, until: { $0 == 1 })
        #expect(entered.value == 1)
        latch.releaseAll()
        do { _ = try await first.value; Issue.record("Canceled native result was accepted") }
        catch { #expect(error is CancellationError) }
        #expect(try await next.value.bytes == Data([255]))
        #expect(entered.value == 2)
        var updates = await budget.stateUpdates().makeAsyncIterator()
        #expect(await updates.next()?.activeInferences == 0)
    }

    @Test func unconfiguredSkyDoesNotInventAColorHeuristicMask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glowroom-sky-none-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = AutomaticMaskWorker(skyModelStore: SkyMaskModelStore(directory: root))
        await #expect(throws: AutomaticMaskError.skyModelNotInstalled) {
            try await worker.generate(try fixture(), kind: .sky, sourceURL: nil)
        }
    }

    /// Explicit developer smoke only. Ordinary tests have no network/model
    /// requirement. Run with the already-downloaded, app-pinned source package.
    @Test func approvedNativeSkyModelSmokeWhenExplicitlyConfigured() async throws {
        guard let path = ProcessInfo.processInfo.environment["GLOWROOM_SKY_MODEL_SMOKE_PACKAGE"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glowroom-sky-native-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: path)
        let store = SkyMaskModelStore(directory: root, files: SkyMaskApprovedPackage.files, budget: AIResourceBudget(),
            downloader: { url, destination, _, _ in
                let marker = "DETRResnet50SemanticSegmentationF16.mlpackage/"
                let relative = try #require(url.absoluteString.range(of: marker)).upperBound
                try FileManager.default.copyItem(at: source.appendingPathComponent(String(url.absoluteString[relative...])), to: destination)
            }, compiler: { try MLModel.compileModel(at: $0) })
        let installed = try await store.install()
        let worker = AutomaticMaskWorker(skyModelStore: store)
        let bitmap = try landscapeFixture()
        let start = ContinuousClock.now
        let raster = try await worker.generate(bitmap, kind: .sky, sourceURL: nil)
        let top = raster.bytes.prefix(raster.width * (raster.height / 3)).filter { $0 > 127 }.count
        let bottom = raster.bytes.suffix(raster.width * (raster.height / 3)).filter { $0 > 127 }.count
        print("Native sky smoke: \(raster.width)x\(raster.height), top=\(top), bottom=\(bottom), duration=\(start.duration(to: .now))")
        #expect(top > raster.width * raster.height / 8)
        #expect(bottom < raster.width * raster.height / 12)
        let cpuConfiguration = MLModelConfiguration()
        cpuConfiguration.computeUnits = .cpuOnly
        let cpuModel = try MLModel(contentsOf: installed.directory.appendingPathComponent("model.mlmodelc"), configuration: cpuConfiguration)
        let cpuInput = try MLFeatureValue(cgImage: bitmap.image, pixelsWide: 448, pixelsHigh: 448,
            pixelFormatType: kCVPixelFormatType_32ARGB, options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
        let cpuPrediction = try await cpuModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": cpuInput]))
        let cpuMap = try #require(cpuPrediction.featureValue(for: "semanticPredictions")?.multiArrayValue)
        let cpuRawRaster = try AutomaticMaskRasterConverter.skyRaster(cpuMap,
            skyClass: AutomaticMaskRasterConverter.skyClass(in: cpuModel), outputSize: (raster.width, raster.height))
        let cpuRaster = try AutomaticMaskRefiner.refine(cpuRawRaster, guide: bitmap.image, softwareRenderer: true)
        let intersection = zip(raster.bytes, cpuRaster.bytes).filter { $0.0 > 127 && $0.1 > 127 }.count
        let union = zip(raster.bytes, cpuRaster.bytes).filter { $0.0 > 127 || $0.1 > 127 }.count
        let overlap = Double(intersection) / Double(max(1, union))
        print("Native sky CPU/automatic-device mask IoU: \(overlap)")
        #expect(overlap >= 0.98)
    }

    private func floatBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent32Float,
                                   [kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary, &optional) == kCVReturnSuccess)
        return try #require(optional)
    }

    private func fixture() throws -> PreviewBitmap {
        let context = try #require(CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
        return PreviewBitmap(image: try #require(context.makeImage()))
    }

    private func landscapeFixture() throws -> PreviewBitmap {
        let width = 768, height = 512
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { storage in
            let pixels = storage.bindMemory(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let horizon = 292 + Int(35 * sin(Double(x) / 71))
                let i = (y * width + x) * 4
                if y < horizon {
                    let fraction = Double(y) / 300
                    pixels[i] = UInt8(65 + 85 * fraction); pixels[i + 1] = UInt8(130 + 65 * fraction); pixels[i + 2] = 235
                } else {
                    pixels[i] = 45; pixels[i + 1] = UInt8(80 + (x + y) % 35); pixels[i + 2] = 35
                }
                pixels[i + 3] = 255
            } }
        }
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        return PreviewBitmap(image: try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)))
    }
}
