import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Decoded folder path aliases", .serialized)
@MainActor
struct FolderPathAliasTests {
    @Test(arguments: [false, true])
    func decodedAliasesPreserveTreeFiltersAndStoredIdentity(reverse: Bool) async throws {
        let fixture = try Fixture(reverse: reverse)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let catalog = fixture.catalog
        let folder = catalog.folders[0]
        let first = catalog.assets[0]
        #expect(!first.fileURL.path.hasPrefix(folder.url.path + "/"), "Fixture retains distinct raw aliases")
        #expect(LibraryProjectionWorker.filePath(first.fileURL).hasPrefix(LibraryProjectionWorker.directoryPrefix(folder.url)))
        let tree = FolderTreeNode.make(folder: folder, assets: catalog.assets)
        #expect(tree.photoCount == 3)
        #expect(tree.children.first { $0.name == "Trip" }?.photoCount == 2)
        #expect(tree.children.first { $0.name == "Trip2" }?.photoCount == 1)

        let worker = LibraryProjectionWorker()
        let filtered = try await worker.project(catalog, generation: 1,
            key: .init(selection: .subfolder(folder.id, "Trip"), query: "", sort: .name, minimumRating: 0),
            date: Date(), overrides: [:])
        #expect(filtered.assets.map(\.id) == Array(catalog.assets.prefix(2)).map(\.id))
        let candidates = try await worker.candidates(catalog, snapshotSessionID: UUID(), generation: 1,
            key: .init(selection: .folder(folder.id), query: "", sort: .name, minimumRating: 0,
                       searchMode: .semantic, semanticQuery: "Reise"), date: Date(), overrides: [:])
        #expect(Set(candidates.assets.map(\.id)) == Set(catalog.assets.prefix(3).map(\.id)))

        let repository = CatalogRepository(directory: fixture.root.appendingPathComponent("Catalog"))
        try repository.save(catalog)
        let model = LibraryModel(repository: repository)
        let deadline = ContinuousClock.now + .seconds(20)
        while model.isLoading {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { Issue.record("Catalog load timed out"); return }
            await Task.yield()
        }
        await model.waitForProjection()
        #expect(model.count(in: folder) == 3)
        #expect(model.contains(first, in: folder))
        #expect(!model.contains(catalog.assets[3], in: folder))
        model.selection = .subfolder(folder.id, "Trip")
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == Array(catalog.assets.prefix(2)).map(\.id))
        #expect(model.catalog.assets == catalog.assets, "Read-time comparison cannot rewrite persisted IDs, URLs or ratings")
        #expect(await model.finishSaving())
        #expect(try repository.load().assets == catalog.assets)
    }

    @Test(arguments: [false, true])
    func refreshAndParentOwnershipUseTheSameAliasComparison(reverse: Bool) async throws {
        let fixture = try Fixture(reverse: reverse)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var catalog = fixture.catalog
        catalog.assets[0].isFavorite = true
        let parent = catalog.folders[0]
        var child = LibraryFolder(url: parent.url.appendingPathComponent("Trip"), subdirectoryPaths: ["Empty"])
        child.url = URL(fileURLWithPath: fixture.assetBase + "/Trip", isDirectory: true)
        var withChild = catalog
        withChild.folders.append(child)
        withChild.assets[0].folderID = child.id
        let worker = LibraryCatalogWorker()
        let removed = await worker.removing(child.id, from: withChild)
        #expect(removed.assets.count == catalog.assets.count)
        #expect(removed.assets[0].folderID == parent.id)
        #expect(removed.assets[0].id == catalog.assets[0].id)
        #expect(removed.assets[0].fileURL == catalog.assets[0].fileURL)

        let refreshed = try await worker.merge(ScanResult(assets: [], skippedFiles: 0), folder: parent, into: catalog)
        #expect(refreshed.catalog.assets == catalog.assets,
                "An empty scan cannot remove catalog identities, through either alias or in the similarly named sibling")

        let original = catalog.assets[0]
        let alternateURL = parent.url.appendingPathComponent("Trip/A.jpg", isDirectory: false)
        let skipped = try await worker.merge(ScanResult(assets: [], skippedFiles: 1, skippedURLs: [alternateURL]),
            folder: parent, into: catalog)
        #expect(skipped.catalog.assets.first { $0.id == original.id } == original,
                "Temporary decode failures preserve the complete original record through the other alias")

        var scanned = original
        scanned.id = alternateURL.path; scanned.fileURL = alternateURL
        scanned.rating = 0; scanned.isFavorite = false
        let rescanned = try await worker.merge(ScanResult(assets: [scanned], skippedFiles: 0), folder: parent, into: catalog)
        #expect(rescanned.addedCount == 0)
        let retained = try #require(rescanned.catalog.assets.first { $0.id == original.id })
        #expect(retained.fileURL == original.fileURL)
        #expect(retained.rating == original.rating && retained.isFavorite == original.isFavorite)

        var duplicate = original
        duplicate.id = alternateURL.path + "-legacy-duplicate"
        var ambiguous = catalog
        ambiguous.assets.append(duplicate)
        do {
            _ = try await worker.merge(ScanResult(assets: [scanned], skippedFiles: 0), folder: parent, into: ambiguous)
            Issue.record("Ambiguous legacy aliases cannot silently choose one saved identity")
        } catch is CatalogRepositoryError { }
        scanned.id = original.id
        do {
            _ = try await worker.merge(ScanResult(assets: [scanned], skippedFiles: 0), folder: parent, into: ambiguous)
            Issue.record("An exact-ID hit cannot discard another legacy identity for the same file")
        } catch is CatalogRepositoryError { }
    }

    @Test(arguments: [false, true])
    func existingMissingUnreadableAndOfflinePathsKeepOneComparison(reverse: Bool) async throws {
        let fixture = try Fixture(reverse: reverse)
        let fm = FileManager.default
        let photos = fixture.root.appendingPathComponent("Photos", isDirectory: true)
        let locked = photos.appendingPathComponent("Locked", isDirectory: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? fm.removeItem(at: fixture.root)
        }
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let present = photos.appendingPathComponent("Trip/Present.jpg")
        let unreadable = photos.appendingPathComponent("Trip/Unreadable.jpg")
        try Data([1, 2]).write(to: present)
        try Data([3, 4]).write(to: unreadable)
        try Data([5, 6]).write(to: locked.appendingPathComponent("Existing.jpg"))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        // A generic, relative link proves this is independent of /tmp spelling.
        let link = fixture.root.appendingPathComponent("PhotoAlias", isDirectory: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "Photos")
        let aliases = [fixture.catalog.folders[0].url,
                       URL(fileURLWithPath: fixture.assetBase, isDirectory: true), link]
        let base = LibraryProjectionWorker.filePath(photos)
        let relativePaths = ["Trip/Present.jpg", "Trip/Unreadable.jpg", "Trip/Missing.jpg",
                             "Missing/Deep/Image.jpg", "Locked/Existing.jpg", "Locked/Missing/Image.jpg"]
        for relative in relativePaths {
            for alias in aliases {
                #expect(LibraryProjectionWorker.filePath(alias.appendingPathComponent(relative)) == base + "/" + relative)
            }
        }
        let absent = photos.appendingPathComponent("Missing/Deep/Image.jpg")
        let before = LibraryProjectionWorker.filePath(absent)
        try fm.createDirectory(at: absent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([7]).write(to: absent)
        #expect(LibraryProjectionWorker.filePath(absent) == before, "Appearance cannot change membership")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        try fm.removeItem(at: photos)
        for alias in aliases {
            #expect(LibraryProjectionWorker.filePath(alias) == base, "An offline root and dangling alias retain their comparison")
            #expect(LibraryProjectionWorker.filePath(alias.appendingPathComponent("Trip/Missing.jpg")) == base + "/Trip/Missing.jpg")
        }
        let tree = FolderTreeNode.make(folder: fixture.catalog.folders[0], assets: fixture.catalog.assets)
        #expect(tree.photoCount == 3)
        let projected = try await LibraryProjectionWorker().project(fixture.catalog, generation: 1,
            key: .init(selection: .folder(fixture.catalog.folders[0].id), query: "", sort: .name, minimumRating: 0),
            date: Date(), overrides: [:])
        #expect(projected.assets.count == 3)
    }

    @Test
    func directoryBoundariesRootAndSymlinkCyclesAreBounded() throws {
        let fixture = try Fixture(reverse: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(LibraryProjectionWorker.directoryPrefix(URL(fileURLWithPath: "/", isDirectory: true)) == "/")
        let prefix = LibraryProjectionWorker.directoryPrefix(fixture.catalog.folders[0].url)
        #expect(!LibraryProjectionWorker.filePath(fixture.catalog.assets[3].fileURL).hasPrefix(prefix))
        let cycle = fixture.root.appendingPathComponent("Cycle")
        try FileManager.default.createSymbolicLink(atPath: cycle.path, withDestinationPath: "Cycle")
        #expect(LibraryProjectionWorker.filePath(cycle.appendingPathComponent("Missing.jpg")).hasSuffix("/Cycle/Missing.jpg"))
    }

    private struct Fixture {
        let root: URL
        let assetBase: String
        let catalog: LibraryCatalog
        init(reverse: Bool) throws {
            let name = "Glowroom-Alias-\(UUID().uuidString)"
            root = URL(fileURLWithPath: "/private/tmp/" + name, isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Photos/Trip"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Photos/Trip2"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Photos2"), withIntermediateDirectories: true)
            let folderBase = (reverse ? "/tmp/" : "/private/tmp/") + name + "/Photos"
            assetBase = (reverse ? "/private/tmp/" : "/tmp/") + name + "/Photos"
            var folder = LibraryFolder(url: root.appendingPathComponent("Photos"), subdirectoryPaths: ["Trip", "Trip2"])
            folder.url = URL(fileURLWithPath: folderBase, isDirectory: true)
            var assets: [PhotoAsset] = []
            for (index, relative) in ["Trip/A.jpg", "Trip/B.jpg", "Trip2/C.jpg", "../Photos2/D.jpg"].enumerated() {
                let path = relative.hasPrefix("../") ? assetBase + "2/D.jpg" : assetBase + "/" + relative
                var asset = PhotoAsset(folderID: folder.id, fileURL: URL(fileURLWithPath: path, isDirectory: false),
                                       createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000), rating: index + 1)
                asset.fileURL = URL(fileURLWithPath: path, isDirectory: false)
                asset.id = path
                assets.append(asset)
            }
            // JSON decoding bypasses canonicalizing memberwise initializers, as
            // real older catalogs do. Keep both raw aliases in the loaded fixture.
            catalog = try JSONDecoder().decode(LibraryCatalog.self,
                from: JSONEncoder().encode(LibraryCatalog(folders: [folder], assets: assets)))
        }
    }
}
