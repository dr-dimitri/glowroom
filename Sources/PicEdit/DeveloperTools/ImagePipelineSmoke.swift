#if PICEDIT_IMAGE_PIPELINE_SMOKE
import AppKit
import Foundation
import ImageIO

@main
struct ImagingSmoke {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("picedit-imaging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("oriented.jpg")
        let context = CGContext(data: nil, width: 1_200, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 800))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        require(CGImageDestinationFinalize(destination), "JPEG fixture creation failed")

        let date = Date()
        let request = PreviewRequest(url: url, modifiedAt: date, pixelSize: 320)
        let pipeline = ImagePreviewPipeline(diskCache: nil)
        let bitmap = try await pipeline.image(for: request)
        require(bitmap.image.height == 320, "Longest dimension was not bounded")
        require((212...214).contains(bitmap.image.width), "EXIF orientation was not applied")
        let cached = try await pipeline.image(for: request)
        require(bitmap.image === cached.image, "Identical requests must reuse cached CGImage")

        let batch = try await withThrowingTaskGroup(of: PreviewBitmap.self) { group in
            for _ in 0..<24 {
                group.addTask { try await pipeline.image(for: PreviewRequest(url: url, modifiedAt: date, pixelSize: 640)) }
            }
            var results: [PreviewBitmap] = []
            for try await result in group { results.append(result) }
            return results
        }
        require(batch.count == 24, "Not every subscriber completed")
        require(batch.allSatisfy { $0.image === batch[0].image }, "Concurrent identical requests were not deduplicated")
        require(batch[0].image.height == 640, "Larger preview used wrong pixel size")

        let changed = try await pipeline.image(for: PreviewRequest(url: url, modifiedAt: date.addingTimeInterval(1), pixelSize: 320))
        require(changed.image !== bitmap.image, "A changed original reused a stale cache entry")
        let uncachedPipeline = ImagePreviewPipeline(memoryLimit: 0, diskCache: nil)
        let uncachedA = try await uncachedPipeline.image(for: request)
        let uncachedB = try await uncachedPipeline.image(for: request)
        require(uncachedA.image !== uncachedB.image, "Cache exceeded its configured memory limit")

        let corrupt = directory.appendingPathComponent("corrupt.jpg")
        try Data([0, 1, 2, 3]).write(to: corrupt)
        for badURL in [directory.appendingPathComponent("missing.jpg"), corrupt] {
            do {
                _ = try await pipeline.image(for: PreviewRequest(url: badURL, modifiedAt: date, pixelSize: 320))
                preconditionFailure("Unreadable/corrupt input did not fail")
            } catch is PreviewFailure { }
        }

        var canceled = 0
        var tasks: [Task<PreviewBitmap, Error>] = []
        for offset in 0..<40 {
            let task = Task {
                try await pipeline.image(for: PreviewRequest(url: url, modifiedAt: date.addingTimeInterval(Double(offset + 100)), pixelSize: 2_400))
            }
            task.cancel()
            tasks.append(task)
        }
        for task in tasks {
            do { _ = try await task.value } catch is CancellationError { canceled += 1 }
        }
        require(canceled == 40, "Canceled image requests unexpectedly completed")
        _ = try await pipeline.image(for: request)
        print("PASS: bounded dimensions, EXIF orientation, deduplication, cache identity/invalidation/budget, corrupt/missing inputs, 40 cancellations, recovery")
    }
}

#endif
