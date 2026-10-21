import Foundation
import Testing
@testable import GlowroomCore

struct MaskRasterizationCacheTests {
    @Test func appendExtensionEraseAndInversionMatchFullBytesAndHash() throws {
        let size = try ArtifactPixelSize(width: 37, height: 23)
        let first = try MaskStroke(points: [.init(x: 0, y: 0)], radius: 7.25, hardness: 0.15)
        let extended = try MaskStroke(points: first.points + [.init(x: 18.5, y: 11.5), .init(x: 37, y: 23)],
                                      radius: first.radius, hardness: first.hardness)
        let erase = try MaskStroke(points: [.init(x: 0, y: 23), .init(x: 37, y: 0)],
                                   radius: 2.75, hardness: 0.4, mode: .erase)
        let empty = try MaskDocument(canvasSize: size)
        let dot = try empty.appending(first)
        let line = try MaskDocument(canvasSize: size, strokes: [extended])
        let longer = try MaskDocument(canvasSize: size, strokes: [.init(
            points: extended.points + [.init(x: 0, y: 23)], radius: extended.radius, hardness: extended.hardness)])
        let erased = try longer.appending(erase)
        let inverted = erased.inverted()
        let afterInvert = try inverted.appending(.init(points: [.init(x: 37, y: 23)], radius: 3.1))
        let states = [empty, dot, line, longer, erased, inverted, afterInvert, afterInvert]
        let expected: [MaskRasterizationReuse] = [.full, .appended, .appended, .appended, .appended, .inverted, .appended, .unchanged]
        var cache = MaskRasterizationCache()
        for (document, reuse) in zip(states, expected) {
            let update = try cache.rasterize(document)
            let reference = try MaskRasterizer.rasterize(document)
            #expect(update.reuse == reuse)
            #expect(update.raster == reference)
            #expect(try update.raster.canonicalSHA256() == reference.canonicalSHA256())
            cache = update.cache
        }
    }

    @Test func seededMixedDocumentsAtNativeScaledAndCroppedCoordinates() throws {
        let size = try ArtifactPixelSize(width: 91, height: 67)
        let crop = try ArtifactPixelRect(x: 7, y: 3, size: .init(width: 71, height: 59))
        var seed: UInt64 = 44
        func value(_ limit: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int((seed >> 32) % UInt64(limit))
        }
        var documents = [try MaskDocument(canvasSize: size)]
        for index in 0..<36 {
            var document = documents.last!
            if index.isMultiple(of: 9) { document = document.inverted() }
            let point = try MaskPoint(x: Double(value(size.width + 1)), y: Double(value(size.height + 1)))
            let stroke = try MaskStroke(points: [point], radius: Double(value(25) + 1) / 2,
                                        hardness: Double(value(5)) / 4,
                                        mode: index.isMultiple(of: 3) ? .erase : .brush)
            document = try document.appending(stroke)
            documents.append(document)
            let extensionPoint = try MaskPoint(x: Double(value(size.width + 1)), y: Double(value(size.height + 1)))
            let extended = try MaskStroke(points: stroke.points + [extensionPoint], radius: stroke.radius,
                                          hardness: stroke.hardness, mode: stroke.mode)
            document = try MaskDocument(canvasSize: size,
                strokes: Array(document.strokes.dropLast()) + [extended], isInverted: document.isInverted)
            documents.append(document)
        }
        for (output, region) in [(nil, nil), (try ArtifactPixelSize(width: 29, height: 17), nil),
                                 (try ArtifactPixelSize(width: 39, height: 43), crop)] as [(ArtifactPixelSize?, ArtifactPixelRect?)] {
            var cache = MaskRasterizationCache()
            for document in documents {
                let update = try cache.rasterize(document, outputSize: output, crop: region)
                let reference = try MaskRasterizer.rasterize(document, outputSize: output, crop: region)
                #expect(update.raster == reference)
                #expect(try update.raster.canonicalSHA256() == reference.canonicalSHA256())
                cache = update.cache
            }
        }
    }

    @Test func undoClearChangedPropertiesCanvasAndOutputInvalidateSafely() throws {
        let size = try ArtifactPixelSize(width: 16, height: 12)
        let base = try MaskDocument(canvasSize: size, strokes: [.init(points: [.init(x: 6, y: 5)], radius: 3)])
        let more = try base.appending(.init(points: [.init(x: 10, y: 7)], radius: 4, mode: .erase))
        let initial = try MaskRasterizationCache().rasterize(more)
        let undo = try initial.cache.rasterize(base)
        #expect(undo.reuse == .full)
        #expect(try undo.cache.rasterize(more).reuse == .appended)
        let changed = try MaskDocument(canvasSize: size, strokes: [.init(points: base.strokes[0].points, radius: 2)])
        #expect(try undo.cache.rasterize(changed).reuse == .full)
        #expect(try initial.cache.rasterize(more.cleared()).reuse == .full)
        #expect(try initial.cache.rasterize(more, outputSize: .init(width: 8, height: 6)).reuse == .full)
        #expect(try initial.cache.rasterize(more, crop: .init(x: 1, y: 0, size: .init(width: 15, height: 12))).reuse == .full)
        let otherCanvas = try MaskDocument(canvasSize: .init(width: 17, height: 12), strokes: more.strokes)
        #expect(try initial.cache.rasterize(otherCanvas).reuse == .full)
        // Flipping only the initial canvas is not inversion of prior brush pixels.
        let differentBase = try MaskDocument(canvasSize: size, strokes: more.strokes, isInverted: true)
        let full = try initial.cache.rasterize(differentBase)
        #expect(full.reuse == .full)
        #expect(try full.raster == MaskRasterizer.rasterize(differentBase))
    }

