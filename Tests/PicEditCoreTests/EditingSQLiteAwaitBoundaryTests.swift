import Foundation
import Testing
@testable import PicEditCore

@Suite("Editing SQLite rejects unowned journals after artifact awaits")
struct EditingSQLiteAwaitBoundaryTests {
    @Test func publicationAwaitCannotAdmitAnUnownedSidecarToSQLite() async throws {
        for suffix in ["-journal","-wal","-shm"] {
            let injection = EditingAwaitSidecar()
            let f = try EditingFixture(hooks:.init(afterPublication:{try injection.write()}))
            let parent = try await f.save(exposure:0.5),draft = try await f.draft(parent:parent)
            let original = try Data(contentsOf:f.repository.fileURL)
            injection.url = URL(fileURLWithPath:f.repository.fileURL.path+suffix)
            let request = try GenerationCommitRequest(commitID:.init(),assetID:f.id,draft:draft,expected:.init(parent),expectedParentSource:draft.artifact.provenance.parentSource,nextRevision:2)
            do {_ = try await f.repository.commitGenerated(request);Issue.record("Sidecar must reject before post-await SQL")}
            catch {#expect(error as? EditingRepositoryError == .recoveryRequired)}
            #expect(try Data(contentsOf:f.repository.fileURL) == original)
            #expect(try Data(contentsOf:injection.url!) == injection.bytes)
            try FileManager.default.removeItem(at:injection.url!)
            #expect(try await f.repository.loadState().byAsset[f.id] == parent)
            #expect(try await f.repository.committed(request.commitID) == nil)
        }
    }
    @Test func artifactDescriptorAwaitIsGuardedBeforeDescriptorSQLRead() async throws {
        let f = try EditingFixture();let parent = try await f.save(exposure:0.5),draft = try await f.draft(parent:parent)
        let request = try GenerationCommitRequest(commitID:.init(),assetID:f.id,draft:draft,expected:.init(parent),expectedParentSource:draft.artifact.provenance.parentSource,nextRevision:2)
        let accepted = try await f.repository.commitGenerated(request)
        let injection = EditingAwaitSidecar();injection.url = URL(fileURLWithPath:f.repository.fileURL.path+"-journal")
        let original = try Data(contentsOf:f.repository.fileURL)
        await f.artifacts.afterNextDescriptor {try injection.write()}
        do {_ = try await f.repository.saveSnapshot(EditingSnapshot(source:accepted.stored.snapshot.source,settings:EditSettings(exposure:1)),for:f.id,expected:.init(accepted.stored),revision:3);Issue.record("Descriptor SQL must not see the injected journal")}
        catch {#expect(error as? EditingRepositoryError == .recoveryRequired)}
        #expect(try Data(contentsOf:f.repository.fileURL) == original)
        #expect(try Data(contentsOf:injection.url!) == injection.bytes)
    }
    @Test func restoreMaterializationAwaitCannotReplayAnUnownedJournal() async throws {
        let f = try EditingFixture();let parent = try await f.save(exposure:0.5)
        let backup = try await f.repository.createBackup(automatic:false)
        let latest = try await f.repository.saveSnapshot(EditingSnapshot(settings:EditSettings(exposure:1)),for:f.id,expected:.init(parent),revision:2)
        let injection = EditingAwaitSidecar();injection.url = URL(fileURLWithPath:f.repository.fileURL.path+"-journal")
        let original = try Data(contentsOf:f.repository.fileURL)
        await f.artifacts.afterNextMaterialize {try injection.write()}
        do {_ = try await f.repository.restoreBackup(from:backup);Issue.record("Restore must reject before touching the live SQL after materialization")}
        catch {#expect(error as? EditingRepositoryError == .recoveryRequired)}
        #expect(try Data(contentsOf:f.repository.fileURL) == original)
        #expect(try Data(contentsOf:injection.url!) == injection.bytes)
        try FileManager.default.removeItem(at:injection.url!)
        #expect(try await f.repository.loadState().byAsset[f.id] == latest)
    }
}
private final class EditingAwaitSidecar:@unchecked Sendable {
    private let lock = NSLock();private var target:URL?
    let bytes = Data("foreign sidecar bytes must not be replayed or removed".utf8)
    var url:URL? {get{lock.withLock{target}}set{lock.withLock{target = newValue}}}
    func write() throws {if let url {try bytes.write(to:url,options:.atomic)}}
}
