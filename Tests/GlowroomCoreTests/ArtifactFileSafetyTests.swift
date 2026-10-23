import Foundation
import Darwin
import Testing
@testable import GlowroomCore

@Suite(.timeLimit(.minutes(1)))
struct ArtifactFileSafetyTests {
    @Test func unownedArtifactRootAndHardlinkedOwnerArePreserved() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let root = fixture.directory.appendingPathComponent("GeneratedArtifacts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let sentinel = root.appendingPathComponent("foreign.txt"); let bytes = Data("foreign".utf8); try bytes.write(to: sentinel)
        await #expect(throws: ArtifactContractError.invalidCapability) { _ = try await fixture.store() }
        #expect(try Data(contentsOf: sentinel) == bytes)
        try FileManager.default.removeItem(at: root)
        _ = try await fixture.store()
        let owner = root.appendingPathComponent(".owner.json")
        let ownerBytes = try Data(contentsOf: owner)
        let alias = fixture.directory.appendingPathComponent("owner-alias.json")
        try FileManager.default.linkItem(at: owner, to: alias)
        await #expect(throws: ArtifactContractError.corruptArtifact) { _ = try await fixture.store() }
        #expect(try Data(contentsOf: alias) == ownerBytes)
        #expect(try Data(contentsOf: owner) == ownerBytes)
    }
    @Test func symlinkedRasterNeverReadsOrModifiesForeignTarget() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let store = try await fixture.store(); let image = fixture.image()
        let draft = try await store.stageRaster(.init(immutableImage: image), provenance: fixture.provenance(image), masks: [])
        _ = try await store.publish(draft, commitID: .init())
        let raster = fixture.directory.appendingPathComponent("GeneratedArtifacts/\(draft.artifact.id.canonicalString)/raster.png")
        let foreign = fixture.directory.appendingPathComponent("foreign-original.png")
        let before = try Data(contentsOf: raster); try before.write(to: foreign)
        try FileManager.default.removeItem(at: raster)
        try FileManager.default.createSymbolicLink(at: raster, withDestinationURL: foreign)
        await #expect(throws: (any Error).self) { _ = try await store.openVerifiedRaster(draft.artifact.id) }
        #expect(try Data(contentsOf: foreign) == before)
    }
    @Test func occupiedPublicationAndUnknownUUIDStageStayIntact() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let store = try await fixture.store(); let image = fixture.image()
        let draft = try await store.stageRaster(.init(immutableImage: image), provenance: fixture.provenance(image), masks: [])
        let root = fixture.directory.appendingPathComponent("GeneratedArtifacts")
        let foreign = root.appendingPathComponent(draft.artifact.id.canonicalString)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        let sentinel = foreign.appendingPathComponent("foreign.txt"); try Data([17]).write(to: sentinel)
        await #expect(throws: (any Error).self) { _ = try await store.publish(draft, commitID: .init()) }
        let unknownID = UUID().uuidString.lowercased()
        let unknown = root.appendingPathComponent(".staging/" + unknownID)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        let other = unknown.appendingPathComponent("foreign.txt"); try Data([29]).write(to: other)
        let result = try await store.recoverStagingAndReportOrphans(referenced: [])
        #expect(result.unrecognizedEntries.contains(".staging/" + unknownID))
        #expect(result.removedOwnedStagingCount == 0)
        #expect(try Data(contentsOf: sentinel) == Data([17]))
        #expect(try Data(contentsOf: other) == Data([29]))
    }
    @Test func failedExclusiveRenameRetriesSameDurableDraftClaim() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let store = try await fixture.store(); let image = fixture.image()
        let draft = try await store.stageRaster(.init(immutableImage: image), provenance: fixture.provenance(image), masks: [])
        let destination = fixture.directory.appendingPathComponent("GeneratedArtifacts/\(draft.artifact.id.canonicalString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("foreign.txt"); try Data([71]).write(to: sentinel)
        let commit = EditingCommitID()
        await #expect(throws: (any Error).self) { _ = try await store.publish(draft, commitID: commit) }
        #expect(try Data(contentsOf: sentinel) == Data([71]))
        // Explicit fixture action models the user removing the conflicting
        // foreign destination. The failed publisher itself must never do this.
        try FileManager.default.removeItem(at: destination)
        let publication = try await store.publish(draft, commitID: commit)
        try await store.validatePublication(publication)
        await #expect(throws: ArtifactContractError.conflictingCommit) { _ = try await store.publish(draft, commitID: .init()) }
    }
    @Test func fileHandleNeverAllowsUnboundedOrOverflowRead() throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let directory = try ArtifactFileIO.root(fixture.directory, create: false)
        let file = try ArtifactFileIO.openFile(directory, "original.bin")
        let handle = try file.handle(ownership: nil)
        #expect(throws: ArtifactContractError.invalidValue("bounded read")) { _ = try handle.read(offset: 0, maximumCount: 65_537) }
        #expect(throws: ArtifactContractError.invalidValue("bounded read")) { _ = try handle.read(offset: .max) }
        #expect(try handle.read(offset: handle.bytes).isEmpty)
    }
}

