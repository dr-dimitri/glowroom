import CoreGraphics
import Darwin
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

// Real raster checks run serially so they do not benchmark competing CI work.
@Suite("Look preview raster and UI reference budgets", .serialized, .timeLimit(.minutes(3)))
struct AILookPreviewTests {
    @Test
    func hardOutputLimitIncludesNeutralAndCacheIdentityUsesActualSize() async throws {
        let source = try lookFixture(width: 2_401, height: 1_601)
        let calls = LookRenderProbe()
        let pipeline = AdjustedPreviewPipeline(renderer: { try calls.render($0, settings: $1) })
        let request = lookRequest()
        let neutral = try await pipeline.image(source, request: request, settings: .neutral,
                                               maximumOutputPixelSize: 512)
        #expect(neutral.image.width == 512)
        #expect(neutral.image.height == 341)
        #expect(calls.count == 0) // Neutral resamples once, without a filter pass.
        let sameNeutral = try await pipeline.image(source, request: request, settings: .neutral,
                                                   maximumOutputPixelSize: 512)
        #expect(sameNeutral.image === neutral.image)
        let target = EditSettings(shadows: 30)
        let card = try await pipeline.image(source, request: request, settings: target,
                                            maximumOutputPixelSize: 512)
        let reused = try await pipeline.image(source, request: lookRequest(pixelSize: 512), settings: target,
                                              priority: .selected, maximumOutputPixelSize: 512)
        #expect(card.image === reused.image)
        #expect(calls.sizes == [[512, 341]])
        let large = try await pipeline.image(source, request: request, settings: target,
                                             priority: .selected, maximumOutputPixelSize: 2_400)
        #expect(large.image.width == 2_400)
        #expect(large.image.height <= 2_400)
        #expect(calls.count == 2)
        let smallSource = try lookFixture(width: 200, height: 101)
        let noUpscale = try await pipeline.image(smallSource, request: request, settings: .neutral,
                                                 maximumOutputPixelSize: 512)
        #expect(noUpscale.image === smallSource.image)
        #expect(await pipeline.state().cachedBytes <= 32 * 1_024 * 1_024)
    }

