import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Artifact bootstrap preserves independent metadata and original editing", .timeLimit(.minutes(1)))
struct ArtifactBootstrapIndependenceTests {
    enum BrokenArtifactTree: String, CaseIterable, Sendable {
        case corruptOwner, unownedTree
    }

    @Test(arguments: BrokenArtifactTree.allCases)
    func unavailableArtifactsKeepRealMetadataAndOriginalOnlyEditingUsable(kind: BrokenArtifactTree) async throws {
        let fixture = try Fixture(kind: kind); defer { fixture.remove() }
        let bootstrap = ArtifactAppBootstrap(directory: fixture.catalog.directory)
        _ = try await bootstrap.startup.value
        let dependencies = try await bootstrap.editingDependencies()
        #expect(dependencies.artifacts == nil)
        #expect(dependencies.artifactStoreError?.isEmpty == false)
        // Use the ACTUAL shared gated metadata actor, not a new ungated store.
        let record = try await confirmManualMetadata(in: bootstrap, fixture: fixture)
        #expect(record.confirmed.title == "Manuell bestätigtes Motiv")
        #expect(record.confirmed.tags == ["Synthetisch"])
        #expect(record.manualDraft == nil && !record.sourceChanged && !record.isOrphaned)
        if case .available(let search) = await bootstrap.metadata.searchState() {
            #expect(search.confirmedByAssetID[fixture.asset.id] == record.confirmed)
        } else { Issue.record("Healthy metadata must remain searchable despite an unavailable artifact tree") }

        let state = try await dependencies.database.loadState()
        let snapshot = try EditingSnapshot(settings: EditSettings(exposure: 0.75, contrast: 4))
        let expected = try EditingExpectedState(storeEpoch: state.storeEpoch, revision: nil, snapshot: nil)
        let stored = try await dependencies.database.saveSnapshot(snapshot, for: fixture.asset.id, expected: expected, revision: 1)
        #expect(stored.snapshot.source == .original && stored.snapshot == snapshot)
        let reloaded = try await dependencies.database.loadState()
        #expect(reloaded.byAsset[fixture.asset.id] == stored)
        #expect(await bootstrap.metadata.finishSaving())
        try fixture.expectOriginalAndForeignTreePreserved()
    }

