#if PICEDIT_LIBRARY_BENCHMARK
import AppKit
import Foundation
import PicEditCore
import Darwin

@main
struct ProjectionBenchmark {
    @MainActor
    static func main() async throws {
        print("Library projection benchmark: 10,000 synthetic records, no image decoding")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Projection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = CatalogRepository(directory: temporary)
        let folder = LibraryFolder(url: URL(fileURLWithPath: "/tmp/PicEdit-Benchmark-Offline"), subdirectoryPaths: ["Trip", "Trip/Nested", "Trip2"])
        let base = PhotoAsset(folderID: folder.id, fileURL: folder.url.appendingPathComponent("initial.CR3"))
        var assets: [PhotoAsset] = []
        for index in 0..<10_000 {
            var photo = base
            let directory = index % 3 == 0 ? "Trip/Nested" : (index % 3 == 1 ? "Trip" : "Trip2")
            photo.fileName = "IMG_\(index).CR3"
            photo.fileURL = folder.url.appendingPathComponent(directory).appendingPathComponent(photo.fileName)
            photo.id = photo.fileURL.path
            photo.createdAt = Date(timeIntervalSince1970: Double(index))
            photo.modifiedAt = photo.createdAt
            photo.rating = index % 6
            photo.isFavorite = index % 7 == 0
            assets.append(photo)
        }
        try repository.save(LibraryCatalog(folders: [folder], assets: assets))
        let model = LibraryModel(repository: repository)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while model.isLoading {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "ProjectionBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Temporary library did not load in 20 seconds."])
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard !model.isReadOnly, model.assets.count == assets.count else {
            throw NSError(domain: "ProjectionBenchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: model.errorMessage ?? "Temporary library did not contain the expected records."])
        }
        model.selection = .folder(folder.id)
        model.sort = .name
        var checksum = 0
        let clock = ContinuousClock()
        func elapsed(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        }
        var heartbeatGaps: [Double] = []
        let heartbeat = Task { @MainActor in
            var previous = clock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(1)) } catch { break }
                let current = clock.now
                heartbeatGaps.append(elapsed(previous.duration(to: current)))
                previous = current
            }
        }
        await Task.yield()
        var start = clock.now
        await model.waitForProjection()
        checksum += model.visibleAssets.count
        print("first visible projection (10k assets): \(elapsed(start.duration(to: clock.now))) ms")
        start = clock.now
        for index in 0..<12 {
            model.selectedID = assets[index].id
            model.gridSize = Double(190 + index)
            await model.waitForProjection()
            checksum += model.visibleAssets.count
            checksum += model.selectedAsset?.rating ?? 0
            checksum += model.favoriteCount
            checksum += model.folderTree(for: folder).photoCount
        }
        print("12 selection/layout updates + visible/tree/count access: \(elapsed(start.duration(to: clock.now))) ms")
        model.selection = .subfolder(folder.id, "Trip")
        start = clock.now
        await model.waitForProjection()
        checksum += model.visibleAssets.count
        print("first subfolder projection: \(elapsed(start.duration(to: clock.now))) ms")
        start = clock.now
        for index in 0..<12 {
            model.selectedID = assets[index].id
            await model.waitForProjection()
            checksum += model.visibleAssets.count
            checksum += model.folderTree(for: folder).photoCount
        }
        print("12 repeated subfolder + tree access: \(elapsed(start.duration(to: clock.now))) ms")
        try await Task.sleep(for: .milliseconds(2))
        heartbeat.cancel()
        await heartbeat.value
        print("MainActor 1 ms heartbeat: max observed gap \(heartbeatGaps.max() ?? 0) ms, \(heartbeatGaps.count) samples")
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 { print("peak resident bytes: \(usage.ru_maxrss)") }
        print("checksum \(checksum)")
        guard checksum == 473_849 else {
            throw NSError(domain: "ProjectionBenchmark", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unexpected projection result: \(checksum)."])
        }
    }
}

#endif
