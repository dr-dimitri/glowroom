import CoreGraphics
import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Develop crop and manual correction rendering")
struct DevelopGeometryRendererTests {
    @Test func straighteningUsesTheSameIntegerCanvasForRenderingAndExport() throws {
        let source = try fixture(width: 100, height: 50) { _, _ in (140, 90, 40, 255) }
        for angle in [-30.0, 30] {
            for constrained in [true, false] {
                for turns in 0...3 {
                    let geometry = DevelopGeometry(quarterTurns: turns, straightenAngle: angle, constrainToImage: constrained)
                    let size = try DevelopGeometryRenderer.outputSize(width: 100, height: 50, geometry: geometry)
                    let expected = constrained ? (53, 26) : (112, 94)
                    #expect(size.width == (turns.isMultiple(of: 2) ? expected.0 : expected.1))
                    #expect(size.height == (turns.isMultiple(of: 2) ? expected.1 : expected.0))
                    let image = try DevelopGeometryRenderer.apply(to: CIImage(cgImage: source), geometry: geometry,
                        extent: CGRect(x: 0, y: 0, width: 100, height: 50))
                    #expect(image.extent == CGRect(x: 0, y: 0, width: size.width, height: size.height))
                    let output = try render(source, geometry: geometry)
                    #expect(output.width == size.width && output.height == size.height)
                    let bytes = try pixels(output)
                    if constrained {
                        #expect(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 })
                    } else {
                        #expect(pixel(bytes, width: size.width, x: 0, y: 0)[3] == 0)
                        #expect(pixel(bytes, width: size.width, x: size.width / 2, y: size.height / 2)[3] == 255)
                    }
                }
            }
        }
    }

    @Test func straighteningFollowsTheSelectedCropAndKeepsSourceAlpha() throws {
        let source = try fixture(width: 120, height: 80) { x, _ in x < 60 ? (220, 40, 30, 160) : (20, 180, 80, 160) }
        let crop = try DevelopCropRect(x: 0, y: 0.25, width: 0.5, height: 0.5)
        for constrained in [true, false] {
            let geometry = DevelopGeometry(crop: crop, straightenAngle: 30, constrainToImage: constrained)
            let image = try render(source, geometry: geometry)
            let bytes = try pixels(image)
            let center = pixel(bytes, width: image.width, x: image.width / 2, y: image.height / 2)
            #expect(abs(center[3] - 160) <= 1)
            #expect(center[0] > center[1] * 3, "Straightening must rotate the crop, rather than sample its discarded neighbor")
        }
        let tiny = try fixture(width: 1, height: 20) { _, _ in (140, 90, 40, 255) }
        let tinyResult = try render(tiny, geometry: .init(straightenAngle: 45))
        #expect(tinyResult.width >= 1 && tinyResult.height >= 1)
        #expect(try pixels(tinyResult)[3] == 255)
    }

    @Test func cropAndClockwiseTurnsKeepSourceCoordinatesAndPixelEdges() throws {
        let source = try fixture(width: 12, height: 8) { x, y in (UInt8(x * 15), UInt8(y * 25), 40, 255) }
        let crop = try DevelopCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let plain = try render(source, geometry: .init(crop: crop))
        #expect(plain.width == 6 && plain.height == 4)
        let original = try pixels(source), cropped = try pixels(plain)
        #expect(pixel(cropped, width: 6, x: 0, y: 0) == pixel(original, width: 12, x: 3, y: 2))
        for turns in 0...3 {
            let geometry = DevelopGeometry(crop: crop, quarterTurns: turns)
            let result = try render(source, geometry: geometry)
            let size = try DevelopGeometryRenderer.outputSize(width: 12, height: 8, geometry: geometry)
            #expect(result.width == size.width && result.height == size.height)
            let resultPixels = try pixels(result)
            // Top-left source coordinate (3,2) follows each clockwise rotation.
            let corner: (Int, Int) = switch turns {
            case 0: (0, 0)
            case 1: (3, 0)
            case 2: (5, 3)
            default: (0, 5)
            }
            #expect(pixel(resultPixels, width: size.width, x: corner.0, y: corner.1) == pixel(cropped, width: 6, x: 0, y: 0))
        }
        let decimal = try DevelopCropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let size = try DevelopGeometryRenderer.outputSize(width: 100, height: 100, geometry: .init(crop: decimal))
        #expect(size.width == 40 && size.height == 40)
    }

    @Test func mirrorsActInsideCropWithoutChangingAlpha() throws {
        let source = try fixture(width: 16, height: 8) { x, y in (UInt8(x * 10), UInt8(y * 15), 30, UInt8(100 + x * 5)) }
        let original = try pixels(source)
        for horizontal in [false, true] {
            for vertical in [false, true] {
                let result = try pixels(render(source, geometry: .init(flipHorizontal: horizontal, flipVertical: vertical)))
                for (x, y) in [(0, 0), (7, 3), (15, 7)] {
                    let expected = pixel(original, width: 16, x: horizontal ? 15 - x : x, y: vertical ? 7 - y : y)
                    #expect(pixel(result, width: 16, x: x, y: y) == expected)
                }
            }
        }
    }

    @Test func cloneCopiesChosenSourceAndDoesNotTouchOutsideThePatch() throws {
        let source = try fixture { x, y in
            x < 64 ? (20, UInt8(80 + y), 170, 255) : (190, 50, 30, 255)
        }
        let patch = try DevelopRetouchStroke(mode: .clone, source: .init(x: 0.25, y: 0.25),
            target: .init(x: 0.75, y: 0.75), radius: 0.1, feather: 0.25)
        let result = try pixels(render(source, geometry: .init(retouchStrokes: [patch])))
        let original = try pixels(source)
        let actual = pixel(result, width: 128, x: 96, y: 72)
        let expected = pixel(original, width: 128, x: 32, y: 24)
        #expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= 1 })
        #expect(pixel(result, width: 128, x: 96, y: 24) == pixel(original, width: 128, x: 96, y: 24))
        #expect(pixel(result, width: 128, x: 32, y: 24) == pixel(original, width: 128, x: 32, y: 24))
    }

