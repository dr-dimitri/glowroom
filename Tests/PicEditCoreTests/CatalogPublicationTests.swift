import Darwin
import Foundation
import Testing
@testable import PicEditCore

@Suite("Catalog exact-byte publication")
struct CatalogPublicationTests {
    @Test func preparedBytesRemainExactAcrossStageAndReloadIncludingAdjacentDates() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = CatalogRepository(directory: root)
        let date = Date(timeIntervalSinceReferenceDate: 810_000_000.1234567.nextUp)
        let folder = LibraryFolder(url: root.appendingPathComponent("Photos"), addedAt: date)
        let photo = PhotoAsset(folderID: folder.id, fileURL: folder.url.appendingPathComponent("a.raw"),
                               createdAt: date, modifiedAt: Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.nextDown))
        let prepared = try repository.prepare(.init(folders: [folder], assets: [photo]))
        let stage = try repository.stage(prepared); defer { repository.discard(stage) }
        #expect(try repository.loadStored().reference == .absent)
        try repository.publish(stage, expected: .absent)
        let loaded = try repository.loadStored()
        #expect(loaded.reference == prepared.reference)
        #expect(loaded.catalog.folders[0].addedAt.timeIntervalSinceReferenceDate.bitPattern == date.timeIntervalSinceReferenceDate.bitPattern)
        #expect(loaded.catalog.assets[0].modifiedAt.timeIntervalSinceReferenceDate.bitPattern == photo.modifiedAt.timeIntervalSinceReferenceDate.bitPattern)
        #expect(try repository.prepare(loaded.catalog).reference == prepared.reference)
    }

    @Test func unrelatedByteChangeRejectsCASAndPreservesCurrentFile() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = CatalogRepository(directory: root)
        try repository.save(.init())
        let before = try repository.loadStored()
        let stage = try repository.stage(repository.prepare(.init(folders: [LibraryFolder(url: root)])))
        defer { repository.discard(stage) }
        // Semantically equal JSON is still a different persisted byte snapshot.
        let external = try Data(contentsOf: repository.fileURL) + Data("\n".utf8)
        try external.write(to: repository.fileURL)
        #expect(throws: CatalogRepositoryError.self) { try repository.publish(stage, expected: before.reference) }
        #expect(try Data(contentsOf: repository.fileURL) == external)
    }

    @Test func existingEmptyFileIsNotAbsentAndCorruptFutureFilesSurviveSave() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = CatalogRepository(directory: root)
        let stage = try repository.stage(repository.prepare(.init())); defer { repository.discard(stage) }
        try Data().write(to: repository.fileURL)
        #expect(throws: CatalogRepositoryError.self) { try repository.publish(stage, expected: .absent) }
        #expect(throws: CatalogRepositoryError.self) { try repository.save(.init()) }
        #expect(try Data(contentsOf: repository.fileURL).isEmpty)
        let future = Data("{\"version\":999,\"folders\":[],\"assets\":[]}".utf8)
        try future.write(to: repository.fileURL)
        #expect(throws: CatalogRepositoryError.self) { try repository.save(.init()) }
        #expect(try Data(contentsOf: repository.fileURL) == future)
    }

    @Test func tamperedStageOrForeignLockAliasCannotPublish() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = CatalogRepository(directory: root)
        let stage = try repository.stage(repository.prepare(.init())); defer { repository.discard(stage) }
        let file = root.appendingPathComponent("MetadataCatalogStaging/" + stage.id.uuidString.lowercased() + ".catalog.json")
        try Data("tampered".utf8).write(to: file)
        #expect(throws: CatalogRepositoryError.self) { try repository.publish(stage, expected: .absent) }
        #expect(!FileManager.default.fileExists(atPath: repository.fileURL.path))
        let original = root.appendingPathComponent("foreign"); let bytes = Data("original".utf8)
        try bytes.write(to: original)
        try FileManager.default.removeItem(at: root.appendingPathComponent("catalog-write.lock"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("catalog-write.lock"), withDestinationURL: original)
        #expect(throws: CatalogRepositoryError.self) { try repository.withPublicationLock { _ in () } }
        #expect(try Data(contentsOf: original) == bytes)
    }

    @Test func discardedStageNeverDeletesAnUnrelatedReplacementAtItsUUIDLeaf() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = CatalogRepository(directory: root)
        let stage = try repository.stage(repository.prepare(.init()))
        let leaf = root.appendingPathComponent("MetadataCatalogStaging/" + stage.id.uuidString.lowercased() + ".catalog.json")
        let oldBytes = try Data(contentsOf: leaf)
        try FileManager.default.removeItem(at: leaf)
        // Equal bytes are not ownership evidence. Keep the original FD alive
        // in the capability, preventing inode reuse from masquerading as ours.
        try oldBytes.write(to: leaf)
        #expect(throws: CatalogRepositoryError.self) { try repository.publish(stage, expected: .absent) }
        repository.discard(stage)
        #expect(try Data(contentsOf: leaf) == oldBytes)
        #expect(!FileManager.default.fileExists(atPath: repository.fileURL.path))
    }

    @Test func sharedPublicationLockReportsActualBytesAndSerializesOtherPublishers() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = CatalogRepository(directory: root); try repository.save(.init())
        let before = try repository.loadStored().reference
        let stage = try repository.stage(repository.prepare(.init(folders: [LibraryFolder(url: root)])))
        defer { repository.discard(stage) }
        let signals = PublicationSignals()
        let holder = Task.detached {
            try repository.withPublicationLock { reference in
                #expect(reference == before); signals.entered.signal()
                guard signals.release.wait(timeout: .now() + 10) == .success else { throw PublicationTestFailure.releaseTimedOut }
            }
        }
        defer { signals.release.signal() }
        try await signals.waitForEntry()
        let publisher = Task.detached { try repository.publish(stage, expected: before) }
        // A second shared handle uses the same OS lock rather than actor-only
        // ordering. No timing-sensitive assertion: bytes change after release.
        #expect(try repository.loadStored().reference == before)
        signals.release.signal(); try await holder.value; try await publisher.value
        #expect(try repository.loadStored().reference == stage.prepared.reference)
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("catalog-publication-" + UUID().uuidString, isDirectory: true)
    }
}
private final class PublicationSignals: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func waitForEntry() async throws {
        let reached: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.entered.wait(timeout: .now() + 5) == .success)
            }
        }
        guard reached else { throw PublicationTestFailure.lockEntryTimedOut }
    }
}
private enum PublicationTestFailure: Error { case lockEntryTimedOut, releaseTimedOut }
