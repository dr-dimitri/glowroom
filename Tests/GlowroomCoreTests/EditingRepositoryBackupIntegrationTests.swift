import Foundation
import Testing
@testable import GlowroomCore

@Suite("Editing backup admission, daily reuse and artifact startup diagnosis")
struct EditingRepositoryBackupIntegrationTests {
    @Test func automaticBackupReusesVerifiedDayBeforeAnyFurtherCopy() async throws {
        let f = try EditingFixture();_ = try await f.save(exposure:0.5)
        let first = try await f.repository.createBackup(automatic:true)
        await f.packages.setFailWrites(true)
        #expect(try await f.repository.createBackup(automatic:true) == first)
        #expect(await f.packages.kinds == [.automatic])
        #expect(await f.repository.backupWarning() == nil)
    }
    @Test func pruningFailureIsAWarningAfterSuccessfulPublication() async throws {
        let f = try EditingFixture();let saved = try await f.save(exposure:1)
        await f.packages.setFailPrune(true)
        let url = try await f.repository.createBackup(automatic:true)
        #expect(await f.packages.saved[url] != nil)
        let concrete = await f.repository.backupWarning()
        let abstract:any EditingPersistence = f.repository
        let existential = await abstract.backupWarning()
        #expect(await f.repository.backupMaintenanceWarning != nil)
        #expect(concrete != nil && concrete == existential)
        #expect(try await f.repository.loadState().byAsset[f.id] == saved)
    }
    @Test func explicitExportHoldsMaintenanceUntilActualPublicationReturns() async throws {
        let f = try EditingFixture();let saved = try await f.save(exposure:0.25)
        let backup = try await f.repository.createBackup(automatic:false)
        let latch = EditingBackupLatch(),destination = f.directory.appendingPathComponent("export.glowroombackup",isDirectory:true)
        await f.packages.blockNextWrite(latch)
        let operation = Task {try await f.repository.exportBackup(from:backup,toNew:destination)}
        for _ in 0..<20_000 {if await latch.entered {break};await Task.yield()}
        let entered = await latch.entered
        #expect(entered)
        if entered {
            let session = try await f.gate.waitForStartup()
            do {_ = try f.gate.registerAcceptedWrite(domain:.editing,session:session);Issue.record("Export must retain maintenance until publication")}
            catch {#expect(error as? CatalogLifecycleError == .maintenanceAlreadyPending)}
        }
        await latch.release()
        #expect(try await operation.value == destination)
        #expect(try await f.repository.loadState().byAsset[f.id] == saved)
        #expect(await f.packages.saved[destination] != nil)
    }
    @Test func artifactRecoveryReportRetainsOrphansAndUsesVariantReferences() async throws {
        let f = try EditingFixture();let parent = try await f.save(exposure:0.5)
        let draft = try await f.draft(parent:parent)
        let request = try GenerationCommitRequest(commitID:.init(),assetID:f.id,draft:draft,expected:.init(parent),expectedParentSource:draft.artifact.provenance.parentSource,nextRevision:2)
        let accepted = try await f.repository.commitGenerated(request)
        // Returning to Original keeps the generated source as a variant.
        _ = try await f.repository.saveSnapshot(parent.snapshot,for:f.id,expected:.init(accepted.stored),revision:3)
        let orphan = try await f.draft(parent:parent)
        _ = try await f.artifacts.publish(orphan,commitID:.init())
        let report = try await f.repository.inspectArtifactRecovery()
        #expect(report.retainedOrphans == [orphan.artifact.id])
        #expect(report.removedOwnedStagingCount == 0)
        #expect(await f.repository.artifactRecoveryReport?.retainedOrphans == report.retainedOrphans)
        #expect(await f.artifacts.wasPublished(orphan.artifact.id))
        #expect(try await f.repository.loadState().byAsset[f.id]?.snapshot == parent.snapshot)
    }
}
