import CoreGraphics
import Foundation
import ImageIO
import GlowroomCore
import Testing
import UniformTypeIdentifiers
@testable import Glowroom

@Suite("Library projections", .serialized)
@MainActor
final class LibraryProjectionTests {
    private let root: URL
    private let repository: CatalogRepository

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-Projections-\(UUID().uuidString)")
        repository = CatalogRepository(directory: root.appendingPathComponent("Catalog"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test
    func visibleProjectionTracksFiltersSortAndFolderSelection() async throws {
        let first = LibraryFolder(url: root.appendingPathComponent("First"), subdirectoryPaths: ["Trip", "Trip2"])
        let second = LibraryFolder(url: root.appendingPathComponent("Second"), subdirectoryPaths: ["Empty"])
        let photos = [
            photo("Trip/Zebra.CR3", in: first, day: 1, rating: 2, camera: "Canon"),
            photo("Trip/Alpha.CR3", in: first, day: 3, rating: 4, favorite: true, camera: "Nikon"),
            photo("Trip2/Beta.CR3", in: first, day: 2, rating: 1, camera: "Sony"),
            photo("Gamma.CR3", in: second, day: 4, rating: 5, favorite: true, camera: "Canon")
        ]
        let model = try await load(LibraryCatalog(folders: [first, second], assets: photos))
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.fileName) == ["Gamma.CR3", "Alpha.CR3", "Beta.CR3", "Zebra.CR3"])
        model.selectedID = photos[0].id
        model.gridSize = 300
        model.showsInspector.toggle()
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.fileName) == ["Gamma.CR3", "Alpha.CR3", "Beta.CR3", "Zebra.CR3"])

        model.sort = .name
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.fileName) == ["Alpha.CR3", "Beta.CR3", "Gamma.CR3", "Zebra.CR3"])
        model.sort = .rating
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.fileName) == ["Gamma.CR3", "Alpha.CR3", "Zebra.CR3", "Beta.CR3"])
        model.minimumRating = 3
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.fileName) == ["Gamma.CR3", "Alpha.CR3"])
        model.search = "  nikon  "
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.fileName) == ["Alpha.CR3"])
        model.search = ""
        model.minimumRating = 0
        model.selection = .folder(first.id)
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.fileName) == ["Alpha.CR3", "Zebra.CR3", "Beta.CR3"])
        model.selection = .subfolder(first.id, "Trip")
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.fileName) == ["Alpha.CR3", "Zebra.CR3"])
        model.selection = .favorites
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.fileName) == ["Gamma.CR3", "Alpha.CR3"])
        model.selection = .folder(UUID())
        await model.waitForProjection()
        #expect(model.visibleAssets.isEmpty)
    }

    @Test
    func catalogChangesInvalidateMetadataCountsAndFolderProjections() async throws {
        let first = LibraryFolder(url: root.appendingPathComponent("First"), subdirectoryPaths: ["Trip"])
        let second = LibraryFolder(url: root.appendingPathComponent("Second"), subdirectoryPaths: ["Empty"])
        let firstPhoto = photo("Trip/first.CR3", in: first, day: 1, rating: 1)
        let secondPhoto = photo("second.CR3", in: second, day: 2, rating: 3, favorite: true)
        let model = try await load(LibraryCatalog(folders: [first, second], assets: [firstPhoto, secondPhoto]))
        model.selectedID = firstPhoto.id
        model.sort = .rating
        await model.waitForProjection()
        #expect(model.visibleAssets.first?.id == secondPhoto.id)
        #expect(model.selectedAsset?.rating == 1)
        #expect(model.favoriteCount == 1)
        #expect(model.folderTree(for: first).photoCount == 1)
        #expect(model.count(in: first) == 1)

        model.setRating(5, for: firstPhoto.id)
        await model.waitForProjection()
        #expect(model.visibleAssets.first?.id == firstPhoto.id)
        #expect(model.selectedAsset?.rating == 5)
        model.selection = .favorites
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [secondPhoto.id])
        model.toggleFavorite(firstPhoto.id)
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [firstPhoto.id, secondPhoto.id])
        #expect(model.favoriteCount == 2)
        model.selectedID = firstPhoto.id
        await model.waitForProjection()
        #expect(model.selectedAsset?.isFavorite == true)

        model.selection = .all
        model.removeFolder(first.id)
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [secondPhoto.id])
        #expect(model.selectedAsset?.id == secondPhoto.id)
        #expect(model.favoriteCount == 1)
        #expect(model.folderTree(for: first).photoCount == 0)
        #expect(model.count(in: second) == 1)
        #expect(await model.finishSaving())
    }

    @Test
    func recentProjectionExpiresAtSevenDayBoundaryAndHandlesClockReversal() async throws {
        let initial = Date(timeIntervalSince1970: 2_000_000_000)
        var currentDate = initial
        let expiring = LibraryFolder(url: root.appendingPathComponent("Expiring"), addedAt: initial.addingTimeInterval(-7 * 86400 + 10), subdirectoryPaths: ["Empty"])
        let old = LibraryFolder(url: root.appendingPathComponent("Old"), addedAt: initial.addingTimeInterval(-7 * 86400 - 1), subdirectoryPaths: ["Empty"])
        let recent = LibraryFolder(url: root.appendingPathComponent("Recent"), addedAt: initial.addingTimeInterval(-2 * 86400), subdirectoryPaths: ["Empty"])
        let photos = [photo("expiring.CR3", in: expiring), photo("old.CR3", in: old), photo("recent.CR3", in: recent)]
        let model = try await load(LibraryCatalog(folders: [expiring, old, recent], assets: photos), now: { currentDate })
        model.selection = .recent
        await model.waitForProjection()
        #expect(Set(model.visibleAssets.map(\.fileName)) == ["expiring.CR3", "recent.CR3"])
        currentDate = initial.addingTimeInterval(10)
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.fileName) == ["recent.CR3"], "Membership expires at the exact boundary without any model mutation")
        currentDate = initial.addingTimeInterval(-2)
        await model.waitForProjection()
        #expect(Set(model.visibleAssets.map(\.fileName)) == ["expiring.CR3", "old.CR3", "recent.CR3"])
        currentDate = initial.addingTimeInterval(7 * 86400)
        await model.waitForProjection()
        #expect(model.visibleAssets.isEmpty)
        currentDate = initial
        await model.waitForProjection()
        #expect(Set(model.visibleAssets.map(\.fileName)) == ["expiring.CR3", "recent.CR3"], "A cached empty result also responds to backward clock changes")
    }

    @Test
    func treeProjectionHonorsChangedFolderPathAndDirectoryArguments() async throws {
        let folder = LibraryFolder(url: root.appendingPathComponent("Photos"), subdirectoryPaths: ["Trip"])
        let model = try await load(LibraryCatalog(folders: [folder], assets: [photo("Trip/image.CR3", in: folder)]))
        await model.waitForProjection()
        #expect(model.folderTree(for: folder).photoCount == 1)
        var changed = folder
        changed.name = "Renamed"
        changed.subdirectoryPaths = ["Trip", "Empty"]
        await model.waitForProjection()
        _ = model.folderTree(for: changed)
        await model.waitForProjection()
        #expect(model.folderTree(for: changed).name == "Renamed")
        _ = model.folderTree(for: changed)
        await model.waitForProjection()
        #expect(model.folderTree(for: changed).contains(relativePath: "Empty"))
        changed.url = root.appendingPathComponent("DifferentRoot")
        await model.waitForProjection()
        _ = model.folderTree(for: changed)
        await model.waitForProjection()
        #expect(model.folderTree(for: changed).photoCount == 0)
        _ = model.folderTree(for: folder)
        await model.waitForProjection()
        #expect(model.folderTree(for: folder).photoCount == 1)
        #expect(!model.folderTree(for: folder).contains(relativePath: "Empty"))
    }

    @Test
    func refreshInvalidatesPreviouslyReadImageAndTreeProjections() async throws {
        let photos = root.appendingPathComponent("Photos")
        let trip = photos.appendingPathComponent("Trip")
        try FileManager.default.createDirectory(at: trip, withIntermediateDirectories: true)
        try writeImage(trip.appendingPathComponent("old.png"))
        let folder = LibraryFolder(url: photos, subdirectoryPaths: ["Trip"])
        let old = photo("Trip/old.png", in: folder, rating: 5, favorite: true)
        let model = try await load(LibraryCatalog(folders: [folder], assets: [old]))
        model.selection = .folder(folder.id)
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [old.id])
        #expect(model.selectedAsset?.id == old.id)
        #expect(model.favoriteCount == 1)
        #expect(model.folderTree(for: folder).contains(relativePath: "Trip"))

        try FileManager.default.removeItem(at: trip)
        let replacement = photos.appendingPathComponent("New")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try writeImage(replacement.appendingPathComponent("new.png"))
        model.refreshCurrentFolder()
        try await waitUntilIdle(model)
        let refreshed = try #require(model.folders.first)
        await model.waitForProjection()
        #expect(Set(model.visibleAssets.map(\.fileName)) == ["old.png", "new.png"])
        #expect(model.selectedAsset?.id == old.id)
        #expect(model.favoriteCount == 1)
        #expect(model.folderTree(for: refreshed).contains(relativePath: "New"))
        #expect(model.folderTree(for: refreshed).contains(relativePath: "Trip"))
        #expect(await model.finishSaving())
    }

    @Test
    func rapidFiltersAndMetadataChangesPublishOnlyTheLatestProjection() async throws {
        let folder = LibraryFolder(url: root.appendingPathComponent("Photos"), subdirectoryPaths: ["Trip"])
        let base = photo("Trip/base.CR3", in: folder)
        var photos: [PhotoAsset] = []
        for index in 0..<5_000 {
            var asset = base
            asset.fileName = "IMG_\(index).CR3"
            asset.fileURL = folder.url.appendingPathComponent("Trip/\(asset.fileName)")
            asset.id = asset.fileURL.path
            photos.append(asset)
        }
        let model = try await load(LibraryCatalog(folders: [folder], assets: photos))
        for index in 0..<30 {
            model.search = "IMG_\(index)"
            model.sort = index.isMultiple(of: 2) ? .name : .rating
            await Task.yield()
        }
        model.setRating(5, for: photos[42].id)
        model.toggleFavorite(photos[42].id)
        model.selection = .favorites
        model.search = "IMG_42."
        model.minimumRating = 5
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [photos[42].id])
        #expect(model.selectedID == photos[42].id)
        #expect(model.selectedAsset?.rating == 5)
        #expect(model.favoriteCount == 1)
        #expect(!model.isProjecting)
        #expect(await model.finishSaving())
    }

    @Test
    func cancelledProjectionDoesNotPoisonWorkerCache() async throws {
        let folder = LibraryFolder(url: root.appendingPathComponent("Photos"), subdirectoryPaths: ["Trip"])
        let catalog = LibraryCatalog(folders: [folder], assets: [photo("Trip/image.CR3", in: folder)])
        let worker = LibraryProjectionWorker()
        let key = LibraryProjectionKey(selection: .all, query: "", sort: .name, minimumRating: 0)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.project(catalog, generation: 1, key: key, date: Date(), overrides: [:])
        }
        do {
            _ = try await cancelled.value
            Issue.record("A cancelled calculation must not return a projection")
        } catch is CancellationError { }
        let fresh = try await worker.project(catalog, generation: 1, key: key, date: Date(), overrides: [:])
        #expect(fresh.assets == catalog.assets)
        #expect(fresh.trees[folder.id]?.photoCount == 1)
    }

    private func photo(_ path: String, in folder: LibraryFolder, day: Int = 0, rating: Int = 0, favorite: Bool = false, camera: String? = nil) -> PhotoAsset {
        let date = Date(timeIntervalSince1970: Double(day * 86400))
        return PhotoAsset(folderID: folder.id, fileURL: folder.url.appendingPathComponent(path), createdAt: date, modifiedAt: date, cameraModel: camera, rating: rating, isFavorite: favorite)
    }

    private func load(_ catalog: LibraryCatalog, now: @escaping () -> Date = Date.init) async throws -> LibraryModel {
        try repository.save(catalog)
        let model = LibraryModel(repository: repository, now: now)
        try await waitUntilIdle(model)
        return model
    }

    private func waitUntilIdle(_ model: LibraryModel) async throws {
        let deadline = Date().addingTimeInterval(20)
        while model.isLoading || model.isImporting || model.isProjecting {
            guard Date() < deadline else { throw ProjectionTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func writeImage(_ url: URL) throws {
        let context = try #require(CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.4, green: 0.2, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

private enum ProjectionTestError: Error { case timeout }
