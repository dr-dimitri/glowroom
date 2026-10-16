import Foundation
import Darwin
import Testing
@testable import PicEditCore

@Suite("Durable editing recovery intent survives real process exits", .serialized, .timeLimit(.minutes(2)))
struct EditingRecoveryCrashTests {
    @Test func everyInstallGapFencesOrdinaryOpenAndExplicitRetryPreservesRawArchives() async throws {
        guard ProcessInfo.processInfo.environment[recoveryChildDirectory] == nil else {return}
        for phase in ["intent","main","journal","candidate","completed"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Recovery-Crash-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            defer {try? FileManager.default.removeItem(at:directory)}
            try runRecoveryChild(directory,phase:phase)
            let database = directory.appendingPathComponent("edits.sqlite"),intent = directory.appendingPathComponent(EditingRecoveryIntent.leaf)
            let hadMain = FileManager.default.fileExists(atPath:database.path)
            let priorMain = hadMain ? try Data(contentsOf:database) : nil
            let priorIntent = FileManager.default.fileExists(atPath:intent.path) ? try Data(contentsOf:intent) : nil
            let resources = ArtifactResourceOwner(limits:try .init()),gate = CatalogLifecycleGate(requiresRecovery:false)
            let artifacts = try await GeneratedArtifactStore.open(in:directory,resources:resources,lifecycleGate:gate)
            let packages = EditingBackupPackageStore(resources:resources,catalog:CatalogRepository(directory:directory))
            let repository = EditingRepository(directory:directory,artifacts:artifacts,packages:packages,gate:gate,resources:resources)
            if phase == "completed" {
                #expect(priorIntent == nil)
                #expect(try await repository.loadState().byAsset[recoveryAssetID]?.snapshot.settings.exposure == 1.5)
            } else {
                #expect(priorIntent != nil)
                do {_ = try await repository.loadState();Issue.record("Interrupted recovery must never initialize an empty store")}
                catch {#expect(error as? EditingRepositoryError == .recoveryRequired)}
                #expect(FileManager.default.fileExists(atPath:database.path) == hadMain)
                if let priorMain {#expect(try Data(contentsOf:database) == priorMain)}
                #expect(try Data(contentsOf:intent) == priorIntent)
                let backups = try FileManager.default.contentsOfDirectory(at:directory.appendingPathComponent("EditBackups"),includingPropertiesForKeys:nil)
                let selected = try #require(backups.first{$0.lastPathComponent.hasPrefix("manual-")})
                let coordinator = JointCatalogCoordinator(repository:CatalogRepository(directory:directory),editing:repository,gate:gate)
                let restored = try await coordinator.recoverEditingDatabase(from:selected)
                #expect(restored.byAsset[recoveryAssetID]?.snapshot.settings.exposure == 1.5)
                #expect(!FileManager.default.fileExists(atPath:intent.path))
                #expect(try await repository.loadState().byAsset == restored.byAsset)
            }
            let archives = try FileManager.default.contentsOfDirectory(at:directory.appendingPathComponent("EditingRecoveryArchives"),includingPropertiesForKeys:nil)
            #expect(archives.count >= (phase == "completed" ? 1 : 2))
            let original = try archives.contains {url in
                let main = url.appendingPathComponent("edits.sqlite"),journal = url.appendingPathComponent("edits.sqlite-journal")
                guard FileManager.default.fileExists(atPath:main.path),FileManager.default.fileExists(atPath:journal.path) else {return false}
                let mainBytes = try Data(contentsOf:main),journalBytes = try Data(contentsOf:journal)
                return mainBytes == recoveryDamagedBytes && journalBytes == recoveryJournalBytes
            }
            #expect(original)
            if let priorIntent,phase != "completed" {
                #expect(try archives.contains {url in
                    let raw = url.appendingPathComponent(EditingRecoveryIntent.leaf)
                    guard FileManager.default.fileExists(atPath:raw.path) else {return false}
                    return try Data(contentsOf:raw) == priorIntent
                })
            }
        }
    }
    @Test func unknownIntentWithMissingMainIsNeverParsedOrSilentlyReset() async throws {
        let f = try EditingFixture();let saved = try await f.save(exposure:0.75)
        let backup = try await f.repository.createBackup(automatic:false)
        let intent = f.directory.appendingPathComponent(EditingRecoveryIntent.leaf),bytes = Data("unknown intent bytes are raw evidence, never authority".utf8)
        try bytes.write(to:intent);try FileManager.default.removeItem(at:f.repository.fileURL)
        do {_ = try await f.reopen().loadState();Issue.record("Intent must fence missing main")}
        catch {#expect(error as? EditingRepositoryError == .recoveryRequired)}
        #expect(!FileManager.default.fileExists(atPath:f.repository.fileURL.path))
        #expect(try Data(contentsOf:intent) == bytes)
        let coordinator = JointCatalogCoordinator(repository:.init(directory:f.directory),editing:f.repository,gate:f.gate)
        let restored = try await coordinator.recoverEditingDatabase(from:backup)
        #expect(restored.byAsset[f.id]?.snapshot == saved.snapshot)
        #expect(!FileManager.default.fileExists(atPath:intent.path))
        let archives = try FileManager.default.contentsOfDirectory(at:f.directory.appendingPathComponent("EditingRecoveryArchives"),includingPropertiesForKeys:nil)
        #expect(try archives.contains {try Data(contentsOf:$0.appendingPathComponent(EditingRecoveryIntent.leaf)) == bytes})
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment[recoveryChildDirectory] != nil))
    func recoveryCrashChildOnly() async throws {
        let directory = URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment[recoveryChildDirectory]),isDirectory:true)
        let requested = try #require(ProcessInfo.processInfo.environment[recoveryChildPhase])
        let resources = ArtifactResourceOwner(limits:try .init()),gate = CatalogLifecycleGate(requiresRecovery:false)
        let artifacts = try await GeneratedArtifactStore.open(in:directory,resources:resources,lifecycleGate:gate)
        let packages = EditingBackupPackageStore(resources:resources,catalog:CatalogRepository(directory:directory))
        let hooks = EditingRepositoryHooks(recoveryCheckpoint:{point in
            switch point {
            case .intentDurable: if requested == "intent" {Darwin._exit(73)}
            case .memberMoved(let name):
                if requested == "main" && name == "edits.sqlite" {Darwin._exit(73)}
                if requested == "journal" && name == "edits.sqlite-journal" {Darwin._exit(73)}
            case .candidateInstalled: if requested == "candidate" {Darwin._exit(73)}
            case .intentRemoved: if requested == "completed" {Darwin._exit(73)}
            }
        })
        let repository = EditingRepository(directory:directory,artifacts:artifacts,packages:packages,gate:gate,hooks:hooks)
        let empty = try await repository.loadState()
        _ = try await repository.saveSnapshot(EditingSnapshot(settings:EditSettings(exposure:1.5)),for:recoveryAssetID,expected:.init(storeEpoch:empty.storeEpoch,revision:nil,snapshot:nil),revision:1)
        let backup = try await repository.createBackup(automatic:false)
        try recoveryDamagedBytes.write(to:repository.fileURL,options:.atomic)
        try recoveryJournalBytes.write(to:URL(fileURLWithPath:repository.fileURL.path+"-journal"))
        let coordinator = JointCatalogCoordinator(repository:.init(directory:directory),editing:repository,gate:gate)
        _ = try await coordinator.recoverEditingDatabase(from:backup)
        Issue.record("Requested process-exit checkpoint was never reached")
        Darwin._exit(74)
    }
}
private let recoveryChildDirectory = "PICEDIT_TEST_RECOVERY_CRASH_DIRECTORY"
private let recoveryChildPhase = "PICEDIT_TEST_RECOVERY_CRASH_PHASE"
private let recoveryAssetID = "/synthetic/recovery-source"
private let recoveryDamagedBytes = Data("damaged original SQL bytes must survive recovery crash".utf8)
private let recoveryJournalBytes = Data("unknown original journal bytes must survive recovery crash".utf8)
private func runRecoveryChild(_ directory:URL,phase:String) throws {
    let invocation = CommandLine.arguments
    let child = Process();child.executableURL = URL(fileURLWithPath:invocation[0])
    var arguments:[String] = []
    if let index = invocation.firstIndex(of:"--test-bundle-path"),index+1 < invocation.count {arguments = ["--test-bundle-path",invocation[index+1]]}
    child.arguments = arguments+["--testing-library","swift-testing","--filter","recoveryCrashChildOnly"]
    var environment = ProcessInfo.processInfo.environment
    environment[recoveryChildDirectory] = directory.path;environment[recoveryChildPhase] = phase
    child.environment = environment;child.standardOutput = FileHandle.nullDevice;child.standardError = FileHandle.nullDevice
    try child.run();child.waitUntilExit()
    try #require(child.terminationReason == .exit && child.terminationStatus == 73)
}