    @Test func healMatchesTargetColorWhileCloneRetainsTheSourceColor() throws {
        let source = try fixture { x, y in
            let value: UInt8 = x < 64 ? (((x + y) % 2 == 0) ? 60 : 80) : ((abs(x - 96) < 3 && abs(y - 48) < 3) ? 220 : 150)
            return (value, value, value, 255)
        }
        var outputs: [DevelopRetouchMode: Int] = [:]
        for mode in [DevelopRetouchMode.clone, .heal] {
            let patch = try DevelopRetouchStroke(mode: mode, source: .init(x: 0.25, y: 0.5),
                target: .init(x: 0.75, y: 0.5), radius: 0.12, feather: 0.5)
            let result = try pixels(render(source, geometry: .init(retouchStrokes: [patch])))
            outputs[mode] = pixel(result, width: 128, x: 96, y: 48)[0]
        }
        #expect(try #require(outputs[.clone]) < 100)
        #expect((130...190).contains(try #require(outputs[.heal])))
    }

    @Test func aWholePathKeepsOneSourceOffsetAndDoesNotPaintBetweenSeparateGestures() throws {
        let source = try fixture { x, y in x < 64 ? (20, UInt8(40 + y), 160, 255) : (190, 30, 20, 255) }
        let target = try LocalMaskPoint(x: 0.75, y: 0.15)
        let stroke = try DevelopRetouchStroke(mode: .clone, source: .init(x: 0.25, y: 0.15),
            target: target, radius: 0.05, feather: 0.4, path: [.init(x: 0.75, y: 0.4)])
        let result = try pixels(render(source, geometry: .init(retouchStrokes: [stroke])))
        let original = try pixels(source)
        for y in [18, 26, 34] {
            let expected = pixel(original, width: 128, x: 32, y: y)
            #expect(zip(pixel(result, width: 128, x: 96, y: y), expected).allSatisfy { abs($0 - $1) <= 1 })
        }
        #expect(pixel(result, width: 128, x: 96, y: 70) == pixel(original, width: 128, x: 96, y: 70))
        #expect(pixel(result, width: 128, x: 80, y: 48) == pixel(original, width: 128, x: 80, y: 48))
    }

