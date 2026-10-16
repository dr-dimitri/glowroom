import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PicEdit

@Suite("Persistent image previews")
final class PreviewDiskCacheTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit Preview Cache \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test
    func persistsBetweenInstancesWithoutReadingOrChangingOriginal() async throws {
        let original = root.appendingPathComponent("Original.nef")
        let originalBytes = Data("Original bytes must remain untouched".utf8)
        try originalBytes.write(to: original)
        let request = request(url: original)
        let directory = root.appendingPathComponent("Cache")
        let cache = PreviewDiskCache(directory: directory)
        let bitmap = try bitmap(alpha: false)
        await cache.store(bitmap, for: request)
        #expect(try Data(contentsOf: original) == originalBytes)
        try FileManager.default.removeItem(at: original)

        let restored = PreviewDiskCache(directory: directory)
        let hit = try #require(await restored.image(for: request))
        #expect(hit.image.width == bitmap.image.width)
        #expect(hit.image.height == bitmap.image.height)
        #expect(hit.byteCost > 0)
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test
    func editingBaseIsPersistedLosslesslyEvenWithoutAlpha() async throws {
        let directory = root.appendingPathComponent("EditingCache")
        let cache = PreviewDiskCache(directory: directory)
        let base = request()
        let editing = PreviewRequest(url: try #require(base.url), modifiedAt: base.modifiedAt, pixelSize: base.pixelSize,
                                     fileSize: base.fileSize, allowsEmbeddedPreview: false)
        let original = try bitmap(alpha: false)
        await cache.store(original, for: editing)
        let file = try #require(cacheFiles(in: directory).first)
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        let reloaded = try #require(await PreviewDiskCache(directory: directory).image(for: editing))
        #expect(reloaded.image.width == original.image.width)
        #expect(reloaded.image.height == original.image.height)
        #expect(reloaded.image.colorSpace?.name == original.image.colorSpace?.name)
    }

    @Test
    func keysInvalidateForPathDateSizeAndResolution() async throws {
        let cache = PreviewDiskCache(directory: root.appendingPathComponent("Cache"))
        let original = request()
        let bitmap = try bitmap(alpha: false)
        await cache.store(bitmap, for: original)
        let variants = [
            request(url: root.appendingPathComponent("Other/Original.nef")),
            request(date: original.modifiedAt.addingTimeInterval(1)),
            request(fileSize: original.fileSize + 1),
            request(pixelSize: original.pixelSize * 2),
            PreviewRequest(url: try #require(original.url), modifiedAt: original.modifiedAt, pixelSize: original.pixelSize,
                           fileSize: original.fileSize, allowsEmbeddedPreview: false)
        ]
        for variant in variants {
            #expect(await cache.image(for: variant) == nil)
        }
        let equivalent = request(url: root.appendingPathComponent("Unused/../Original.nef"))
        #expect(await cache.image(for: equivalent) != nil)
    }

    @Test
    func corruptEntryBecomesMissAndIsRemoved() async throws {
        let directory = root.appendingPathComponent("Cache")
        let cache = PreviewDiskCache(directory: directory)
        let request = request()
        await cache.store(try bitmap(alpha: false), for: request)
        let file = try #require(cacheFiles(in: directory).first)
        try Data("broken cached image".utf8).write(to: file)
        #expect(await cache.image(for: request) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await cache.image(for: request) == nil)
    }

    @Test
    func budgetEvictsLeastRecentlyUsedPreview() async throws {
        let bitmap = try bitmap(alpha: true)
        let cost = try await encodedCost(bitmap)
        let directory = root.appendingPathComponent("Cache")
        let cache = PreviewDiskCache(directory: directory, byteLimit: cost * 2)
        let a = request(url: root.appendingPathComponent("a.nef"))
        let b = request(url: root.appendingPathComponent("b.nef"))
        let c = request(url: root.appendingPathComponent("c.nef"))
        await cache.store(bitmap, for: a)
        await cache.store(bitmap, for: b)
        #expect(await cache.image(for: a) != nil)
        await cache.store(bitmap, for: c)
        #expect(await cache.image(for: b) == nil)
        #expect(await cache.image(for: a) != nil)
        #expect(await cache.image(for: c) != nil)
        let files = try cacheFiles(in: directory)
        #expect(files.count == 2)
        #expect(try totalBytes(files) <= cost * 2)
    }

    @Test
    func recencySurvivesRestartAndEvictionLeavesUnownedFilesAlone() async throws {
        let bitmap = try bitmap(alpha: true)
        let cost = try await encodedCost(bitmap)
        let directory = root.appendingPathComponent("Cache")
        let cache = PreviewDiskCache(directory: directory, byteLimit: cost * 2)
        let a = request(url: root.appendingPathComponent("a.nef"))
        let b = request(url: root.appendingPathComponent("b.nef"))
        let c = request(url: root.appendingPathComponent("c.nef"))
        await cache.store(bitmap, for: a)
        let aFile = try #require(cacheFiles(in: directory).first)
        await cache.store(bitmap, for: b)
        let bFile = try #require(cacheFiles(in: directory).first { $0 != aFile })
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: aFile.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: bFile.path)
        let note = directory.appendingPathComponent("my-notes.txt")
        let malformedName = directory.appendingPathComponent("picedit-v2-not-a-cache-key.preview")
        try Data("keep me".utf8).write(to: note)
        try Data("keep this too".utf8).write(to: malformedName)
        let symlink = directory.appendingPathComponent("picedit-v2-" + String(repeating: "a", count: 64) + ".preview")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: note)
        let nestedDirectory = directory.appendingPathComponent("picedit-v2-" + String(repeating: "b", count: 64) + ".preview")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

        let reopened = PreviewDiskCache(directory: directory, byteLimit: cost * 2)
        #expect(await reopened.image(for: a) != nil)
        let reopenedAgain = PreviewDiskCache(directory: directory, byteLimit: cost * 2)
        await reopenedAgain.store(bitmap, for: c)
        #expect(await reopenedAgain.image(for: a) != nil)
        #expect(await reopenedAgain.image(for: b) == nil)
        #expect(await reopenedAgain.image(for: c) != nil)
        #expect(try String(contentsOf: note, encoding: .utf8) == "keep me")
        #expect(try String(contentsOf: malformedName, encoding: .utf8) == "keep this too")
        #expect(try symlink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(try nestedDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    @Test(arguments: [false, true])
    func encodingPreservesOrientationAlphaAndColorProfile(alpha: Bool) async throws {
        let bitmap = try bitmap(alpha: alpha)
        let directory = root.appendingPathComponent("Cache")
        let cache = PreviewDiskCache(directory: directory)
        let request = request()
        await cache.store(bitmap, for: request)
        let file = try #require(cacheFiles(in: directory).first)
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let type = CGImageSourceGetType(source) as String?
        #expect(type == (alpha ? UTType.png.identifier : UTType.jpeg.identifier))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let restored = try #require(await cache.image(for: request))
        #expect(restored.image.width == bitmap.image.width)
        #expect(restored.image.height == bitmap.image.height)
        #expect(restored.image.colorSpace?.name == bitmap.image.colorSpace?.name)
        let before = try pixels(bitmap.image)
        let after = try pixels(restored.image)
        // Compare the centers of four asymmetrically colored quadrants: a flip
        // or rotation cannot accidentally pass a uniform-color round trip.
        for (x, y) in [(10, 6), (30, 6), (10, 18), (30, 18)] {
            for component in 0..<4 {
                let index = (y * bitmap.image.width + x) * 4 + component
                let tolerance = alpha ? 1 : 12
                #expect(abs(Int(before[index]) - Int(after[index])) <= tolerance)
            }
        }
    }

    @Test
    func disabledOversizedAndInaccessibleCachesAreNonfatal() async throws {
        let bitmap = try bitmap(alpha: true)
        let request = request()
        for limit in [0, 1] {
            let directory = root.appendingPathComponent("Cache-\(limit)")
            let cache = PreviewDiskCache(directory: directory, byteLimit: limit)
            await cache.store(bitmap, for: request)
            #expect(await cache.image(for: request) == nil)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
        let unavailable = root.appendingPathComponent("FileInsteadOfDirectory")
        try Data("do not replace".utf8).write(to: unavailable)
        let cache = PreviewDiskCache(directory: unavailable)
        await cache.store(bitmap, for: request)
        #expect(await cache.image(for: request) == nil)
        #expect(try String(contentsOf: unavailable, encoding: .utf8) == "do not replace")
    }

    @Test
    func reloadingWithSmallerBudgetPrunesOwnedPreviews() async throws {
        let directory = root.appendingPathComponent("Cache")
        let cache = PreviewDiskCache(directory: directory)
        let request = request()
        await cache.store(try bitmap(alpha: true), for: request)
        let smaller = PreviewDiskCache(directory: directory, byteLimit: 1)
        #expect(await smaller.image(for: request) == nil)
        #expect(try cacheFiles(in: directory).isEmpty)
    }

    private func request(url: URL? = nil, date: Date = Date(timeIntervalSince1970: 1_700_000_000.25), fileSize: Int64 = 12_345, pixelSize: Int = 128) -> PreviewRequest {
        PreviewRequest(url: url ?? root.appendingPathComponent("Original.nef"), modifiedAt: date, pixelSize: pixelSize, fileSize: fileSize)
    }

    private func bitmap(alpha: Bool) throws -> PreviewBitmap {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let alphaInfo: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
        let context = try #require(CGContext(data: nil, width: 40, height: 24, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: alphaInfo.rawValue))
        for (rect, components) in [
            (CGRect(x: 0, y: 0, width: 20, height: 12), [CGFloat(0.8), 0.2, 0.1, alpha ? 0.5 : 1]),
            (CGRect(x: 20, y: 0, width: 20, height: 12), [CGFloat(0.1), 0.7, 0.2, 1]),
            (CGRect(x: 0, y: 12, width: 20, height: 12), [CGFloat(0.2), 0.1, 0.8, alpha ? 0.25 : 1]),
            (CGRect(x: 20, y: 12, width: 20, height: 12), [CGFloat(0.8), 0.6, 0.2, 1])
        ] {
            context.setFillColor(try #require(CGColor(colorSpace: space, components: components)))
            context.fill(rect)
        }
        return PreviewBitmap(image: try #require(context.makeImage()))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private func encodedCost(_ bitmap: PreviewBitmap) async throws -> Int {
        let directory = root.appendingPathComponent("Probe")
        let cache = PreviewDiskCache(directory: directory)
        await cache.store(bitmap, for: request())
        let file = try #require(cacheFiles(in: directory).first)
        return try Data(contentsOf: file).count
    }

    private func cacheFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { $0.pathExtension == "preview" && (try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile) == true }
    }

    private func totalBytes(_ files: [URL]) throws -> Int {
        try files.reduce(0) { try $0 + Data(contentsOf: $1).count }
    }
}
