import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Image-aware assistant proposal integration", .serialized, .timeLimit(.minutes(2)))
@MainActor
final class AIRegionalProposalTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-RegionalAI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test
    func globalAndRegionalChangesAppendPersistExportAndUndoTogether() async throws {
        let existing = try layer(name: "Vorhandene Maske", exposure: 0.2)
        let initial = EditSettings(exposure: 0.4, localAdjustments: [existing])
        let (library, editor, store) = try await fixture(initial: initial)
        let snapshot = try #require(editor.aiSnapshot(in: library))
        let regional = try layer(name: "Hintergrund", exposure: -0.5, inverted: true)
        let patch = EditProposal(changes: [.init(parameter: .shadows, value: 18)], explanation: "Hintergrund korrigiert.")
        let provider = RegionalResolvedProvider(data: try JSONEncoder().encode(patch), layers: [regional])
        let coordinator = AIRequestCoordinator(provider: provider, budget: AIResourceBudget())
        let request = AIEditingRequest(prompt: "Korrigiere den überstrahlten Hintergrund", snapshot: snapshot)
        let result = try await coordinator.proposal(for: request)
        guard case .changes(let validatedPatch, let target) = result.validation else {
            Issue.record("Expected a combined global and regional target")
            return
        }
        #expect(validatedPatch == patch)
        #expect(result.localAdjustments == [regional])
        #expect(target.localAdjustments == [existing, regional])
        #expect(target.exposure == initial.exposure && target.shadows == 18)
        #expect(editor.settings(for: snapshot.assetID) == initial)
        #expect(!editor.canUndo(assetID: snapshot.assetID))
        #expect(editor.acceptAIProposal(result, in: library))
        #expect(!editor.acceptAIProposal(result, in: library))
        #expect(editor.settings(for: snapshot.assetID) == target)
        #expect(editor.localRevision(for: snapshot.assetID) == 1)
        #expect(await editor.flush())
        #expect(await store.savedSettings(for: snapshot.assetID) == target)
        // The persisted settings representation retains exact frozen selections.
        let encoded = try JSONEncoder().encode(await store.savedSettings(for: snapshot.assetID))
        #expect(try JSONDecoder().decode(EditSettings.self, from: encoded) == target)

        let exports = RegionalExportProbe()
        let exporter = JPEGExportModel(preferences: nil, export: { await exports.export($0) })
        exporter.destinationDirectory = directory
        exporter.present(asset: try #require(library.selectedAsset), settings: editor.settings(for: snapshot.assetID))
        exporter.startExport()
        try await wait { !exporter.isExporting }
        #expect(await exports.settings == [target])
        exporter.cancel()

        editor.undo(assetID: snapshot.assetID)
        #expect(editor.settings(for: snapshot.assetID) == initial)
        #expect(!editor.canUndo(assetID: snapshot.assetID))
        editor.redo(assetID: snapshot.assetID)
        #expect(editor.settings(for: snapshot.assetID) == target)
        #expect(await editor.finishSaving())
        #expect(await library.finishSaving())
    }

    @Test
    func regionalOnlyResultRetainsExplanationAndSharedCallerIdentityWithoutOuterLease() async throws {
        let (library, editor, _) = try await fixture()
        let snapshot = try #require(editor.aiSnapshot(in: library))
        let regional = try layer()
        let budget = AIResourceBudget()
        let provider = RegionalResolvedProvider(data: Data(#"{"schemaVersion":1,"changes":[],"explanation":"Nur der Hintergrund wird korrigiert."}"#.utf8),
                                                layers: [regional], budget: budget, gated: true)
        let coordinator = AIRequestCoordinator(provider: provider, budget: budget)
        let firstRequest = AIEditingRequest(prompt: "Hintergrund abdunkeln", snapshot: snapshot)
        let secondRequest = AIEditingRequest(prompt: firstRequest.prompt, snapshot: snapshot)
        let first = Task { try await coordinator.proposal(for: firstRequest) }
        defer { first.cancel(); Task { await provider.release() } }
        // This provider acquires the same one-slot budget itself. Reaching this
        // gate proves that the coordinator has not retained an outer lease.
        try await provider.waitUntilStarted()
        let second = Task { try await coordinator.proposal(for: secondRequest) }
        defer { second.cancel() }
        try await waitForWaiters(2, coordinator: coordinator)
        await provider.release()
        let firstResult = try await first.value
        let secondResult = try await second.value
        #expect(firstResult.request == firstRequest && secondResult.request == secondRequest)
        #expect(firstResult.localAdjustments == [regional])
        #expect(secondResult.localAdjustments == firstResult.localAdjustments)
        #expect(secondResult.validation == firstResult.validation)
        guard case .changes(let proposal, let target) = firstResult.validation else {
            Issue.record("Regional-only work must remain an applicable change")
            return
        }
        #expect(proposal.changes.isEmpty)
        #expect(proposal.explanation == "Nur der Hintergrund wird korrigiert.")
        #expect(target.localAdjustments == [regional])
        #expect(await provider.resolvedCalls == 1)
        #expect(await provider.rawCalls == 0)
        #expect(editor.acceptAIProposal(secondResult, in: library))
        #expect(await editor.finishSaving())
        #expect(await library.finishSaving())
    }

    @Test
    func acceptanceRejectsChangedExistingLayersAndMismatchedRegionalMetadataAtomically() async throws {
        let existing = try layer(name: "Manuelle Auswahl")
        let initial = EditSettings(localAdjustments: [existing])
        let (library, editor, store) = try await fixture(initial: initial)
        let snapshot = try #require(editor.aiSnapshot(in: library))
        let request = AIEditingRequest(prompt: "Hintergrund korrigieren", snapshot: snapshot)
        let patch = EditProposal(changes: [.init(parameter: .shadows, value: 10)])
        let newLayer = try layer(name: "Neuer Hintergrund")
        let checked = try AIProposalResult.validate(proposal: patch, localAdjustments: [newLayer], against: initial)
        guard case .changes(_, let validTarget) = checked else { return }
        var replacedBaseline = validTarget
        replacedBaseline.localAdjustments[0].settings.exposure = 1
        var changedNewLayer = newLayer
        changedNewLayer.mask.opacity = .nan
        let forged = [
            AIProposalResult(request: request, validation: .changes(proposal: patch, settings: replacedBaseline), localAdjustments: [newLayer]),
            AIProposalResult(request: request, validation: checked),
            AIProposalResult(request: request, validation: checked, localAdjustments: [changedNewLayer]),
            AIProposalResult(request: request, validation: checked, localAdjustments: [existing]),
            AIProposalResult(request: AIEditingRequest(prompt: request.prompt, snapshot: snapshot, mode: .lookGroup),
                             validation: checked, localAdjustments: [newLayer])
        ]
        for result in forged { #expect(!editor.acceptAIProposal(result, in: library)) }
        #expect(editor.settings(for: snapshot.assetID) == initial)
        #expect(!editor.canUndo(assetID: snapshot.assetID))
        #expect(!editor.hasPendingChanges)
        #expect(await store.saveCount == 0)
        #expect(editor.acceptAIProposal(AIProposalResult(request: request, validation: checked, localAdjustments: [newLayer]), in: library))
        #expect(await editor.finishSaving())
        #expect(await library.finishSaving())
    }

    @Test
    func invalidDuplicateIneffectiveAndUnsupportedAppLayersNeverProduceTargets() throws {
        let good = try layer()
        var disabled = good; disabled.isEnabled = false
        var neutral = good; neutral.settings = .neutral
        var transparent = good; transparent.mask.opacity = 0
        var invalidMask = good; invalidMask.mask.feather = .infinity
        var invalidSettings = good; invalidSettings.settings.exposure = 99
        var invalidName = good; invalidName.name = ""
        var geometric = good
        geometric.mask.shape = .linear(start: try LocalMaskPoint(x: 0, y: 0), end: try LocalMaskPoint(x: 1, y: 1))
        let empty = EditProposal(changes: [])
        for invalid in [disabled, neutral, transparent, invalidMask, invalidSettings, invalidName, geometric] {
            #expect(throws: AIEditingError.self) {
                try AIProposalResult.validate(proposal: empty, localAdjustments: [invalid], against: .neutral)
            }
        }
        #expect(throws: AIEditingError.self) {
            try AIProposalResult.validate(proposal: empty, localAdjustments: [good, good], against: .neutral)
        }
        #expect(throws: AIEditingError.self) {
            try AIProposalResult.validate(proposal: empty, localAdjustments: [good], against: EditSettings(localAdjustments: [good]))
        }
        #expect(throws: AIEditingError.self) {
            try AIProposalResult.validate(proposal: empty, localAdjustments: (0..<4).map { _ in try layer() }, against: .neutral)
        }
        #expect(throws: AIEditingError.self) {
            try AIProposalResult.validate(proposal: EditProposal(changes: [.init(parameter: .exposure, value: .nan)]),
                                          localAdjustments: [good], against: .neutral)
        }
    }

    @Test
    func aggregateLimitsIncludeExistingLayersAndRejectInvalidBaseline() throws {
        let empty = EditProposal(changes: [])
        let full = EditSettings(localAdjustments: try (0..<LocalAdjustment.maximumCount).map { _ in try layer() })
        #expect(throws: AIEditingError.self) {
            try AIProposalResult.validate(proposal: empty, localAdjustments: [try layer()], against: full)
        }
        let raster = try LocalMaskRaster(width: 2_048, height: 2_048, bytes: Data(repeating: 128, count: 2_048 * 2_048))
        let rasterLimit = EditSettings(localAdjustments: try (0..<4).map { _ in
            try LocalAdjustment(name: "Große Auswahl", mask: LocalAdjustmentMask(shape: .subject(raster)),
                                settings: LocalAdjustmentSettings(exposure: 0.2))
        })
        #expect(throws: AIEditingError.self) {
            try AIProposalResult.validate(proposal: empty, localAdjustments: [try layer()], against: rasterLimit)
        }
        var invalidBaseline = EditSettings(localAdjustments: [try layer()])
        invalidBaseline.localAdjustments[0].mask.opacity = -1
        #expect(throws: AIEditingError.self) {
            try AIProposalResult.validate(proposal: empty, localAdjustments: [], against: invalidBaseline)
        }
    }

    @Test
    func staleRegionalResultCannotOverrideNewerEditingOrSelection() async throws {
        let (library, editor, store) = try await fixture()
        let snapshot = try #require(editor.aiSnapshot(in: library))
        let local = try layer()
        let checked = try AIProposalResult.validate(proposal: EditProposal(changes: []), localAdjustments: [local], against: snapshot.settings)
        let result = AIProposalResult(request: AIEditingRequest(prompt: "Hintergrund", snapshot: snapshot),
                                      validation: checked, localAdjustments: [local])
        library.selectedID = library.assets[1].id
        library.selectedID = snapshot.assetID
        #expect(!editor.acceptAIProposal(result, in: library))
        let current = try #require(editor.aiSnapshot(in: library))
        let next = AIProposalResult(request: AIEditingRequest(prompt: "Hintergrund", snapshot: current),
                                    validation: checked, localAdjustments: [local])
        editor.setSettings(EditSettings(shadows: 20), for: snapshot.assetID)
        #expect(!editor.acceptAIProposal(next, in: library))
        #expect(editor.settings(for: snapshot.assetID).localAdjustments.isEmpty)
        #expect(await editor.finishSaving())
        #expect(await store.savedSettings(for: snapshot.assetID) == EditSettings(shadows: 20))
        #expect(await library.finishSaving())
    }

    @Test
    func regionalServiceCannotBypassStrictGlobalWireValidationOrSupplyLookMasks() async throws {
        let (library, editor, _) = try await fixture()
        let snapshot = try #require(editor.aiSnapshot(in: library))
        let local = try layer()
        let unknownField = Data(#"{"schemaVersion":1,"changes":[],"localAdjustments":[]}"#.utf8)
        let malformedProvider = RegionalResolvedProvider(data: unknownField, layers: [local])
        let malformedCoordinator = AIRequestCoordinator(provider: malformedProvider, budget: AIResourceBudget())
        await #expect(throws: AIEditingError.invalidResponse(.unknownField)) {
            try await malformedCoordinator.proposal(for: AIEditingRequest(prompt: "Hintergrund", snapshot: snapshot))
        }
        let lookProvider = RegionalResolvedProvider(data: Data(), layers: [local])
        let lookCoordinator = AIRequestCoordinator(provider: lookProvider, budget: AIResourceBudget())
        await #expect(throws: AIEditingError.invalidResponse(.invalidType)) {
            try await lookCoordinator.lookGroup(for: AIEditingRequest(prompt: "", snapshot: snapshot, mode: .lookGroup))
        }
        #expect(!editor.hasPendingChanges && !editor.canUndo(assetID: snapshot.assetID))
        #expect(await library.finishSaving())
    }

    private func layer(name: String = "Assistent: Hintergrund", exposure: Double = -0.3,
                       inverted: Bool = false) throws -> LocalAdjustment {
        let raster = try LocalMaskRaster(width: 2, height: 2, bytes: Data([0, 64, 192, 255]))
        return try LocalAdjustment(name: name, mask: LocalAdjustmentMask(shape: .subject(raster),
            isInverted: inverted, feather: 0), settings: LocalAdjustmentSettings(exposure: exposure))
    }

    private func fixture(initial: EditSettings = .neutral) async throws -> (LibraryModel, EditingModel, RegionalEditStore) {
        let photos = directory.appendingPathComponent("Photos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let folder = LibraryFolder(url: photos)
        let assets = ["A.png", "B.png"].map {
            PhotoAsset(folderID: folder.id, fileURL: photos.appendingPathComponent($0), fileSize: 1,
                       createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 1))
        }
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog-\(UUID().uuidString)"))
        try repository.save(LibraryCatalog(folders: [folder], assets: assets))
        let library = LibraryModel(repository: repository)
        let store = RegionalEditStore(initial: [assets[0].id: initial])
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await wait { !library.isLoading && !library.isProjecting && !editor.isLoading }
        library.selectedID = assets[0].id
        return (library, editor, store)
    }

    private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw RegionalTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForWaiters(_ count: Int, coordinator: AIRequestCoordinator) async throws {
        let state = TestStateSignal<AIRequestCoordinator.State?>(nil)
        let updates = await coordinator.stateUpdates()
        let observation = Task { for await value in updates { state.update { $0 = value } } }
        defer { observation.cancel() }
        try await state.wait("shared regional request", timeout: .seconds(10), until: { $0?.waiterCount == count })
    }
}

