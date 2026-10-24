import Foundation
import Testing
@testable import GlowroomCore

@Suite("Conservative common automatic Levels proposals")
struct AutomaticLevelsProposalTests {
    @Test func thePublishedQualityPolicyMatchesThePreregisteredContract() {
        #expect(AutomaticLevelsPolicy.binCount == 4096)
        #expect(AutomaticLevelsPolicy.referenceCommit == "7d518c7971e80719ce30f70ec44b55e49ab2aeb7")
        #expect(AutomaticLevelsPolicy.tailFraction == 0.006)
        #expect(AutomaticLevelsPolicy.minimumVisibleEquivalent == 64)
        #expect(AutomaticLevelsPolicy.minimumRobustSpan == 0.125)
        #expect(AutomaticLevelsPolicy.minimumInterquartileRange == 0.03125)
        #expect(AutomaticLevelsPolicy.keyRange == (0.3...0.7))
        #expect(AutomaticLevelsPolicy.gainRange == (1.01...3))
        #expect(AutomaticLevelsPolicy.maximumKeyShift == 0.075)
        #expect(AutomaticLevelsPolicy.strengths == [1, 0.875, 0.75, 0.625, 0.5, 0.375, 0.25,
            0.1875, 0.125, 0.09375, 0.0625, 0.046875, 0.03125])
    }

    @Test func aMidtoneRampProducesCommonAnalyticEndpointsAndMonotoneNeutralCurves() throws {
        let stencil = try proposal(uniformBins: 819...3276)
        // 2458 equally weighted bins; .006*N=14.748, closest tail mass=15.
        #expect(stencil.common == .init(black: 834.0 / 4095, white: 3261.0 / 4095))
        #expect(stencil.visibleEquivalent == 2458)
        #expect(abs(stencil.keyProxy - 2047.0 / 4095) < 1e-15)
        let candidate = try stencil.evaluate(at: 0.5, preserving: nonneutralLevels())
        #expect(abs(candidate.endpoints.black - 417.0 / 4095) < 1e-15)
        #expect(abs(candidate.endpoints.white - 3678.0 / 4095) < 1e-15)
        #expect(candidate.checks.isEligible)
        let levels = try #require(candidate.levels)
        #expect(levels.red.isNeutral && levels.green.isNeutral && levels.blue.isNeutral)
        #expect(levels.master.gamma == 1 && levels.master.outputBlack == 0 && levels.master.outputWhite == 1)
        #expect(!levels.master.clampInput && !levels.master.clampOutput)
        #expect(levels.transferFunction == .signedSRGB && levels.version == .v1)
        var previous = -Double.infinity
        for index in 0...256 {
            let value = Double(index) / 256
            let output = try levels.rgb(red: value, green: value, blue: value)
            #expect(output.red >= previous && output.red == output.green && output.green == output.blue)
            previous = output.red
        }
    }

    @Test(arguments: ToneProcessingVersion.allCases)
    func completeLevelsReplacementPreservesAllOtherSettingsAndIsIdempotent(version: ToneProcessingVersion) throws {
        let stencil = try proposal(uniformBins: 819...3276)
        var baseline = EditSettings(exposure: 0.7, contrast: 12, highlights: -15, texture: 9,
            naturalBalanceAmount: 25, developColor: .init(temperature: 7100, tint: -6, profile: .vivid),
            developGeometry: .init(quarterTurns: 1, flipHorizontal: true), toneProcessingVersion: version)
        baseline.levels = nonneutralLevels()
        let proposedLevels = try stencil.candidate(at: 0.75, preserving: baseline.levels)
        let levels = try #require(proposedLevels)
        var accepted = baseline; accepted.levels = levels
        var restoredForeign = accepted; restoredForeign.levels = baseline.levels
        #expect(restoredForeign == baseline)
        #expect(accepted.toneProcessingVersion == version)
        #expect(try EditingSnapshot(settings: accepted).settings == accepted)
        #expect(try stencil.candidate(at: 0.75, preserving: accepted.levels) == accepted.levels)
        #expect(try stencil.evaluate(at: 0.75, preserving: baseline.levels).levels == levels)
    }

    @Test func commonHeadroomUsesTheSmallestBlackAndLargestWhiteAcrossChannels() throws {
        var builder = AutomaticLevelsHistogramBuilder()
        for index in 0..<1000 {
            builder.add(encodedRed: Double(800 + index) / 4095,
                green: Double(1200 + index) / 4095, blue: Double(1600 + index) / 4095, alpha: 1)
        }
        let stencil = try requireStencil(builder.finish())
        #expect(stencil.common == .init(black: 806.0 / 4095, white: 2593.0 / 4095))
        let candidate = try stencil.evaluate(at: 0.5, preserving: .neutral)
        #expect(candidate.levels?.red.isNeutral == true)
        #expect(candidate.endpoints.black <= stencil.reference.red.black)
        #expect(candidate.endpoints.white >= stencil.reference.blue.white)
    }

    @Test func aStrongNarrowBandRequiresBackoffToRespectTheGainGate() throws {
        let stencil = try proposal(uniformBins: 1638...2457)
        let strong = try stencil.evaluate(at: 1, preserving: .neutral)
        #expect(strong.checks.usefulGain && !strong.checks.boundedGain && strong.levels == nil)
        let weaker = try stencil.evaluate(at: 0.75, preserving: .neutral)
        #expect(weaker.checks.isEligible && weaker.levels != nil)
        #expect(weaker.endpoints.black < strong.endpoints.black && weaker.endpoints.white > strong.endpoints.white)
    }

    @Test func aModeratelyOffCenterBandCannotShiftItsKeyBeyondThePublishedLimit() throws {
        let stencil = try proposal(uniformBins: 819...2047)
        let strong = try stencil.evaluate(at: 0.875, preserving: .neutral)
        #expect(strong.checks.boundedGain && !strong.checks.boundedKeyShift && strong.levels == nil)
        let weaker = try stencil.evaluate(at: 0.5, preserving: .neutral)
        #expect(weaker.checks.isEligible && weaker.keyShift <= 0.075)
    }

    @Test(arguments: [63.0, 64.0])
    func sampleGateUsesOpaqueEquivalentInsteadOfCount(equivalent: Double) throws {
        let histogram = band(from: 0.2, to: 0.8, count: 256, alpha: equivalent / 256)
        #expect(histogram.visibleEquivalent == equivalent && histogram.validPixelCount == 256)
        let result = AutomaticLevelsProposalStencil.make(histogram: histogram)
        if equivalent == 63 { #expect(result == .noProposal(.insufficientSamples)) }
        else { _ = try requireStencil(histogram) }
    }

    @Test(arguments: [false, true])
    func lowAndHighKeyNarrowBandsStayUnchanged(high: Bool) {
        let histogram = band(from: high ? 0.84 : 0.02, to: high ? 0.98 : 0.16)
        #expect(histogram.statistics.maximumRobustSpan >= 0.125)
        #expect(histogram.statistics.maximumInterquartileRange >= 0.03125)
        #expect(AutomaticLevelsProposalStencil.make(histogram: histogram) == .noProposal(high ? .highKey : .lowKey))
    }

    @Test func flatAndNearFlatNoisyFieldsStayUnchanged() {
        for (lower, upper) in [(0.5, 0.5), (0.48, 0.52), (0.0, 0.0), (1.0, 1.0)] {
            #expect(AutomaticLevelsProposalStencil.make(histogram: band(from: lower, to: upper)) == .noProposal(.insufficientRange))
        }
        #expect(AutomaticLevelsProposalStencil.make(histogram: AutomaticLevelsHistogramBuilder().finish()) == .noProposal(.insufficientSamples))
    }

    @Test func aNarrowCentralMassWithSparseWideTailsFailsTheIQRNoiseGate() {
        var builder = AutomaticLevelsHistogramBuilder()
        for index in 0..<1000 {
            let value = index < 50 ? 0.2 : index >= 950 ? 0.8 : 0.5
            builder.add(encodedRed: value, green: value, blue: value, alpha: 1)
        }
        let histogram = builder.finish()
        #expect(histogram.statistics.maximumRobustSpan > 0.125)
        #expect(histogram.statistics.maximumInterquartileRange == 0)
        #expect(AutomaticLevelsProposalStencil.make(histogram: histogram) == .noProposal(.insufficientRange))
    }

    @Test func tightIndividualChannelHeadroomCanLeaveNoUsefulCommonStretch() {
        var builder = AutomaticLevelsHistogramBuilder()
        for index in 0..<256 {
            builder.add(encodedRed: 0, green: 0.2 + 0.6 * Double(index) / 255, blue: 1, alpha: 1)
        }
        let histogram = builder.finish()
        #expect(histogram.statistics.maximumRobustSpan > 0.125)
        #expect(AutomaticLevelsPolicy.keyRange.contains(histogram.statistics.keyProxy))
        #expect(AutomaticLevelsProposalStencil.make(histogram: histogram) == .noProposal(.noUsefulImprovement))
    }

    @Test(arguments: [Double.nan, .infinity, -0.1, 0, 1.001])
    func invalidStrengthsAreRejectedWithoutNormalization(strength: Double) throws {
        let stencil = try proposal(uniformBins: 819...3276)
        #expect(throws: LevelsValidationError.invalidCurve) { try stencil.evaluate(at: strength, preserving: .neutral) }
    }

    private func proposal(uniformBins range: ClosedRange<Int>) throws -> AutomaticLevelsProposalStencil {
        var builder = AutomaticLevelsHistogramBuilder()
        for index in range {
            let value = Double(index) / 4095
            builder.add(encodedRed: value, green: value, blue: value, alpha: 1)
        }
        return try requireStencil(builder.finish())
    }

    private func requireStencil(_ histogram: AutomaticLevelsHistogram,
                                sourceLocation: SourceLocation = #_sourceLocation) throws -> AutomaticLevelsProposalStencil {
        let result = AutomaticLevelsProposalStencil.make(histogram: histogram)
        guard case let .stencil(stencil) = result else {
            Issue.record("Expected a useful common Levels stencil, got \(result)", sourceLocation: sourceLocation)
            throw LevelsValidationError.invalidCurve
        }
        return stencil
    }

    private func band(from lower: Double, to upper: Double, count: Int = 256, alpha: Double = 1) -> AutomaticLevelsHistogram {
        var builder = AutomaticLevelsHistogramBuilder()
        for index in 0..<count {
            let value = lower + (upper - lower) * Double(index) / Double(count - 1)
            builder.add(encodedRed: value, green: value, blue: value, alpha: alpha)
        }
        return builder.finish()
    }

    private func nonneutralLevels() -> LevelsSettings {
        LevelsSettings(master: .init(inputBlack: 0.1, inputWhite: 0.9, gamma: 2, outputBlack: 0.1,
                outputWhite: 0.8, clampInput: true, clampOutput: true),
            red: .init(gamma: 1.3, clampInput: true), green: .init(outputWhite: 0.9, clampOutput: true),
            blue: .init(inputBlack: 0.05, inputWhite: 0.95, gamma: 0.8))
    }
}
