import Foundation
import Testing
@testable import PicEditCore

struct MaskDocumentTests {
    @Test func versionedCanonicalRoundTripAndValidation() throws {
        let size = try ArtifactPixelSize(width: 31, height: 19)
        let stroke = try MaskStroke(points: [.init(x: 0, y: 0), .init(x: 31, y: 19)], radius: 2.5, hardness: 0.2)
        let document = try MaskDocument(canvasSize: size, strokes: [stroke])
        try document.validate()
        let encoded = try document.canonicalData()
        #expect(try JSONDecoder().decode(MaskDocument.self, from: encoded) == document)
        #expect(try document.canonicalData() == encoded)
        let invalid = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        #expect(throws: ArtifactContractError.unsupportedVersion(2)) {
            _ = try JSONDecoder().decode(MaskDocument.self, from: Data(invalid.utf8))
        }
        #expect(throws: ArtifactContractError.self) { _ = try MaskPoint(x: .infinity, y: 0) }
        #expect(throws: ArtifactContractError.self) { _ = try MaskStroke(points: [], radius: 1) }
        #expect(throws: ArtifactContractError.self) { _ = try MaskStroke(points: [.init(x: 1, y: 1)], radius: 0) }
        #expect(throws: ArtifactContractError.self) { _ = try MaskStroke(points: [.init(x: 1, y: 1)], radius: 1, hardness: 1.1) }
        #expect(throws: ArtifactContractError.self) {
            _ = try MaskDocument(canvasSize: size, strokes: [.init(points: [.init(x: 32, y: 1)], radius: 1)])
        }
    }

    @Test func limitsRejectOversizedStrokeAndDocument() throws {
        let point = try MaskPoint(x: 1, y: 1)
        #expect(throws: ArtifactContractError.self) {
            _ = try MaskStroke(points: Array(repeating: point, count: MaskStroke.maximumPoints + 1), radius: 1)
        }
        let stroke = try MaskStroke(points: Array(repeating: point, count: MaskStroke.maximumPoints), radius: 1)
        let size = try ArtifactPixelSize(width: 10, height: 10)
        #expect(throws: ArtifactContractError.self) { _ = try MaskDocument(canvasSize: size, strokes: [stroke, stroke, stroke]) }
        let bounded = try MaskDocument(canvasSize: size, strokes: [stroke, stroke])
        #expect(try bounded.canonicalData().count <= MaskDocument.maximumEncodedBytes)
    }

    @Test func inversionIsExactAndSubsequentBrushKeepsMeaning() throws {
        let size = try ArtifactPixelSize(width: 9, height: 5)
        let stroke = try MaskStroke(points: [.init(x: 2.5, y: 2.5)], radius: 2, hardness: 0.25)
        let document = try MaskDocument(canvasSize: size, strokes: [stroke])
        let original = try MaskRasterizer.rasterize(document)
        let inverted = try MaskRasterizer.rasterize(document.inverted())
        #expect(zip(original.bytes, inverted.bytes).allSatisfy { Int($0) + Int($1) == 255 })
        #expect(document.inverted().inverted() == document)
        let paint = try MaskStroke(points: [.init(x: 2.5, y: 2.5)], radius: 1)
        let painted = try MaskRasterizer.rasterize(document.inverted().appending(paint))
        #expect(painted.bytes[2 * size.width + 2] == 255)
        let erased = try MaskRasterizer.rasterize(document.inverted().appending(.init(points: [.init(x: 8.5, y: 2.5)], radius: 1, mode: .erase)))
        #expect(erased.bytes[2 * size.width + 8] == 0)
        #expect(document.cleared().strokes.isEmpty)
        #expect(!document.cleared().isInverted)
    }
}
