import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Bounded local repair model service")
struct DevelopRepairAIServiceTests {
    @Test
    func brushMaskKeepsCompletePathAndSourceAspectRatio() throws {
        let mask = try DevelopRepairAIService.brushMask(path: [LocalMaskPoint(x: 0.2, y: 0.3),
            LocalMaskPoint(x: 0.8, y: 0.3)], radius: 0.04, sourceSize: CGSize(width: 1_200, height: 800))
        #expect(mask.width == 256 && mask.height == 171)
        func weight(_ x: Double, _ y: Double) -> UInt8 {
            mask.bytes[min(mask.height - 1, Int(y * Double(mask.height))) * mask.width +
                min(mask.width - 1, Int(x * Double(mask.width)))]
        }
        #expect(weight(0.2, 0.3) == 255)
        #expect(weight(0.5, 0.3) == 255)
        #expect(weight(0.8, 0.3) == 255)
        #expect(weight(0.5, 0.5) == 0)
        #expect(weight(0, 0) == 0)
        // A circular source brush has a narrower normalized horizontal radius.
        #expect(weight(0.18, 0.3) > 128)
        #expect(weight(0.2, 0.335) > 128)
        #expect(weight(0.2, 0.355) == 0)
    }

    @Test
    func invalidBrushAndLargeModelSelectionsFailBeforePrediction() throws {
        #expect(throws: DevelopRepairAIError.invalidMask) {
            try DevelopRepairAIService.brushMask(path: [], radius: 0.03, sourceSize: CGSize(width: 120, height: 80))
        }
        #expect(throws: DevelopRepairAIError.invalidMask) {
            try DevelopRepairAIService.brushMask(path: [LocalMaskPoint(x: 0.5, y: 0.5)], radius: .nan,
                sourceSize: CGSize(width: 120, height: 80))
        }
        #expect(throws: DevelopRepairAIError.invalidMask) {
            try DevelopRepairAIService.brushMask(path: [LocalMaskPoint(x: 0.5, y: 0.5)], radius: 0.03,
                sourceSize: CGSize(width: CGFloat.infinity, height: 80))
        }
        let bitmap = try repairAITestBitmap(width: 120, height: 80)
        #expect(throws: DevelopRepairAIError.invalidMask) {
            try DevelopRepairAIPrepared(bitmap, mask: LocalMaskRaster(width: 8, height: 8, bytes: Data(repeating: 0, count: 64)))
        }
        #expect(throws: DevelopRepairAIError.selectionTooLarge) {
            try DevelopRepairAIPrepared(bitmap, mask: LocalMaskRaster(width: 8, height: 8, bytes: Data(repeating: 255, count: 64)))
        }
        #expect(throws: DevelopRepairAIError.selectionTooLarge) {
            try DevelopRepairAIPrepared(bitmap, mask: LocalMaskRaster(width: 1, height: 1, bytes: Data([255])))
        }
        let wide = try repairAITestBitmap(width: 1_600, height: 40)
        var separated = Data(count: 32 * 4)
        separated[1] = 255; separated[30] = 255
        #expect(throws: DevelopRepairAIError.selectionTooLarge) {
            try DevelopRepairAIPrepared(wide, mask: LocalMaskRaster(width: 32, height: 4, bytes: separated))
        }
    }

    @Test
    func preparedCropKeepsTopLeftCoordinatesAndIndependentAlpha() throws {
        let bitmap = try repairAITestBitmap(width: 120, height: 80, alpha: 128)
        var bytes = Data(count: 12 * 8)
        bytes[1 * 12 + 1] = 255
        let prepared = try DevelopRepairAIPrepared(bitmap, mask: LocalMaskRaster(width: 12, height: 8, bytes: bytes))
        #expect(prepared.width == 32 && prepared.height == 32)
        #expect(prepared.bounds.x == 0 && prepared.bounds.y == 0)
        #expect(prepared.rgba.count == prepared.width * prepared.height * 4)
        #expect(prepared.mask[15 * prepared.width + 15] == 255)
        #expect(prepared.mask[0] == 0)
        #expect(stride(from: 3, to: prepared.rgba.count, by: 4).allSatisfy { prepared.rgba[$0] == 128 })
        // Source RGB is x/y encoded. This detects accidental vertical inversion
        // as well as a second alpha premultiplication in the model transport.
        #expect(abs(Int(prepared.rgba[0]) - 30) <= 1)
        #expect(abs(Int(prepared.rgba[1]) - 40) <= 1)
        #expect(abs(Int(prepared.rgba[(20 * prepared.width + 20) * 4]) - 50) <= 1)
        #expect(abs(Int(prepared.rgba[(20 * prepared.width + 20) * 4 + 1]) - 60) <= 1)
    }

    @Test
    func successfulPredictionFreezesRGBAndRestoresEveryAlphaByte() async throws {
        let fixture = try RepairAIStoreFixture()
        defer { fixture.remove() }
        try await fixture.store.importModel(from: fixture.package)
        let budget = AIResourceBudget()
        let service = DevelopRepairAIService(store: fixture.store, budget: budget, predictor: { _, prepared in
            var bytes = Data(repeating: 240, count: prepared.width * prepared.height * 4)
            for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
            return bytes
        })
        let bitmap = try repairAITestBitmap(width: 80, height: 60, alpha: 64)
        let mask = try DevelopRepairAIService.brushMask(path: [LocalMaskPoint(x: 0.6, y: 0.5)], radius: 0.06,
            sourceSize: CGSize(width: 80, height: 60))
        let output = try await service.replace(bitmap, mask: mask)
        #expect(output.width <= 800 && output.height <= 800)
        #expect(output.bounds.x > 0 && output.bounds.width < 1)
        #expect(output.rgba[0] == 240 && output.rgba[1] == 240 && output.rgba[2] == 240)
        #expect(stride(from: 3, to: output.rgba.count, by: 4).allSatisfy { output.rgba[$0] == 64 })
        var updates = await budget.stateUpdates().makeAsyncIterator()
        let state = await updates.next()
        #expect(state?.activeInferences == 0)
        #expect(state?.residentModelBytes == 0)
    }

    @Test
    func modelContextIncludesFrozenPixelsAndKeepsManualDonorSourceImmutable() async throws {
        let fixture = try RepairAIStoreFixture()
        defer { fixture.remove() }
        try await fixture.store.importModel(from: fixture.package)
        let bitmap = try repairAITestBitmap(width: 80, height: 60, alpha: 128)
        let original = try #require(bitmap.image.dataProvider?.data) as Data
        let bounds = try DevelopCropRect(x: 0.25, y: 0.4, width: 0.2, height: 0.2)
        let replacement = try DevelopRetouchReplacement(bounds: bounds, width: 1, height: 1,
            rgba: Data([15, 210, 70, 255]))
        let donor = try LocalMaskPoint(x: 0.35, y: 0.5), target = try LocalMaskPoint(x: 0.6, y: 0.5)
        let prior = try [
            DevelopRetouchStroke(source: .init(x: 0.1, y: 0.1), target: donor, radius: 0.1,
                mask: .init(width: 8, height: 6, bytes: Data(repeating: 255, count: 48)), replacement: replacement),
            DevelopRetouchStroke(mode: .clone, source: donor, target: target, radius: 0.08, feather: 0, path: [target])
        ]
        let mask = try DevelopRepairAIService.brushMask(path: [target], radius: 0.04, sourceSize: CGSize(width: 80, height: 60))
        let budget = AIResourceBudget(), entered = TestStateSignal(false)
        let service = DevelopRepairAIService(store: fixture.store, budget: budget, predictor: { _, prepared in
            entered.update { $0 = true }
            let x = Int(((target.x - prepared.bounds.x) * 80).rounded())
            let y = Int(((target.y - prepared.bounds.y) * 60).rounded())
            let index = (y * prepared.width + x) * 4
            #expect(prepared.width <= 800 && prepared.height <= 800)
            #expect(abs(Int(prepared.rgba[index]) - 58) <= 2 && abs(Int(prepared.rgba[index + 1]) - 70) <= 2,
                    "The later clone must still use its immutable original donor")
            let frozenX = Int(((0.425 - prepared.bounds.x) * 80).rounded())
            let frozenIndex = (y * prepared.width + frozenX) * 4
            #expect(prepared.rgba[frozenIndex] < 30 && prepared.rgba[frozenIndex + 1] > 190,
                    "The model must also see the earlier accepted green replacement at its stored position")
            #expect(prepared.rgba[index + 3] == 128)
            var states = await budget.stateUpdates().makeAsyncIterator()
            let state = await states.next()
            #expect(state?.activeInferences == 1 && state?.residentModelBytes == DevelopRepairAIService.residentBytes)
            return prepared.rgba
        })
        let output = try await service.replace(bitmap, mask: mask, priorRepairs: prior)
        #expect(entered.value)
        #expect(stride(from: 3, to: output.rgba.count, by: 4).allSatisfy { output.rgba[$0] == 128 })
        let after = try #require(bitmap.image.dataProvider?.data) as Data
        #expect(after == original)
        var states = await budget.stateUpdates().makeAsyncIterator()
        let final = await states.next()
        #expect(final?.activeInferences == 0 && final?.residentModelBytes == 0)
    }

    @Test
    func graphROICropUsesTopLeftSelectionAndKeepsNativeRowsAndAlpha() throws {
        let bitmap = try repairAITestBitmap(width: 120, height: 80, alpha: 128)
        let input = CIImage(cgImage: bitmap.image)
        let replacement = try DevelopRetouchReplacement(bounds: .init(x: 0, y: 0, width: 32.0 / 120, height: 32.0 / 80),
            width: 1, height: 2, rgba: Data([220, 20, 40, 255, 20, 210, 40, 255]))
        let stroke = try DevelopRetouchStroke(source: .init(x: 0.8, y: 0.8), target: .init(x: 0.1, y: 0.1), radius: 0.1,
            mask: .init(width: 12, height: 8, bytes: Data(repeating: 255, count: 96)), replacement: replacement)
        let graph = try DevelopGeometryRenderer.apply(to: input,
            geometry: .init(retouchStrokes: [stroke]), extent: input.extent)
        var weights = Data(count: 12 * 8); weights[1 * 12 + 1] = 255
        let mask = try LocalMaskRaster(width: 12, height: 8, bytes: weights)
        let prepared = try DevelopRepairAIPrepared(bitmap, mask: mask, graph: graph)
        let original = try DevelopRepairAIPrepared(bitmap, mask: mask)
        #expect(prepared.width == 32 && prepared.height == 32)
        #expect(prepared.bounds.x == 0 && prepared.bounds.y == 0)
        #expect(prepared.mask == original.mask)
        let top = (2 * prepared.width + 8) * 4, bottom = (29 * prepared.width + 8) * 4
        #expect(prepared.rgba[top] > 200 && prepared.rgba[top + 1] < 35)
        #expect(prepared.rgba[bottom] < 35 && prepared.rgba[bottom + 1] > 190)
        #expect(stride(from: 3, to: prepared.rgba.count, by: 4).allSatisfy { prepared.rgba[$0] == original.rgba[$0] })
    }

    @Test
    func excessivePriorRepairGraphFailsBeforePredictionAndReleasesItsLease() async throws {
        let fixture = try RepairAIStoreFixture()
        defer { fixture.remove() }
        try await fixture.store.importModel(from: fixture.package)
        let bitmap = try repairAITestBitmap(width: 512, height: 512)
        let target = try LocalMaskPoint(x: 0.6, y: 0.5)
        let prior = try (0..<256).map { _ in
            try DevelopRetouchStroke(source: .init(x: 0.2, y: 0.2), target: target, radius: 0.02, path: [target])
        }
        try DevelopGeometry(retouchStrokes: prior).validate()
        let bytes = try #require(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: .init(retouchStrokes: prior), width: 512, height: 512))
        #expect(bytes > DevelopRepairAIService.maximumPriorGraphBytes)
        let mask = try DevelopRepairAIService.brushMask(path: [target], radius: 0.02, sourceSize: CGSize(width: 512, height: 512))
        let budget = AIResourceBudget(), entered = TestStateSignal(false)
        let service = DevelopRepairAIService(store: fixture.store, budget: budget, predictor: { _, prepared in
            entered.update { $0 = true }; return prepared.rgba
        })
        await #expect(throws: DevelopRepairAIContextError.insufficientMemory) {
            try await service.replace(bitmap, mask: mask, priorRepairs: prior)
        }
        #expect(!entered.value)
        var states = await budget.stateUpdates().makeAsyncIterator()
        let state = await states.next()
        #expect(state?.activeInferences == 0 && state?.residentModelBytes == 0)
    }

    @Test
    func canceledPredictionKeepsBudgetAndRejectsItsLateResult() async throws {
        let fixture = try RepairAIStoreFixture()
        defer { fixture.remove() }
        try await fixture.store.importModel(from: fixture.package)
        let gate = TestAsyncLatch(), entered = TestStateSignal(false)
        defer { gate.releaseAll() }
        let budget = AIResourceBudget()
        let service = DevelopRepairAIService(store: fixture.store, budget: budget, predictor: { _, prepared in
            entered.update { $0 = true }
            await gate.wait()
            return prepared.rgba
        })
        let bitmap = try repairAITestBitmap(width: 80, height: 60)
        let mask = try DevelopRepairAIService.brushMask(path: [LocalMaskPoint(x: 0.5, y: 0.5)], radius: 0.06,
            sourceSize: CGSize(width: 80, height: 60))
        let task = Task { try await service.replace(bitmap, mask: mask) }
        try await entered.wait("local repair prediction entered", until: { $0 })
        task.cancel()
        var updates = await budget.stateUpdates().makeAsyncIterator()
        let busy = await updates.next()
        #expect(busy?.activeInferences == 1)
        #expect(busy?.residentModelBytes == DevelopRepairAIService.residentBytes)
        gate.releaseAll()
        await #expect(throws: CancellationError.self) { try await task.value }
        var finalUpdates = await budget.stateUpdates().makeAsyncIterator()
        let finalState = await finalUpdates.next()
        #expect(finalState?.activeInferences == 0)
    }

    @Test
    func absentModelAndInvalidNativeOutputReleaseAdmission() async throws {
        let fixture = try RepairAIStoreFixture()
        defer { fixture.remove() }
        let budget = AIResourceBudget()
        let service = DevelopRepairAIService(store: fixture.store, budget: budget, predictor: { _, _ in Data() })
        let bitmap = try repairAITestBitmap(width: 80, height: 60)
        let mask = try DevelopRepairAIService.brushMask(path: [LocalMaskPoint(x: 0.5, y: 0.5)], radius: 0.06,
            sourceSize: CGSize(width: 80, height: 60))
        await #expect(throws: DevelopRepairAIError.modelNotInstalled) { try await service.replace(bitmap, mask: mask) }
        try await fixture.store.importModel(from: fixture.package)
        await #expect(throws: DevelopRepairAIError.unavailable) { try await service.replace(bitmap, mask: mask) }
        var updates = await budget.stateUpdates().makeAsyncIterator()
        let state = await updates.next()
        #expect(state?.activeInferences == 0)
    }
}