    @Test func firstCapsuleRepairsDotAtSoftThresholdsWithoutChangingParentCoordinates() throws {
        let size = try ArtifactPixelSize(width: 96, height: 64)
        let prefix = try MaskDocument(canvasSize: size, strokes: [
            .init(points: [.init(x: 9.5, y: 17.5), .init(x: 88, y: 48)], radius: 24, hardness: 0.17),
            .init(points: [.init(x: 11, y: 49), .init(x: 83, y: 8)], radius: 3.3, hardness: 0.41, mode: .erase),
            .init(points: [.init(x: 39.5, y: 29.5)], radius: 8.7, hardness: 0.33)
        ])
        let crop = try ArtifactPixelRect(x: 7, y: 11, size: .init(width: 61, height: 43))
        let outside = try ArtifactPixelRect(x: 70, y: 40, size: .init(width: 16, height: 16))
        let grids: [(ArtifactPixelSize?, ArtifactPixelRect?)] = [
            (nil, nil), (try .init(width: 31, height: 17), nil),
            (try .init(width: 29, height: 19), crop), (try .init(width: 13, height: 17), outside),
            (try .init(width: 257, height: 131), nil)
        ]
        for radius in [Double(6).nextDown, 6, Double(6).nextUp] {
            for mode in [MaskStrokeMode.brush, .erase] {
                for startsInverted in [false, true] {
                    let base = startsInverted ? prefix.inverted() : prefix
                    // Pixel centers exactly three pixels away lie on a 127.5
                    // feather threshold at radius six/hardness zero. Adjacent
                    // representable radii and nearly horizontal projections
                    // exercise either side of the final byte rounding.
                    let point = try MaskPoint(x: 39.5, y: 29.5)
                    let dot = try MaskStroke(points: [point], radius: radius, hardness: 0, mode: mode)
                    let before = try base.appending(dot)
                    let line = try MaskStroke(points: [point, .init(x: 76.5, y: Double(29.5).nextUp)],
                                              radius: radius, hardness: 0, mode: mode)
                    let after = try MaskDocument(canvasSize: size, strokes: base.strokes + [line], isInverted: base.isInverted)
                    for flipsDuringExtension in [false, true] {
                        let replacement = flipsDuringExtension ? after.inverted() : after
                        let next = try replacement.appending(.init(points: [.init(x: 94, y: 63)], radius: 1.7, mode: .erase))
                        for (output, region) in grids {
                            let initial = try MaskRasterizationCache().rasterize(before, outputSize: output, crop: region)
                            let actual = try initial.cache.rasterize(next, outputSize: output, crop: region)
                            let reference = try MaskRasterizer.rasterize(next, outputSize: output, crop: region)
                            #expect(actual.reuse == (flipsDuringExtension ? .inverted : .appended))
                            #expect(actual.raster == reference)
                            #expect(try actual.raster.canonicalSHA256() == reference.canonicalSHA256())
                            #expect(try initial.cache.rasterize(before, outputSize: output, crop: region).raster == initial.raster)
                        }
                    }
                }
            }
        }
    }

    @Test func firstCapsuleRepairKeepsFullDocumentAdmissionAndTransactionalCancellation() throws {
        let size = try ArtifactPixelSize(width: 32, height: 24)
        let prefix = try MaskDocument(canvasSize: size, strokes: [.init(points: [.init(x: 16, y: 12)], radius: 8)])
        let before = try prefix.appending(.init(points: [.init(x: 16, y: 12)], radius: 1, mode: .erase))
        let after = try MaskDocument(canvasSize: size, strokes: prefix.strokes + [
            .init(points: [.init(x: 16, y: 12), .init(x: 17, y: 12)], radius: 1, mode: .erase)
        ])
        let initial = try MaskRasterizationCache().rasterize(before, maximumSampleEvaluations: 260)
        #expect(throws: ArtifactContractError.limitExceeded) {
            _ = try initial.cache.rasterize(after, maximumSampleEvaluations: 261)
        }
        let admitted = try initial.cache.rasterize(after, maximumSampleEvaluations: 262)
        #expect(admitted.reuse == .appended)
        #expect(try admitted.raster == MaskRasterizer.rasterize(after, maximumSampleEvaluations: 262))