private final class ArtifactCleanupObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    private let events: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func finish(_ cleaned: Bool) {
        let first = lock.withLock {
            guard value == nil else { return false }
            value = cleaned
            return true
        }
        if first { continuation.yield(cleaned); continuation.finish() }
    }
    var result: Bool? { lock.withLock { value } }

    func wait() async -> Bool? {
        // The callback can arrive before registration or while the cooperative
        // executor is busy. Buffer the result instead of racing a polling clock.
        var iterator = events.makeAsyncIterator()
        return await iterator.next()
    }
}
extension ArtifactFileSafetyTests {
    private func privateStage(_ fixture: ArtifactTestFixture) throws -> ArtifactDirectory {
        let parent = try ArtifactFileIO.root(fixture.directory, create: false)
        let name = ".private-package-stage-" + UUID().uuidString.lowercased()
        guard mkdirat(parent.fd.value, name, 0o700) == 0 else { throw ArtifactContractError.invalidCapability }
        return try ArtifactFileIO.child(parent, name)
    }
    private func stageLease(_ ownership: ArtifactPrivateStageOwnership) -> ArtifactLease {
        ArtifactLease(storeID: .init(), artifactIDs: [], purpose: .restore, nonce: UUID(), releaseOwnership: { withExtendedLifetime(ownership) {} })
    }
    @Test func privateStageCleanupWaitsForLastActualReadHandle() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let directory = try privateStage(fixture); let observation = ArtifactCleanupObservation()
        var ownership: ArtifactPrivateStageOwnership? = try .init(stage: directory, onCleanup: { observation.finish($0) })
        try ArtifactFileIO.writeSmall(directory, "owned.bin", bytes: Data([1, 2]), ownership: ownership)
        var lease: ArtifactLease? = stageLease(try #require(ownership))
        var handle: ArtifactFileReadHandle? = try ArtifactFileIO.openFile(directory, "owned.bin").handle(ownership: lease)
        ownership = nil; lease = nil
        #expect(observation.result == nil)
        #expect(FileManager.default.fileExists(atPath: directory.url.path))
        #expect(try handle?.read(offset: 0) == Data([1, 2]))
        handle = nil
        let cleaned = try #require(await observation.wait(), "Private-stage cleanup ended without its callback")
        #expect(cleaned)
        #expect(!FileManager.default.fileExists(atPath: directory.url.path))
    }
    @Test func privateCleanupPreflightPreservesWholeUnknownTree() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let directory = try privateStage(fixture); let observation = ArtifactCleanupObservation()
        var ownership: ArtifactPrivateStageOwnership? = try .init(stage: directory, onCleanup: { observation.finish($0) })
        try ArtifactFileIO.writeSmall(directory, "owned.bin", bytes: Data([4]), ownership: ownership)
        let unknown = directory.url.appendingPathComponent("foreign.txt"); try Data([9]).write(to: unknown)
        ownership = nil
        let cleaned = try #require(await observation.wait(), "Private-stage cleanup ended without its callback")
        #expect(!cleaned)
        #expect(try Data(contentsOf: unknown) == Data([9]))
        #expect(try Data(contentsOf: directory.url.appendingPathComponent("owned.bin")) == Data([4]))
    }
    @Test func privateCleanupRejectsEqualByteReplacementBeforeAnyUnlink() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let directory = try privateStage(fixture); let observation = ArtifactCleanupObservation()
        var ownership: ArtifactPrivateStageOwnership? = try .init(stage: directory, onCleanup: { observation.finish($0) })
        try ArtifactFileIO.writeSmall(directory, "first.bin", bytes: Data([5]), ownership: ownership)
        try ArtifactFileIO.writeSmall(directory, "replaced.bin", bytes: Data([8]), ownership: ownership)
        try Data([8]).write(to: directory.url.appendingPathComponent("replaced.bin"), options: .atomic)
        ownership = nil
        let cleaned = try #require(await observation.wait(), "Private-stage cleanup ended without its callback")
        #expect(!cleaned)
        #expect(try Data(contentsOf: directory.url.appendingPathComponent("first.bin")) == Data([5]))
        #expect(try Data(contentsOf: directory.url.appendingPathComponent("replaced.bin")) == Data([8]))
        #expect(ArtifactPrivateStageOwnership.cleanupDiagnostics().pendingJobs <= 16)
    }
}

extension ArtifactFileSafetyTests {
    @Test(arguments: [false, true])
    func privateCleanupObservationRetainsResultBeforeWaiterRegisters(cleaned: Bool) async throws {
        let observation = ArtifactCleanupObservation()
        observation.finish(cleaned)
        // A completed stream still owes its buffered result to a late waiter.
        // No elapsed-time assumption or live cleanup queue is needed here.
        #expect(try #require(await observation.wait()) == cleaned)
    }
}
