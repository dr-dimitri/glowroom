import Foundation
import Testing
@testable import GlowroomCore

@Suite("Independent 0.6-percent Levels reference")
struct AutomaticLevelsReferenceTests {
    @Test(arguments: [0.25, 1.0])
    func aUniform4096BinHistogramHasAnalyticallyKnownClosestMassBoundaries(alpha: Double) {
        var builder = AutomaticLevelsHistogramBuilder()
        for index in 0..<4096 {
            let value = Double(index) / 4095
            builder.add(encodedRed: value, green: value, blue: value, alpha: alpha)
        }
        let histogram = builder.finish()
        // .006*4096=24.576: 25 rejected bins are closer than 24 or 26.
        // The lower boundary is the next bin, and the upper side is mirrored.
        expectReference(histogram, black: 25.0 / 4095, white: 4070.0 / 4095)
        #expect(histogram.statistics.red.q006 == 24.0 / 4095)
        #expect(histogram.statistics.red.q994 == 4071.0 / 4095)
        #expect(histogram.visibleEquivalent == 4096 * alpha)
    }

    @Test func emptyAndSingleBinHistogramsRetainDegenerateRawReferenceValues() {
        expectReference(AutomaticLevelsHistogramBuilder().finish(), black: 0, white: 0)
        for index in [0, 2048, 4095] {
            let histogram = fixture([(index, 64)])
            expectReference(histogram, black: Double(index) / 4095, white: Double(index) / 4095)
        }
    }

    @Test func twoTinySpikesRemainAReferenceEvenWhenProductionHasTooFewSamples() {
        let histogram = fixture([(1024, 1), (3072, 1)])
        expectReference(histogram, black: 1024.0 / 4095, white: 3072.0 / 4095)
        #expect(AutomaticLevelsProposalStencil.make(histogram: histogram) == .noProposal(.insufficientSamples))
    }

    @Test func isolatedExtremePixelsDoNotDetermineTheReferenceEndpoints() {
        let histogram = fixture([(0, 1), (1024, 499), (3072, 499), (4095, 1)])
        #expect(histogram.visibleEquivalent == 1000)
        expectReference(histogram, black: 1024.0 / 4095, white: 3072.0 / 4095)
    }

    @Test(arguments: [-1.0 / 1024, 0.0, 1.0 / 1024])
    func exactTiesMoveInwardWhileAGenuinelyCloserOuterTailDoesNot(delta: Double) {
        // N=125 makes .006*N=.75 exactly. The first two low-tail masses
        // straddle .75 at .5 and 1+delta. On an exact tie strict comparison
        // continues inward to bin17. A positive delta makes boundary16 closer.
        let histogram = fixture([(0, 0.5), (16, 0.5 + delta), (17, 1), (2048, 121 - delta),
                                 (4078, 1), (4079, 0.5), (4095, 0.5)])
        #expect(histogram.visibleEquivalent == 125)
        expectReference(histogram, black: Double(delta > 0 ? 16 : 17) / 4095, white: 4078.0 / 4095)
    }

    @Test func anExactTailMassTraversesAnEmptyPlateauWithoutInterpolating() {
        let histogram = fixture([(0, 0.75), (1000, 62.125), (3000, 62.125)])
        #expect(histogram.visibleEquivalent == 125)
        #expect(histogram.statistics.red.q006 == 0)
        expectReference(histogram, black: 1000.0 / 4095, white: 3000.0 / 4095)
    }

    @Test func referenceChannelsAreIndependentComparisonCurves() {
        var builder = AutomaticLevelsHistogramBuilder()
        for index in 0..<1000 {
            builder.add(encodedRed: Double(800 + index) / 4095,
                green: Double(1200 + index) / 4095, blue: Double(1600 + index) / 4095, alpha: 1)
        }
        let result = AutomaticLevelsReference.estimate(histogram: builder.finish())
        #expect(result.red == .init(black: 806.0 / 4095, white: 1793.0 / 4095))
        #expect(result.green == .init(black: 1206.0 / 4095, white: 2193.0 / 4095))
        #expect(result.blue == .init(black: 1606.0 / 4095, white: 2593.0 / 4095))
    }

    private func fixture(_ masses: [(Int, Double)]) -> AutomaticLevelsHistogram {
        var builder = AutomaticLevelsHistogramBuilder()
        for (index, mass) in masses {
            var remaining = mass
            while remaining > 0 {
                let alpha = min(remaining, 1), value = Double(index) / 4095
                builder.add(encodedRed: value, green: value, blue: value, alpha: alpha)
                remaining -= alpha
            }
        }
        return builder.finish()
    }

    private func expectReference(_ histogram: AutomaticLevelsHistogram, black: Double, white: Double,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        let actual = AutomaticLevelsReference.estimate(histogram: histogram)
        let expected = AutomaticLevelsEndpoints(black: black, white: white)
        #expect(actual.red == expected && actual.green == expected && actual.blue == expected, sourceLocation: sourceLocation)
    }
}
