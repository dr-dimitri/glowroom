import CoreGraphics
import Foundation
import ImageIO
import PicEditCore
import Testing
import UniformTypeIdentifiers
@testable import PicEdit

@Suite("Library projections", .serialized)
@MainActor
final class LibraryProjectionTests {
    private let root: URL
    private let repository: CatalogRepository

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Projections-\(UUID().uuidString)")
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
        #expect(model.visibleAssets.map(\.fileName) == ["Gamma.CR3", "Alpha.CR3", "Beta.CR3", "Zebra.CR3"])
        model.selectedID = photos[0].id
        model.gridSize = 300
        model.showsInspector.toggle()
        #expect(model.visibleAssets.map(\.fileName) == ["Gamma.CR3", "Alpha.CR3", "Beta.CR3", "Zebra.CR3"])

        model.sort = .name
        #expect(model.visibleAssets.map(\.fileName) == ["Alpha.CR3", "Beta.CR3", "Gamma.CR3", "Zebra.CR3"])
        model.sort = .rating
        #expect(model.visibleAssets.map(\.fileName) == ["Gamma.CR3", "Alpha.CR3", "Zebra.CR3", "Beta.CR3"])
        model.minimumRating = 3
        #expect(model.visibleAssets.map(\.fileName) == ["Gamma.CR3", "Alpha.CR3"])
        model.search = "  nikon  "
        #expect(model.visibleAssets.map(\.fileName) == ["Alpha.CR3"])
        model.search = ""
        model.minimumRating = 0
        model.selection = .folder(first.id)
        #expect(model.visibleAssets.map(\.fileName) == ["Alpha.CR3", "Zebra.CR3", "Beta.CR3"])
        model.selection = .subfolder(first.id, "Trip")
        #expect(model.visibleAssets.map(\.fileName) == ["Alpha.CR3", "Zebra.CR3"])
        model.selection = .favorites
        #expect(model.visibleAssets.map(\.fileName) == ["Gamma.CR3", "Alpha.CR3"])
        model.selection = .folder(UUID())
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
        #expect(model.visibleAssets.first?.id == secondPhoto.id)
        #expect(model.selectedAsset?.rating == 1)
        #expect(model.favoriteCount == 1)
        #expect(model.folderTree(for: first).photoCount == 1)
        #expect(model.count(in: first) == 1)

        model.setRating(5, for: firstPhoto.id)
        #expect(model.visibleAssets.first?.id == firstPhoto.id)
        #expect(model.selectedAsset?.rating == 5)
        model.selection = .favorites
        #expect(model.visibleAssets.map(\.id) == [secondPhoto.id])
        model.toggleFavorite(firstPhoto.id)
        #expect(model.visibleAssets.map(\.id) == [firstPhoto.id, secondPhoto.id])
        #expect(model.favoriteCount == 2)
        model.selectedID = firstPhoto.id
        #expect(model.selectedAsset?.isFavorite == true)

        model.selection = .all
        model.removeFolder(first.id)
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
        #expect(Set(model.visibleAssets.map(\.fileName)) == ["expiring.CR3", "recent.CR3"])
        currentDate = initial.addingTimeInterval(10)
        #expect(model.visibleAssets.map(\.fileName) == ["recent.CR3"], "Membership expires at the exact boundary without any model mutation")
        currentDate = initial.addingTimeInterval(-2)
        #expect(Set(model.visibleAssets.map(\.fileName)) == ["expiring.CR3", "old.CR3", "recent.CR3"])
        currentDate = initial.addingTimeInterval(7 * 86400)
        #expect(model.visibleAssets.isEmpty)
        currentDate = initial
        #expect(Set(model.visibleAssets.map(\.fileName)) == ["expiring.CR3", "recent.CR3"], "A cached empty result also responds to backward clock changes")
    }

    @Test
    func treeProjectionHonorsChangedFolderPathAndDirectoryArguments() async throws {
        let folder = LibraryFolder(url: root.appendingPathComponent("Photos"), subdirectoryPaths: ["Trip"])
        let model = try await load(LibraryCatalog(folders: [folder], assets: [photo("Trip/image.CR3", in: folder)]))
        #expect(model.folderTree(for: folder).photoCount == 1)
        var changed = folder
        changed.name = "Renamed"
        changed.subdirectoryPaths = ["Trip", "Empty"]
        #expect(model.folderTree(for: changed).name == "Renamed")
        #expect(model.folderTree(for: changed).contains(relativePath: "Empty"))
        changed.url = root.appendingPathComponent("DifferentRoot")
        #expect(model.folderTree(for: changed).photoCount == 0)
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
        #expect(model.visibleAssets.map(\.fileName) == ["new.png"])
        #expect(model.selectedAsset?.fileName == "new.png")
        #expect(model.favoriteCount == 0)
        #expect(model.folderTree(for: refreshed).contains(relativePath: "New"))
        #expect(!model.folderTree(for: refreshed).contains(relativePath: "Trip"))
        #expect(await model.finishSaving())
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
        while model.isLoading || model.isImporting {
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