@Suite("Explicit native local repair inference", .serialized)
struct DevelopRepairAINativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_REPAIR_AI_MODEL"]?.isEmpty == false))
    func importedRealModelRunsTheProductServiceAndPreservesSourceAlpha() async throws {
        let model = try #require(ProcessInfo.processInfo.environment["GLOWROOM_REPAIR_AI_MODEL"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-RepairAI-Native-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = AIResourceBudget()
        let store = DevelopRepairAIModelStore(directory: root, budget: budget)
        let installation = try await store.importModel(from: URL(fileURLWithPath: model))
        #expect(try DevelopRepairAIModelStore.verifyInstallation(installation).count > 1)
        let bitmap = try repairAITestBitmap(width: 80, height: 60, alpha: 128, redObject: true)
        let mask = try DevelopRepairAIService.brushMask(path: [LocalMaskPoint(x: 0.5, y: 0.5)], radius: 0.10,
            sourceSize: CGSize(width: 80, height: 60))
        let prepared = try DevelopRepairAIPrepared(bitmap, mask: mask)
        let service = DevelopRepairAIService(store: store, budget: budget)
        let output = try await service.replace(bitmap, mask: mask)
        #expect(output.bounds == prepared.bounds)
        #expect(output.width == prepared.width && output.height == prepared.height)
        #expect(output.rgba != prepared.rgba, "A real model prediction must produce different RGB pixels")
        #expect(stride(from: 3, to: output.rgba.count, by: 4).allSatisfy { output.rgba[$0] == prepared.rgba[$0] })
        let selectedPixels = prepared.mask.indices.filter { prepared.mask[$0] >= 128 }
        let meanChange = selectedPixels.reduce(0.0) { sum, index in
            sum + abs(Double(output.rgba[index * 4]) - Double(prepared.rgba[index * 4]))
        } / Double(selectedPixels.count)
        #expect(meanChange > 10, "The marked red test object must be changed by actual native inference")
        var geometry = DevelopGeometry()
        geometry.retouchStrokes = [try DevelopRetouchStroke(source: LocalMaskPoint(x: 0.2, y: 0.2),
            target: LocalMaskPoint(x: 0.5, y: 0.5), radius: 0.10, feather: 0, mask: mask, replacement: output)]
        let input = CIImage(cgImage: bitmap.image)
        let rendered = try DevelopGeometryRenderer.apply(to: input, geometry: geometry, extent: input.extent)
        let context = CIContext(options: [.cacheIntermediates: false])
        func renderedPixels(_ image: CIImage) -> Data {
            var bytes = Data(count: bitmap.image.width * bitmap.image.height * 4)
            bytes.withUnsafeMutableBytes { storage in
                context.render(image, toBitmap: storage.baseAddress!, rowBytes: bitmap.image.width * 4,
                    bounds: input.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
            return bytes
        }
        let before = renderedPixels(input), after = renderedPixels(rendered)
        for index in mask.bytes.indices {
            #expect(after[index * 4 + 3] == before[index * 4 + 3], "Model repairs must preserve every native source alpha byte")
            if mask.bytes[index] == 0 {
                #expect(after[index * 4..<index * 4 + 4] == before[index * 4..<index * 4 + 4],
                    "Model predictions must not alter unmasked native pixels")
            }
        }
        #expect(after != before)
        // Exercise the actual product color path with the same frozen pixels,
        // including preview materialization and the full-size export graph.
        let color = DevelopColorSettings(temperature: 8_500, tint: -15)
        let productSettings = EditSettings(exposure: 0.35, developColor: color, developGeometry: geometry)
        let productPreview = try EditRenderer.render(bitmap, settings: productSettings).image
        let productGraph = try EditRenderer.filterGraph(bitmap.image, settings: productSettings)
        let productExport = try #require(EditRenderer.maskCompositingContext().createCGImage(productGraph,
            from: productGraph.extent, format: .RGBA8, colorSpace: bitmap.image.colorSpace!, deferred: false))
        #expect(productPreview.width == bitmap.image.width && productPreview.height == bitmap.image.height)
        #expect(productExport.width == bitmap.image.width && productExport.height == bitmap.image.height)
        let previewBytes = renderedPixels(CIImage(cgImage: productPreview))
        let exportBytes = renderedPixels(CIImage(cgImage: productExport))
        #expect(zip(previewBytes, exportBytes).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
        let colorOnly = renderedPixels(try EditRenderer.filterGraph(bitmap.image,
            settings: .init(exposure: productSettings.exposure, developColor: color)))
        for index in mask.bytes.indices {
            #expect(previewBytes[index * 4 + 3] == before[index * 4 + 3])
            if mask.bytes[index] == 0 {
                #expect(zip(previewBytes[index * 4..<index * 4 + 4], colorOnly[index * 4..<index * 4 + 4])
                    .allSatisfy { abs(Int($0) - Int($1)) <= 1 })
            }
        }
        #expect(mask.bytes.indices.filter { mask.bytes[$0] >= 128 }.contains { index in
            (0..<3).contains { abs(Int(previewBytes[index * 4 + $0]) - Int(colorOnly[index * 4 + $0])) > 2 }
        }, "The real frozen model output must remain visible through the product renderer")
        if let path = ProcessInfo.processInfo.environment["GLOWROOM_REPAIR_AI_REPORT"] {
            let report = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
            try writeRepairAINativePNG(bitmap.image, to: report.appendingPathComponent("source.png"))
            let composed = try #require(context.createCGImage(rendered, from: input.extent))
            try writeRepairAINativePNG(composed, to: report.appendingPathComponent("repaired.png"))
            try writeRepairAINativePNG(productPreview, to: report.appendingPathComponent("product-preview.png"))
            try writeRepairAINativePNG(productExport, to: report.appendingPathComponent("product-export.png"))
            let summary = "Imported model identity: \(installation.identity)\nROI: \(output.width) × \(output.height)\nSelected red mean change: \(meanChange)\nNative alpha and zero-mask pixels preserved.\nEditRenderer preview and native export graph agree after exposure and white balance; outside-mask pixels preserve the corresponding color-only render.\nThis small synthetic probe is not a general image-quality approval.\n"
            try Data(summary.utf8).write(to: report.appendingPathComponent("result.txt"))
        }
        // This proves actual product transport, inference and composition. It
        // does not grant the broader image-generation quality capabilities.
        print("Local repair native model: \(installation.identity); ROI \(output.width)×\(output.height); selected red mean change \(meanChange)")
    }
}

private func writeRepairAINativePNG(_ image: CGImage, to url: URL) throws {
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

private func repairAITestBitmap(width: Int, height: Int, alpha: UInt8 = 255, redObject: Bool = false) throws -> PreviewBitmap {
    var pixels = Data(count: width * height * 4)
    for y in 0..<height { for x in 0..<width {
        let index = (y * width + x) * 4
        pixels[index] = UInt8((30 + x) % 220)
        pixels[index + 1] = UInt8((40 + y) % 220)
        pixels[index + 2] = 90
        pixels[index + 3] = alpha
        if redObject, abs(x - width / 2) <= 4 && abs(y - height / 2) <= 4 {
            pixels[index] = 230; pixels[index + 1] = 15; pixels[index + 2] = 15
        }
    } }
    let provider = try #require(CGDataProvider(data: pixels as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    return PreviewBitmap(image: image)
}
