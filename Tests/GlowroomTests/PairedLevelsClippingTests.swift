import Foundation
import Testing
@testable import Glowroom

@Suite("Paired automatic Levels clipping")
struct PairedLevelsClippingTests {
    @Test(arguments: [PairedClippingCategory.anyLower, .anyUpper, .allBlack, .allWhite])
    func clippingRemovedElsewhereCannotCancelNewlyClippedPixels(category: PairedClippingCategory) throws {
        let baseline = raster(count: 1_000) { index in category.pixel(clipped: index < 20) }
        let candidate = raster(count: 1_000) { index in category.pixel(clipped: (20..<40).contains(index)) }
        let result = try PairedLevelsClipping.measure(baseline: baseline, candidate: candidate)
        #expect(category.mass(result.baseline) == 20)
        #expect(category.mass(result.candidate) == 20, "Aggregate clipping is unchanged in this counterexample")
        #expect(category.mass(result.newlyClipped) == 20)
        #expect(result.visibleEquivalent == 1_000 && result.limit == 7)
        #expect(!result.isWithinBudget, "The paired new region exceeds .006*N+1 despite unchanged totals")
    }

    @Test(arguments: [PairedClippingCategory.anyLower, .anyUpper, .allBlack, .allWhite])
    func exactlyThePublishedMassBudgetIsAcceptedAndTheNextPixelIsRejected(category: PairedClippingCategory) throws {
        let baseline = raster(count: 1_000) { _ in category.pixel(clipped: false) }
        let boundary = try PairedLevelsClipping.measure(baseline: baseline,
            candidate: raster(count: 1_000) { category.pixel(clipped: $0 < 7) })
        #expect(boundary.limit == 7 && category.mass(boundary.newlyClipped) == 7)
        #expect(boundary.isWithinBudget)
        let excessive = try PairedLevelsClipping.measure(baseline: baseline,
            candidate: raster(count: 1_000) { category.pixel(clipped: $0 < 8) })
        #expect(category.mass(excessive.newlyClipped) == 8 && !excessive.isWithinBudget)
    }

    @Test func alphaWeightsAndInvisibleMarginsUseVisibleEquivalentRatherThanPixelCount() throws {
        let baseline = raster(count: 1_000, alpha: { $0 < 800 ? 0.5 : 0 }) { _ in (0.5, 0.5, 0.5) }
        let candidate = raster(count: 1_000, alpha: { $0 < 800 ? 0.5 : 0 }) { index in
            index < 6 ? (1.1, 0.5, 0.5) : (0.5, 0.5, 0.5)
        }
        let result = try PairedLevelsClipping.measure(baseline: baseline, candidate: candidate)
        #expect(result.visibleEquivalent == 400)
        #expect(result.newlyClipped.anyUpper == 3)
        #expect(result.limit == 3.4 && result.isWithinBudget)
        let excessive = raster(count: 1_000, alpha: { $0 < 800 ? 0.5 : 0 }) { index in
            index < 7 ? (1.1, 0.5, 0.5) : (0.5, 0.5, 0.5)
        }
        #expect(try !PairedLevelsClipping.measure(baseline: baseline, candidate: excessive).isWithinBudget)
    }

    @Test func allWhiteAndBlackAreIndependentFromAnyChannelBoundary() throws {
        let baseline = raster(count: 100) { _ in (1, 0, 0.5) }
        let candidate = raster(count: 100) { $0 < 50 ? (1.2, 1.1, 1) : (0, -0.1, -0.2) }
        let result = try PairedLevelsClipping.measure(baseline: baseline, candidate: candidate)
        #expect(result.baseline.anyLower == 100 && result.baseline.anyUpper == 100)
        #expect(result.newlyClipped.anyLower == 0 && result.newlyClipped.anyUpper == 0)
        #expect(result.newlyClipped.allBlack == 50 && result.newlyClipped.allWhite == 50)
        #expect(!result.isWithinBudget)
    }

    @Test func mismatchedPositionsAlphaAndNonfiniteVisibleDataAreNeverCertified() throws {
        let valid = raster(count: 100) { _ in (0.5, 0.5, 0.5) }
        #expect(throws: PairedLevelsClipping.ValidationError.incompatibleRaster) {
            try PairedLevelsClipping.measure(baseline: valid,
                candidate: .init(width: 10, height: 10, pixels: valid.pixels))
        }
        for alpha in [Float(0.5), .nan, .infinity, -0.1, 1.1] {
            var pixels = valid.pixels; pixels[3] = alpha
            #expect(throws: PairedLevelsClipping.ValidationError.invalidAlpha) {
                try PairedLevelsClipping.measure(baseline: valid,
                    candidate: .init(width: valid.width, height: valid.height, pixels: pixels))
            }
        }
        var pixels = valid.pixels; pixels[0] = .nan
        #expect(throws: PairedLevelsClipping.ValidationError.nonfiniteSample) {
            try PairedLevelsClipping.measure(baseline: valid,
                candidate: .init(width: valid.width, height: valid.height, pixels: pixels))
        }
    }

    @Test func alreadyClippedPixelsAreNotNewAndEmptyEvidenceDoesNotPass() throws {
        let clipped = raster(count: 100) { $0 < 50 ? (-0.2, -0.1, 0) : (1, 1.1, 1.2) }
        let unchanged = try PairedLevelsClipping.measure(baseline: clipped, candidate: clipped)
        #expect(unchanged.newlyClipped == .init() && unchanged.isWithinBudget)
        let transparent = raster(count: 100, alpha: { _ in 0 }) { _ in (0, 0, 0) }
        let empty = try PairedLevelsClipping.measure(baseline: transparent, candidate: transparent)
        #expect(empty.visibleEquivalent == 0 && !empty.isWithinBudget)
    }

    private func raster(count: Int, alpha: (Int) -> Float = { _ in 1 },
                        pixel: (Int) -> (Float, Float, Float)) -> FloatAnalysisRaster {
        let width = min(250, count), height = count / width
        var pixels: [Float] = []
        for index in 0..<count {
            let (r, g, b) = pixel(index), a = alpha(index)
            pixels += [r * a, g * a, b * a, a]
        }
        return .init(width: width, height: height, pixels: pixels)
    }
}

enum PairedClippingCategory: Sendable {
    case anyLower, anyUpper, allBlack, allWhite

    func pixel(clipped: Bool) -> (Float, Float, Float) {
        guard clipped else { return (0.5, 0.5, 0.5) }
        switch self {
        case .anyLower: return (0, 0.5, 0.5)
        case .anyUpper: return (1, 0.5, 0.5)
        case .allBlack: return (-0.1, 0, -0.2)
        case .allWhite: return (1, 1.1, 1.2)
        }
    }

    func mass(_ mass: PairedLevelsClipping.Mass) -> Double {
        switch self {
        case .anyLower: mass.anyLower
        case .anyUpper: mass.anyUpper
        case .allBlack: mass.allBlack
        case .allWhite: mass.allWhite
        }
    }
}
