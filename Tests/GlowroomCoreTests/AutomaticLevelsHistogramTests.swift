import Foundation
import Testing
@testable import GlowroomCore

@Suite("Streaming automatic Levels histograms")
struct AutomaticLevelsHistogramTests {
    @Test func threeFixedHistogramsKeepWeightedExtendedCoordinatesWithoutCallingThemHDR() {
        var builder = AutomaticLevelsHistogramBuilder()
        builder.add(encodedRed: -0.2, green: 0.5, blue: 1.2, alpha: 0.25)
        builder.add(encodedRed: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        let histogram = builder.finish()
        #expect(histogram.redBins.count == 4_096 && histogram.greenBins.count == 4_096 && histogram.blueBins.count == 4_096)
        #expect(AutomaticLevelsPolicy.maximumHistogramBytes == 98_304)
        #expect(histogram.visibleEquivalent == 1.25 && histogram.validPixelCount == 2)
        #expect(histogram.redBins[0] == 0.25 && histogram.redBins[819] == 1)
        #expect(histogram.greenBins[2048] == 1.25)
        #expect(histogram.blueBins[4095] == 0.25 && histogram.blueBins[3276] == 1)
        #expect(histogram.statistics.red.belowZero == 0.25 && histogram.statistics.red.aboveOne == 0)
        #expect(histogram.statistics.blue.aboveOne == 0.25 && histogram.statistics.blue.belowZero == 0)
    }

    @Test func invisibleAndInvalidSamplesAreCountedAndDoNotPolluteTheBins() {
        var builder = AutomaticLevelsHistogramBuilder()
        builder.add(encodedRed: .nan, green: .infinity, blue: -.infinity, alpha: 0)
        for alpha in [Double.nan, -.infinity, -0.1, 1.1] {
            builder.add(encodedRed: 0.2, green: 0.3, blue: 0.4, alpha: alpha)
        }
        for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            builder.add(encodedRed: value, green: 0.3, blue: 0.4, alpha: 1)
        }
        builder.add(encodedRed: 0.2, green: 0.3, blue: 0.4, alpha: 0.25)
        let histogram = builder.finish()
        #expect(histogram.visibleEquivalent == 0.25 && histogram.validPixelCount == 1)
        #expect(histogram.invisiblePixelCount == 1 && histogram.invalidPixelCount == 8)
        #expect(histogram.redBins.reduce(0, +) == 0.25)
        #expect(histogram.greenBins.reduce(0, +) == 0.25)
        #expect(histogram.blueBins.reduce(0, +) == 0.25)
    }

    @Test func gateQuantilesUseTheFirstOccupiedBinReachingTheWeightedCDF() {
        var builder = AutomaticLevelsHistogramBuilder()
        for index in [0, 1024, 2048, 4095] {
            let value = Double(index) / 4095
            builder.add(encodedRed: value, green: value, blue: value, alpha: 1)
        }
        let statistics = builder.finish().statistics.red
        #expect(statistics.q006 == 0 && statistics.q25 == 0)
        #expect(statistics.median == 1024.0 / 4095)
        #expect(statistics.q75 == 2048.0 / 4095 && statistics.q994 == 1)
        #expect(statistics.interquartileRange == 2048.0 / 4095)
    }

    @Test func quantilesUseAlphaMassRatherThanNumberOfPixels() {
        var builder = AutomaticLevelsHistogramBuilder()
        builder.add(encodedRed: 0, green: 0, blue: 0, alpha: 0.25)
        builder.add(encodedRed: 1, green: 1, blue: 1, alpha: 0.75)
        let histogram = builder.finish()
        #expect(histogram.visibleEquivalent == 1 && histogram.validPixelCount == 2)
        #expect(histogram.statistics.red.q25 == 0 && histogram.statistics.red.median == 1)
        #expect(histogram.statistics.red.q75 == 1)
    }

    @Test func finishedSnapshotsRemainImmutableWhenTheBuilderIsReused() {
        var builder = AutomaticLevelsHistogramBuilder()
        builder.add(encodedRed: 0, green: 0, blue: 0, alpha: 1)
        let first = builder.finish()
        builder.add(encodedRed: 1, green: 1, blue: 1, alpha: 1)
        let second = builder.finish()
        #expect(first.visibleEquivalent == 1 && first.redBins[4095] == 0)
        #expect(second.visibleEquivalent == 2 && second.redBins[4095] == 1)
    }

    @Test func emptyHistogramsHaveFiniteZeroStatistics() {
        let histogram = AutomaticLevelsHistogramBuilder().finish()
        #expect(histogram.visibleEquivalent == 0 && histogram.validPixelCount == 0)
        #expect(histogram.statistics.keyProxy == 0)
        #expect(histogram.statistics.maximumRobustSpan == 0)
        #expect(histogram.statistics.maximumInterquartileRange == 0)
    }
}