        let larger = try ArtifactPixelSize(width: 80, height: 80)
        let base = try MaskDocument(canvasSize: larger, strokes: [.init(points: [.init(x: 40, y: 40)], radius: 40)])
        let dot = try base.appending(.init(points: [.init(x: 40, y: 40)], radius: 35, mode: .erase))
        let line = try MaskDocument(canvasSize: larger, strokes: base.strokes + [
            .init(points: [.init(x: 40, y: 40), .init(x: 70, y: 60)], radius: 35, mode: .erase)
        ])
        let published = try MaskRasterizationCache().rasterize(dot)
        // Five validation checks precede reset rows 16/32. Cancellation at row32
        // discards already-cleared candidate bytes and preserves the old dot.
        let probe = MaskCancellationProbe(throwOn: 7)
        #expect(throws: CancellationError.self) {
            _ = try published.cache.rasterize(line, cancellation: { try probe.check() })
        }
        #expect(try published.cache.rasterize(dot).raster == published.raster)
        let retried = try published.cache.rasterize(line)
        #expect(retried.reuse == .appended)
        #expect(try retried.raster == MaskRasterizer.rasterize(line))
    }

    @Test func workLimitCannotBeBypassedByAnUnchangedOrIncrementalEntry() throws {
        let size = try ArtifactPixelSize(width: 32, height: 24)
        let base = try MaskDocument(canvasSize: size, strokes: [.init(points: [.init(x: 16, y: 12)], radius: 8)])
        let cached = try MaskRasterizationCache().rasterize(base).cache
        let next = try base.appending(.init(points: [.init(x: 0, y: 0)], radius: 1))
        for document in [base, next, base.inverted()] {
            #expect(throws: ArtifactContractError.limitExceeded) {
                _ = try cached.rasterize(document, maximumSampleEvaluations: 255)
            }
            #expect(throws: ArtifactContractError.limitExceeded) {
                _ = try MaskRasterizer.rasterize(document, maximumSampleEvaluations: 255)
            }
        }
        #expect(throws: ArtifactContractError.limitExceeded) { _ = try cached.rasterize(base, maximumSampleEvaluations: 0) }
        #expect(try cached.rasterize(base, maximumSampleEvaluations: 256).reuse == .unchanged)
    }

    @Test func cancellationAfterPartialIncrementalWritesPreservesPublishedBase() throws {
        let size = try ArtifactPixelSize(width: 80, height: 80)
        let base = try MaskDocument(canvasSize: size, strokes: [.init(points: [.init(x: 40, y: 40)], radius: 10)])
        let initial = try MaskRasterizationCache().rasterize(base)
        let next = try base.appending(.init(points: [.init(x: 40, y: 40)], radius: 35, mode: .erase))
        // Five validation checks precede stroke/segment checks and row16.
        // Throw after the first row block has already changed candidate bytes.
        let probe = MaskCancellationProbe(throwOn: 8)
        #expect(throws: CancellationError.self) {
            _ = try initial.cache.rasterize(next, cancellation: { try probe.check() })
        }
        let unchanged = try initial.cache.rasterize(base)
        #expect(unchanged.reuse == .unchanged)
        #expect(unchanged.raster == initial.raster)
        #expect(try initial.cache.rasterize(next).raster == MaskRasterizer.rasterize(next))
        #expect(throws: CancellationError.self) {
            _ = try initial.cache.rasterize(base.inverted(), cancellation: { throw CancellationError() })
        }
    }

    @Test func fullHashAndOptimizedResamplingHonorCallbackCancellation() throws {
        let raster = try MaskRaster(size: .init(width: 257, height: 257), bytes: Data(repeating: 51, count: 257 * 257))
        let hashProbe = MaskCancellationProbe(throwOn: 3)
        #expect(throws: CancellationError.self) { _ = try raster.canonicalSHA256(cancellation: { try hashProbe.check() }) }
        let sampleProbe = MaskCancellationProbe(throwOn: 4)
        #expect(throws: CancellationError.self) {
            _ = try raster.resampledOptimized(to: .init(width: 129, height: 129), cancellation: { try sampleProbe.check() })
        }
    }

    @Test func optimizedResamplingMatchesReferenceAcrossPixelCentersCropsAndEdges() throws {
        for source in [try ArtifactPixelSize(width: 1, height: 1), try .init(width: 31, height: 19), try .init(width: 7, height: 43)] {
            let bytes = Data((0..<(source.width * source.height)).map { UInt8(($0 * 71 + 23) % 256) })
            let raster = try MaskRaster(size: source, bytes: bytes)
            let cropped = try ArtifactPixelRect(x: source.width / 3, y: source.height / 3,
                size: .init(width: max(1, source.width / 2), height: max(1, source.height / 2)))
            for crop in [nil, cropped] {
                for output in [source, try .init(width: 1, height: 1), try .init(width: 53, height: 29), try .init(width: 4, height: 3)] {
                    #expect(try raster.resampledOptimized(to: output, crop: crop) == raster.resampled(to: output, crop: crop))
                }
            }
        }
    }
}

private final class MaskCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let throwOn: Int
    init(throwOn: Int) { self.throwOn = throwOn }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        count += 1
        if count == throwOn { throw CancellationError() }
    }
}
