import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import PicEditCore

@Suite("Library import and persistence")
final class PicEditCoreTests {
    private let temporaryDirectory: URL

    init() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicEdit Tests \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    @Test
    func testScanRecursesAndIgnoresHiddenPackagesAndSymbolicLinks() async throws {
        let nested = temporaryDirectory.appendingPathComponent("Reise/Österreich", isDirectory: true)
        let hidden = temporaryDirectory.appendingPathComponent(".hidden", isDirectory: true)
        let package = temporaryDirectory.appendingPathComponent("Example.app", isDirectory: true)
        for directory in [nested, hidden, package] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeImage(to: temporaryDirectory.appendingPathComponent("photo10.PNG"))
        try writeImage(to: nested.appendingPathComponent("photo2.png"))
        try writeImage(to: temporaryDirectory.appendingPathComponent(".secret.png"))
        try writeImage(to: hidden.appendingPathComponent("hidden.png"))
        try writeImage(to: package.appendingPathComponent("package.png"))
        try Data("not an image".utf8).write(to: temporaryDirectory.appendingPathComponent("broken.jpg"))
        try Data("ordinary document".utf8).write(to: temporaryDirectory.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(
            at: nested.appendingPathComponent("loop", isDirectory: true),
            withDestinationURL: temporaryDirectory
        )
        try FileManager.default.createSymbolicLink(
            at: temporaryDirectory.appendingPathComponent("alias.png"),
            withDestinationURL: nested.appendingPathComponent("photo2.png")
        )

        let folder = LibraryFolder(url: temporaryDirectory)
        let first = try await FolderScanner().scan(folder: folder)
        let second = try await FolderScanner().scan(folder: folder)

        #expect(Set(first.assets.map(\.fileName)) == ["photo10.PNG", "photo2.png"])
        #expect(first.skippedFiles == 1, "Only unreadable image candidates count as skipped images")
        #expect(first.skippedURLs.map(\.lastPathComponent) == ["broken.jpg"])
        #expect(first.assets.map(\.id) == second.assets.map(\.id), "Refresh must preserve stable identities")
        #expect(first.assets.allSatisfy { $0.folderID == folder.id && $0.fileSize > 0 })
        #expect(first.assets.allSatisfy { $0.pixelWidth == 80 && $0.pixelHeight == 40 })
        #expect(first.assets.allSatisfy { $0.id == $0.fileURL.standardizedFileURL.resolvingSymlinksInPath().path })
        #expect(first.subdirectoryPaths == ["Reise", "Reise/Österreich"])
    }

    @Test
    func testDirectoryTreeIncludesEmptyAndUnicodeFoldersInNaturalOrder() async throws {
        let expected = ["Album 2", "Album 2/Empty", "Album 2/Österreich", "Album 10", "Empty"]
        for path in expected + [".hidden/Nested", "Example.app/Contents/Resources"] {
            try FileManager.default.createDirectory(
                at: temporaryDirectory.appendingPathComponent(path, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createSymbolicLink(
            at: temporaryDirectory.appendingPathComponent("Linked Album", isDirectory: true),
            withDestinationURL: temporaryDirectory.appendingPathComponent("Album 2", isDirectory: true)
        )
        let folder = LibraryFolder(url: temporaryDirectory)
        let first = try await FolderScanner().scan(folder: folder)
        let second = try await FolderScanner().scan(folder: folder)

        #expect(first.assets.isEmpty)
        #expect(first.skippedFiles == 0)
        #expect(first.subdirectoryPaths == expected)
        #expect(second.subdirectoryPaths == first.subdirectoryPaths)
        #expect(first.subdirectoryPaths.allSatisfy { !$0.hasPrefix("/") && !$0.hasSuffix("/") })
    }

    @Test
    func testReadsExifAndHonorsImageOrientation() async throws {
        let imageURL = temporaryDirectory.appendingPathComponent("Portrait.jpeg")
        try writeImage(to: imageURL, metadata: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "  Test Camera  "],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "50mm Prime",
                kCGImagePropertyExifFocalLength: 50,
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifExposureTime: 0.008,
                kCGImagePropertyExifISOSpeedRatings: [200],
                kCGImagePropertyExifDateTimeOriginal: "2024:06:15 12:34:56",
                kCGImagePropertyExifOffsetTimeOriginal: "+02:00"
            ]
        ])

        let scan = try await FolderScanner().scan(folder: LibraryFolder(url: temporaryDirectory))
        let asset = try #require(scan.assets.first)
        #expect(asset.pixelWidth == 40)
        #expect(asset.pixelHeight == 80)
        #expect(asset.cameraModel == "Test Camera")
        #expect(asset.lensModel == "50mm Prime")
        #expect(asset.focalLength == "50 mm")
        #expect(asset.aperture == "ƒ/2.8")
        #expect(asset.shutterSpeed == "1/125 s")
        #expect(asset.iso == "200")
        #expect(asset.captureDate == ISO8601DateFormatter().date(from: "2024-06-15T10:34:56Z"))
        #expect(asset.format == "JPEG")
        #expect(asset.rating == 0)
        #expect(!asset.isFavorite)
    }

    @Test
    func testScanPreservesDecimalExposuresAndConventionalReciprocals() async throws {
        let exposures: [(Double, String)] = [
            (0.8, "0.8 s"), (0.6, "0.6 s"), (0.3, "0.3 s"),
            (2.5, "2.5 s"), (2.25, "2.25 s"),
            (1 / 300.0, "1/300 s"), (0.008, "1/125 s"), (0.5, "1/2 s")
        ]
        for (index, exposure) in exposures.enumerated() {
            try writeImage(to: temporaryDirectory.appendingPathComponent("exposure-\(index).jpg"), metadata: [
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: exposure.0]
            ])
        }

        let scan = try await FolderScanner().scan(folder: LibraryFolder(url: temporaryDirectory))
        #expect(scan.assets.count == exposures.count)
        for (index, exposure) in exposures.enumerated() {
            let asset = try #require(scan.assets.first { $0.fileName == "exposure-\(index).jpg" })
            #expect(asset.shutterSpeed == exposure.1)
        }
    }

