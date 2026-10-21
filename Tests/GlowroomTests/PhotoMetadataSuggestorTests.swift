import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Metadata and image analysis share one actual worker", .timeLimit(.minutes(1)))
struct PhotoMetadataSuggestorTests {
    @Test func metadataWaitsForActualCanceledVisionReturnAndPerformsOneTypedRequest() async throws {
        let provider = MetadataVisionProvider()
        await provider.setAnalysisBlocked(true)
        let budget = AIResourceBudget()
        let service = ImageAnalysisService(provider: provider, preparer: MetadataVisionPreparer(), budget: budget)
        let analysis = metadataAnalysisRequest()
        let first = Task { try await service.analyze(analysis) }
        try await wait { await provider.analysisCalls == 1 }
        let context = PhotoMetadataSelectionContext(assetID: analysis.snapshot.assetID,
            source: metadataVisionSource(), selectionSessionID: analysis.snapshot.token.selectionSessionID,
            selectionGeneration: 1, catalogSessionID: analysis.snapshot.token.editSessionID, catalogGeneration: 1,
            canModify: true, isClosing: false)
        let request = PhotoMetadataSuggestionRequest(context: context, lifecycleID: UUID(), formGeneration: 0, expectedVersion: .absent)
        let suggestor = LocalPhotoMetadataSuggestor(service: service)
        let next = Task { try await suggestor.suggest(request) }
        try await wait {
            var iterator = await service.stateUpdates().makeAsyncIterator()
            return await iterator.next()?.queuedCount == 1
        }
        #expect(await provider.metadataCalls == 0)
        var states = await budget.stateUpdates().makeAsyncIterator()
        #expect(await states.next()?.activeInferences == 1)
        await provider.releaseAnalysis()
        let result = try await next.value
        _ = await first.result
        #expect(result.request.id == request.id)
        #expect(result.fields.title == "Synthetisches Motiv")
        #expect(result.source.original == .metadata(context.source))
        #expect(result.source.analyzedRaster?.metadataPromptVersion == 1)
        #expect(result.source.analyzedRaster?.inputKind == .originalPreview)
        #expect(await provider.metadataCalls == 1)
        #expect(await provider.maximumActive == 1)
        var completed = await budget.stateUpdates().makeAsyncIterator()
        #expect(await completed.next()?.activeInferences == 0)
    }