    @Test func aFrozenMaskUsesGlobalTopLeftCoordinatesAndTakesPrecedenceOverPath() throws {
        let source = try fixture { x, y in x < 64 ? (20, UInt8(40 + y), 160, 255) : (190, 30, 20, 255) }
        var coverage = Data(count: 32 * 24)
        for y in [4, 5, 6, 16, 17, 18] { for x in 24...27 { coverage[y * 32 + x] = 255 } }
        let mask = try LocalMaskRaster(width: 32, height: 24, bytes: coverage)
        let stroke = try DevelopRetouchStroke(mode: .clone, source: .init(x: 0.25, y: 0.25),
            target: .init(x: 0.75, y: 0.25), radius: 0.01, path: [.init(x: 0.5, y: 0.5)], mask: mask)
        let result = try pixels(render(source, geometry: .init(retouchStrokes: [stroke])))
        let original = try pixels(source)
        for y in [22, 70] {
            #expect(zip(pixel(result, width: 128, x: 104, y: y), pixel(original, width: 128, x: 40, y: y))
                .allSatisfy { abs($0 - $1) <= 1 })
        }
        for (x, y) in [(104, 48), (104, 86), (64, 48), (90, 22)] {
            #expect(pixel(result, width: 128, x: x, y: y) == pixel(original, width: 128, x: x, y: y))
        }
    }

    @Test func pathHealingMatchesCleanSurroundingsWithoutAveragingTheObject() throws {
        let source = try fixture { x, y in
            let value: UInt8 = x < 64 ? ((x + y).isMultiple(of: 2) ? 60 : 80)
                : (hypot(Double(x - 96), Double(y - 48)) < 9 ? 240 : 150)
            return (value, value, value, 255)
        }
        let target = try LocalMaskPoint(x: 0.75, y: 0.5)
        let stroke = try DevelopRetouchStroke(source: .init(x: 0.25, y: 0.5), target: target,
            radius: 0.12, feather: 0.2, path: [target])
        let result = try pixels(render(source, geometry: .init(retouchStrokes: [stroke])))
        #expect((135...165).contains(pixel(result, width: 128, x: 96, y: 48)[0]))
        let original = try pixels(source)
        #expect(pixel(result, width: 128, x: 96, y: 72) == pixel(original, width: 128, x: 96, y: 72))
    }

    @Test func boundedHealingMatchesFullFrameLocalCorrectionAtMaskEdgesAndFeatheredPaths() throws {
        let source = try fixture { x, y in
            (UInt8((x * 3 + y) % 220), UInt8((y * 2 + x) % 200), UInt8((x + y * 3) % 230),
             [UInt8](arrayLiteral: 0, 32, 128, 255)[(x / 7 + y / 9) % 4])
        }
        let target = try LocalMaskPoint(x: 0.75, y: 0.25)
        var strokes = [DevelopRetouchStroke]()
        // Small active regions at opposite image corners exercise the source
        // mask-cell interpolation footprint and morphology clipped by the image.
        for (x, y) in [(0, 0), (15, 11), (9, 5)] {
            var cells = Data(count: 16 * 12)
            cells[y * 16 + x] = 128
            cells[max(0, y - 1) * 16 + x] = 255
            strokes.append(try .init(source: .init(x: 0.25, y: 0.25), target: target,
                radius: 0.025, feather: 0.8, opacity: 0.7, mask: .init(width: 16, height: 12, bytes: cells)))
        }
        strokes.append(try .init(source: .init(x: 0.25, y: 0.25), target: target,
            radius: 0.035, feather: 1, opacity: 0.6, path: [.init(x: 0.9, y: 0.04), .init(x: 1, y: 0)]))
        strokes.append(try .init(source: target, target: target, radius: 0.05,
            mask: .init(width: 16, height: 12, bytes: Data(count: 192))))
        for (caseIndex, stroke) in strokes.enumerated() {
            let actual = try pixels(render(source, geometry: .init(retouchStrokes: [stroke])))
            let expected = try pixels(fullFrameHealingReference(source, stroke: stroke))
            let differences = zip(actual, expected).map { abs($0 - $1) }
            let maximum = differences.max() ?? 0
            let mismatch = differences.firstIndex(of: maximum) ?? 0
            #expect(maximum <= 1, "Ring case \(caseIndex): maximum delta \(maximum) at x\((mismatch / 4) % 128),y\(mismatch / 4 / 128),channel\(mismatch % 4); actual \(actual[mismatch]), expected \(expected[mismatch])")
            let original = try pixels(source)
            #expect(stride(from: 3, to: actual.count, by: 4).allSatisfy { actual[$0] == original[$0] })
            let context = try #require(DevelopRetouchMaskRenderer.healingContextBounds(for: stroke,
                extent: CGRect(x: 0, y: 0, width: 128, height: 96)))
            #expect(context.isNull || context.width * context.height < 128 * 96 / 2)
        }
    }

    @Test func boundedHealingIncludesTheCappedPathRasterReconstructionFootprint() throws {
        let source = try fixture(width: 2_200, height: 96) { x, y in
            (UInt8((x + y) % 200), UInt8((x / 11 + y) % 210), 90, UInt8(64 + y % 4 * 48))
        }
        let stroke = try DevelopRetouchStroke(source: .init(x: 0.1, y: 0.3), target: .init(x: 0.75, y: 0.3),
            radius: 0.08, feather: 0.9, path: [.init(x: 0.85, y: 0.05)])
        let actual = try pixels(render(source, geometry: .init(retouchStrokes: [stroke])))
        let expected = try pixels(fullFrameHealingReference(source, stroke: stroke))
        #expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= 1 })
    }

    @Test func smallTranslucentRepairsMatchTheirSurroundingsWithoutAFullFrameWeightCutoff() throws {
        let target = try LocalMaskPoint(x: 0.75, y: 0.5)
        var cells = Data(count: 256 * 256); cells[128 * 256 + 192] = 255
        let stroke = try DevelopRetouchStroke(source: .init(x: 0.25, y: 0.5), target: target, radius: 0.000_001,
            mask: .init(width: 256, height: 256, bytes: cells))
        for alpha: UInt8 in [4, 64] {
            let source = try fixture(width: 512, height: 512) { x, _ in
                let gray: UInt8 = x < 256 ? 64 : 192
                return (gray, gray, gray, alpha)
            }
            let actual = try pixels(render(source, geometry: .init(retouchStrokes: [stroke])))
            let expected = try pixels(fullFrameHealingReference(source, stroke: stroke))
            #expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= 1 })
            let original = try pixels(source)
            #expect(zip(pixel(actual, width: 512, x: 385, y: 257),
                        pixel(original, width: 512, x: 385, y: 257)).allSatisfy { abs($0 - $1) <= 1 },
                    "A clean translucent target must not inherit the darker donor tone")
        }
    }

    @Test func crossingPathsApplyOpacityOnceAndPreserveTargetAlpha() throws {
        let source = try fixture { x, _ in x < 64 ? (240, 120, 40, 255) : (40, 90, 140, 128) }
        let target = try LocalMaskPoint(x: 0.75, y: 0.5)
        let simple = try DevelopRetouchStroke(mode: .clone, source: .init(x: 0.25, y: 0.5), target: target,
            radius: 0.06, feather: 0.3, opacity: 0.5, path: [target])
        let crossing = try DevelopRetouchStroke(mode: .clone, source: simple.source, target: target,
            radius: simple.radius, feather: simple.feather, opacity: simple.opacity,
            path: [.init(x: 0.65, y: 0.3), .init(x: 0.85, y: 0.7), target])
        let first = try pixels(render(source, geometry: .init(retouchStrokes: [simple])))
        let second = try pixels(render(source, geometry: .init(retouchStrokes: [crossing])))
        #expect(pixel(first, width: 128, x: 96, y: 48) == pixel(second, width: 128, x: 96, y: 48))
        #expect(pixel(second, width: 128, x: 96, y: 48)[3] == 128)
        let original = try pixels(source)
        #expect(pixel(second, width: 128, x: 120, y: 80) == pixel(original, width: 128, x: 120, y: 80))
    }

    @Test func gestureAdmissionCountsOneGraphAndItsBoundedRasterInsteadOfOneGraphPerPoint() throws {
        let point = try LocalMaskPoint(x: 0.5, y: 0.5)
        let simple = try DevelopRetouchStroke(source: .init(x: 0.25, y: 0.5), target: point,
            radius: 0.05, path: [point])
        let long = try DevelopRetouchStroke(source: simple.source, target: point, radius: simple.radius,
            path: [LocalMaskPoint](repeating: point, count: DevelopRetouchStroke.maximumPathPoints))
        let smallBytes = try #require(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: .init(retouchStrokes: [simple]), width: 128, height: 96))
        let longBytes = try #require(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: .init(retouchStrokes: [long]), width: 128, height: 96))
        #expect(smallBytes > 128 * 96 * 51 + 128)
        #expect(smallBytes < 128 * 96 * 147 + 128)
        #expect(longBytes - smallBytes == UInt64(long.path.count - simple.path.count) * 64)
        let mask = try LocalMaskRaster(width: 16, height: 12, bytes: Data(repeating: 255, count: 192))
        let masked = try DevelopRetouchStroke(mode: .clone, source: simple.source, target: point, radius: simple.radius, mask: mask)
        #expect(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: .init(retouchStrokes: [masked]), width: 128, height: 96) == 128 * 96 * 48 + 192 * 3)
        let size = try #require(DevelopRetouchMaskRenderer.rasterSize(width: 12_000, height: 8_000))
        #expect(size.width == 2_048 && size.height == 1_365)
    }

    @Test func frozenReplacementKeepsNativeCanvasPositionSourceAlphaAndPixelsOutsideMask() throws {
        let source = try fixture { _, _ in (40, 90, 140, 128) }
        let bounds = try DevelopCropRect(x: 0.5, y: 0.25, width: 0.25, height: 0.5)
        let replacement = try DevelopRetouchReplacement(bounds: bounds, width: 2, height: 2,
            rgba: Data([220, 40, 20, 255, 220, 40, 20, 255, 20, 200, 60, 255, 20, 200, 60, 255]))
        var mask = Data(count: 32 * 24)
        for y in 0..<24 { for x in 16..<20 { mask[y * 32 + x] = 255 } }
        let stroke = try DevelopRetouchStroke(source: .init(x: 0.1, y: 0.1), target: .init(x: 0.9, y: 0.9),
            radius: 0.01, mask: .init(width: 32, height: 24, bytes: mask), replacement: replacement)
        let rendered = try render(source, geometry: .init(retouchStrokes: [stroke]))
        #expect(rendered.width == 128 && rendered.height == 96)
        let result = try pixels(rendered), original = try pixels(source)
        let top = pixel(result, width: 128, x: 72, y: 28)
        let bottom = pixel(result, width: 128, x: 72, y: 68)
        #expect(top[0] > 100, "Top-left ROI pixel: \(top)")
        #expect(top[1] < 35 && top[3] == 128)
        #expect(bottom[1] > 90, "Bottom-left ROI pixel: \(bottom)")
        #expect(bottom[0] < 25 && bottom[3] == 128)
        // The stored source/target offset is irrelevant to frozen model pixels.
        // The mask extends beyond the ROI; those rows still preserve the source.
        for (x, y) in [(72, 10), (72, 85), (88, 48), (112, 80)] {
            #expect(pixel(result, width: 128, x: x, y: y) == pixel(original, width: 128, x: x, y: y))
        }
        let budget = try #require(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: .init(retouchStrokes: [stroke]), width: 128, height: 96))
        #expect(budget == 128 * 96 * 48 + 32 * 24 * 3 + 16 * 6)
        let doubled = try fixture(width: 256, height: 192) { _, _ in (40, 90, 140, 128) }
        let export = try render(doubled, geometry: .init(retouchStrokes: [stroke]))
        #expect(export.width == 256 && export.height == 192)
        let exportPixels = try pixels(export)
        #expect(pixel(exportPixels, width: 256, x: 144, y: 56)[0] > 100)
        #expect(pixel(exportPixels, width: 256, x: 144, y: 136)[1] > 90)
    }

    @Test(arguments: [0.25, -0.25])
    func movingFullFrameModelContextPreservesPixelsAcrossImageEdgesAndBack(delta: Double) throws {
        let source = try fixture { _, _ in (40, 90, 140, 173) }
        var modelPixels = Data()
        for row in 0..<3 { for column in 0..<3 {
            modelPixels.append(contentsOf: [UInt8(20 + column * 90), UInt8(30 + row * 80),
                UInt8((row + column).isMultiple(of: 2) ? 220 : 20), 255])
        } }
        let replacement = try DevelopRetouchReplacement(bounds: .init(x: 0, y: 0, width: 1, height: 1),
            width: 3, height: 3, rgba: modelPixels)
        var coverage = Data(count: 32 * 24)
        for row in 9..<12 { for column in 12..<16 { coverage[row * 32 + column] = 255 } }
        let target = try LocalMaskPoint(x: 0.4375, y: 0.4375)
        let stroke = try DevelopRetouchStroke(source: target, target: target, radius: 0.01,
            mask: .init(width: 32, height: 24, bytes: coverage), replacement: replacement)
        let original = try pixels(render(source, geometry: .init(retouchStrokes: [stroke])))
        let moved = try DevelopRepairEditing.moved(stroke, handle: .target,
            translation: CGSize(width: delta, height: delta))
        let patch = try #require(moved.replacement)
        #expect(patch.bounds == replacement.bounds && patch.rgba == replacement.rgba)
        #expect(patch.offsetX == delta && patch.offsetY == delta)
        let shiftedBounds = DevelopRetouchMaskRenderer.replacementBounds(patch,
            extent: CGRect(x: 0, y: 0, width: 128, height: 96))
        #expect(!CGRect(x: 0, y: 0, width: 128, height: 96).contains(shiftedBounds))
        let movedImage = try render(source, geometry: .init(retouchStrokes: [moved]))
        #expect(movedImage.width == 128 && movedImage.height == 96)
        let shifted = try pixels(movedImage), unchanged = try pixels(source)
        let dx = Int(delta * 128), dy = Int(delta * 96)
        for (x, y) in [(54, 41), (56, 42), (58, 43)] {
            let before = pixel(original, width: 128, x: x, y: y)
            let after = pixel(shifted, width: 128, x: x + dx, y: y + dy)
            #expect(zip(before, after).allSatisfy { abs($0 - $1) <= 1 },
                "The moved selection must sample the original model pixels at the same local position")
            #expect(after[3] == 173)
            #expect(pixel(shifted, width: 128, x: x, y: y) == pixel(unchanged, width: 128, x: x, y: y))
        }
        let returned = try DevelopRepairEditing.moved(moved, handle: .target,
            translation: CGSize(width: -delta, height: -delta))
        #expect(returned == stroke)
        #expect(try pixels(render(source, geometry: .init(retouchStrokes: [returned]))) == original)
    }

    @Test func frozenSourceRepairsFollowExposureAndWhiteBalanceInPreviewAndExport() throws {
        let source = try fixture { x, _ in x < 64 ? (80, 110, 150, 255) : (210, 70, 20, 255) }
        let bounds = try DevelopCropRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let replacement = try DevelopRetouchReplacement(bounds: bounds, width: 2, height: 2,
            rgba: Data(Array(repeating: [UInt8]([80, 110, 150, 255]), count: 4).flatMap { $0 }))
        let mask = try LocalMaskRaster(width: 4, height: 4, bytes: Data([0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255]))
        let stroke = try DevelopRetouchStroke(source: .init(x: 0.1, y: 0.1), target: .init(x: 0.75, y: 0.5),
            radius: 0.05, mask: mask, replacement: replacement)
        let bitmap = PreviewBitmap(image: source)
        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: false)
        var settings = EditSettings(exposure: 0.75, developColor: .init(temperature: 8_500, tint: -25))
        let before = try pixels(EditRenderer.render(bitmap, settings: settings, session: session).image)
        settings.developGeometry.retouchStrokes = [stroke]
        var prior: [Int]?
        for exposure in [0.75, -0.5] {
            settings.exposure = exposure
            let preview = try pixels(EditRenderer.render(bitmap, settings: settings, session: session).image)
            let clean = pixel(preview, width: 128, x: 24, y: 48)
            let repaired = pixel(preview, width: 128, x: 96, y: 48)
            #expect(zip(clean, repaired).allSatisfy { abs($0 - $1) <= 1 })
            #expect(repaired != pixel(before, width: 128, x: 96, y: 48))
            if let prior { #expect(repaired != prior) }
            prior = repaired
            let graph = try EditRenderer.filterGraph(source, settings: settings)
            let exported = try #require(EditRenderer.maskCompositingContext().createCGImage(graph, from: graph.extent,
                format: .RGBA8, colorSpace: source.colorSpace!, deferred: false))
            let exportPixels = try pixels(exported)
            #expect(zip(pixel(exportPixels, width: 128, x: 96, y: 48), repaired).allSatisfy { abs($0 - $1) <= 1 })
        }
        // Removing a repair must restore the original cached prefix after Undo.
        settings.developGeometry.retouchStrokes = []; settings.exposure = 0.75
        let undone = try pixels(EditRenderer.render(bitmap, settings: settings, session: session).image)
        #expect(undone == before)
    }

    @Test func frozenAndManualRepairsKeepStoredOrderAtTheSameTarget() throws {
        let source = try fixture { x, _ in x < 64 ? (30, 80, 200, 255) : (200, 30, 20, 255) }
        let target = try LocalMaskPoint(x: 0.75, y: 0.5)
        let clone = try DevelopRetouchStroke(mode: .clone, source: .init(x: 0.25, y: 0.5), target: target,
            radius: 0.14, feather: 0, path: [target])
        let frozen = try frozenRepair(target: target, color: [40, 210, 80])
        let bitmap = PreviewBitmap(image: source)
        let laterAI = try pixels(EditRenderer.render(bitmap,
            settings: .init(developGeometry: .init(retouchStrokes: [clone, frozen]))).image)
        let laterClone = try pixels(EditRenderer.render(bitmap,
            settings: .init(developGeometry: .init(retouchStrokes: [frozen, clone]))).image)
        let first = pixel(laterAI, width: 128, x: 96, y: 48)
        let second = pixel(laterClone, width: 128, x: 96, y: 48)
        #expect(first[1] > 190 && first[0] < 60)
        #expect(second[2] > 190 && second[1] < 100)
    }

    @Test func aLaterFrozenROIInAnOldCloneDonorDoesNotRewriteTheClone() throws {
        let source = try fixture { x, _ in x < 64 ? (30, 80, 200, 255) : (200, 30, 20, 255) }
        let target = try LocalMaskPoint(x: 0.75, y: 0.5), donor = try LocalMaskPoint(x: 0.25, y: 0.5)
        let clone = try DevelopRetouchStroke(mode: .clone, source: donor, target: target, radius: 0.1, feather: 0, path: [target])
        let frozen = try frozenRepair(target: donor, color: [40, 210, 80])
        let result = try pixels(EditRenderer.render(PreviewBitmap(image: source),
            settings: .init(developGeometry: .init(retouchStrokes: [clone, frozen]))).image)
        #expect(pixel(result, width: 128, x: 96, y: 48)[2] > 190)
        #expect(pixel(result, width: 128, x: 32, y: 48)[1] > 190)
    }

    @Test func addingFrozenPixelsPreservesEveryOutsidePixelOfAnOlderHealUnderNonlinearTone() throws {
        let source = try fixture { x, y in
            let value: UInt8 = x < 64 ? ((x + y).isMultiple(of: 2) ? 55 : 95) : (abs(x - 96) < 9 && abs(y - 48) < 9 ? 230 : 160)
            return (value, UInt8(max(0, Int(value) - 20)), value, 255)
        }
        let target = try LocalMaskPoint(x: 0.75, y: 0.5)
        let heal = try DevelopRetouchStroke(source: .init(x: 0.25, y: 0.5), target: target, radius: 0.2, feather: 0.5)
        let frozen = try frozenRepair(target: target, color: [40, 210, 80])
        var settings = EditSettings(exposure: 1.1, contrast: 70, highlights: -35, shadows: 30,
            developColor: .init(temperature: 9_000, tint: -30), developGeometry: .init(retouchStrokes: [heal]))
        let bitmap = PreviewBitmap(image: source)
        let before = try pixels(EditRenderer.render(bitmap, settings: settings).image)
        settings.developGeometry.retouchStrokes.append(frozen)
        let after = try pixels(EditRenderer.render(bitmap, settings: settings).image)
        let mask = try #require(frozen.mask)
        for index in mask.bytes.indices where mask.bytes[index] == 0 {
            #expect(Array(after[index * 4..<index * 4 + 4]) == Array(before[index * 4..<index * 4 + 4]))
        }
        #expect(pixel(after, width: 128, x: 96, y: 48) != pixel(before, width: 128, x: 96, y: 48))
    }

    @Test func replacementCoverageIsAppliedOnceAfterItsColorTransform() throws {
        let source = try fixture { _, _ in (40, 80, 120, 255) }
        let target = try LocalMaskPoint(x: 0.75, y: 0.5)
        let full = try frozenRepair(target: target, color: [200, 130, 30])
        let softMask = try LocalMaskRaster(width: 128, height: 96, bytes: Data(full.mask!.bytes.map { $0 == 0 ? 0 : 128 }))
        let half = try DevelopRetouchStroke(source: full.source, target: full.target, radius: full.radius,
            mask: softMask, replacement: full.replacement)
        let settings = EditSettings(exposure: 0.6, contrast: 45, developColor: .init(temperature: 8_000))
        let plain = try EditRenderer.filterGraph(source, settings: settings)
        let complete = try EditRenderer.filterGraph(source,
            settings: .init(exposure: settings.exposure, contrast: settings.contrast, developColor: settings.developColor,
                developGeometry: .init(retouchStrokes: [full])))
        let partial = try EditRenderer.filterGraph(source,
            settings: .init(exposure: settings.exposure, contrast: settings.contrast, developColor: settings.developColor,
                developGeometry: .init(retouchStrokes: [half])))
        let weightProvider = try #require(CGDataProvider(data: Data(repeating: 128, count: 128 * 96) as CFData))
        let weightBitmap = try #require(CGImage(width: 128, height: 96, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: weightProvider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let expected = complete.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: plain,
            kCIInputMaskImageKey: CIImage(cgImage: weightBitmap, options: [.colorSpace: NSNull()])])
        let context = EditRenderer.maskCompositingContext()
        let actualImage = try #require(context.createCGImage(partial, from: partial.extent, format: .RGBA8, colorSpace: source.colorSpace!, deferred: false))
        let expectedImage = try #require(context.createCGImage(expected, from: plain.extent, format: .RGBA8, colorSpace: source.colorSpace!, deferred: false))
        let actualPixels = try pixels(actualImage), expectedPixels = try pixels(expectedImage)
        #expect(zip(pixel(actualPixels, width: 128, x: 96, y: 48), pixel(expectedPixels, width: 128, x: 96, y: 48)).allSatisfy { abs($0 - $1) <= 1 })
    }

    @Test func sRGBReplacementIsColorManagedIntoTheOriginalDisplayP3Profile() throws {
        let base = try fixture { _, _ in (180, 50, 25, 128) }
        let profile = CGColorSpace(name: CGColorSpace.displayP3)!
        let source = try #require(CGImage(width: base.width, height: base.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: base.bytesPerRow, space: profile, bitmapInfo: base.bitmapInfo,
            provider: base.dataProvider!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let target = try LocalMaskPoint(x: 0.75, y: 0.5)
        let frozen = try frozenRepair(target: target, color: [80, 110, 150])
        let color = DevelopColorSettings(temperature: 8_000, tint: -20)
        let settings = EditSettings(exposure: 0.5, developColor: color,
            developGeometry: .init(retouchStrokes: [frozen]))
        let actual = try EditRenderer.render(PreviewBitmap(image: source), settings: settings).image
        #expect(actual.colorSpace?.name == profile.name)
        let reference = try fixture { _, _ in (80, 110, 150, 128) }
        let graph = try EditRenderer.filterGraph(reference, settings: .init(exposure: 0.5, developColor: color))
        let expected = try #require(EditRenderer.maskCompositingContext().createCGImage(graph, from: graph.extent,
            format: .RGBA8, colorSpace: profile, deferred: false))
        let actualPixels = try pixels(actual), expectedPixels = try pixels(expected)
        #expect(zip(pixel(actualPixels, width: 128, x: 96, y: 48), pixel(expectedPixels, width: 128, x: 96, y: 48)).allSatisfy { abs($0 - $1) <= 2 })
    }

    @Test func replacementColorAndLocalPlanesAreIncludedInPreviewAdmission() throws {
        let target = try LocalMaskPoint(x: 0.75, y: 0.5)
        let frozen = try frozenRepair(target: target, color: [80, 110, 150])
        var settings = EditSettings(exposure: 0.5, texture: 20, developColor: .init(temperature: 8_000),
            developGeometry: .init(retouchStrokes: [frozen]))
        settings.localAdjustments = [try .init(name: "Local color", mask: .init(shape: .radial(center: target,
            radiusX: 0.2, radiusY: 0.3, rotation: 0)), settings: .init(exposure: 0.3))]
        let overhead = EditRenderer.replacementColorBytesPerPixel(settings: settings)
        #expect(overhead > 16)
        let single = try #require(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: settings.localAdjustments, width: 128, height: 96))
        let repeated = try #require(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: settings.localAdjustments,
            width: 128, height: 96, additionalRenderCount: 1))
        #expect(repeated == 2 * single)
        let size = try LocalAdjustmentRenderer.previewSize(width: 2_048, height: 1_536, adjustments: settings.localAdjustments,
            geometry: settings.developGeometry, replacementColorBytesPerPixel: overhead)
        let local = try #require(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: settings.localAdjustments,
            width: size.width, height: size.height, additionalRenderCount: 1))
        let geometry = try #require(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: settings.developGeometry,
            width: size.width, height: size.height, replacementColorBytesPerPixel: overhead))
        #expect(local + geometry <= LocalAdjustmentRenderer.previewWorkingMemoryBudget)
        #expect(size.width < 2_048)
    }

    @Test func largeRepairExportPlanningBoundsHealContextAndKeepsFullFrameCompositeCosts() throws {
        let budget: UInt64 = 4 * 1_024 * 1_024 * 1_024 // 16 GiB / four.
        let width = 6_000, height = 4_000
        let pixels = UInt64(width * height)
        let base = pixels * 60 // Existing decoder + native-size JPEG output.
        let target = try LocalMaskPoint(x: 0.75, y: 0.5)
        let heal = try DevelopRetouchStroke(source: .init(x: 0.25, y: 0.5), target: target, radius: 0.05, path: [target])
        let healBytes = try #require(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: .init(retouchStrokes: [heal]),
            width: width, height: height))
        #expect(base + healBytes <= budget, "A normal 24-MP heal must fit the 16-GiB Mac's 4-GiB export plan")
        #expect(healBytes > pixels * 48, "Coverage, shifted source and composition still have full-frame costs")
        let context = try #require(DevelopRetouchMaskRenderer.healingContextBounds(for: heal,
            extent: CGRect(x: 0, y: 0, width: width, height: height)))
        #expect(context.width * context.height < CGFloat(width * height) / 20)
        let fullMaskHeal = try DevelopRetouchStroke(source: heal.source, target: target, radius: heal.radius,
            mask: .init(width: 256, height: 256, bytes: Data(repeating: 255, count: 65_536)))
        let fullHealBytes = try #require(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: .init(retouchStrokes: [fullMaskHeal]),
            width: width, height: height))
        #expect(base + fullHealBytes > budget, "A full-frame comparison graph still requires full-frame admission")
        let replacement = try DevelopRetouchReplacement(bounds: .init(x: 0.6, y: 0.3, width: 0.2, height: 0.3),
            width: 800, height: 800, rgba: Data(count: 800 * 800 * 4))
        let frozen = try DevelopRetouchStroke(source: target, target: target, radius: 0.05,
            mask: .init(width: 256, height: 256, bytes: Data(repeating: 255, count: 65_536)), replacement: replacement)
        var settings = EditSettings(developGeometry: .init(retouchStrokes: [frozen]))
        for corrected in [false, true] {
            if corrected { settings.exposure = 0.5; settings.developColor.temperature = 8_000 }
            let bytes = try #require(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: settings.developGeometry,
                width: width, height: height, replacementColorBytesPerPixel: EditRenderer.replacementColorBytesPerPixel(settings: settings)))
            #expect(base + bytes <= budget)
        }
        settings.texture = 20; settings.clarity = 20; settings.naturalBalanceAmount = 50
        settings.luminanceNoiseReduction = 20; settings.colorNoiseReduction = 20; settings.developColor.isMonochrome = true
        let decorated = try #require(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: settings.developGeometry,
            width: width, height: height, replacementColorBytesPerPixel: EditRenderer.replacementColorBytesPerPixel(settings: settings)))
        #expect(base + decorated > budget)
    }

    @Test func redEyeOnlyChangesRedDominanceInsideTheSelectedEllipseAndPreservesAlpha() throws {
        let source = try fixture { x, _ in x < 64 ? (220, 35, 25, 180) : (30, 140, 100, 180) }
        let corrections = try [
            DevelopRedEyeCorrection(center: .init(x: 0.25, y: 0.25), radiusX: 0.1, radiusY: 0.15),
            DevelopRedEyeCorrection(center: .init(x: 0.75, y: 0.25), radiusX: 0.1, radiusY: 0.15)
        ]
        let result = try pixels(render(source, geometry: .init(redEyeCorrections: corrections)))
        let original = try pixels(source)
        let corrected = pixel(result, width: 128, x: 32, y: 24), before = pixel(original, width: 128, x: 32, y: 24)
        #expect(corrected[0] < before[0] / 2)
        #expect(abs(corrected[1] - before[1]) <= 1 && abs(corrected[2] - before[2]) <= 1 && corrected[3] == before[3])
        #expect(pixel(result, width: 128, x: 32, y: 72) == pixel(original, width: 128, x: 32, y: 72))
        #expect(pixel(result, width: 128, x: 96, y: 24) == pixel(original, width: 128, x: 96, y: 24))
    }

    @Test func memoryPlanningIsBoundedAndDoesNotOverflow() throws {
        let patch = try DevelopRetouchStroke(source: .init(x: 0.25, y: 0.25), target: .init(x: 0.75, y: 0.75), radius: 0.02)
        #expect(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: .neutral, width: 128, height: 96) == 0)
        #expect(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: .init(retouchStrokes: [patch]), width: 128, height: 96) == 128 * 96 * 48)
        #expect(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: .init(straightenAngle: 12), width: 128, height: 96) == 128 * 96 * 32)
        #expect(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: .init(retouchStrokes: [patch]), width: Int.max, height: Int.max) == nil)
    }

    @Test func panoramicRotationAdmissionUsesTheExpandedCanvasAndRejectsOverflow() throws {
        let geometry = DevelopGeometry(straightenAngle: 45, constrainToImage: false)
        let output = try DevelopGeometryRenderer.outputSize(width: 4_000, height: 40, geometry: geometry)
        #expect(output.width == 2_857 && output.height == 2_857)
        let bytes = try #require(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: geometry, width: 4_000, height: 40))
        #expect(bytes == UInt64(output.width * output.height) * 32)
        #expect(bytes > 4_000 * 40 * 32 * 50)
        #expect(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: geometry, width: 1_000_000_000_000, height: 1) == nil)
        #expect(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: geometry, width: Int.max, height: 1) == nil)
        #expect(throws: (any Error).self) {
            try DevelopGeometryRenderer.outputSize(width: Int.max, height: 1, geometry: geometry)
        }
    }

    private func render(_ source: CGImage, geometry: DevelopGeometry) throws -> CGImage {
        let image = try DevelopGeometryRenderer.apply(to: CIImage(cgImage: source), geometry: geometry,
            extent: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return try #require(EditRenderer.maskCompositingContext().createCGImage(image, from: image.extent,
            format: .RGBA8, colorSpace: source.colorSpace!, deferred: false))
    }

    /// Full-frame reference catches accidental ROI clipping of mask interpolation,
    /// donor exclusions and Gaussian support. Quality is checked independently in
    /// DevelopRepairQualityTests against known clean image fields.
    private func fullFrameHealingReference(_ source: CGImage, stroke: DevelopRetouchStroke) throws -> CGImage {
        let input = CIImage(cgImage: source), extent = input.extent
        let coverage = try DevelopRetouchMaskRenderer.coverage(for: stroke, extent: extent)
        let translation = CGAffineTransform(translationX: (stroke.target.x - stroke.source.x) * extent.width,
            y: (stroke.source.y - stroke.target.y) * extent.height)
        let shifted = input.clampedToExtent().transformed(by: translation)
        let donorSelection = coverage.transformed(by: translation)
        let radius = CGFloat(stroke.radius) * min(extent.width, extent.height)
        let expanded = coverage.applyingFilter("CIMorphologyMaximum", parameters: [
            kCIInputRadiusKey: max(1, radius * 0.5)
        ]).cropped(to: extent)
        let differenceKernel = try #require(CIColorKernel(source: """
            kernel vec4 referenceDifference(__sample target, __sample donor, __sample mask,
                                             __sample expanded, __sample donorMask, vec4 bounds) {
                vec2 p = destCoord();
                if (p.x < bounds.x || p.y < bounds.y || p.x >= bounds.z || p.y >= bounds.w) { return vec4(0.0); }
                float outside = (mask.r > 0.000001 || donorMask.r > 0.000001 || expanded.r <= 0.000001) ? 0.0 : 1.0;
                float weight = outside * min(target.a, donor.a);
                if (weight <= 0.0) { return vec4(0.0); }
                return vec4((unpremultiply(target).rgb - unpremultiply(donor).rgb) * weight, weight);
            }
            """))
        let difference = try #require(differenceKernel.apply(extent: extent,
            arguments: [input, shifted, coverage, expanded, donorSelection,
                CIVector(x: extent.minX, y: extent.minY, z: extent.maxX, w: extent.maxY)]))
        let local = difference.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, radius * 0.6)])
        let context = try #require(DevelopRetouchMaskRenderer.healingContextBounds(for: stroke, extent: extent))
        let normalization = context.isNull || context.isEmpty ? 1 : extent.width * extent.height / (context.width * context.height)
        // Condition the full-frame reduction before accumulation, rather than
        // multiplying its already rounded result. This preserves tiny signed
        // differences in RGBAh and gives the same per-ROI weight threshold while
        // still checking every input pixel in the complete-image reference.
        let scaleKernel = try #require(CIColorKernel(source: """
            kernel vec4 referenceReductionScale(__sample weighted, float factor) { return weighted * factor; }
            """))
        let conditioned = try #require(scaleKernel.apply(extent: extent, arguments: [difference, normalization]))
        let average = conditioned.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
            .clampedToExtent()
        let correctionKernel = try #require(CIColorKernel(source: """
            kernel vec4 referenceCorrection(__sample local, __sample average) {
                vec3 fallback = average.a > 0.000001 ? average.rgb / average.a : vec3(0.0);
                if (local.a <= 0.00001) { return vec4(fallback, 1.0); }
                vec3 correction = mix(fallback, local.rgb / local.a, smoothstep(0.00001, 0.0001, local.a));
                return vec4(correction, 1.0);
            }
            """))
        let correction = try #require(correctionKernel.apply(extent: extent, arguments: [local, average]))
        let composite = try #require(CIColorKernel(source: """
            kernel vec4 referenceLocalHeal(__sample original, __sample donor, __sample mask,
                                           __sample correction, float opacity) {
                vec3 replacement = max(vec3(0.0), unpremultiply(donor).rgb + correction.rgb);
                vec3 color = mix(unpremultiply(original).rgb, replacement, clamp(mask.r * opacity, 0.0, 1.0));
                return vec4(color * original.a, original.a);
            }
            """))
        let graph = try #require(composite.apply(extent: extent,
            arguments: [input, shifted, coverage, correction, stroke.opacity]))
        return try #require(EditRenderer.maskCompositingContext().createCGImage(graph, from: extent,
            format: .RGBA8, colorSpace: source.colorSpace!, deferred: false))
    }

    /// Previous production healing, retained for explicit before/after photo diagnostics.
    func previousHealingReference(_ source: CGImage, stroke: DevelopRetouchStroke,
                                           expectedRingAlpha: ClosedRange<Float>? = nil) throws -> CGImage {
        let input = CIImage(cgImage: source), extent = input.extent
        let coverage = try DevelopRetouchMaskRenderer.coverage(for: stroke, extent: extent)
        let shifted = input.clampedToExtent().transformed(by: CGAffineTransform(
            translationX: (stroke.target.x - stroke.source.x) * extent.width,
            y: (stroke.source.y - stroke.target.y) * extent.height))
        let expanded = coverage.applyingFilter("CIMorphologyMaximum", parameters: [
            kCIInputRadiusKey: max(1, CGFloat(stroke.radius) * min(extent.width, extent.height) * 0.5)
        ]).cropped(to: extent)
        let ringKernel = try #require(CIColorKernel(source: """
            kernel vec4 referenceRing(__sample selected, __sample expanded) {
                float weight = selected.r > 0.000001 ? 0.0 : clamp(expanded.r, 0.0, 1.0);
                return vec4(weight, weight, weight, 1.0);
            }
            """))
        let ring = try #require(ringKernel.apply(extent: extent, arguments: [coverage, expanded]))
        let weightedKernel = try #require(CIColorKernel(source: """
            kernel vec4 referenceWeighted(__sample color, __sample mask) { return color * mask.r; }
            """))
        func mean(_ image: CIImage) throws -> CIImage {
            let weighted = try #require(weightedKernel.apply(extent: extent, arguments: [image, ring]))
            return weighted.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)]).clampedToExtent()
        }
        let compositeKernel = try #require(CIColorKernel(source: """
            kernel vec4 referenceHeal(__sample original, __sample sampled, __sample mask,
                                      __sample sourceMean, __sample targetMean, float opacity) {
                vec4 base = unpremultiply(original);
                vec3 correction = vec3(0.0);
                if (sourceMean.a > 0.000001 && targetMean.a > 0.000001) {
                    correction = unpremultiply(targetMean).rgb - unpremultiply(sourceMean).rgb;
                }
                vec3 replacement = max(vec3(0.0), unpremultiply(sampled).rgb + correction);
                vec3 color = mix(base.rgb, replacement, clamp(mask.r * opacity, 0.0, 1.0));
                return vec4(color * original.a, original.a);
            }
            """))
        let sourceMean = try mean(shifted), targetMean = try mean(input)
        if let expectedRingAlpha {
            var rgba = [Float](repeating: 0, count: 4)
            rgba.withUnsafeMutableBytes { bytes in
                EditRenderer.maskCompositingContext().render(sourceMean, toBitmap: bytes.baseAddress!, rowBytes: 16,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
            }
            #expect(expectedRingAlpha.contains(rgba[3]), "Reference ring alpha \(rgba[3]) must straddle the historical cutoff")
        }
        let graph = try #require(compositeKernel.apply(extent: extent,
            arguments: [input, shifted, coverage, sourceMean, targetMean, stroke.opacity]))
        return try #require(EditRenderer.maskCompositingContext().createCGImage(graph, from: extent,
            format: .RGBA8, colorSpace: source.colorSpace!, deferred: false))
    }

    private func frozenRepair(target: LocalMaskPoint, color: [UInt8]) throws -> DevelopRetouchStroke {
        var coverage = Data(count: 128 * 96)
        for y in 0..<96 { for x in 0..<128 where hypot(Double(x) + 0.5 - target.x * 128,
            Double(y) + 0.5 - target.y * 96) < 8 { coverage[y * 128 + x] = 255 } }
        let replacement = try DevelopRetouchReplacement(bounds: .init(x: target.x - 0.125, y: target.y - 0.15,
            width: 0.25, height: 0.3), width: 1, height: 1, rgba: Data(color + [255]))
        return try DevelopRetouchStroke(source: .init(x: 0.1, y: 0.1), target: target, radius: 0.08,
            mask: .init(width: 128, height: 96, bytes: coverage), replacement: replacement)
    }

    private func fixture(width: Int = 128, height: Int = 96,
                         pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        var data = [UInt8]()
        for y in 0..<height { for x in 0..<width {
            let (r, g, b, a) = pixel(x, y)
            data += [UInt8(Int(r) * Int(a) / 255), UInt8(Int(g) * Int(a) / 255), UInt8(Int(b) * Int(a) / 255), a]
        } }
        let provider = try #require(CGDataProvider(data: Data(data) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: image.colorSpace!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height * 4)).map { Int(bytes[$0]) }
    }

    private func pixel(_ data: [Int], width: Int, x: Int, y: Int) -> [Int] {
        let index = (y * width + x) * 4
        return Array(data[index..<(index + 4)])
    }
}
