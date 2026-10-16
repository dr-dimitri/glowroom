import Foundation
import Darwin
import Testing
@testable import PicEditCore

@Suite("Editing SQLite coordinates in-process inode scopes", .serialized, .timeLimit(.minutes(1)))
struct EditingDatabaseCooperationTests {
    @Test func actualJournalContentionThroughNativeAliasProducesOneCASWinner() async throws {
        let probe = EditingCooperationProbe()
        let f = try EditingFixture(hooks:.init(beforeCommit:{try probe.holdCommit()}))
        let state = try await f.repository.loadState()
        let alias = f.directory.appendingPathComponent("native-alias",isDirectory:true)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:f.directory)
        let second = EditingRepository(directory:alias,artifacts:f.artifacts,packages:f.packages,gate:f.gate,
            hooks:.init(databaseContention:{probe.contended()}))
        let expected = try EditingExpectedState(storeEpoch:state.storeEpoch,revision:nil,snapshot:nil)
        let first = try EditingSnapshot(settings:EditSettings(exposure:1))
        let other = try EditingSnapshot(settings:EditSettings(exposure:2))
        let writer = Task.detached {try await f.repository.saveSnapshot(first,for:"asset",expected:expected,revision:1)}
        defer{probe.release()}
        try await probe.waitFor(.entered)
        #expect(FileManager.default.fileExists(atPath:f.repository.fileURL.path+"-journal"))
        let contender = Task.detached {try await second.saveSnapshot(other,for:"asset",expected:expected,revision:1)}
        try await probe.waitFor(.contention)
        // Admission was actually attempted while the first real journal lived.
        // Releasing its owner must yield stale CAS, never crash recovery.
        probe.release()
        let committed = try await writer.value
        await #expect(throws:ArtifactContractError.staleSnapshot) {_ = try await contender.value}
        #expect(try await second.loadState().byAsset["asset"] == committed)
        #expect(!FileManager.default.fileExists(atPath:f.repository.fileURL.path+"-journal"))
    }

    @Test(arguments:["state","variants","identity","receipt"])
    func cachedReadersWaitForActualWriterWithoutSeeingItsJournal(reader:String) async throws {
        let probe = EditingCooperationProbe()
        let f = try EditingFixture(hooks:.init(beforeCommit:{try probe.holdCommit()}))
        let state = try await f.repository.loadState()
        let second = EditingRepository(directory:f.directory,artifacts:f.artifacts,packages:f.packages,gate:f.gate,
            hooks:.init(databaseContention:{probe.contended()}))
        _ = try await second.loadState() // Exercise an ALREADY CACHED native fd.
        let snapshot = try EditingSnapshot(settings:EditSettings(exposure:1))
        let expected = try EditingExpectedState(storeEpoch:state.storeEpoch,revision:nil,snapshot:nil)
        let writer = Task.detached {try await f.repository.saveSnapshot(snapshot,for:"asset",expected:expected,revision:1)}
        defer{probe.release()}
        try await probe.waitFor(.entered)
        let observer = Task.detached { () async throws -> Bool in
            switch reader {
            case "state": return try await second.loadState().byAsset["asset"]?.snapshot == snapshot
            case "variants": return try await second.variants(for:"asset").isEmpty
            case "identity": return try await second.participantStoreIdentity().kind == .editing
            default: return try await second.committed(.init()) == nil
            }
        }
        try await probe.waitFor(.contention)
        probe.release()
        _ = try await writer.value
        #expect(try await observer.value)
    }

    @Test func competingFirstOpenCreatesOneStableStoreWithoutEmptyFileObservation() async throws {
        let f = try EditingFixture(createDirectory:false),second = f.reopen()
        async let first = f.repository.loadState()
        async let other = second.loadState()
        let (a,b) = try await (first,other)
        #expect(a.storeEpoch == b.storeEpoch)
        let firstIdentity = try await f.repository.participantStoreIdentity()
        let secondIdentity = try await second.participantStoreIdentity()
        #expect(firstIdentity == secondIdentity)
        #expect(try await f.repository.loadState().byAsset.isEmpty)
    }

    @Test func cancellationWhileCooperativeOwnerLivesPreservesForeignSidecars() async throws {
        let probe = EditingCooperationProbe(),f = try EditingFixture()
        let state = try await f.repository.loadState()
        let holder = open(f.repository.fileURL.path,O_RDONLY|O_CLOEXEC)
        #expect(holder >= 0);guard holder >= 0 else {return}
        defer{close(holder)}
        let owner = try EditingDatabaseAccess.acquire(fd:holder,url:f.repository.fileURL)
        defer{owner.release()}
        let journal = URL(fileURLWithPath:f.repository.fileURL.path+"-journal")
        let foreign = Data("foreign journal is never admitted by a process identity mutex".utf8)
        try foreign.write(to:journal)
        let main = try Data(contentsOf:f.repository.fileURL)
        let second = EditingRepository(directory:f.directory,artifacts:f.artifacts,packages:f.packages,gate:f.gate,
            hooks:.init(databaseContention:{probe.contended()}))
        let snapshot = try EditingSnapshot(settings:EditSettings(exposure:2))
        let expected = try EditingExpectedState(storeEpoch:state.storeEpoch,revision:nil,snapshot:nil)
        let waiting = Task.detached {try await second.saveSnapshot(snapshot,for:"asset",expected:expected,revision:1)}
        try await probe.waitFor(.contention)
        waiting.cancel()
        await #expect(throws:CancellationError.self) {_ = try await waiting.value}
        #expect(try Data(contentsOf:f.repository.fileURL) == main)
        #expect(try Data(contentsOf:journal) == foreign)
        owner.release()
        // Even after the cooperating owner returns, an unknown journal
        // must still fail closed with exactly the same bytes.
        await #expect(throws:EditingRepositoryError.recoveryRequired) {_ = try await second.loadState()}
        #expect(try Data(contentsOf:journal) == foreign)
    }

    @Test(arguments:[false,true])
    func healthyWriterTimeoutOrCancellationNeverBecomesDamagedRecovery(cancel:Bool) async throws {
        let probe = EditingCooperationProbe(holdTimeout:5),f = try EditingFixture()
        let first = try await f.save(exposure:0.5),backup = try await f.repository.createBackup(automatic:false)
        // An independent gate models a second repository in this process. The
        // identity mutex must coordinate actors beyond one gate/DI instance.
        let writer = EditingRepository(directory:f.directory,artifacts:f.artifacts,packages:f.packages,
            gate:CatalogLifecycleGate(requiresRecovery:false),hooks:.init(beforeCommit:{try probe.holdCommit()}))
        let recovery = EditingRepository(directory:f.directory,artifacts:f.artifacts,packages:f.packages,gate:f.gate,
            hooks:.init(databaseContention:{probe.contended()}))
        let coordinator = JointCatalogCoordinator(repository:.init(directory:f.directory),editing:recovery,gate:f.gate)
        let saving = Task.detached {try await writer.saveSnapshot(EditingSnapshot(settings:EditSettings(exposure:2)),for:f.id,expected:.init(first),revision:2)}
        defer{probe.release()}
        try await probe.waitFor(.entered)
        let main = try readSyntheticMain(f.repository.fileURL)
        let journalURL = URL(fileURLWithPath:f.repository.fileURL.path+"-journal")
        let journal = try Data(contentsOf:journalURL)
        let restoring = Task.detached {try await coordinator.recoverEditingDatabase(from:backup)}
        try await probe.waitFor(.contention)
        if cancel {
            restoring.cancel()
            await #expect(throws:CancellationError.self) {_ = try await restoring.value}
        } else {
            await #expect(throws:EditingRepositoryError.databaseBusy) {_ = try await restoring.value}
        }
        #expect(try readSyntheticMain(f.repository.fileURL) == main)
        #expect(try Data(contentsOf:journalURL) == journal)
        #expect(!FileManager.default.fileExists(atPath:f.directory.appendingPathComponent("EditingRecoveryArchives").path))
        #expect(!FileManager.default.fileExists(atPath:f.directory.appendingPathComponent(EditingRecoveryIntent.leaf).path))
        probe.release()
        let committed = try await saving.value
        #expect(try await recovery.loadState().byAsset[f.id] == committed)
    }

    @Test func finalRecoveryInstallCannotMoveANativelyLockedOldMain() async throws {
        let owner = EditingRecoveryNativeOwner()
        defer{owner.release()}
        let f = try EditingFixture(hooks:.init(beforeRecoveryInstall:{try owner.hold()}))
        let first = try await f.save(exposure:0.5),backup = try await f.repository.createBackup(automatic:false)
        let damaged = Data("opaque original must not move while native owner lives".utf8)
        try damaged.write(to:f.repository.fileURL,options:.atomic)
        owner.url = f.repository.fileURL
        let coordinator = JointCatalogCoordinator(repository:.init(directory:f.directory),editing:f.repository,gate:f.gate)
        await #expect(throws:EditingRepositoryError.databaseBusy) {_ = try await coordinator.recoverEditingDatabase(from:backup)}
        #expect(try Data(contentsOf:f.repository.fileURL) == damaged)
        #expect(!FileManager.default.fileExists(atPath:f.directory.appendingPathComponent(EditingRecoveryIntent.leaf).path))
        let archives = try FileManager.default.contentsOfDirectory(at:f.directory.appendingPathComponent("EditingRecoveryArchives"),includingPropertiesForKeys:nil)
        let raw = try #require(archives.first)
        #expect(try Data(contentsOf:raw.appendingPathComponent("edits.sqlite")) == damaged)
        #expect(try FileManager.default.contentsOfDirectory(atPath:raw.appendingPathComponent("original-inodes").path).isEmpty)
        owner.release()
        let restored = try await coordinator.recoverEditingDatabase(from:backup)
        #expect(restored.byAsset[f.id]?.snapshot == first.snapshot)
    }

    @Test(arguments:["open","readOnly"])
    func canceledPinAndArtifactDropCannotUnlockAnotherActorsRealSQLiteTransaction(path:String) async throws {
        var phase = "fixture"
        let probe = EditingCooperationProbe(holdTimeout:5)
        do {
        let f = try EditingFixture(hooks:.init(beforeCommit:{try probe.holdCommit()}))
        phase = "initial-load"
        let initial = try await f.repository.loadState()
        // A cached connection/native FD must also close safely while another
        // connection owns actual POSIX SQLite locks on this same inode.
        var idle:EditingSQLite? = EditingSQLite(directory:f.directory)
        phase = "idle-open"
        _ = try idle?.open(validateRows:EditingRepository.validateRows)
        let replacement = EditingSQLite(directory:f.directory)
        phase = "replacement-open"
        _ = try replacement.open(validateRows:EditingRepository.validateRows)
        let second = EditingRepository(directory:f.directory,artifacts:f.artifacts,packages:f.packages,gate:f.gate,
            hooks:.init(databaseContention:{probe.contended()}))
        let expected = try EditingExpectedState(storeEpoch:initial.storeEpoch,revision:nil,snapshot:nil)
        let writer = Task.detached {try await f.repository.saveSnapshot(EditingSnapshot(settings:EditSettings(exposure:1)),for:"asset",expected:expected,revision:1)}
        defer{probe.release()}
        phase = "await-parent-entered"
        try await probe.waitFor(.entered)
        phase = "child-parent-held"
        #expect(try externalSQLiteCanBegin(f.repository.fileURL,phase:"parent-held") == false)
        let waiting = Task.detached { () async throws -> Void in
            if path == "open" {_ = try await second.loadState()}
            else {_ = try EditingSQLite.readOnly(f.repository.fileURL,onContention:{probe.contended()}) {_,_ in true}}
        }
        phase = "await-pin-contention"
        try await probe.waitFor(.contention)
        waiting.cancel()
        await #expect(throws:CancellationError.self) {try await waiting.value}
        #expect(try externalSQLiteCanBegin(f.repository.fileURL,phase:"pin-cancelled") == false)
        idle = nil
        phase = "replacement-close"
        try replacement.closeForReplacement()
        #expect(try externalSQLiteCanBegin(f.repository.fileURL,phase:"cached-connections-closed") == false)
        // This exercises the REAL B ownership hook, not just the helper API.
        do {
            let directory = try ArtifactFileIO.root(f.directory,create:false)
            let file = try ArtifactFileIO.openFile(directory,"edits.sqlite")
            withExtendedLifetime(file){}
        }
        #expect(try externalSQLiteCanBegin(f.repository.fileURL,phase:"artifact-pin-dropped") == false)
        phase = "source-capture"
        _ = try AssetRemapVerifier.capture(f.repository.fileURL,referenceDate:Date())
        #expect(MetadataCatalogSourceReader.nativeStamp(f.repository.fileURL) != nil)
        #expect(try externalSQLiteCanBegin(f.repository.fileURL,phase:"source-capture-and-stamp") == false)
        probe.release()
        phase = "parent-commit-result"
        let committed = try await writer.value
        phase = "child-parent-committed"
        #expect(try externalSQLiteCanBegin(f.repository.fileURL,phase:"parent-committed"))
        phase = "final-second-load"
        #expect(try await second.loadState().byAsset["asset"] == committed)
        } catch {throw SQLiteCooperationStepFailure(path:path,phase:phase,error:String(reflecting:error))}
    }

    @Test func rejectedHardlinkKeepsKernelLocksUntilControlledParentFailureReturns() async throws {
        let probe = EditingCooperationProbe(holdTimeout:5),f = try EditingFixture()
        let previous = try await f.save(exposure:0.5)
        let writer = EditingRepository(directory:f.directory,artifacts:f.artifacts,packages:f.packages,gate:f.gate,
            hooks:.init(beforeCommit:{try probe.holdCommit()}))
        let nextSnapshot = try EditingSnapshot(settings:EditSettings(exposure:2))
        let saving = Task.detached {try await writer.saveSnapshot(nextSnapshot,for:f.id,expected:.init(previous),revision:2)}
        defer{probe.release()}
        try await probe.waitFor(.entered)
        #expect(try externalSQLiteCanBegin(f.repository.fileURL,phase:"hardlink-parent-held") == false)
        let alias = f.directory.appendingPathComponent(".automatic-backup.lock")
        #expect(link(f.repository.fileURL.path,alias.path) == 0)
        do {
            let directory = try ArtifactFileIO.root(f.directory,create:false)
            #expect(throws:ArtifactContractError.corruptArtifact) {try ArtifactFileIO.withAutomaticBackupLock(directory){true}}
        }
        #expect(try externalSQLiteCanBegin(f.repository.fileURL,phase:"hardlink-rejected") == false)
        #expect(unlink(alias.path) == 0)
        #expect(try externalSQLiteCanBegin(f.repository.fileURL,phase:"hardlink-unlinked") == false)
        probe.release()
        // Apple's SQLite3.54 reports SQLITE_IOERR_VNODE(6922) after this
        // temporary hardlink mutation (NativeProbeFoundation.swift proves both
        // unlink variants). Older VFS implementations may legitimately commit
        // after the original namespace is restored. Require either EXACT state;
        // neither branch may lose the lock before the actual parent return.
        let committed:StoredEditingState?
        do {committed = try await saving.value}
        catch EditingRepositoryError.storageFailure {committed = nil}
        let fresh = f.reopen()
        if let committed {
            #expect(committed.snapshot == nextSnapshot)
            #expect(committed.version == (try EditingStoreVersion(storeEpoch:previous.version.storeEpoch,revision:2)))
            #expect(try await fresh.loadState().byAsset[f.id] == committed)
            #expect(try externalSQLiteCanBegin(f.repository.fileURL,phase:"hardlink-parent-committed"))
            return
        }
        do {
            let state = try await fresh.loadState()
            #expect(state.byAsset[f.id] == previous)
            #expect(try externalSQLiteCanBegin(f.repository.fileURL,phase:"hardlink-parent-returned"))
        }catch EditingRepositoryError.recoveryRequired {
            // A platform may preserve its failed transaction's journal rather
            // than finish rollback. In that case prove conservative, repeatable
            // recovery state and byte preservation, never claim a clean rollback.
            let family = try readSyntheticSQLiteFamily(f.repository.fileURL)
            #expect(family["edits.sqlite"] != nil)
            await #expect(throws:EditingRepositoryError.recoveryRequired) {_ = try await f.reopen().loadState()}
            #expect(try readSyntheticSQLiteFamily(f.repository.fileURL) == family)
        }
    }

    @Test func actualNativeCloseWaitsForScopeReleaseAndIsThenDrained() async throws {
        let f = try EditingFixture();_ = try await f.repository.loadState()
        let reservation = try EditingDatabaseAccess.reserveNativeFile()
        let fd = open(f.repository.fileURL.path,O_RDONLY|O_CLOEXEC)
        #expect(fd >= 0);guard fd >= 0 else {return}
        let native = reservation.own(fd)
        var before = stat();#expect(fstat(fd,&before) == 0)
        let owner = try EditingDatabaseAccess.acquire(fd:fd,url:f.repository.fileURL)
        native.close()
        #expect(fcntl(fd,F_GETFD) >= 0)
        owner.release()
        // Another concurrently running test may already have reused the FD
        // number; require that OUR inode is gone, rather than assuming EBADF.
        var after = stat()
        if fstat(fd,&after) == 0 {#expect(before.st_dev != after.st_dev || before.st_ino != after.st_ino)}
        else {#expect(errno == EBADF)}
        // Both close methods are idempotent, without retaining an inactive ID.
        native.close();owner.release()
        _ = try await f.reopen().loadState()
    }

    @Test func synchronousReadRejectsNamedReplacementBeforePublishingItsResult() async throws {
        let f = try EditingFixture();_ = try await f.repository.loadState()
        let sql = EditingSQLite(directory:f.directory)
        let db = try sql.open(validateRows:EditingRepository.validateRows)
        let original = try Data(contentsOf:f.repository.fileURL)
        let moved = f.directory.appendingPathComponent("moved-read-source.sqlite")
        #expect(throws:EditingRepositoryError.invalidDatabase) {
            _ = try sql.read(db) {
                let value = try EditingSQLite.scalar(db,"PRAGMA user_version")
                try FileManager.default.moveItem(at:f.repository.fileURL,to:moved)
                try original.write(to:f.repository.fileURL)
                return value
            }
        }
        #expect(try Data(contentsOf:moved) == original)
        #expect(try Data(contentsOf:f.repository.fileURL) == original)
    }

    @Test func cooperativeContentionHasBoundedDeadlineAndRejectsReplacedNamedInode() async throws {
        let f = try EditingFixture();_ = try await f.repository.loadState()
        let holder = open(f.repository.fileURL.path,O_RDONLY|O_CLOEXEC)
        let contender = open(f.repository.fileURL.path,O_RDONLY|O_CLOEXEC)
        #expect(holder >= 0 && contender >= 0);guard holder >= 0 && contender >= 0 else {return}
        defer{close(holder);close(contender)}
        let owner = try EditingDatabaseAccess.acquire(fd:holder,url:f.repository.fileURL)
        defer{owner.release()}
        let before = try Data(contentsOf:f.repository.fileURL)
        #expect(throws:EditingRepositoryError.databaseBusy) {
            _ = try EditingDatabaseAccess.acquire(fd:contender,url:f.repository.fileURL,timeout:.milliseconds(20))
        }
        #expect(try Data(contentsOf:f.repository.fileURL) == before)
        owner.release()
        let previous = f.directory.appendingPathComponent("previous.sqlite")
        try FileManager.default.moveItem(at:f.repository.fileURL,to:previous)
        try before.write(to:f.repository.fileURL)
        #expect(throws:EditingRepositoryError.invalidDatabase) {
            _ = try EditingDatabaseAccess.acquire(fd:contender,url:f.repository.fileURL)
        }
        #expect(try Data(contentsOf:previous) == before)
        #expect(try Data(contentsOf:f.repository.fileURL) == before)
    }
}