private enum RegionalTestError: Error { case timeout }

private actor RegionalResolvedProvider: AIResolvedEditingProvider {
    nonisolated let id = "regional-test"
    nonisolated let capabilities: AIProviderCapabilities = [.textEditing, .lookSuggestions]
    private let data: Data
    private let layers: [LocalAdjustment]
    private let budget: AIResourceBudget?
    private let gated: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private nonisolated let started = TestStateSignal(false)
    private(set) var rawCalls = 0
    private(set) var resolvedCalls = 0

    init(data: Data, layers: [LocalAdjustment], budget: AIResourceBudget? = nil, gated: Bool = false) {
        self.data = data; self.layers = layers; self.budget = budget; self.gated = gated
    }
    func availability() -> AIAvailability { .available }
    func proposal(for request: AIEditingRequest) throws -> Data { rawCalls += 1; return data }
    func resolvedProposal(for request: AIEditingRequest) async throws -> AIResolvedEditingProposal {
        let lease = try await budget?.acquireLocalInference()
        resolvedCalls += 1
        if gated { await withCheckedContinuation { gate = $0; started.update { $0 = true } } }
        if let budget, let lease { await budget.release(lease) }
        return AIResolvedEditingProposal(data: data, localAdjustments: layers)
    }
    nonisolated func waitUntilStarted() async throws {
        try await started.wait("resolved provider acquired its own budget", timeout: .seconds(10), until: { $0 })
    }
    func release() { gate?.resume(); gate = nil }
}

private actor RegionalEditStore: LegacySnapshotTestStore {
    private var values: [String: EditSettings]
    private var revisionsByAsset: [String: Int64] = [:]
    private(set) var saveCount = 0
    init(initial: [String: EditSettings]) { values = initial }
    func loadAll() -> [String: EditSettings] { values }
    func revisions() -> [String: Int64] { revisionsByAsset }
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) {
        values[assetID] = settings; revisionsByAsset[assetID] = revision; saveCount += 1
    }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/regional-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { values }
    func savedSettings(for id: String) -> EditSettings { values[id] ?? .neutral }
}

private actor RegionalExportProbe {
    private(set) var settings: [EditSettings] = []
    func export(_ request: JPEGExportRequest) -> JPEGExportResult {
        settings.append(request.settings)
        return JPEGExportResult(url: request.destinationURL, width: 1, height: 1)
    }
}