    @Test
    func testExposureDescriptionHandlesSerializationAndNumericLimits() throws {
        #expect(FolderScanner.exposureDescription(Double(Float(1 / 300.0))) == "1/300 s")
        for seconds in [1e-30, Double.leastNonzeroMagnitude, Double.leastNormalMagnitude, 1 / Double(Int.max)] {
            let description = try #require(FolderScanner.exposureDescription(seconds))
            #expect(description.hasSuffix(" s"))
            let restored = try #require(Double(description.dropLast(2)))
            #expect(restored.isFinite && restored > 0)
            #expect(abs(restored / seconds - 1) < 1e-12)
        }
        for seconds in [0.0, -1, Double.nan, Double.infinity, -Double.infinity] {
            #expect(FolderScanner.exposureDescription(seconds) == nil)
        }
    }

    @Test
    func testMissingFolderFailsInsteadOfReturningEmptyScan() async throws {
        let absent = temporaryDirectory.appendingPathComponent("missing")
        do {
            _ = try await FolderScanner().scan(folder: LibraryFolder(url: absent))
            Issue.record("A missing folder must not replace a previously imported folder with an empty scan")
        } catch FolderScanError.unavailableFolder(let url) {
            #expect(url == absent.standardizedFileURL.resolvingSymlinksInPath())
        }
    }

    @Test
    func testFileCannotBeScannedAsFolder() async throws {
        let image = temporaryDirectory.appendingPathComponent("photo.png")
        try writeImage(to: image)
        do {
            _ = try await FolderScanner().scan(folder: LibraryFolder(url: image))
            Issue.record("Regular files are not folders")
        } catch FolderScanError.notDirectory(let url) {
            #expect(url == image.standardizedFileURL.resolvingSymlinksInPath())
        }
    }

