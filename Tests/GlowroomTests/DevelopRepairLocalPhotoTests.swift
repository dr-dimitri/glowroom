import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import GlowroomCore
import ImageIO
import Testing
@testable import Glowroom

/// Explicit, reproducible photo diagnostic with known clean reference pixels.
/// Local photographs and all derived crops remain outside version control.
@Suite("Repair on local photographs with injected defects", .serialized)
struct DevelopRepairLocalPhotoTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_REPAIR_FIXTURES"] != nil))
    func comparePreviousAndLocalHealingOnWallSkyAndWater() throws {
        let env = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(env["GLOWROOM_REPAIR_FIXTURES"]), isDirectory: true)
        let output = URL(fileURLWithPath: try #require(env["GLOWROOM_REPAIR_FIXTURES_OUTPUT"]), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let allowed = output.path.hasPrefix("/private/tmp/") || output.path.hasPrefix(temporary + "/")
        try #require(allowed, "Photo derivatives must stay in temporary storage")
        try #require(!FileManager.default.fileExists(atPath: output.path), "Use a new output directory")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let cases: [(String, String, Double, Double, Double, Double)] = [
            ("wall", "test_picture1.jpg", 0.48, 0.08, 0.34, 0.30),
            ("sky", "test_picture2.jpg", 0.35, 0.04, 0.26, 0.65),
            ("water", "test_picture5.jpg", 0.68, 0.60, 0.85, 0.79)
        ]
        let context = EditRenderer.maskCompositingContext()
        var reports: [[String: Any]] = []
        for (name, filename, x, y0, y1, sourceX) in cases {
            let url = directory.appendingPathComponent(filename)
            let originalData = try Data(contentsOf: url), hash = SHA256.hash(data: originalData)
            let source = try #require(CGImageSourceCreateWithData(originalData as CFData, nil))
            let original = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_024
            ] as CFDictionary))
            let width = original.width, height = original.height
            let clean = try pixels(original)
            let radius = 0.024, pixelRadius = radius * Double(min(width, height))
            var damaged = clean, measured: [Int] = []
            // Put a narrow red scratch completely inside the fully covered core.
            for row in 0..<height { for col in 0..<width {
                let xx = Double(col) + 0.5 - x * Double(width)
                let yy = Double(row) + 0.5
                let dy = max(y0 * Double(height) - yy, max(0, yy - y1 * Double(height)))
                if hypot(xx, dy) < pixelRadius * 0.35 {
                    let i = (row * width + col) * 4
                    damaged[i] = 210; damaged[i + 1] = 15; damaged[i + 2] = 30
                    measured.append(i)
                }
            } }
            let input = try bitmap(damaged, width: width, height: height)
            let target = try LocalMaskPoint(x: x, y: y0)
            let path = try [target, LocalMaskPoint(x: x, y: y1)]
            let auto = try DevelopRepairPixels(PreviewBitmap(image: input)).source(path: path, radius: radius, mask: nil)
            let choices = [("manual", try LocalMaskPoint(x: sourceX, y: y0)), ("auto", auto)]
            let crop = CGRect(x: x * Double(width) - 3 * pixelRadius, y: y0 * Double(height) - 3 * pixelRadius,
                width: 6 * pixelRadius, height: (y1 - y0) * Double(height) + 6 * pixelRadius)
                .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            try png(try #require(original.cropping(to: crop)), output.appendingPathComponent(name + "-clean.png"))
            try png(try #require(input.cropping(to: crop)), output.appendingPathComponent(name + "-damaged.png"))
            for (choice, donor) in choices {
                let stroke = try DevelopRetouchStroke(source: donor, target: target, radius: radius, feather: 0.25, path: path)
                // Compare against the immediately preceding local ring-delta
                // algorithm, rather than the older single global correction.
                let previous = try DevelopGeometryRendererTests().ringHealingReference(input, stroke: stroke)
                let extent = CGRect(x: 0, y: 0, width: width, height: height)
                let graph = try DevelopGeometryRenderer.apply(to: CIImage(cgImage: input),
                    geometry: .init(retouchStrokes: [stroke]), extent: extent)
                let current = try #require(context.createCGImage(graph, from: extent,
                    format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, deferred: false))
                let before = try pixels(previous), after = try pixels(current)
                func error(_ actual: [UInt8]) -> Double {
                    measured.reduce(0.0) { result, i in
                        result + (0..<3).reduce(0.0) { $0 + Double(abs(Int(actual[i + $1]) - Int(clean[i + $1]))) }
                    } / Double(measured.count * 3)
                }
                let coverage = try DevelopRetouchMaskRenderer.coverage(for: stroke, extent: extent)
                let mask = try #require(context.createCGImage(coverage, from: extent, format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, deferred: false))
                let maskBytes = try pixels(mask)
                var changedOutside = 0
                for i in stride(from: 0, to: after.count, by: 4) where maskBytes[i] == 0 {
                    if (0..<4).contains(where: { abs(Int(after[i + $0]) - Int(damaged[i + $0])) > 1 }) { changedOutside += 1 }
                }
                #expect(changedOutside == 0)
                #expect(error(after) < error(damaged), "Repair must reduce the injected defect: \(name), \(choice)")
                try png(try #require(previous.cropping(to: crop)), output.appendingPathComponent(name + "-" + choice + "-previous.png"))
                try png(try #require(current.cropping(to: crop)), output.appendingPathComponent(name + "-" + choice + "-current.png"))
                reports.append(["case": name, "source": choice, "donorX": donor.x, "donorY": donor.y,
                    "inputSHA256": hash.map { String(format: "%02x", $0) }.joined(),
                    "width": width, "height": height, "targetX": x, "targetY": y0, "endY": y1,
                    "radius": radius, "feather": stroke.feather,
                    "damagedMAE8": error(damaged), "previousMAE8": error(before), "currentMAE8": error(after),
                    "changedOutside": changedOutside])
            }
            #expect(SHA256.hash(data: try Data(contentsOf: url)) == hash)
        }
        let report = try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
        try report.write(to: output.appendingPathComponent("report.json"))
        print("Local photo healing report: \(output.path)")
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
            count: image.width * image.height * 4))
    }

    private func bitmap(_ bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func png(_ image: CGImage, _ url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }
}
