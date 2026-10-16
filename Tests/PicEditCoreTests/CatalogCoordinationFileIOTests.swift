import CryptoKit
import Foundation
import Testing
@testable import PicEditCore

@Suite("Durable catalog payloads")
struct CatalogCoordinationFileIOTests {
    private struct Fixture {
        let directory: URL
        let repository: CatalogRepository
        let value: CatalogCoordinationJournalValue
        let stage: DurableCatalogStage
        var operation: URL { directory.appendingPathComponent("CatalogCoordination").appendingPathComponent(value.body.operationID.uuidString.lowercased()) }
        func journal(_ value: CatalogCoordinationJournalValue? = nil) -> ValidatedCatalogCoordinatorJournal {
            let value = value ?? self.value
            return ValidatedCatalogCoordinatorJournal(value: value, ownerID: value.body.catalog.rootOwnerID, nonce: UUID())
        }
    }
    private func fixture(in requestedDirectory: URL? = nil) throws -> Fixture {
        let directory = requestedDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Catalog-Coordinator-\(UUID().uuidString)", isDirectory: true)
        let repository = CatalogRepository(directory: directory)
        let root = try repository.coordinationRootIdentity()
        let id = UUID(), prepared = try repository.prepare(LibraryCatalog())
        let payload = CatalogPreparedPayloadIdentity(operationID: id, rootOwnerID: root, before: .absent, after: prepared.reference)
        let command = MetadataCatalogChange(id: id, before: .absent, after: prepared.reference, relocations: [], expectedRecords: [])
        let bytes = try PhotoMetadataInternalCodec.encode(command)
        let descriptor = CatalogParticipantCommandDescriptor(store: .init(kind: .photoMetadata, durableStoreID: UUID()),
            operationID: id, requestSchemaVersion: 1,
            requestSHA256: try ArtifactDigest(sha256: PhotoMetadataInternalCodec.digest(kind: "catalogChange", payload: command)), canonicalByteCount: Int64(bytes.count))
        let body = CatalogCoordinationRequestBody(operationID: id, catalog: payload, requiredParticipants: [descriptor])
        let value = CatalogCoordinationJournalValue(body: body,
            requestSHA256: try ArtifactDigest(sha256: CatalogFileIO.digest(EditingContractJSON.encoder().encode(body))),
            revision: 1, phase: .prepared, disposition: .active)
        let stage = try repository.coordinationFiles.create(value, prepared: prepared, editing: nil, metadata: bytes)
        return Fixture(directory: directory, repository: repository, value: value, stage: stage)
    }