    @Test func explicitFreshnessMissesAnalysisDecodeAndRenderDespiteIdenticalNativeStamp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-fresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.raw")
        try Data([1, 2, 3, 4]).write(to: url)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let source = AIOriginalSourceFingerprint(fileURL: url, modifiedAt: try #require(values.contentModificationDate), fileSize: Int64(try #require(values.fileSize)))
        let token = AIEditingToken(editSessionID: UUID(), editGeneration: 1, selectionSessionID: UUID(), selectionGeneration: 1)
        let snapshot = AIEditingSnapshot(assetID: url.path, source: .original(source), settings: EditSettings(exposure: 0.2), token: token)
        let lifecycle = UUID()
        let normal = ImageAnalysisRequest(snapshot: snapshot, inputKind: .editedPreview, lifecycleID: lifecycle)
        let freshA = ImageAnalysisRequest(snapshot: snapshot, inputKind: .editedPreview, lifecycleID: lifecycle, cachePolicy: .refreshRaster)
        let freshB = ImageAnalysisRequest(snapshot: snapshot, inputKind: .editedPreview, lifecycleID: lifecycle, cachePolicy: .refreshRaster)
        let probe = MetadataFreshRasterProbe()
        let decoder = ImagePreviewPipeline(concurrencyLimit: 1, decoder: { try probe.decode($0) })
        let renderer = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, renderer: { image, _ in probe.render(image) })
        let preparer = ImageAnalysisPreparer(imagePipeline: decoder, renderPipeline: renderer)
        let provider = MetadataVisionProvider()
        let service = ImageAnalysisService(provider: provider, preparer: preparer, budget: AIResourceBudget())
        let before = try await preparer.sourceStamp(for: normal)
        _ = try await service.analyze(normal)
        _ = try await service.analyze(normal)
        #expect(probe.decodeCount == 1 && probe.renderCount == 1)
        _ = try await service.analyze(freshA)
        _ = try await service.analyze(freshB)
        #expect(try await preparer.sourceStamp(for: normal) == before)
        #expect(probe.decodeCount == 3 && probe.renderCount == 3)
        #expect(Set(probe.revisions.compactMap { $0 }).count == 3)
        #expect(await provider.analysisCalls == 3)
    }

    @Test func actualSuggestorSourceWithOptionalNativeEvidenceMissingIsAcceptedByRealStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-source-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.raw")
        try Data([1, 2, 3, 4]).write(to: url)
        let attributes = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let asset = PhotoAsset(folderID: UUID(), fileURL: url,
            fileSize: Int64(try #require(attributes.fileSize)), modifiedAt: try #require(attributes.contentModificationDate))
        let source = AIOriginalSourceFingerprint(fileURL: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize)
        let session = UUID()
        let context = PhotoMetadataSelectionContext(assetID: asset.id, source: source, selectionSessionID: UUID(),
            selectionGeneration: 1, catalogSessionID: session, catalogGeneration: 1, canModify: true, isClosing: false)
        let preparer = ImageAnalysisPreparer(imagePipeline: ImagePreviewPipeline(decoder: { _ in try metadataVisionRaster() }),
            renderPipeline: AdjustedPreviewPipeline(renderer: { image, _ in image }))
        let service = ImageAnalysisService(provider: MetadataVisionProvider(), preparer: preparer, budget: AIResourceBudget())
        let suggested = try await LocalPhotoMetadataSuggestor(service: service).suggest(
            PhotoMetadataSuggestionRequest(context: context, lifecycleID: UUID(), formGeneration: 0, expectedVersion: .absent))
        let catalogSource = await Task.detached { MetadataCatalogSources.source(asset) }.value
        #expect(suggested.source.nativeStamp?.birthTime == nil)
        #expect(suggested.source.nativeStamp?.fileGeneration == nil)
        let store = PhotoMetadataRepository(directory: directory.appendingPathComponent("Store"))
        _ = try await store.reconcile(MetadataCatalogSnapshot(catalogSessionID: session, catalogGeneration: 1,
            persistedReference: .absent, assets: [MetadataCatalogAsset(assetID: asset.id, source: catalogSource)]))
        let draftID = UUID()
        let drafted = try await store.saveAIDraft(MetadataAIDraftOperation(header: MetadataCommandHeader(assetID: asset.id, expectedVersion: .absent),
            mutation: .createSuggested(draftID: draftID, fields: suggested.fields, source: suggested.source)))
        let record = try #require(drafted.currentRecord)
        let confirmed = try await store.confirm(MetadataConfirmOperation(header: MetadataCommandHeader(assetID: asset.id, expectedVersion: record.version),
            values: suggested.fields, fields: [.title], source: suggested.source,
            origin: .proposal(draftID: draftID, expectedDraftRevision: record.version.aiDraftRevision)))
        #expect(confirmed.currentRecord?.confirmed.title == "Synthetisches Motiv")
        #expect(confirmed.currentRecord?.confirmed.description.isEmpty == true)
        #expect(confirmed.currentRecord?.confirmedProvenance.title == .confirmedAI(MetadataAIFieldOrigin(draftID: draftID,
            analysis: try #require(suggested.source.analyzedRaster), wasHumanEdited: false)))
    }

    private func wait(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw ImageAnalysisError.providerFailure }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private func metadataVisionSource() -> AIOriginalSourceFingerprint {
    AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: "/synthetic/vision.png"), modifiedAt: Date(timeIntervalSince1970: 100), fileSize: 10)
}
private func metadataAnalysisRequest() -> ImageAnalysisRequest {
    ImageAnalysisRequest(snapshot: AIEditingSnapshot(assetID: "synthetic", source: .original(metadataVisionSource()), settings: .neutral,
        token: AIEditingToken(editSessionID: UUID(), editGeneration: 0, selectionSessionID: UUID(), selectionGeneration: 1)), lifecycleID: UUID())
}
private func metadataVisionRaster() throws -> PreviewBitmap {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.4, green: 0.1, blue: 0.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    return PreviewBitmap(image: try #require(context.makeImage()))
}
private actor MetadataVisionProvider: ImageAnalysisProvider {
    nonisolated let descriptor = ImageAnalysisProviderDescriptor(providerID: "synthetic-vision", modelID: "synthetic")
    private(set) var analysisCalls = 0
    private(set) var metadataCalls = 0
    private(set) var maximumActive = 0
    private var active = 0
    private var blockAnalysis = false
    private var continuation: CheckedContinuation<Void, Never>?
    func availability() -> ImageAnalysisAvailability { .available }
    func setAnalysisBlocked(_ value: Bool) { blockAnalysis = value }
    func releaseAnalysis() { blockAnalysis = false; continuation?.resume(); continuation = nil }
    func analyze(_ input: PreparedImageAnalysisInput) async throws -> Data {
        analysisCalls += 1; active += 1; maximumActive = max(active, maximumActive)
        defer { active -= 1 }
        if blockAnalysis { await withCheckedContinuation { continuation = $0 } }
        return Data(#"{"schemaVersion":1,"description":"Synthetisches Raster","attributes":[]}"#.utf8)
    }
    func metadata(_ input: PreparedImageAnalysisInput) -> Data {
        metadataCalls += 1; active += 1; maximumActive = max(active, maximumActive)
        defer { active -= 1 }
        return Data(#"{"schemaVersion":1,"title":"Synthetisches Motiv","description":"Sichtbare synthetische Farbe","tags":["Farbe"],"language":"de_DE"}"#.utf8)
    }
}
private struct MetadataVisionPreparer: ImageAnalysisPreparing {
    func sourceStamp(for request: ImageAnalysisRequest) -> ImageAnalysisSourceStamp {
        ImageAnalysisSourceStamp(device: 1, inode: 2, byteCount: 10, modifiedSeconds: 100, modifiedNanoseconds: 0, changedSeconds: 100, changedNanoseconds: 0)
    }
    func prepare(_ request: ImageAnalysisRequest) throws -> PreparedImageAnalysisInput {
        PreparedImageAnalysisInput(bitmap: try metadataVisionRaster(), sourceStamp: sourceStamp(for: request),
            rasterSHA256: String(repeating: "a", count: 64), colorProfile: "sRGB", colorProfileSHA256: nil)
    }
}
private final class MetadataFreshRasterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var decodes: [String?] = []
    private var renders = 0
    var decodeCount: Int { lock.lock(); defer { lock.unlock() }; return decodes.count }
    var renderCount: Int { lock.lock(); defer { lock.unlock() }; return renders }
    var revisions: [String?] { lock.lock(); defer { lock.unlock() }; return decodes }
    func decode(_ request: PreviewRequest) throws -> PreviewBitmap {
        lock.lock(); decodes.append(request.sourceRevision); lock.unlock()
        return try metadataVisionRaster()
    }
    func render(_ bitmap: PreviewBitmap) -> PreviewBitmap {
        lock.lock(); renders += 1; lock.unlock()
        return bitmap
    }
}