private final class EditingCooperationProbe:@unchecked Sendable {
    enum Point:Equatable {case entered,contention}
    private let lock = NSLock(),resumeCommit = DispatchSemaphore(value:0)
    private var entered = false,contention = false,released = false
    private let holdTimeout:TimeInterval
    init(holdTimeout:TimeInterval = 1.5){self.holdTimeout = holdTimeout}
    func holdCommit() throws {
        lock.withLock{entered = true}
        guard resumeCommit.wait(timeout:.now()+holdTimeout) == .success else {throw EditingRepositoryError.storageFailure}
    }
    func contended(){lock.withLock{contention = true}}
    func release(){let shouldResume = lock.withLock{if released{return false};released = true;return true};if shouldResume{resumeCommit.signal()}}
    func waitFor(_ point:Point) async throws {
        let deadline = ContinuousClock.now.advanced(by:.seconds(1))
        while !lock.withLock({point == .entered ? entered : contention}) {
            guard ContinuousClock.now < deadline else {throw EditingRepositoryError.storageFailure}
            try await Task.sleep(for:.milliseconds(1))
        }
    }
}

private final class EditingRecoveryNativeOwner:@unchecked Sendable {
    private let lock = NSLock()
    private var descriptor:Int32 = -1,target:URL?
    var url:URL?{get{lock.withLock{target}}set{lock.withLock{target = newValue}}}
    func hold() throws {
        try lock.withLock {
            guard let target else {return}
            guard descriptor < 0 else {throw EditingRepositoryError.storageFailure}
            let fd = open(target.path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
            guard fd >= 0 else {throw EditingRepositoryError.storageFailure}
            guard flock(fd,LOCK_EX|LOCK_NB) == 0 else {close(fd);throw EditingRepositoryError.databaseBusy}
            descriptor = fd
        }
    }
    func release(){lock.withLock{if descriptor >= 0{_ = flock(descriptor,LOCK_UN);close(descriptor);descriptor = -1};target = nil}}
}

/// Fresh process uses the actual system SQLite and its kernel locks. A zero
/// timeout makes this a bounded lock probe; it never mutates rows or sidecars.
private func externalSQLiteCanBegin(_ url:URL,phase:String) throws -> Bool {
    let process = Process(),output = Pipe()
    process.executableURL = URL(fileURLWithPath:"/usr/bin/sqlite3")
    // Only BEGIN: a following ROLLBACK hides a failed BEGIN's busy diagnostic
    // with "no transaction is active" in the macOS CLI. Process exit rolls back
    // a successful BEGIN. Never read user ~/.sqliterc in a synthetic test.
    process.arguments = ["-batch","-init","/dev/null","-cmd",".timeout 0",url.path,"BEGIN IMMEDIATE;"]
    process.standardOutput = output;process.standardError = output
    let ended = DispatchSemaphore(value:0)
    process.terminationHandler = {_ in ended.signal()}
    try process.run()
    guard ended.wait(timeout:.now()+5) == .success else {
        process.terminate();process.waitUntilExit()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        throw ExternalSQLiteProbeFailure(phase:phase,status:process.terminationStatus,output:String(decoding:bytes.prefix(65_536),as:UTF8.self),timedOut:true)
    }
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    if process.terminationStatus == 0 {return true}
    let text = String(decoding:bytes.prefix(65_536),as:UTF8.self)
    guard text.contains("database is locked") else {
        throw ExternalSQLiteProbeFailure(phase:phase,status:process.terminationStatus,output:text,timedOut:false)
    }
    return false
}

private struct ExternalSQLiteProbeFailure:Error,CustomStringConvertible,Sendable {
    let phase:String,status:Int32,output:String,timedOut:Bool,reportPath:String?
    init(phase:String,status:Int32,output:String,timedOut:Bool) {
        self.phase = phase;self.status = status;self.output = output;self.timedOut = timedOut
        let directory = URL(fileURLWithPath:"/private/tmp/picedit-external-sqlite-diagnostics",isDirectory:true)
        let target = directory.appendingPathComponent(UUID().uuidString+".json")
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let payload:[String:Any] = ["phase":phase,"status":status,"output":output,"timedOut":timedOut]
            let data = try JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys])
            try data.write(to:target,options:.withoutOverwriting);reportPath = target.path
        }catch{reportPath = nil}
    }
    var description:String {"External SQLite probe phase=\(phase), status=\(status), timeout=\(timedOut), output=\(output), report=\(reportPath ?? "unavailable")"}
}

