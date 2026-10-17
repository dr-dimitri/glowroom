import Foundation
import Testing
@testable import PicEditCore

struct MaskRasterizerTests {
    @Test func emptyFullAndEdgeCrossingMasks() throws {
        let size = try ArtifactPixelSize(width: 12, height: 8)
        let empty = try MaskDocument(canvasSize: size)
        #expect(try MaskRasterizer.rasterize(empty).bytes.allSatisfy { $0 == 0 })
        #expect(try MaskRasterizer.rasterize(empty.inverted()).bytes.allSatisfy { $0 == 255 })
        let edge = try empty.appending(.init(points: [.init(x: 0, y: 0), .init(x: 12, y: 8)], radius: 2))
        let raster = try MaskRasterizer.rasterize(edge)
        #expect(raster.bytes.count == size.width * size.height)
        #expect(raster.bytes[0] == 255)
        #expect(raster.bytes[raster.bytes.count - 1] == 255)
        #expect(raster.bytes[11] == 0)
    }

    @Test func narrowCapsulesConnectPointsAndOrderedEraseIsDeterministic() throws {
        let size = try ArtifactPixelSize(width: 11, height: 5)
        let line = try MaskStroke(points: [.init(x: 0, y: 2.5), .init(x: 11, y: 2.5)], radius: 0.49)
        let base = try MaskDocument(canvasSize: size, strokes: [line])
        let native = try MaskRasterizer.rasterize(base)
        #expect((0..<size.width).allSatisfy { native.bytes[2 * size.width + $0] == 255 })
        #expect((0..<size.width).allSatisfy { native.bytes[size.width + $0] == 0 })
        let erase = try MaskStroke(points: [.init(x: 5.5, y: 2.5)], radius: 1.1, mode: .erase)
        let document = try base.appending(erase)
        let first = try MaskRasterizer.rasterize(document)
        #expect(first.bytes[2 * size.width + 5] == 0)
        #expect(first.bytes[2 * size.width + 2] == 255)
        #expect(try MaskRasterizer.rasterize(document) == first)
        let repainted = try document.appending(.init(points: [.init(x: 5.5, y: 2.5)], radius: 0.4))
        #expect(try MaskRasterizer.rasterize(repainted).bytes[2 * size.width + 5] == 255)
    }

    @Test func hardnessControlsLinearFeatherWithoutAccumulatingOverlappingSegments() throws {
        let size = try ArtifactPixelSize(width: 11, height: 3)
        let center = try MaskPoint(x: 5.5, y: 1.5)
        let stroke = try MaskStroke(points: [center, center, center], radius: 4, hardness: 0.5)
        let raster = try MaskRasterizer.rasterize(.init(canvasSize: size, strokes: [stroke]))
        #expect(raster.bytes[16] == 255)
        #expect(raster.bytes[18] == 255)
        #expect(raster.bytes[19] == 128)
        #expect(raster.bytes[20] == 0)
        let single = try MaskRasterizer.rasterize(.init(canvasSize: size, strokes: [.init(points: [center], radius: 4, hardness: 0.5)]))
        #expect(single == raster)
    }

    @Test func nativeCropAndModelCoordinatesUsePixelCenters() throws {
        let nativeSize = try ArtifactPixelSize(width: 8, height: 6)
        let document = try MaskDocument(canvasSize: nativeSize, strokes: [.init(points: [.init(x: 4, y: 3)], radius: 2.2, hardness: 0.1)])
        let native = try MaskRasterizer.rasterize(document)
        let crop = try ArtifactPixelRect(x: 2, y: 1, size: .init(width: 4, height: 4))
        let cropped = try MaskRasterizer.rasterize(document, crop: crop)
        for y in 0..<4 {
            #expect(Array(cropped.bytes[(y * 4)..<(y * 4 + 4)]) == Array(native.bytes[((y + 1) * 8 + 2)..<((y + 1) * 8 + 6)]))
        }
        let model = try MaskRasterizer.rasterize(document, outputSize: .init(width: 2, height: 2), crop: crop)
        // The four model centers map to native (3,2), (5,2), (3,4), (5,4).
        #expect(Set(model.bytes).count == 1)
        #expect(model.bytes[0] > 0)
        #expect(throws: ArtifactContractError.self) {
            _ = try MaskRasterizer.rasterize(document, crop: .init(x: 7, y: 0, size: .init(width: 2, height: 2)))
        }
        let negative = try JSONDecoder().decode(ArtifactPixelRect.self, from: Data("{\"x\":-1,\"y\":0,\"size\":{\"width\":2,\"height\":2}}".utf8))
        #expect(throws: ArtifactContractError.self) { _ = try MaskRasterizer.rasterize(document, crop: negative) }
    }

    @Test func resamplingCoordinateGridCropsAndConstantEdges() throws {
        let grid = try MaskRaster(size: .init(width: 4, height: 4), bytes: Data((0..<16).map { UInt8($0 * 16) }))
        let reduced = try grid.resampled(to: .init(width: 2, height: 2))
        #expect(Array(reduced.bytes) == [40, 72, 168, 200])
        let crop = try ArtifactPixelRect(x: 1, y: 1, size: .init(width: 2, height: 2))
        let cropped = try grid.resampled(to: crop.size, crop: crop)
        #expect(Array(cropped.bytes) == [80, 96, 144, 160])
        #expect(try grid.resampled(to: grid.size) == grid)
        let sliced = Data([255, 1, 2, 3, 4])[1...]
        #expect(try MaskRaster(size: .init(width: 2, height: 2), bytes: sliced).bytes[0] == 1)
        let constant = try MaskRaster(size: .init(width: 1, height: 1), bytes: Data([123]))
        #expect(try constant.resampled(to: .init(width: 19, height: 7)).bytes.allSatisfy { $0 == 123 })
        #expect(throws: ArtifactContractError.self) { _ = try MaskRaster(size: grid.size, bytes: Data([1])) }
    }

    @Test func rasterHashSeparatesDimensionsAndCoverage() throws {
        let a = try MaskRaster(size: .init(width: 4, height: 1), bytes: Data([0, 1, 2, 3]))
        let b = try MaskRaster(size: .init(width: 2, height: 2), bytes: a.bytes)
        #expect(try a.canonicalSHA256() == a.canonicalSHA256())
        #expect(try a.canonicalSHA256() != b.canonicalSHA256())
        #expect(try a.canonicalSHA256() != MaskRaster(size: a.size, bytes: Data([0, 1, 2, 4])).canonicalSHA256())
    }

    @Test func cancellationAndWorkBudgetsStopLargeRasterization() async throws {
        let size = try ArtifactPixelSize(width: 4_096, height: 4_096)
        let document = try MaskDocument(canvasSize: size, strokes: [.init(points: [.init(x: 2_048, y: 2_048)], radius: 4_096)])
        #expect(throws: CancellationError.self) { _ = try MaskRasterizer.rasterize(document, cancellation: { throw CancellationError() }) }
        #expect(throws: ArtifactContractError.limitExceeded) { _ = try MaskRasterizer.rasterize(document, maximumSampleEvaluations: 100) }
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MaskRasterizer.rasterize(document)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(throws: ArtifactContractError.limitExceeded) { _ = try ArtifactPixelSize(width: 4_097, height: 4_096) }
    }
}