    @Test
    func resizingPreservesProfileAlphaAndAsymmetricGeometry() async throws {
        let input = try lookFixture(width: 768, height: 384, p3: true, asymmetric: true)
        let pipeline = AdjustedPreviewPipeline()
        let output = try await pipeline.image(input, request: lookRequest(), settings: .neutral,
                                              maximumOutputPixelSize: 512)
        #expect(output.image.width == 512)
        #expect(output.image.height == 256)
        #expect(output.image.colorSpace?.name == input.image.colorSpace?.name)
        let before = try sampleCorners(input.image)
        let after = try sampleCorners(output.image)
        // Samples are well inside four different quadrants; resampling may
        // round colors by one byte, but must not rotate/mirror or drop alpha.
        for (a, b) in zip(before, after) {
            for channel in 0..<4 { #expect(abs(Int(a[channel]) - Int(b[channel])) <= 2) }
        }
    }

    @Test(arguments: [false, true])
    func sixteenBitSDRAndGrayscaleUseTheExistingPreviewColorContract(grayscale: Bool) async throws {
        let input = try sixteenBitLookFixture(grayscale: grayscale)
        let pipeline = AdjustedPreviewPipeline()
        let output = try await pipeline.image(input, request: lookRequest(), settings: .neutral,
                                              maximumOutputPixelSize: 128)
        #expect(output.image.width == 128)
        #expect(output.image.height == 64)
        #expect(output.image.bitsPerComponent == 16)
        #expect(output.image.colorSpace?.model == input.image.colorSpace?.model)
        #expect(output.image.colorSpace?.name == input.image.colorSpace?.name)
        let before = try sampleCorners(input.image)
        let after = try sampleCorners(output.image)
        for (a, b) in zip(before, after) {
            for channel in 0..<4 { #expect(abs(Int(a[channel]) - Int(b[channel])) <= 2) }
        }
        // This checks 16-bit SDR, matching the preexisting renderer format.
        // It is not a claim to preserve arbitrary floating-point/HDR ranges.
    }

    @Test
    func downsampledSemitransparentEdgeKeepsPremultiplicationWithoutDarkFringes() async throws {
        let width = 513
        let height = 129
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let alpha = UInt8(x * 255 / (width - 1))
                let offset = (y * width + x) * 4
                pixels[offset] = alpha // Pure red, premultiplied by smooth alpha.
                pixels[offset + 3] = alpha
            }
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let pipeline = AdjustedPreviewPipeline()
        let result = try await pipeline.image(PreviewBitmap(image: image), request: lookRequest(),
                                              settings: .neutral, maximumOutputPixelSize: 128)
        let context = try #require(CGContext(data: nil, width: result.image.width, height: result.image.height,
            bitsPerComponent: 8, bytesPerRow: result.image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(result.image, in: CGRect(x: 0, y: 0, width: result.image.width, height: result.image.height))
        let output = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for x in 0..<result.image.width {
            let offset = (result.image.height / 2) * context.bytesPerRow + x * 4
            let alpha = Int(output[offset + 3])
            #expect(abs(Int(output[offset]) - alpha) <= 2)
            #expect(output[offset + 1] <= 1 && output[offset + 2] <= 1)
            #expect(abs(alpha - x * 255 / (result.image.width - 1)) <= 2)
        }
    }

    @Test @MainActor
    func cardsShareExistingDevelopedBaseAndEnforceBytesIncludingViewReferences() async throws {
        let source = try lookFixture(width: 1_024, height: 512)
        let decoder = LookDecodeProbe(source)
        let imagePipeline = ImagePreviewPipeline(concurrencyLimit: 1, decoder: { decoder.decode($0) })
        let calls = LookRenderProbe()
        let renders = AdjustedPreviewPipeline(maximumConcurrentRenders: 1,
                                              priorityRenderer: { try calls.render($0, settings: $1, priority: $2) })
        let request = lookRequest()
        _ = try await imagePipeline.image(for: request, priority: .selected)
        // ImagePreviewPipeline may return this larger cached base for a small
        // request. The card service must downsample the actual raster itself.
        let cached = try await imagePipeline.image(for: lookRequest(pixelSize: 512), priority: .thumbnail)
        #expect(cached.image.width == 1_024)
        let small = try EditRenderer.resized(source, width: 512, height: 256, priority: .thumbnail)
        let store = AILookCardStore(imagePipeline: imagePipeline, renderPipeline: renders,
                                   maximumBytes: small.byteCost * 2, maximumCards: 2,
                                   observesMemoryPressure: false)
        let group = lookGroup()
        store.begin(group: group, selectedID: .natural)
        try await lookWait { store.pendingIDs.isEmpty && store.cardCount == 2 }
        #expect(store.cardByteCount <= small.byteCost * 2)
        #expect(store.bitmap(for: .natural) != nil)
        #expect(store.bitmaps.values.allSatisfy { max($0.image.width, $0.image.height) <= 512 })
        #expect(decoder.count == 1)
        #expect(calls.count == 3)
        #expect(calls.backgroundCount == 3)
        // A card view carries only the store reference and ID, never its own
        // bitmap. The same actual byteCost accounts for every retained raster.
        let view = AILookCardImage(store: store, id: .natural)
        #expect(view.store === store)
        #expect(store.cardByteCount == store.bitmaps.values.reduce(0) { $0 + $1.byteCost })
        let missing = try #require(AILookID.allCases.first { store.bitmap(for: $0) == nil })
        store.select(id: missing)
        try await lookWait { store.bitmap(for: missing) != nil && store.pendingIDs.isEmpty }
        #expect(store.cardCount == 2)
        #expect(store.cardByteCount <= small.byteCost * 2)
        #expect(calls.count == 3) // Lazy reattachment hits the existing render cache.
        for index in 0..<10 { store.select(id: AILookID.allCases[index % 3]) }
        try await lookWait { store.pendingIDs.isEmpty }
        #expect(decoder.count == 1)
        #expect(calls.count == 3)
        store.handleMemoryPressure()
        #expect(store.cardCount == 0)
        #expect(store.cardByteCount == 0)
        #expect(store.pendingIDs.isEmpty)
        #expect(store.groupID == group.request.id)
        store.select(id: .contrasty)
        try await lookWait { store.bitmap(for: .contrasty) != nil }
        store.clear()
        #expect(store.groupID == nil)
        #expect(store.cardCount == 0)
        #expect(store.cardByteCount == 0)
    }

    @Test @MainActor
    func defaultBudgetRejectsOversizedRasterReferencesAndCannotBeRaised() async throws {
        let source = try lookFixture(width: 32, height: 24)
        // A valid CGImage with deliberately padded scanlines proves that bytes,
        // not width*height*4 assumptions, determine the UI reference budget.
        let padded = try lookFixture(width: 512, height: 128, rowBytes: 131_072)
        #expect(padded.byteCost > AILookCardStore.maximumCardBytes)
        let images = ImagePreviewPipeline(decoder: { _ in source })
        let renders = AdjustedPreviewPipeline(renderer: { _, _ in padded })
        let store = AILookCardStore(imagePipeline: images, renderPipeline: renders,
                                   maximumBytes: Int.max, maximumCards: Int.max,
                                   observesMemoryPressure: false)
        store.begin(group: lookGroup(), selectedID: .natural)
        try await lookWait { store.pendingIDs.isEmpty && store.errors.count == 3 }
        #expect(store.cardByteCount == 0)
        #expect(store.cardCount == 0)
        #expect(AILookCardStore.maximumCardBytes == 8 * 1_024 * 1_024)
        #expect(AILookCardStore.maximumCardCount == 3)
        #expect(store.errors.values.allSatisfy { $0.contains("Speicherlimit") })
        store.clear()
    }

    @Test @MainActor
    func twentyRapidGroupsReleaseStaleReferencesAndBoundQueuedWork() async throws {
        let source = try lookFixture(width: 64, height: 32)
        let decodes = LookDecodeProbe(source)
        let images = ImagePreviewPipeline(concurrencyLimit: 1, decoder: { decodes.decode($0) })
        let probe = LookRenderProbe(blocking: true)
        defer { probe.release() }
        let renders = AdjustedPreviewPipeline(maximumConcurrentRenders: 1,
                                              renderer: { try probe.render($0, settings: $1) })
        let store = AILookCardStore(imagePipeline: images, renderPipeline: renders, observesMemoryPressure: false)
        store.begin(group: lookGroup(index: 0), selectedID: .natural)
        try await lookWait { probe.count == 1 }
        var latest = lookGroup(index: 1)
        for index in 1...20 {
            latest = lookGroup(index: index)
            store.begin(group: latest, selectedID: .natural)
            await Task.yield()
        }
        try await lookWait {
            let state = await renders.state()
            return state.queuedCount == 3 && state.waiterCount == 3
        }
        #expect(store.groupID == latest.request.id)
        #expect(store.cardCount == 0)
        #expect(probe.count == 1)
        probe.release()
        try await lookWait { store.cardCount == 3 && store.pendingIDs.isEmpty }
        #expect(store.groupID == latest.request.id)
        #expect(probe.count == 4)
        #expect(decodes.count == 1)
        #expect(await renders.state().queuedCount == 0)
        store.clear()
        #expect(store.cardCount == 0)
        #expect(store.pendingIDs.isEmpty)
    }

    @Test @MainActor
    func clearingCardsPreservesAnotherObserverOfTheSameRender() async throws {
        let source = try lookFixture(width: 64, height: 32)
        let images = ImagePreviewPipeline(decoder: { _ in source })
        let probe = LookRenderProbe(blocking: true)
        defer { probe.release() }
        let renders = AdjustedPreviewPipeline(maximumConcurrentRenders: 1,
                                              renderer: { try probe.render($0, settings: $1) })
        let group = lookGroup()
        let natural = try #require(group.validation.variants.first { $0.proposal.id == .natural })
        let observer = Task {
            try await renders.image(source, request: lookRequest(), settings: natural.target,
                                    maximumOutputPixelSize: 512)
        }
        try await lookWait { probe.count == 1 }
        let store = AILookCardStore(imagePipeline: images, renderPipeline: renders, observesMemoryPressure: false)
        store.begin(group: group, selectedID: .natural)
        try await lookWait { await renders.state().waiterCount == 4 }
        store.clear()
        try await lookWait {
            let state = await renders.state()
            return state.waiterCount == 1 && state.queuedCount == 0
        }
        probe.release()
        _ = try await observer.value
        #expect(probe.count == 1)
        #expect(store.cardCount == 0)
    }

    @Test @MainActor
    func memoryPressureDuringRenderingCannotPublishTheLateCard() async throws {
        let source = try lookFixture(width: 64, height: 32)
        let images = ImagePreviewPipeline(decoder: { _ in source })
        let probe = LookRenderProbe(blocking: true)
        defer { probe.release() }
        let renders = AdjustedPreviewPipeline(maximumConcurrentRenders: 1,
                                              renderer: { try probe.render($0, settings: $1) })
        let store = AILookCardStore(imagePipeline: images, renderPipeline: renders, observesMemoryPressure: false)
        store.begin(group: lookGroup(), selectedID: .natural)
        try await lookWait { probe.count == 1 }
        store.handleMemoryPressure()
        try await lookWait { await renders.state().waiterCount == 0 }
        #expect(await renders.state().runningBackground == 1)
        probe.release()
        try await lookWait { await renders.state().runningBackground == 0 }
        #expect(store.cardCount == 0)
        #expect(store.pendingIDs.isEmpty)
        store.clear()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PICEDIT_RUN_LOOK_PREVIEW_BENCHMARK"] == "1"))
    @MainActor
    func synthetic2400PixelFirstAndWarmCacheBenchmark() async throws {
        let source = try lookFixture(width: 2_400, height: 1_600, asymmetric: true)
        let decodes = LookDecodeProbe(source)
        let images = ImagePreviewPipeline(concurrencyLimit: 1, decoder: { decodes.decode($0) })
        let probe = LookRenderProbe(actualRendering: true)
        let renders = AdjustedPreviewPipeline(maximumConcurrentRenders: 2,
                                              priorityRenderer: { try probe.render($0, settings: $1, priority: $2) })
        let store = AILookCardStore(imagePipeline: images, renderPipeline: renders, observesMemoryPressure: false)
        let group = lookGroup()
        for phase in ["first-render-caches", "warm-render-caches"] {
            let beforeDecodes = decodes.count
            let beforeRenders = probe.count
            let beforeBackgroundRenders = probe.backgroundCount
            let started = ProcessInfo.processInfo.systemUptime
            let base = try await images.image(for: lookRequest(), priority: .selected)
            let activeStart = ProcessInfo.processInfo.systemUptime
            _ = try await renders.image(base, request: lookRequest(), settings: group.validation.variants[0].target,
                                         priority: .selected, maximumOutputPixelSize: 2_400)
            let activeTime = ProcessInfo.processInfo.systemUptime - activeStart
            store.begin(group: group, selectedID: .natural)
            try await lookWait { store.cardCount == 3 && store.pendingIDs.isEmpty }
            let cardsReady = ProcessInfo.processInfo.systemUptime - started
            for index in 0..<10 {
                let look = group.validation.variants[index % 3]
                store.select(id: look.proposal.id)
                // Only this local return/current display is large. Never keep
                // a three-element array of large variant bitmap references.
                let active = try await renders.image(base, request: lookRequest(), settings: look.target,
                    priority: .selected, maximumOutputPixelSize: 2_400)
                #expect(max(active.image.width, active.image.height) <= 2_400)
            }
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let total = ProcessInfo.processInfo.systemUptime - started
            print("Look benchmark \(phase): active=\(activeTime)s cards-ready=\(cardsReady)s total10switches=\(total)s decodes=\(decodes.count-beforeDecodes) filter-renders=\(probe.count-beforeRenders) background-filter-renders=\(probe.backgroundCount-beforeBackgroundRenders) UI-card-bytes=\(store.cardByteCount) process-high-water-RSS=\(usage.ru_maxrss) bytes")
            #expect(store.cardCount <= 3)
            #expect(store.cardByteCount <= 8 * 1_024 * 1_024)
            store.clear()
        }
        #expect(decodes.count == 1)
        // These are synthetic filter measurements. No model was invoked;
        // ru_maxrss includes both phases, not incremental card/model memory.
    }
}

private let lookPreviewURL = URL(fileURLWithPath: "/tmp/look-preview-synthetic.raw")

private func lookRequest(pixelSize: Int = 2_400) -> PreviewRequest {
    PreviewRequest(url: lookPreviewURL,
                   modifiedAt: Date(timeIntervalSince1970: 123), pixelSize: pixelSize,
                   fileSize: 100, allowsEmbeddedPreview: false)
}

private func lookGroup(index: Int = 0) -> AILookGroupResult {
    let baseline = EditSettings.neutral
    let request = AIEditingRequest(prompt: "", snapshot: AIEditingSnapshot(assetID: "synthetic",
        source: .original(AIOriginalSourceFingerprint(fileURL: lookPreviewURL,
            modifiedAt: lookRequest().modifiedAt, fileSize: 100)), settings: baseline,
        token: AIEditingToken(editSessionID: UUID(), editGeneration: UInt64(index),
                              selectionSessionID: UUID(), selectionGeneration: 0)), mode: .lookGroup)
    let values: [EditSettings] = [EditSettings(shadows: Double(10 + index)),
                                 EditSettings(contrast: Double(20 + index)),
                                 EditSettings(saturation: Double(-30 - index))]
    let variants = zip(AILookID.allCases, values).map { id, target in
        let parameter: EditParameter = id == .natural ? .shadows : id == .contrasty ? .contrast : .saturation
        let proposal = EditProposal(changes: [.init(parameter: parameter, value: parameter.value(in: target))])
        return AIValidatedLook(proposal: AILookProposal(id: id, name: id.rawValue, proposal: proposal), target: target)
    }
    return AILookGroupResult(request: request, validation: AIValidatedLookGroup(variants: variants))
}

private func lookFixture(width: Int, height: Int, p3: Bool = false,
                         asymmetric: Bool = false, rowBytes: Int? = nil) throws -> PreviewBitmap {
    let space = try #require(CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: rowBytes ?? width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    if asymmetric {
        let colors: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0.8,0.1,0.1,1), (0.1,0.8,0.1,0.5),
                                                              (0.1,0.1,0.8,0.75), (0.8,0.7,0.1,0)]
        for (index, color) in colors.enumerated() {
            context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: color.3)
            context.fill(CGRect(x: index % 2 * width / 2, y: index / 2 * height / 2,
                                width: width / 2, height: height / 2))
        }
    } else {
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 0.7)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    return PreviewBitmap(image: try #require(context.makeImage()))
}

