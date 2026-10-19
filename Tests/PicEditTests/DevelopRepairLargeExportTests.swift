import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PicEditCore
import Testing
@testable import PicEdit

/// Opt-in native-sized work runs alone, rather than adding a 24 MP allocation
/// to the ordinary parallel test suite's many independent render fixtures.
@Suite("Native-sized repair export")
struct DevelopRepairLargeExportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PICEDIT_REPAIR_LARGE_EXPORT_TEST"] == "1"))
    func smallHealExportsTwentyFourMegapixelsWithinFourGiBAdmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Repair-Large-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png"), target = directory.appendingPathComponent("repaired.jpg")
        try autoreleasepool {
            let context = try #require(CGContext(data: nil, width: 6_000, height: 4_000, bitsPerComponent: 8,
                bytesPerRow: 6_000 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 6_000, height: 4_000))
            context.setFillColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1)
            context.fill(CGRect(x: 4_400, y: 1_900, width: 200, height: 200))
            let image = try #require(context.makeImage())
            let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        let digest = SHA256.hash(data: try Data(contentsOf: source))
        let point = try LocalMaskPoint(x: 0.75, y: 0.5)
        let stroke = try DevelopRetouchStroke(source: .init(x: 0.25, y: 0.5), target: point,
            radius: 0.05, feather: 0.2, path: [point])
        let result = try await JPEGExporter(memoryBudget: 4 * 1_024 * 1_024 * 1_024).export(.init(
            sourceURL: source, destinationURL: target,
            settings: .init(developGeometry: .init(retouchStrokes: [stroke])), options: .init(quality: 95)))
        #expect(result.width == 6_000 && result.height == 4_000)
        let decodedSource = try #require(CGImageSourceCreateWithURL(target as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(decodedSource, 0, nil))
        #expect(decoded.width == 6_000 && decoded.height == 4_000)
        let sample = try #require(decoded.cropping(to: CGRect(x: 4_500, y: 2_000, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress!, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        #expect(rgba.prefix(3).allSatisfy { (170...190).contains($0) }, "The red target must become the gray surrounding texture")
        #expect(rgba[3] == 255)
        #expect(SHA256.hash(data: try Data(contentsOf: source)) == digest)
    }
}