    @Test func originalBytesPublishThroughExistingCASAndRecoverAfterRename() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let originalBytes = try Data(contentsOf: f.operation.appendingPathComponent("catalog.json"))
        #expect(!FileManager.default.fileExists(atPath: f.repository.fileURL.path))
        let first = try f.repository.coordinationFiles.advance(f.journal(), phase: .armed)
        let committed = try f.repository.coordinationFiles.advance(f.journal(first), phase: .editingCommitted)
        let armed = ArmedCatalogCoordination(journal: f.journal(committed), nonce: UUID())
        let result = try f.repository.publishDurableCatalogStage(f.stage, armedBy: armed)
        #expect(result.published == f.value.body.catalog.after)
        #expect(try Data(contentsOf: f.repository.fileURL) == originalBytes)
        #expect(!FileManager.default.fileExists(atPath: f.operation.appendingPathComponent("catalog.json").path))
        let restarted = CatalogRepository(directory: f.directory)
        guard case .exactAfter = try restarted.inspectCatalogRecovery(f.journal(committed)) else { Issue.record("Lost post-rename evidence"); return }
        let published = try restarted.coordinationFiles.advance(f.journal(committed), phase: .catalogPublished)
        _ = try restarted.coordinationFiles.advance(f.journal(published), phase: .completed, disposition: .completed)
        #expect(try restarted.coordinationFiles.pendingValues().isEmpty)
        #expect(try restarted.coordinationFiles.command(f.journal(published), kind: .photoMetadata).count > 0)
    }

    @Test func foreignEqualByteInodeRejectedBeforeAndAfterRestart() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let payload = f.operation.appendingPathComponent("catalog.json")
        let original = try Data(contentsOf: payload)
        try original.write(to: payload, options: .atomic)
        let armedValue = try f.repository.coordinationFiles.advance(f.journal(), phase: .armed)
        let armed = ArmedCatalogCoordination(journal: f.journal(armedValue), nonce: UUID())
        #expect(throws: (any Error).self) { try f.repository.publishDurableCatalogStage(f.stage, armedBy: armed) }
        #expect(throws: (any Error).self) { try CatalogRepository(directory: f.directory).inspectCatalogRecovery(f.journal(armedValue)) }
        #expect(!FileManager.default.fileExists(atPath: f.repository.fileURL.path))
        #expect(try Data(contentsOf: payload) == original)
    }

    @Test func unrelatedCatalogIsNeverOverwritten() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let foreign = Data("unrelated catalog bytes".utf8)
        try foreign.write(to: f.repository.fileURL)
        let armedValue = try f.repository.coordinationFiles.advance(f.journal(), phase: .armed)
        let armed = ArmedCatalogCoordination(journal: f.journal(armedValue), nonce: UUID())
        #expect(throws: CatalogRepositoryError.self) { try f.repository.publishDurableCatalogStage(f.stage, armedBy: armed) }
        #expect(try Data(contentsOf: f.repository.fileURL) == foreign)
        guard case .conflict = try f.repository.inspectCatalogRecovery(f.journal(armedValue)) else { Issue.record("Expected exact-reference conflict"); return }
        #expect(FileManager.default.fileExists(atPath: f.operation.appendingPathComponent("catalog.json").path))
    }

    @Test func journalCASAndPhaseOrderingCannotSkipOrReplay() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(throws: CatalogCoordinationError.invalidPhase) { try f.repository.coordinationFiles.advance(f.journal(), phase: .completed, disposition: .completed) }
        let next = try f.repository.coordinationFiles.advance(f.journal(), phase: .armed)
        #expect(throws: CatalogCoordinationError.invalidPhase) { try f.repository.coordinationFiles.advance(f.journal(), phase: .armed) }
        #expect(throws: CatalogCoordinationError.invalidPhase) { try f.repository.coordinationFiles.advance(f.journal(next), phase: .prepared, disposition: .aborted) }
        #expect(try f.repository.coordinationFiles.pendingValues().first?.revision == 2)
    }

    @Test func hardlinkedPayloadAndUnknownJournalPreserveAllBytes() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let payload = f.operation.appendingPathComponent("catalog.json")
        let alias = f.directory.appendingPathComponent("outside-link.json")
        try FileManager.default.linkItem(at: payload, to: alias)
        #expect(throws: (any Error).self) { try f.repository.inspectCatalogRecovery(f.journal()) }
        let before = try Data(contentsOf: alias)
        #expect(try Data(contentsOf: payload) == before)
        let journalURL = f.operation.appendingPathComponent("journal.json")
        var journalBytes = try Data(contentsOf: journalURL); journalBytes.append(0x20)
        try journalBytes.write(to: journalURL)
        #expect(throws: (any Error).self) { try CatalogRepository(directory: f.directory).coordinationFiles.pendingValues() }
        #expect(try Data(contentsOf: journalURL) == journalBytes)
        #expect(try Data(contentsOf: alias) == before)
    }

    @Test func unownedDirectoryAndSymlinkDoNotAcquireOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Unowned-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("CatalogCoordination")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try CatalogRepository(directory: root).coordinationRootIdentity() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: second.appendingPathComponent("CatalogCoordination"), withDestinationURL: directory)
        #expect(throws: (any Error).self) { try CatalogRepository(directory: second).coordinationRootIdentity() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
    @Test func abortIntentStaysPendingUntilParticipantsHaveFinished() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let intent = try f.repository.coordinationFiles.advance(f.journal(), phase: .prepared, disposition: .aborted)
        #expect(try f.repository.coordinationFiles.pendingValues().first?.disposition == .aborted)
        #expect(throws: CatalogCoordinationError.recoveryRequired) { try f.repository.coordinationFiles.recoveryInventory() }
        let completed = try f.repository.coordinationFiles.advance(f.journal(intent), phase: .completed, disposition: .aborted)
        #expect(try f.repository.coordinationFiles.pendingValues().isEmpty)
        _ = try f.repository.coordinationFiles.recoveryInventory()
        // Even explicit cleanup cannot remove an equal-byte replacement.
        let payload = f.operation.appendingPathComponent("catalog.json")
        let bytes = try Data(contentsOf: payload); try bytes.write(to: payload, options: .atomic)
        #expect(throws: (any Error).self) { try f.repository.coordinationFiles.cleanup(f.journal(completed), abort: true) }
        #expect(try Data(contentsOf: payload) == bytes)
    }

    @Test func damagedRecoveryChecksBothJournalInventoryAndCatalogAtInstall() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Recovery-CAS-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CatalogRepository(directory: directory)
        let initial = try repository.coordinationFiles.recoveryInventory()
        var calls = 0
        #expect(try repository.coordinationFiles.withRecoveryBoundary(initial) { calls += 1; return 42 } == 42)
        #expect(calls == 1)
        _ = try fixture(in: directory)
        #expect(throws: CatalogCoordinationError.recoveryRequired) {
            try repository.coordinationFiles.withRecoveryBoundary(initial) { calls += 1 }
        }
        #expect(calls == 1)
        let other = directory.appendingPathComponent("other")
        let second = CatalogRepository(directory: other)
        let beforeCatalog = try second.coordinationFiles.recoveryInventory()
        try second.save(LibraryCatalog())
        #expect(throws: CatalogCoordinationError.externallyModifiedCatalog) {
            try second.coordinationFiles.withRecoveryBoundary(beforeCatalog) { calls += 1 }
        }
        #expect(calls == 1)
    }

    @Test func recoveryPermitRequiresItsRealMaintenanceExecutionAndGate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Recovery-Permit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CatalogRepository(directory: directory)
        let gate = CatalogLifecycleGate(requiresRecovery: false)
        let cap = try await gate.beginMaintenance(.restore(UUID()))
        let permit = CatalogEditingRecoveryPermit(files: repository.coordinationFiles, gate: gate, maintenance: cap,
            inventory: try repository.coordinationFiles.recoveryInventory())
        #expect(throws: CatalogLifecycleError.invalidAdmission) { try permit.validateGate(gate) }
        let value = try await gate.withMaintenance(cap) {
            try permit.validateGate(gate)
            return try permit.withCriticalSection { 19 }
        }
        #expect(value == 19)
        let foreign = CatalogLifecycleGate(requiresRecovery: false)
        let foreignCap = try await foreign.beginMaintenance(.restore(UUID()))
        try await foreign.withMaintenance(foreignCap) {
            #expect(throws: CatalogCoordinationError.invalidCapability) { try permit.validateGate(foreign) }
        }
        try await foreign.finishMaintenance(foreignCap)
        try await gate.finishMaintenance(cap)
        #expect(throws: CatalogLifecycleError.invalidAdmission) { try permit.withCriticalSection { 0 } }
    }

    @Test(arguments: ["edits.sqlite", "edits.sqlite-recovery.json"])
    func explicitRecoveryCannotReplaceCataloguedOriginalAtDatabaseLeaf(leaf: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Recovery-Original-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent(leaf)
        let bytes = Data("opaque original fixture".utf8)
        try bytes.write(to: original)
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: original)
        let repository = CatalogRepository(directory: directory)
        try repository.save(LibraryCatalog(folders: [folder], assets: [asset]))
        let proof = try repository.coordinationFiles.recoveryInventory()
        var called = false
        #expect(throws: PhotoMetadataError.protectedPath) {
            try repository.coordinationFiles.withRecoveryBoundary(proof) { called = true }
        }
        #expect(!called)
        #expect(try Data(contentsOf: original) == bytes)
    }

}