    @Test
    func testCancelledScanThrowsCancellationError() async throws {
        let folder = LibraryFolder(url: temporaryDirectory)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await FolderScanner().scan(folder: folder)
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled import must not publish partial results")
        } catch is CancellationError {
            // Expected.
        }
    }

    @Test
    func testParallelScanMatchesSerialMetadataAndStableCorruptImageOrder() async throws {
        for index in (1...18).reversed() {
            try writeImage(to: temporaryDirectory.appendingPathComponent("photo\(index).jpeg"), metadata: [
                kCGImagePropertyOrientation: index.isMultiple(of: 2) ? 6 : 1,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Camera \(index)"],
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [100 * index]]
            ])
        }
        for name in ["broken10.jpg", "broken2.jpg", "broken1.jpg"] {
            try Data("invalid image".utf8).write(to: temporaryDirectory.appendingPathComponent(name))
        }
        let folder = LibraryFolder(url: temporaryDirectory)
        async let serial = FolderScanner(maximumConcurrentMetadataReads: 1).scan(folder: folder)
        async let parallel = FolderScanner(maximumConcurrentMetadataReads: 4).scan(folder: folder)
        let (serialResult, parallelResult) = try await (serial, parallel)

        #expect(parallelResult.assets == serialResult.assets)
        #expect(parallelResult.assets.map(\.fileName) == (1...18).map { "photo\($0).jpeg" })
        #expect(parallelResult.skippedURLs == serialResult.skippedURLs)
        #expect(parallelResult.skippedURLs.map(\.lastPathComponent) == ["broken1.jpg", "broken2.jpg", "broken10.jpg"])
        #expect(parallelResult.skippedFiles == 3)
    }

    @Test
    func testMetadataReadersOverlapWithoutExceedingWorkerLimit() async throws {
        for index in 0..<15 {
            try Data().write(to: temporaryDirectory.appendingPathComponent("photo\(index).png"))
        }
        let probe = ScannerReadProbe()
        let scanner = FolderScanner(maximumConcurrentMetadataReads: 3) { url, folderID in
            await probe.started()
            try await Task.sleep(for: .milliseconds(10))
            await probe.finished(cancelled: false)
            return PhotoAsset(folderID: folderID, fileURL: url)
        }
        let result = try await scanner.scan(folder: LibraryFolder(url: temporaryDirectory))
        let state = await probe.state
        #expect(result.assets.count == 15)
        #expect(state.started == 15)
        #expect(state.peak == 3, "Independent readers should overlap within the configured bound")
        #expect(state.active == 0)
    }

    @Test
    func testCancellationStopsQueuedReadsAndDrainsActiveReaders() async throws {
        for index in 0..<20 {
            try Data().write(to: temporaryDirectory.appendingPathComponent("photo\(index).png"))
        }
        let probe = ScannerReadProbe()
        let scanner = FolderScanner(maximumConcurrentMetadataReads: 2) { url, folderID in
            await probe.started()
            do {
                try await Task.sleep(for: .seconds(60))
                await probe.finished(cancelled: false)
                return PhotoAsset(folderID: folderID, fileURL: url)
            } catch {
                await probe.finished(cancelled: error is CancellationError)
                throw error
            }
        }
        let folder = LibraryFolder(url: temporaryDirectory)
        let task = Task { try await scanner.scan(folder: folder) }
        await probe.waitForStarts(2)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled scan must not return a partial catalog")
        } catch is CancellationError {
            let state = await probe.state
            #expect(state.started == 2, "Queued files must never begin decoding after cancellation")
            #expect(state.cancelled == 2)
            #expect(state.active == 0, "The scan must drain children before returning")
        }
    }

    @Test
    func testMetadataFailureCancelsSiblingAndNeverReturnsPartialScan() async throws {
        let missing = temporaryDirectory.appendingPathComponent("photo0.png")
        for index in 0..<2 {
            try Data().write(to: temporaryDirectory.appendingPathComponent("photo\(index).png"))
        }
        let probe = ScannerReadProbe()
        let scanner = FolderScanner(maximumConcurrentMetadataReads: 2) { url, folderID in
            await probe.started()
            await probe.waitForStarts(2)
            if url == missing {
                await probe.finished(cancelled: false)
                throw FolderScanError.unavailableFolder(url)
            }
            do {
                try await Task.sleep(for: .seconds(60))
                await probe.finished(cancelled: false)
                return PhotoAsset(folderID: folderID, fileURL: url)
            } catch {
                await probe.finished(cancelled: error is CancellationError)
                throw error
            }
        }
        do {
            _ = try await scanner.scan(folder: LibraryFolder(url: temporaryDirectory))
            Issue.record("A failed metadata read must not publish a partial catalog")
        } catch FolderScanError.unavailableFolder(let url) {
            #expect(url == missing)
            let state = await probe.state
            #expect(state.started == 2)
            #expect(state.cancelled == 1)
            #expect(state.active == 0)
        }
    }

    @Test
    func testCatalogRoundTripPreservesMetadataAndUserEdits() throws {
        let repository = CatalogRepository(directory: temporaryDirectory.appendingPathComponent("Support/PicEdit"))
        #expect(try repository.load() == LibraryCatalog())
        let date = Date(timeIntervalSinceReferenceDate: 700_000_000.125)
        let folder = LibraryFolder(
            url: temporaryDirectory,
            bookmarkData: Data([1, 2, 3]),
            addedAt: date,
            lastScannedAt: date,
            subdirectoryPaths: ["Reise", "Reise/Österreich", "Leer"]
        )
        let asset = PhotoAsset(
            folderID: folder.id,
            fileURL: temporaryDirectory.appendingPathComponent("Urlaub Foto.jpg"),
            fileSize: 123_456,
            pixelWidth: 6000,
            pixelHeight: 4000,
            createdAt: date,
            modifiedAt: date,
            captureDate: date,
            format: "JPEG",
            cameraModel: "Camera",
            lensModel: "Lens",
            focalLength: "35 mm",
            aperture: "ƒ/4",
            shutterSpeed: "1/250 s",
            iso: "100",
            rating: 4,
            isFavorite: true
        )
        let catalog = LibraryCatalog(folders: [folder], assets: [asset])
        try repository.save(catalog)
        #expect(try repository.load() == catalog)
        var changed = catalog
        changed.assets[0].rating = 2
        changed.assets[0].isFavorite = false
        try repository.save(changed)
        #expect(try repository.load() == changed)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: repository.directory.path)) ==
            Set(["catalog.json", "catalog-write.lock", "MetadataCatalogStaging"]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: repository.directory.appendingPathComponent("MetadataCatalogStaging").path).isEmpty)
    }

    @Test
    func testLegacyCatalogWithoutDirectoryTreeLoadsWithEmptyDefault() throws {
        let repository = CatalogRepository(directory: temporaryDirectory)
        let folder = LibraryFolder(url: temporaryDirectory, bookmarkData: Data([1, 2, 3]))
        let photo = PhotoAsset(folderID: folder.id, fileURL: temporaryDirectory.appendingPathComponent("Trip/photo.png"), rating: 4, isFavorite: true)
        let catalog = LibraryCatalog(folders: [folder], assets: [photo])
        let data = try JSONEncoder().encode(catalog)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var folders = try #require(json["folders"] as? [[String: Any]])
        folders[0].removeValue(forKey: "subdirectoryPaths")
        json["folders"] = folders
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        try legacyData.write(to: repository.fileURL)

        let loaded = try repository.load()
        #expect(loaded == catalog)
        #expect(loaded.version == 1)
        #expect(loaded.folders.first?.subdirectoryPaths == [])
        #expect(loaded.assets.first?.rating == 4)
        #expect(loaded.assets.first?.isFavorite == true)
        #expect(try Data(contentsOf: repository.fileURL) == legacyData)
    }

    @Test
    func testMalformedCatalogIsNotSilentlyResetOrModified() throws {
        let repository = CatalogRepository(directory: temporaryDirectory)
        let invalidData = Data("{ incomplete JSON".utf8)
        try invalidData.write(to: repository.fileURL)
        do {
            _ = try repository.load()
            Issue.record("A corrupt catalog must throw")
        } catch CatalogRepositoryError.corruptCatalog(let url) {
            #expect(url == repository.fileURL)
        }
        #expect(try Data(contentsOf: repository.fileURL) == invalidData)
    }

    @Test
    func testRejectsFutureCatalogVersionWithoutOverwriting() throws {
        let repository = CatalogRepository(directory: temporaryDirectory)
        let futureCatalog = LibraryCatalog(version: 999)
        let futureData = try JSONEncoder().encode(futureCatalog)
        try futureData.write(to: repository.fileURL)
        do {
            _ = try repository.load()
            Issue.record("A future catalog version must throw")
        } catch CatalogRepositoryError.unsupportedVersion(let version) {
            #expect(version == 999)
        }
        #expect(try Data(contentsOf: repository.fileURL) == futureData)
    }

    @Test
    func testInvalidCatalogCannotReplaceValidCatalog() throws {
        let repository = CatalogRepository(directory: temporaryDirectory)
        let folder = LibraryFolder(url: temporaryDirectory)
        let valid = LibraryCatalog(folders: [folder])
        try repository.save(valid)
        let orphan = PhotoAsset(folderID: UUID(), fileURL: temporaryDirectory.appendingPathComponent("orphan.jpg"))
        #expect(throws: CatalogRepositoryError.self) {
            try repository.save(LibraryCatalog(folders: [folder], assets: [orphan]))
        }
        #expect(try repository.load() == valid)
        #expect(throws: CatalogRepositoryError.self) {
            try repository.save(LibraryCatalog(folders: [folder, folder]))
        }
        #expect(try repository.load() == valid)
    }

    private func writeImage(to url: URL, metadata: [CFString: Any] = [:]) throws {
        let context = try #require(CGContext(
            data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        let image = try #require(context.makeImage())
        let type = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? UTType.jpeg : UTType.png
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }
}

private actor ScannerReadProbe {
    struct State: Sendable {
        var started = 0
        var active = 0
        var peak = 0
        var cancelled = 0
    }

    private(set) var state = State()
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func started() {
        state.started += 1
        state.active += 1
        state.peak = max(state.peak, state.active)
        let ready = waiters.filter { state.started >= $0.0 }
        waiters.removeAll { state.started >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
    }

    func finished(cancelled: Bool) {
        state.active -= 1
        if cancelled { state.cancelled += 1 }
    }

    func waitForStarts(_ count: Int) async {
        guard state.started < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}
