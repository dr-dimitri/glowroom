import Foundation
import CSQLite
import Testing
@testable import PicEditCore

@Suite("Metadata durable participant identity and shared recovery fence")
struct PhotoMetadataCoordinationTests {
    @Test func legacySchemaOneMigratesExplicitlyAndStableUUIDSurvivesRestart() async throws {
        let directory = MetadataFixture.directory();defer{try? FileManager.default.removeItem(at:directory)}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let url = directory.appendingPathComponent("photo-metadata.sqlite")
        try metadataSQL(url,"PRAGMA application_id=\(PhotoMetadataSQLite.applicationID);PRAGMA user_version=1;"+PhotoMetadataSQLite.legacySchemas.keys.sorted().map{PhotoMetadataSQLite.legacySchemas[$0]!}.joined(separator:";")+";")
        var db:OpaquePointer?;#expect(sqlite3_open(url.path,&db) == SQLITE_OK)
        try PhotoMetadataSQLite.statement(try #require(db),"INSERT INTO metadata_state VALUES(1,7,?)") {s in
            try PhotoMetadataSQLite.bind(PhotoMetadataInternalCodec.encode(MetadataCatalogFileReference.absent),1,s);try PhotoMetadataSQLite.done(s)
        };sqlite3_close(db)
        let repository = PhotoMetadataRepository(directory:directory)
        let before = try Data(contentsOf:url)
        do {_ = try await repository.inspectParticipantIdentity();Issue.record("Readonly inspection must not migrate")}
        catch {#expect(error as? PhotoMetadataError == .recoveryRequired)}
        #expect(try Data(contentsOf:url) == before)
        let id = try await repository.participantStoreIdentity()
        #expect(id.kind == .photoMetadata)
        #expect(try editingScalar(url,"PRAGMA user_version") == 2)
        let restarted = PhotoMetadataRepository(directory:directory)
        #expect(try await restarted.inspectParticipantIdentity() == id)
        #expect(try await restarted.participantStoreIdentity() == id)
        #expect(await restarted.searchState().version.generation == 7)
    }
    @Test func absentParticipantInspectionDoesNotCreateOrMigrate() async throws {
        let directory = MetadataFixture.directory(),repository = PhotoMetadataRepository(directory:directory)
        #expect(try await repository.inspectParticipantIdentity() == nil)
        #expect(!FileManager.default.fileExists(atPath:directory.path))
    }
    @Test func ordinaryMetadataReadAndWriteWaitForTheCommonStartupBarrier() async throws {
        let directory = MetadataFixture.directory();defer{try? FileManager.default.removeItem(at:directory)}
        let gate = CatalogLifecycleGate(),repository = PhotoMetadataRepository(directory:directory,gate:gate),probe = MetadataAccessProbe()
        let reader = Task {let row = try await repository.record(assetID:"a");await probe.finished();return row}
        let writer = Task {try await repository.saveManualDraft(.init(header:.init(assetID:"a",expectedVersion:.absent),mutation:.save(fields:.init(title:"held"),baseConfirmedRevision:0)))}
        for _ in 0..<20 {await Task.yield()}
        #expect(await probe.didFinish == false)
        #expect(!FileManager.default.fileExists(atPath:repository.fileURL.path))
        let maintenance = try await gate.beginMaintenance(.coordination(UUID()))
        let id = try await gate.withMaintenance(maintenance) {try await repository.participantStoreIdentity()}
        #expect(id.kind == .photoMetadata)
        try await gate.finishMaintenance(maintenance)
        _ = try gate.openAfterRecovery()
        let readValue = try await reader.value,currentValue = try await repository.record(assetID:"a")
        #expect(readValue == nil || currentValue != nil)
        #expect(try await writer.value.currentRecord?.manualDraft?.fields.title == "held")
    }
    @Test func invalidJointLinkFailsClosedWithoutRepairOrTextMutation() async throws {
        let f = try MetadataFixture();try await f.bind();_ = try await f.confirm(.init(title:"Keep"))
        let id = try await f.repository.participantStoreIdentity()
        #expect(id.kind == .photoMetadata)
        try metadataSQL(f.repository.fileURL,"INSERT INTO metadata_coordinations VALUES('\(UUID().uuidString.lowercased())','\(String(repeating:"a",count:64))')")
        let bytes = try Data(contentsOf:f.repository.fileURL)
        let restarted = PhotoMetadataRepository(directory:f.directory)
        do {_ = try await restarted.record(assetID:f.id);Issue.record("Expected dangling joint-link rejection")}
        catch {#expect(error as? PhotoMetadataError == .corruptStore)}
        #expect(try Data(contentsOf:f.repository.fileURL) == bytes)
    }
    @Test func sameIdentityIsNotRecreatedWhenExistingStoreIsCorrupt() async throws {
        let f = try MetadataFixture();let first = try await f.repository.participantStoreIdentity()
        try metadataSQL(f.repository.fileURL,"UPDATE metadata_identity SET store_id='not-uuid'")
        let bytes = try Data(contentsOf:f.repository.fileURL),restarted = PhotoMetadataRepository(directory:f.directory)
        do {_ = try await restarted.participantStoreIdentity();Issue.record("Expected identity failure")}
        catch {#expect(error as? PhotoMetadataError == .corruptStore)}
        #expect(first.kind == .photoMetadata)
        #expect(try Data(contentsOf:f.repository.fileURL) == bytes)
    }
}
private actor MetadataAccessProbe {var didFinish = false;func finished(){didFinish = true}}