private func sampleCorners(_ image: CGImage) throws -> [[UInt8]] {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    return [(1,1), (3,1), (1,3), (3,3)].map { x, y in
        let offset = (image.height * y / 4) * context.bytesPerRow + (image.width * x / 4) * 4
        return (0..<4).map { bytes[offset + $0] }
    }
}

private func sixteenBitLookFixture(grayscale: Bool) throws -> PreviewBitmap {
    let width = 384
    let height = 192
    let channels = grayscale ? 2 : 4
    let rowBytes = width * channels * 2
    var values = [UInt16](repeating: 0, count: width * height * channels)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * channels
            let alpha: UInt16 = x < width / 2 ? 65_535 : 32_768
            let tone: UInt16 = y < height / 2 ? 10_000 : 25_000
            values[offset] = tone
            if !grayscale {
                values[offset + 1] = tone / 2
                values[offset + 2] = tone / 3
            }
            values[offset + channels - 1] = alpha
        }
    }
    let data = values.withUnsafeBytes { Data($0) }
    let provider = try #require(CGDataProvider(data: data as CFData))
    let space = try #require(CGColorSpace(name: grayscale ? CGColorSpace.genericGrayGamma2_2 : CGColorSpace.sRGB))
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 16,
        bitsPerPixel: channels * 16, bytesPerRow: rowBytes, space: space, bitmapInfo: info,
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    return PreviewBitmap(image: image)
}

