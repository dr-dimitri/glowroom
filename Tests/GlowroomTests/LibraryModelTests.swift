import CoreGraphics
import Foundation
import ImageIO
import GlowroomCore
import Testing
import UniformTypeIdentifiers
@testable import Glowroom

// Workflows touch the process-wide AppKit focus state; simulate one app session at a time.
@Suite("Library workflows", .serialized)
@MainActor
final class LibraryModelTests {
    private let root: URL
    private let repository: CatalogRepository

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom Workflow \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = CatalogRepository(directory: root.appendingPathComponent("Catalog"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test
    func persistedLibraryLoadsWithUserMetadata() async throws {
        let folder = LibraryFolder(url: try directory("Photos"))
        let photo = PhotoAsset(folderID: folder.id, fileURL: folder.url.appendingPathComponent("photo.png"), rating: 4, isFavorite: true)
        let catalog = LibraryCatalog(folders: [folder], assets: [photo])
        try repository.save(catalog)
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)
        await model.waitForProjection()
        #expect(model.catalog == catalog)
        #expect(model.selectedAsset?.rating == 4)
        #expect(model.favoriteCount == 1)
        #expect(model.canModify)
    }

    @Test(arguments: [true, false])
    func overlappingImportsRemainUniqueAndBrowseable(childFirst: Bool) async throws {
        let parent = try directory("Photos")
        let child = try directory("Photos/Trip")
        try writeImage(parent.appendingPathComponent("parent.png"))
        try writeImage(child.appendingPathComponent("child.png"))
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)
        for folder in childFirst ? [child, parent, parent] : [parent, child, child] {
            model.importFolders([folder])
            try await waitUntilIdle(model)
        }
        await model.waitForProjection()
        #expect(model.assets.count == 2)
        #expect(Set(model.assets.map(\.id)).count == 2)
        #expect(model.folders.count == 2)
        let parentFolder = try #require(model.folders.first { $0.url.path == parent.path })
        let childFolder = try #require(model.folders.first { $0.url.path == child.path })
        model.selection = .folder(parentFolder.id)
        await model.waitForProjection()
        #expect(model.visibleAssets.count == 2)
        #expect(model.count(in: parentFolder) == 2)
        model.selection = .folder(childFolder.id)
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.fileName) == ["child.png"])
        #expect(model.count(in: childFolder) == 1)
        #expect(await model.finishSaving())
        #expect(try repository.load().assets.count == 2)
    }

    @Test
    func removingParentRetainsChildAndRatingsWithoutTouchingFiles() async throws {
        let parent = try directory("Photos")
        let child = try directory("Photos/Trip")
        let parentImage = parent.appendingPathComponent("parent.png")
        let childImage = child.appendingPathComponent("child.png")
        try writeImage(parentImage)
        try writeImage(childImage)
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)
        model.importFolders([parent, child])
        try await waitUntilIdle(model)
        let childAsset = try #require(model.assets.first { $0.fileName == "child.png" })
        model.setRating(5, for: childAsset.id)
        model.toggleFavorite(childAsset.id)
        let parentFolder = try #require(model.folders.first { $0.url.path == parent.path })
        let childFolder = try #require(model.folders.first { $0.url.path == child.path })
        model.removeFolder(parentFolder.id)
        await model.waitForProjection()
        #expect(model.folders.count == 1)
        #expect(model.assets.count == 1)
        #expect(model.assets.first?.folderID == childFolder.id)
        #expect(model.assets.first?.rating == 5)
        #expect(model.assets.first?.isFavorite == true)
        #expect(FileManager.default.fileExists(atPath: parentImage.path))
        #expect(FileManager.default.fileExists(atPath: childImage.path))
        #expect(await model.finishSaving())
        #expect(try repository.load() == model.catalog)
    }

    @Test
    func refreshFindsAddedPhotosAndRetainsMissingPhotosAndRatings() async throws {
        let folder = try directory("Photos")
        let retained = folder.appendingPathComponent("retained.png")
        let removed = folder.appendingPathComponent("removed.png")
        try writeImage(retained)
        try writeImage(removed)
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)
        model.importFolders([folder])
        try await waitUntilIdle(model)
        let retainedID = try #require(model.assets.first { $0.fileName == "retained.png" }?.id)
        model.setRating(3, for: retainedID)
        model.toggleFavorite(retainedID)
        try FileManager.default.removeItem(at: removed)
        try writeImage(folder.appendingPathComponent("new.png"))
        model.refreshCurrentFolder()
        try await waitUntilIdle(model)
        await model.waitForProjection()
        #expect(Set(model.assets.map(\.fileName)) == ["retained.png", "removed.png", "new.png"])
        #expect(model.assets.first { $0.id == retainedID }?.rating == 3)
        #expect(model.assets.first { $0.id == retainedID }?.isFavorite == true)
        #expect(await model.finishSaving())
    }

    @Test
    func missingFolderRefreshPreservesCatalog() async throws {
        let folder = try directory("Photos")
        try writeImage(folder.appendingPathComponent("photo.png"))
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)
        model.importFolders([folder])
        try await waitUntilIdle(model)
        let before = model.catalog
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("Disconnected"))
        model.refreshCurrentFolder()
        try await waitUntilIdle(model)
        await model.waitForProjection()
        #expect(model.catalog == before)
        #expect(model.errorMessage != nil)
        #expect(await model.finishSaving())
        #expect(try repository.load() == before)
    }

    @Test
    func childRefreshUpdatesParentOwnedPhotosWithoutLosingRatings() async throws {
        let parent = try directory("Photos")
        let child = try directory("Photos/Trip")
        try writeImage(parent.appendingPathComponent("parent.png"))
        try writeImage(child.appendingPathComponent("retained.png"))
        let removed = child.appendingPathComponent("removed.png")
        try writeImage(removed)
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)
        model.importFolders([parent, child])
        try await waitUntilIdle(model)
        let retainedID = try #require(model.assets.first { $0.fileName == "retained.png" }?.id)
        model.setRating(5, for: retainedID)
        model.toggleFavorite(retainedID)
        try FileManager.default.removeItem(at: removed)
        try writeImage(child.appendingPathComponent("new.png"))
        model.refreshCurrentFolder()
        try await waitUntilIdle(model)
        await model.waitForProjection()
        #expect(Set(model.assets.map(\.fileName)) == ["parent.png", "retained.png", "removed.png", "new.png"])
        #expect(model.assets.first { $0.id == retainedID }?.rating == 5)
        #expect(model.assets.first { $0.id == retainedID }?.isFavorite == true)
        #expect(await model.finishSaving())
        #expect(try repository.load() == model.catalog)
    }

    @Test
    func corruptImageRefreshAndRepairPreserveRatings() async throws {
        let folder = try directory("Photos")
        let image = folder.appendingPathComponent("photo.png")
        try writeImage(image)
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)
        model.importFolders([folder])
        try await waitUntilIdle(model)
        let assetID = try #require(model.assets.first?.id)
        model.setRating(4, for: assetID)
        model.toggleFavorite(assetID)
        try Data("temporarily broken".utf8).write(to: image)
        model.refreshCurrentFolder()
        try await waitUntilIdle(model)
        await model.waitForProjection()
        #expect(model.assets.count == 1)
        #expect(model.assets.first?.rating == 4)
        #expect(model.assets.first?.isFavorite == true)
        try writeImage(image)
        model.refreshCurrentFolder()
        try await waitUntilIdle(model)
        await model.waitForProjection()
        #expect(model.assets.first?.id == assetID)
        #expect(model.assets.first?.rating == 4)
        #expect(model.assets.first?.isFavorite == true)
        #expect(await model.finishSaving())
    }

    @Test
    func corruptCatalogEntersReadOnlyModeAndRemainsUntouched() async throws {
        try FileManager.default.createDirectory(at: repository.directory, withIntermediateDirectories: true)
        let corrupt = Data("not valid catalog JSON".utf8)
        try corrupt.write(to: repository.fileURL)
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)
        await model.waitForProjection()
        #expect(model.isReadOnly)
        #expect(!model.canModify)
        #expect(model.errorMessage != nil)
        let folder = try directory("Photos")
        try writeImage(folder.appendingPathComponent("photo.png"))
        model.importFolders([folder])
        await model.waitForProjection()
        #expect(!model.isImporting)
        #expect(model.assets.isEmpty)
        #expect(await model.finishSaving())
        #expect(try Data(contentsOf: repository.fileURL) == corrupt)
    }

    @Test
    func terminationLocksChangesAndStillSavesLatestCatalog() async throws {
        let folder = LibraryFolder(url: try directory("Photos"))
        let photo = PhotoAsset(folderID: folder.id, fileURL: folder.url.appendingPathComponent("photo.png"), rating: 1)
        try repository.save(LibraryCatalog(folders: [folder], assets: [photo]))
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)
        model.setRating(4, for: photo.id)
        model.toggleFavorite(photo.id)
        let latestCatalog = model.catalog

        model.beginTermination()
        await model.waitForProjection()
        #expect(model.isClosing)
        #expect(!model.canModify)
        model.setRating(0, for: photo.id)
        model.toggleFavorite(photo.id)
        model.removeFolder(folder.id)
        model.enqueueFolders([try directory("RejectedDuringTermination")])
        await model.waitForProjection()
        #expect(model.catalog == latestCatalog)
        #expect(!model.isImporting)
        #expect(await model.finishSaving())
        #expect(try repository.load() == latestCatalog)

        model.cancelTermination()
        await model.waitForProjection()
        #expect(!model.isClosing)
        #expect(model.canModify)
        model.setRating(2, for: photo.id)
        await model.waitForProjection()
        #expect(model.assets.first?.rating == 2)
        #expect(await model.finishSaving())
        #expect(try repository.load().assets.first?.rating == 2)
    }

    @Test
    func queuedFoldersImportAfterCurrentImportWithoutDuplicates() async throws {
        let first = try directory("First")
        let queued = try directory("Queued")
        try writeImage(first.appendingPathComponent("first.png"))
        try writeImage(queued.appendingPathComponent("queued.png"))
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)

        // All calls occur on the main actor before the import task can run, making the
        // queued-import transition deterministic even with tiny test images.
        model.importFolders([first])
        await model.waitForProjection()
        #expect(model.isImporting)
        model.enqueueFolders([queued])
        model.enqueueFolders([queued])
        try await waitUntilIdle(model)

        await model.waitForProjection()
        #expect(Set(model.assets.map(\.fileName)) == ["first.png", "queued.png"])
        #expect(model.folders.count == 2)
        #expect(Set(model.assets.map(\.id)).count == 2)
        #expect(await model.finishSaving())
        #expect(try repository.load() == model.catalog)
    }

    @Test(arguments: [false, true])
    func cancellationDropsQueuedFoldersAndAllowsFreshImport(terminating: Bool) async throws {
        let first = try directory("First")
        let queued = try directory("Queued")
        let fresh = try directory("Fresh")
        for (folder, name) in [(first, "first.png"), (queued, "queued.png"), (fresh, "fresh.png")] {
            try writeImage(folder.appendingPathComponent(name))
        }
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)
        model.importFolders([first])
        model.enqueueFolders([queued])
        if terminating { model.beginTermination() }
        else { model.cancelImport() }
        try await waitUntilIdle(model)
        await model.waitForProjection()
        #expect(model.assets.isEmpty)
        #expect(model.folders.isEmpty)

        if terminating { model.cancelTermination() }
        model.enqueueFolders([fresh])
        try await waitUntilIdle(model)
        await model.waitForProjection()
        #expect(model.assets.map(\.fileName) == ["fresh.png"])
        #expect(model.folders.count == 1)
        #expect(await model.finishSaving())
        #expect(try repository.load() == model.catalog)
    }

    @Test
    func folderTreeIncludesEmptyBranchesAndSelectionSeparatesSiblingPrefixes() async throws {
        let photos = try directory("Photos")
        let trip = try directory("Photos/Trip")
        let nested = try directory("Photos/Trip/Nested")
        let sibling = try directory("Photos/Trip2")
        _ = try directory("Photos/Trip/Empty")
        _ = try directory("Photos/Archive")
        for (directory, name) in [(photos, "root.png"), (trip, "trip.png"), (nested, "nested.png"), (sibling, "sibling.png")] {
            try writeImage(directory.appendingPathComponent(name))
        }
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)
        model.importFolders([photos])
        try await waitUntilIdle(model)
        let folder = try #require(model.folders.first)
        let tree = model.folderTree(for: folder)
        let tripNode = try #require(tree.children.first { $0.relativePath == "Trip" })
        let nestedNode = try #require(tripNode.children.first { $0.relativePath == "Trip/Nested" })

        #expect(tree.relativePath.isEmpty)
        #expect(tree.name == "Photos")
        #expect(tree.photoCount == 4)
        #expect(tree.children.map(\.name) == ["Archive", "Trip", "Trip2"])
        #expect(tree.children.first?.photoCount == 0)
        #expect(tripNode.photoCount == 2)
        #expect(tripNode.children.map(\.name) == ["Empty", "Nested"])
        #expect(tripNode.children.first?.photoCount == 0)
        #expect(nestedNode.name == "Nested")
        #expect(nestedNode.photoCount == 1)
        #expect(tree.children.last?.photoCount == 1)

        model.selectFolder(folder, relativePath: "Trip")
        await model.waitForProjection()
        #expect(model.selection == .subfolder(folder.id, "Trip"))
        #expect(model.title == "Trip")
        #expect(model.subtitle == trip.path)
        #expect(Set(model.visibleAssets.map(\.fileName)) == ["trip.png", "nested.png"])
        model.selectFolder(folder, relativePath: "Trip2")
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.fileName) == ["sibling.png"])
        model.selectFolder(folder, relativePath: "Trip/Nested")
        await model.waitForProjection()
        #expect(model.title == "Nested")
        #expect(model.subtitle == nested.path)
        #expect(model.visibleAssets.map(\.fileName) == ["nested.png"])
        model.showsDetail = true
        model.selectFolder(folder, relativePath: "Trip/Empty")
        await model.waitForProjection()
        #expect(model.selection == .subfolder(folder.id, "Trip/Empty"))
        #expect(model.visibleAssets.isEmpty)
        #expect(model.selectedID == nil)
        #expect(!model.showsDetail)
        model.selectFolder(folder, relativePath: "")
        await model.waitForProjection()
        #expect(model.selection == .folder(folder.id))
        #expect(model.visibleAssets.count == 4)
        #expect(await model.finishSaving())
    }

    @Test
    func subfolderRefreshUpdatesTreeAndRetainsNavigationToMissingPhotos() async throws {
        let photos = try directory("Photos")
        let trip = try directory("Photos/Trip")
        let oldEmpty = try directory("Photos/Trip/OldEmpty")
        try writeImage(trip.appendingPathComponent("retained.png"))
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)
        model.importFolders([photos])
        try await waitUntilIdle(model)
        let folder = try #require(model.folders.first)
        model.selectFolder(folder, relativePath: "Trip")
        let selectedID = model.selectedID
        let newNested = try directory("Photos/Trip/New")
        _ = try directory("Photos/AddedEmpty")
        try FileManager.default.removeItem(at: oldEmpty)
        try writeImage(newNested.appendingPathComponent("new.png"))
        try writeImage(photos.appendingPathComponent("root.png"))
        model.refreshCurrentFolder()
        try await waitUntilIdle(model)

        await model.waitForProjection()
        #expect(model.selection == .subfolder(folder.id, "Trip"))
        #expect(model.selectedID == selectedID)
        #expect(Set(model.visibleAssets.map(\.fileName)) == ["retained.png", "new.png"])
        #expect(Set(model.assets.map(\.fileName)) == ["retained.png", "new.png", "root.png"], "Refreshing a subfolder scans its owning root")
        let refreshedFolder = try #require(model.folders.first)
        #expect(refreshedFolder.subdirectoryPaths == ["AddedEmpty", "Trip", "Trip/New"])
        #expect(!model.folderTree(for: refreshedFolder).contains(relativePath: "Trip/OldEmpty"))

        model.refreshCurrentFolder()
        // A user may navigate while the asynchronous refresh is running.
        model.selection = .all
        model.search = "root"
        model.minimumRating = 3
        try await waitUntilIdle(model)
        await model.waitForProjection()
        #expect(model.selection == .all)
        #expect(model.search == "root")
        #expect(model.minimumRating == 3)

        model.search = ""
        model.minimumRating = 0
        model.selectFolder(refreshedFolder, relativePath: "Trip")
        try FileManager.default.removeItem(at: trip)
        model.refreshCurrentFolder()
        try await waitUntilIdle(model)
        await model.waitForProjection()
        #expect(model.selection == .subfolder(folder.id, "Trip"))
        #expect(Set(model.visibleAssets.map(\.fileName)) == ["retained.png", "new.png"])
        #expect(model.folderTree(for: try #require(model.folders.first)).contains(relativePath: "Trip"))
        #expect(model.folders.first?.subdirectoryPaths == ["AddedEmpty"])
        #expect(await model.finishSaving())
    }

    @Test(arguments: [false, true])
    func removingRootReconcilesOnlyItsOwnSubfolderSelection(removeSelected: Bool) async throws {
        let first = try directory("First")
        let firstChild = try directory("First/Trip")
        let second = try directory("Second")
        let secondChild = try directory("Second/Trip")
        try writeImage(firstChild.appendingPathComponent("first.png"))
        try writeImage(secondChild.appendingPathComponent("second.png"))
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)
        model.importFolders([first, second])
        try await waitUntilIdle(model)
        let firstFolder = try #require(model.folders.first { $0.url.path == first.path })
        let secondFolder = try #require(model.folders.first { $0.url.path == second.path })
        model.selectFolder(firstFolder, relativePath: "Trip")
        model.removeFolder(removeSelected ? firstFolder.id : secondFolder.id)
        await model.waitForProjection()
        #expect(model.selection == (removeSelected ? .all : .subfolder(firstFolder.id, "Trip")))
        #expect(model.visibleAssets.map(\.fileName) == [removeSelected ? "second.png" : "first.png"])
        #expect(model.selectedAsset?.fileName == (removeSelected ? "second.png" : "first.png"))
        #expect(model.folders.count == 1)
        #expect(await model.finishSaving())
    }

    @Test
    func legacyAssetPathsBuildTreeEvenWhenFolderIsOffline() async throws {
        let offline = root.appendingPathComponent("Offline", isDirectory: true)
        let folder = LibraryFolder(url: offline)
        let assets = ["root.png", "Trip/Nested/photo.png", "Trip2/sibling.png"].map {
            PhotoAsset(folderID: folder.id, fileURL: offline.appendingPathComponent($0), rating: 4)
        }
        let unrelated = PhotoAsset(folderID: folder.id, fileURL: root.appendingPathComponent("Offline2/Other/unrelated.png"))
        let directTree = FolderTreeNode.make(folder: folder, assets: assets + [unrelated])
        #expect(directTree.photoCount == 3)
        #expect(directTree.children.map(\.relativePath) == ["Trip", "Trip2"])
        #expect(directTree.children.first?.children.first?.relativePath == "Trip/Nested")
        #expect(directTree.children.first?.photoCount == 1)
        #expect(!directTree.contains(relativePath: "Other"))

        let catalog = LibraryCatalog(folders: [folder], assets: assets)
        try repository.save(catalog)
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)
        await model.waitForProjection()
        #expect(model.catalog == catalog)
        #expect(!model.isReadOnly)
        #expect(model.folderTree(for: folder).contains(relativePath: "Trip/Nested"))
        model.selectFolder(folder, relativePath: "Trip/Nested")
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.fileName) == ["photo.png"])
        #expect(model.selectedAsset?.rating == 4)
        #expect(await model.finishSaving())
    }

    @Test
    func loadingLegacyCatalogBackfillsEmptyFoldersWithoutChangingPhotoMetadata() async throws {
        let photos = try directory("Photos")
        _ = try directory("Photos/Empty")
        let nested = try directory("Photos/Trip/Nested")
        let folder = LibraryFolder(url: photos)
        let unreadable = nested.appendingPathComponent("photo.png")
        try Data("temporarily undecodable original".utf8).write(to: unreadable)
        let photo = PhotoAsset(folderID: folder.id, fileURL: unreadable, fileSize: 1234, pixelWidth: 6000, pixelHeight: 4000, rating: 5, isFavorite: true)
        try repository.save(LibraryCatalog(folders: [folder], assets: [photo]))
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)

        let loadedFolder = try #require(model.folders.first)
        #expect(loadedFolder.subdirectoryPaths == ["Empty", "Trip", "Trip/Nested"])
        #expect(loadedFolder.lastScannedAt == folder.lastScannedAt)
        #expect(model.assets == [photo], "Directory-only backfill must retain stored metadata even for currently unreadable images")
        let tree = model.folderTree(for: loadedFolder)
        #expect(tree.children.first?.relativePath == "Empty")
        #expect(tree.children.first?.photoCount == 0)
        #expect(tree.photoCount == 1)
        #expect(await model.finishSaving())
        #expect(try repository.load() == model.catalog)
    }

    @Test
    func terminationWaitsForAcceptedFolderRemoval() async throws {
        let first = LibraryFolder(url: try directory("First"), subdirectoryPaths: ["Trip"])
        let second = LibraryFolder(url: try directory("Second"), subdirectoryPaths: ["Trip"])
        let assets = [first, second].map { PhotoAsset(folderID: $0.id, fileURL: $0.url.appendingPathComponent("image.png")) }
        try repository.save(LibraryCatalog(folders: [first, second], assets: assets))
        let model = LibraryModel(repository: repository)
        try await waitUntilIdle(model)
        model.removeFolder(first.id)
        model.beginTermination()
        #expect(await model.finishSaving())
        let saved = try repository.load()
        #expect(saved.folders.map(\.id) == [second.id])
        #expect(saved.assets.map(\.id) == [assets[1].id])
        #expect(!model.isUpdatingCatalog)
    }

    private func waitUntilIdle(_ model: LibraryModel) async throws {
        let deadline = Date().addingTimeInterval(20)
        while model.isLoading || model.isImporting || model.isProjecting || model.isUpdatingCatalog {
            guard Date() < deadline else { throw WorkflowTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeImage(_ url: URL) throws {
        let context = try #require(CGContext(
            data: nil, width: 24, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.5, green: 0.3, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

private enum WorkflowTestError: Error { case timeout }