    @Test func ambiguousSharedJournalStillBlocksStartupAndMetadataWithUnavailableArtifacts() async throws {
        let fixture = try Fixture(kind: .unownedTree); defer { fixture.remove() }
        // First obtain a genuinely owned coordinator root and healthy SQL stores
        // through the production bootstrap. No hand-minted owner/receipt fixture.
        let before = ArtifactAppBootstrap(directory: fixture.catalog.directory)
        _ = try await before.startup.value
        let confirmed = try await confirmManualMetadata(in: before, fixture: fixture)
        let metadataBytes = try Data(contentsOf: before.metadata.fileURL)
        let operation = fixture.catalog.directory.appendingPathComponent("CatalogCoordination/" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: operation, withIntermediateDirectories: false)
        let descriptor = operation.appendingPathComponent("descriptor.json")
        let journal = operation.appendingPathComponent("journal.json")
        let descriptorBytes = Data("{\"schemaVersion\":99,\"incomplete\":true}".utf8)
        let journalBytes = Data("{\"phase\":\"armed\",\"truncated\":true}".utf8)
        try descriptorBytes.write(to: descriptor); try journalBytes.write(to: journal)

        let blocked = ArtifactAppBootstrap(directory: fixture.catalog.directory)
        await #expect(throws: (any Error).self) { _ = try await blocked.startup.value }
        // Service construction still succeeds; it is the REAL malformed joint
        // inventory that refuses opening, not the independent artifact error.
        let coordinator = try await blocked.coordinator()
        await #expect(throws: (any Error).self) { _ = try await coordinator.pending() }
        await #expect(throws: CatalogLifecycleError.recoveryRequired) { _ = try await blocked.gate.waitForStartup() }
        await #expect(throws: CatalogLifecycleError.recoveryRequired) {
            _ = try await blocked.metadata.saveManualDraft(.init(
                header: .init(assetID: fixture.asset.id, expectedVersion: confirmed.version),
                mutation: .save(fields: .init(title: "Must not be admitted"), baseConfirmedRevision: confirmed.confirmedRevision)))
        }
        #expect(try Data(contentsOf: before.metadata.fileURL) == metadataBytes)
        #expect(try Data(contentsOf: descriptor) == descriptorBytes)
        #expect(try Data(contentsOf: journal) == journalBytes)
        try fixture.expectOriginalAndForeignTreePreserved()
        withExtendedLifetime(before) {}
    }

    private func confirmManualMetadata(in bootstrap: ArtifactAppBootstrap, fixture: Fixture) async throws -> PhotoMetadataRecord {
        let stored = try fixture.catalog.loadStored()
        let source = MetadataCatalogSources.source(fixture.asset)
        _ = try await bootstrap.metadata.reconcile(.init(catalogSessionID: UUID(), catalogGeneration: 1,
            persistedReference: stored.reference, assets: [.init(assetID: fixture.asset.id, source: source)]))
        let session = try await bootstrap.gate.waitForStartup()
        let draftAdmission = try bootstrap.gate.registerAcceptedWrite(domain: .photoMetadata, session: session)
        let fields = PhotoTextFields(title: "Manuell bestätigtes Motiv", description: "Ohne Bildanalyse gespeichert.", tags: ["Synthetisch"])
        let drafted = try await bootstrap.gate.withAcceptedWrite(draftAdmission) {
            try await bootstrap.metadata.saveManualDraft(.init(header: .init(assetID: fixture.asset.id, expectedVersion: .absent),
                mutation: .save(fields: fields, baseConfirmedRevision: 0)))
        }
        let draft = try #require(drafted.currentRecord)
        #expect(draft.manualDraft?.fields == fields)
        let confirmationAdmission = try bootstrap.gate.registerAcceptedWrite(domain: .photoMetadata, session: session)
        let result = try await bootstrap.gate.withAcceptedWrite(confirmationAdmission) {
            try await bootstrap.metadata.confirm(.init(header: .init(assetID: fixture.asset.id, expectedVersion: draft.version),
                values: fields, fields: Set(PhotoMetadataField.allCases), tagPolicy: .replace, source: source,
                origin: .manual(expectedManualDraftRevision: draft.version.manualDraftRevision, reviewedConfirmedRevision: 0)))
        }
        let confirmed = try #require(result.currentRecord)
        #expect(confirmed.confirmed == fields)
        return confirmed
    }

    private struct Fixture: Sendable {
        let root: URL
        let catalog: CatalogRepository
        let asset: PhotoAsset
        let originalBytes: Data
        let catalogBytes: Data
        let artifactRoot: URL
        let foreignFiles: [String: Data]
        init(kind: BrokenArtifactTree) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-Artifact-Bootstrap-" + UUID().uuidString, isDirectory: true)
            let originals = root.appendingPathComponent("Originals", isDirectory: true)
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            let folder = LibraryFolder(url: originals)
            let original = originals.appendingPathComponent("synthetic.raw")
            originalBytes = Data("synthetic bootstrap source; no model or decoding".utf8)
            try originalBytes.write(to: original)
            let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
            asset = PhotoAsset(folderID: folder.id, fileURL: original, fileSize: Int64(originalBytes.count),
                modifiedAt: try #require(attributes[.modificationDate] as? Date))
            catalog = CatalogRepository(directory: root.appendingPathComponent("Data", isDirectory: true))
            try catalog.save(.init(folders: [folder], assets: [asset]))
            catalogBytes = try Data(contentsOf: catalog.fileURL)
            artifactRoot = catalog.directory.appendingPathComponent("GeneratedArtifacts", isDirectory: true)
            try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: false)
            var files = ["foreign-original.bin": Data("foreign bytes must survive all bootstrap attempts".utf8)]
            if kind == .corruptOwner { files[".owner.json"] = Data("{\"schemaVersion\":99,\"application\":\"foreign\"}".utf8) }
            foreignFiles = files
            for (name, bytes) in files { try bytes.write(to: artifactRoot.appendingPathComponent(name)) }
        }
        func expectOriginalAndForeignTreePreserved() throws {
            #expect(try Data(contentsOf: asset.fileURL) == originalBytes)
            #expect(try Data(contentsOf: catalog.fileURL) == catalogBytes)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: artifactRoot.path)) == Set(foreignFiles.keys))
            for (name, bytes) in foreignFiles { #expect(try Data(contentsOf: artifactRoot.appendingPathComponent(name)) == bytes) }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
