import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Library accepted catalog operations", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LibraryAdmissionTests {
    @Test func maintenanceWaitsForAcceptedScanAndAlreadyQueuedImportThroughPublication() async throws {
        let f = try await fixture()
        defer { f.model.cancelImport(); Task { await f.scanner.releaseAll() }; try? FileManager.default.removeItem(at: f.directory) }
        f.model.importFolders([f.folders[0]])
        f.model.enqueueFolders([f.folders[1]])
        #expect(throws: JPEGExportError.catalogBusy) { try f.model.jpegExportProtection.snapshot() }
        // These calls all precede the first import Task running. Both batches
        // must already be registered; no later registration may race maintenance.
        var granted = false
        let maintenance = Task {
            let cap = try await f.gate.beginMaintenance(.backup(UUID()))
            granted = true
            return (cap, try f.repository.load())
        }
        try await wait { await f.scanner.callCount == 1 }
        #expect(!granted)
        await f.scanner.releaseNext()
        try await wait { await f.scanner.callCount == 2 }
        #expect(!granted)
        #expect(throws: JPEGExportError.catalogBusy) { try f.model.jpegExportProtection.snapshot() }
        await f.scanner.releaseNext()
        let (cap, persisted) = try await maintenance.value
        #expect(persisted.assets.count == 2)
        #expect(Set(persisted.assets.map(\.fileName)) == ["First.png", "Second.png"])
        #expect(f.model.catalog == persisted)
        try await f.gate.finishMaintenance(cap)
        try await wait { !f.model.isImporting }
        _ = try f.model.jpegExportProtection.snapshot()
    }

    @Test func cancelDropsUnstartedQueuedAdmissionButDrainsActualScanner() async throws {
        let f = try await fixture()
        defer { f.model.cancelImport(); Task { await f.scanner.releaseAll() }; try? FileManager.default.removeItem(at: f.directory) }
        f.model.importFolders([f.folders[0]])
        f.model.enqueueFolders([f.folders[1]])
        try await wait { await f.scanner.callCount == 1 }
        f.model.cancelImport()
        #expect(throws: JPEGExportError.catalogBusy) { try f.model.jpegExportProtection.snapshot() }
        var granted = false
        let maintenance = Task {
            let cap = try await f.gate.beginMaintenance(.backup(UUID()))
            granted = true
            return cap
        }
        await Task.yield()
        #expect(!granted)
        await f.scanner.releaseNext()
        let cap = try await maintenance.value
        #expect(await f.scanner.callCount == 1)
        #expect(try f.repository.load().assets.isEmpty)
        try await f.gate.finishMaintenance(cap)
        try await wait { !f.model.isImporting }
        _ = try f.model.jpegExportProtection.snapshot()
    }

    @Test func editorialAcceptancePrecedesMutationAndMaintenanceRejectsAllNewCatalogActions() async throws {
        let f = try await fixture(initialAsset: true)
        defer { f.model.cancelImport(); Task { await f.scanner.releaseAll() }; try? FileManager.default.removeItem(at: f.directory) }
        let asset = try #require(f.model.assets.first)
        f.model.setRating(4, for: asset.id)
        f.model.toggleFavorite(asset.id)
        let cap = try await f.gate.beginMaintenance(.backup(UUID()))
        let persisted = try f.repository.load()
        #expect(persisted.assets.first?.rating == 4)
        #expect(persisted.assets.first?.isFavorite == true)
        let before = f.model.catalog
        f.model.setRating(1, for: asset.id)
        f.model.toggleFavorite(asset.id)
        f.model.removeFolder(asset.folderID)
        f.model.importFolders([f.folders[1]])
        f.model.enqueueFolders([f.folders[1]])
        #expect(f.model.catalog == before)
        #expect(!f.model.isImporting && !f.model.isUpdatingCatalog)
        #expect(await f.scanner.callCount == 0)
        #expect(f.model.errorMessage != nil)
        try await f.gate.finishMaintenance(cap)
        _ = try f.model.jpegExportProtection.snapshot()
    }

    @Test func ratingsAcceptedDuringScanSurviveTheImportCommit() async throws {
        let f = try await fixture(initialAsset: true)
        defer { f.model.cancelImport(); Task { await f.scanner.releaseAll() }; try? FileManager.default.removeItem(at: f.directory) }
        let existing = try #require(f.model.assets.first)
        f.model.importFolders([f.folders[1]])
        try await wait { await f.scanner.callCount == 1 }
        f.model.setRating(5, for: existing.id)
        f.model.toggleFavorite(existing.id)
        let maintenance = Task { try await f.gate.beginMaintenance(.backup(UUID())) }
        await f.scanner.releaseNext()
        let cap = try await maintenance.value
        let persisted = try f.repository.load()
        #expect(persisted.assets.count == 2)
        #expect(persisted.assets.first(where: { $0.id == existing.id })?.rating == 5)
        #expect(persisted.assets.first(where: { $0.id == existing.id })?.isFavorite == true)
        try await f.gate.finishMaintenance(cap)
    }

    @Test func failedImportPublicationDoesNotExposeAnUnpersistedOriginalReference() async throws {
        let f = try await fixture()
        defer { f.model.cancelImport(); Task { await f.scanner.releaseAll() }; try? FileManager.default.removeItem(at: f.directory) }
        let before = f.model.catalog
        f.model.importFolders([f.folders[0]])
        try await wait { await f.scanner.callCount == 1 }
        let external = LibraryCatalog(folders: [LibraryFolder(url: f.folders[1])])
        try f.repository.save(external)
        let maintenance = Task { try await f.gate.beginMaintenance(.backup(UUID())) }
        await f.scanner.releaseNext()
        let cap = try await maintenance.value
        #expect(f.model.catalog == before)
        #expect(try f.repository.load() == external)
        #expect(f.model.errorMessage != nil)
        try await f.gate.finishMaintenance(cap)
    }

    @Test func unchangedQuitDoesNotRegisterAnotherWriteDuringGrantedMaintenance() async throws {
        let f = try await fixture(initialAsset: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let before = try f.repository.load()
        let cap = try await f.gate.beginMaintenance(.backup(UUID()))
        #expect(await f.model.finishSaving())
        #expect(try f.repository.load() == before)
        try await f.gate.finishMaintenance(cap)
    }

    @Test func dirtyCatalogRetryRunsOnlyAfterEditorMaintenanceActuallyEnds() async throws {
        let f = try await fixture(initialAsset: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let before = f.model.catalog, asset = try #require(f.model.assets.first)
        var external = before
        external.assets[0].rating = 2
        try f.repository.save(external)
        f.model.setRating(4, for: asset.id)
        try await wait { f.model.errorMessage != nil }
        // Restore the exact expected catalog bytes, making the preserved local
        // dirty value retryable after the synthetic editor maintenance ends.
        try f.repository.save(before)
        let cap = try await f.gate.beginMaintenance(.backup(UUID()))
        var editorStarted = false, finalized = false
        var releaseEditor: CheckedContinuation<Void, Never>?
        let quit = Task {
            await AppDelegate.finishSaving(catalog: {
                await f.model.drainAcceptedCatalogOperations(); return true
            }, edits: {
                editorStarted = true
                await withCheckedContinuation { releaseEditor = $0 }
                try? await f.gate.finishMaintenance(cap)
                return true
            }, finalize: {
                finalized = true
                return await f.model.finishSaving()
            })
        }
        try await wait { editorStarted }
        #expect(!finalized)
        releaseEditor?.resume(); releaseEditor = nil
        #expect(await quit.value)
        #expect(finalized)
        #expect(try f.repository.load().assets.first?.rating == 4)
    }

    private func fixture(initialAsset: Bool = false) async throws -> AdmissionFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-Admission-" + UUID().uuidString)
        let folders = ["First", "Second"].map { directory.appendingPathComponent($0, isDirectory: true) }
        for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        let folder = LibraryFolder(url: folders[0])
        let asset = PhotoAsset(folderID: folder.id, fileURL: folder.url.appendingPathComponent("existing.png"))
        try repository.save(initialAsset ? LibraryCatalog(folders: [folder], assets: [asset]) : LibraryCatalog())
        let gate = CatalogLifecycleGate(requiresRecovery: false), scanner = AdmissionScanner()
        let model = LibraryModel(repository: repository, lifecycle: gate, folderScanner: { try await scanner.scan($0) })
        try await wait { !model.isLoading && !model.isProjecting }
        return AdmissionFixture(directory: directory, folders: folders, repository: repository, gate: gate, scanner: scanner, model: model)
    }
    private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw AdmissionTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct AdmissionFixture {
    let directory: URL
    let folders: [URL]
    let repository: CatalogRepository
    let gate: CatalogLifecycleGate
    let scanner: AdmissionScanner
    let model: LibraryModel
}
private actor AdmissionScanner {
    private(set) var callCount = 0
    private var pending: [CheckedContinuation<Void, Never>] = []
    func scan(_ folder: LibraryFolder) async throws -> ScanResult {
        callCount += 1
        await withCheckedContinuation { pending.append($0) }
        let photo = PhotoAsset(folderID: folder.id,
            fileURL: folder.url.appendingPathComponent(folder.url.lastPathComponent + ".png"))
        return ScanResult(assets: [photo], skippedFiles: 0)
    }
    func releaseNext() { if !pending.isEmpty { pending.removeFirst().resume() } }
    func releaseAll() { let current = pending; pending = []; for waiter in current { waiter.resume() } }
}
private enum AdmissionTestError: Error { case timeout }