@MainActor
private func lookWait(_ condition: @escaping @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw LookTestError.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum LookTestError: Error { case timeout }

private final class LookDecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let source: PreviewBitmap
    init(_ source: PreviewBitmap) { self.source = source }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func decode(_ request: PreviewRequest) -> PreviewBitmap {
        lock.lock(); calls += 1; lock.unlock()
        return source
    }
}

private final class LookRenderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [[Int]] = []
    private var priorities: [PreviewPriority] = []
    private var blocked: Bool
    private var gates: [DispatchSemaphore] = []
    private let actualRendering: Bool
    init(blocking: Bool = false, actualRendering: Bool = false) {
        blocked = blocking
        self.actualRendering = actualRendering
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return inputs.count }
    var sizes: [[Int]] { lock.lock(); defer { lock.unlock() }; return inputs }
    var backgroundCount: Int { lock.lock(); defer { lock.unlock() }; return priorities.filter { $0 == .thumbnail }.count }
    func release() {
        lock.lock()
        blocked = false
        let current = gates
        gates.removeAll()
        lock.unlock()
        for gate in current { gate.signal() }
    }
    func render(_ source: PreviewBitmap, settings: EditSettings, priority: PreviewPriority = .selected) throws -> PreviewBitmap {
        let gate = DispatchSemaphore(value: 0)
        lock.lock()
        inputs.append([source.image.width, source.image.height])
        priorities.append(priority)
        let shouldBlock = blocked
        if shouldBlock { gates.append(gate) }
        lock.unlock()
        if shouldBlock, gate.wait(timeout: .now() + 15) == .timedOut { throw LookTestError.timeout }
        return actualRendering ? try EditRenderer.render(source, settings: settings, priority: priority) : source
    }
}