private struct SQLiteCooperationStepFailure:Error,CustomStringConvertible,Sendable {
    let path:String,phase:String,error:String
    var description:String {"SQLite cooperation path=\(path), phase=\(phase), error=\(error)"}
}

/// Test reads of an active SQL main use the same bounded close capability as
/// production. Foundation Data(contentsOf: URL) could close an independent FD
/// and silently invalidate the kernel-lock assertion being tested.
private func readSyntheticMain(_ url:URL) throws -> Data {
    let root = try ArtifactFileIO.root(url.deletingLastPathComponent(),create:false)
    let file = try ArtifactFileIO.openFile(root,url.lastPathComponent,limit:524_288)
    var bytes = Data(),offset:Int64 = 0
    while offset < file.stamp.bytes {
        let chunk = try file.read(offset:offset,count:Int(min(65_536,file.stamp.bytes-offset)))
        guard !chunk.isEmpty else {throw EditingRepositoryError.storageFailure}
        bytes.append(chunk);offset += Int64(chunk.count)
    }
    return bytes
}

private func readSyntheticSQLiteFamily(_ url:URL) throws -> [String:Data] {
    var result:[String:Data] = [:]
    for suffix in ["","-journal","-wal","-shm"] {
        let member = URL(fileURLWithPath:url.path+suffix)
        if FileManager.default.fileExists(atPath:member.path) {result[member.lastPathComponent] = try readSyntheticMain(member)}
    }
    return result
}
