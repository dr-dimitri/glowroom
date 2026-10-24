import Foundation
import Testing
@testable import GlowroomCore

@Suite("Atomic levels picker mathematics")
struct LevelsPickerProposalTests {
    @Test(arguments: [0.1, 1.0, 2.0, 10.0])
    func analyticalMidtonesCoverTheAllowedGammaRange(gamma: Double) throws {
        let sample = LevelsPickerSample(red: pow(0.5, gamma), green: 0.4, blue: 0.6)
        let actual = try LevelsPickerProposal.applying(sample: sample, point: .gray, mode: .setTone, channel: .red, to: fixture())
        #expect(abs(actual.levels.red.gamma - gamma) < 1e-12)
        #expect(abs(reference(sample.red, curve: actual.levels.red) - 0.5) < 1e-12)
    }

    @Test func anExtendedSampleIsPreservedBeforeSelectingTheRequestedChannel() throws {
        let sample = LevelsPickerSample(red: 0.25, green: 4, blue: -0.2)
        try sample.validate()
        let actual = try LevelsPickerProposal.applying(sample: sample, point: .gray, mode: .setTone, channel: .red, to: fixture())
        #expect(actual.levels.red.gamma == 2)
        #expect(sample.green == 4 && sample.blue == -0.2)
        #expect(throws: LevelsPickerError.degenerateMidtone) {
            try LevelsPickerProposal.applying(sample: sample, point: .gray, mode: .setTone, to: fixture())
        }
    }

    @Test(arguments: ToneProcessingVersion.allCases)
    func aQuarterGraySampleGivesGammaTwoAndPreservesEveryOtherSetting(version: ToneProcessingVersion) throws {
        let baseline = fixture(version: version)
        let sample = LevelsPickerSample(red: 0.25, green: 0.4, blue: 0.6)
        let actual = try LevelsPickerProposal.applying(sample: sample, point: .gray, mode: .setTone, channel: .red, to: baseline)
        var expected = baseline; expected.levels.red.gamma = 2
        #expect(actual == expected)
        #expect(abs(reference(sample.red, curve: actual.levels.red) - 0.5) < 1e-12)
        #expect(try LevelsPickerProposal.applying(sample: sample, point: .gray, mode: .setTone, channel: .red, to: actual) == actual)
    }

    @Test(arguments: LevelsPickerPoint.allCases)
    func masterMeasuresValueAfterTheUnchangedIndividualCurves(point: LevelsPickerPoint) throws {
        var baseline = fixture()
        baseline.levels.master = .init(inputBlack: 0.1, inputWhite: 0.9, gamma: 1.7, outputBlack: 0.1, outputWhite: 0.8)
        baseline.levels.red.gamma = 2
        let sample = LevelsPickerSample(red: 0.25, green: 0.4, blue: 0.1)
        let actual = try LevelsPickerProposal.applying(sample: sample, point: point, mode: .setTone, to: baseline)
        var expected = baseline
        switch point {
        case .black: expected.levels.master.inputBlack = 0.5
        case .white: expected.levels.master.inputWhite = 0.5
        case .gray: expected.levels.master.gamma = 1
        }
        #expect(actual == expected)
    }

    @Test(arguments: [LevelsChannel.red, .green, .blue], [LevelsPickerPoint.black, .white])
    func endpointSetterChangesOnlyTheSelectedInput(channel: LevelsChannel, point: LevelsPickerPoint) throws {
        let baseline = fixture()
        let sample = LevelsPickerSample(red: 0.2, green: 0.3, blue: 0.4)
        let actual = try LevelsPickerProposal.applying(sample: sample, point: point, mode: .setTone, channel: channel, to: baseline)
        let value = channel == .red ? 0.2 : channel == .green ? 0.3 : 0.4
        var expected = baseline
        if point == .black { expected.levels[channel].inputBlack = value }
        else { expected.levels[channel].inputWhite = value }
        #expect(actual == expected)
    }

    @Test(arguments: [LevelsPickerPoint.black, .white])
    func rgbEndpointsNeutralizeOnlyTheCorrespondingMasterParameter(point: LevelsPickerPoint) throws {
        var baseline = fixture()
        baseline.levels.master = .init(inputBlack: 0.15, inputWhite: 0.85, gamma: 1.8,
            outputBlack: 0.05, outputWhite: 0.9, clampInput: true, clampOutput: true)
        baseline.levels.red.gamma = 1.3; baseline.levels.green.gamma = 1.6; baseline.levels.blue.gamma = 0.8
        let sample = LevelsPickerSample(red: 0.2, green: 0.3, blue: 0.4)
        let actual = try LevelsPickerProposal.applying(sample: sample, point: point, mode: .neutralizeRGB, channel: .blue, to: baseline)
        var expected = baseline
        if point == .black {
            expected.levels.master.inputBlack = 0
            expected.levels.red.inputBlack = 0.2; expected.levels.green.inputBlack = 0.3; expected.levels.blue.inputBlack = 0.4
        } else {
            expected.levels.master.inputWhite = 1
            expected.levels.red.inputWhite = 0.2; expected.levels.green.inputWhite = 0.3; expected.levels.blue.inputWhite = 0.4
        }
        #expect(actual == expected)
        let values = referenceRGB(sample, levels: actual.levels)
        #expect(abs(values[0] - values[1]) < 1e-12 && abs(values[1] - values[2]) < 1e-12)
    }

    @Test(arguments: [false, true])
    func rgbGrayInvertsTheProposedMasterAndCommonOutputBoundsAndIsIdempotent(nonNeutralOutputs: Bool) throws {
        var baseline = fixture(version: .consistentV2)
        baseline.levels.master = .init(inputBlack: 0.1, inputWhite: 0.8, gamma: 2,
            outputBlack: 0.05, outputWhite: 0.9, clampInput: true, clampOutput: true)
        let outBlack = nonNeutralOutputs ? 0.1 : 0, outWhite = nonNeutralOutputs ? 0.9 : 1
        baseline.levels.red = .init(inputBlack: 0.02, inputWhite: 0.9, gamma: 1.7, outputBlack: outBlack, outputWhite: outWhite)
        baseline.levels.green = .init(inputBlack: 0.03, inputWhite: 0.85, gamma: 0.7, outputBlack: outBlack, outputWhite: outWhite, clampInput: true)
        baseline.levels.blue = .init(inputBlack: 0.04, inputWhite: 0.8, gamma: 1.4, outputBlack: outBlack, outputWhite: outWhite, clampOutput: true)
        let sample = LevelsPickerSample(red: 0.25, green: 0.4, blue: 0.6)
        let actual = try LevelsPickerProposal.applying(sample: sample, point: .gray, mode: .neutralizeRGB, to: baseline)
        let desiredChannelOutput = 0.1 + ((0.5 - 0.05) / (0.9 - 0.05)) * (0.8 - 0.1)
        let desiredPower = (desiredChannelOutput - outBlack) / (outWhite - outBlack)
        for (value, old, proposed) in [(sample.red, baseline.levels.red, actual.levels.red),
                                       (sample.green, baseline.levels.green, actual.levels.green),
                                       (sample.blue, baseline.levels.blue, actual.levels.blue)] {
            let expected = log((value - old.inputBlack) / (old.inputWhite - old.inputBlack)) / log(desiredPower)
            #expect(abs(proposed.gamma - expected) < 1e-12)
            var withoutGamma = proposed; withoutGamma.gamma = old.gamma
            #expect(withoutGamma == old)
        }
        var master = baseline.levels.master; master.gamma = 1
        #expect(actual.levels.master == master)
        for value in referenceRGB(sample, levels: actual.levels) { #expect(abs(value - 0.5) < 1e-12) }
        var onlyLevels = actual; onlyLevels.levels = baseline.levels
        #expect(onlyLevels == baseline)
        #expect(try LevelsPickerProposal.applying(sample: sample, point: .gray, mode: .neutralizeRGB, to: actual) == actual)
    }

    @Test func anUnclampedMasterCanBeInvertedAtItsInputAnchor() throws {
        var baseline = fixture()
        baseline.levels.master = .init(inputBlack: 0.3, inputWhite: 0.9, gamma: 2, outputBlack: 0.5, clampOutput: true)
        let sample = LevelsPickerSample(red: 0.2, green: 0.3, blue: 0.4)
        let actual = try LevelsPickerProposal.applying(sample: sample, point: .gray, mode: .neutralizeRGB, to: baseline)
        for value in referenceRGB(sample, levels: actual.levels) { #expect(abs(value - 0.5) < 1e-12) }
    }

    @Test func aNarrowExpansiveMasterRejectsAFalseDoubleOnlyNeutralization() throws {
        var baseline = fixture()
        baseline.levels.master = .init(inputBlack: 0.4999, inputWhite: 0.5001, gamma: 2)
        let common = LevelsCurve(outputBlack: 0.4999, outputWhite: 0.5001)
        baseline.levels.red = common; baseline.levels.green = common; baseline.levels.blue = common
        let sample = LevelsPickerSample(red: 0.25, green: 0.36, blue: 0.49)
        let frozen = baseline
        // All endpoints and noncollapsed Float spans are legal. The analytic
        // solution hits exactly 0.5, but Float channel rounding is expanded by
        // the master to approximately 0.49992549, outside the target tolerance.
        var analytical = baseline.levels
        analytical.master.gamma = 1
        analytical.red.gamma = 2
        analytical.green.gamma = log(sample.green) / log(0.5)
        analytical.blue.gamma = log(sample.blue) / log(0.5)
        try analytical.validate()
        for output in referenceRGB(sample, levels: analytical) { #expect(abs(output - 0.5) < 1e-12) }
        #expect(throws: LevelsPickerError.unreachableTarget) {
            try LevelsPickerProposal.applying(sample: sample, point: .gray, mode: .neutralizeRGB, to: baseline)
        }
        #expect(baseline == frozen)
    }

    @Test func aNarrowMasterRejectsANeutralizationThatDependsOnUnfusedRounding() throws {
        var baseline = fixture()
        baseline.levels.master = .init(inputBlack: 0.5999389886856079,
            inputWhite: 0.6000610589981079, gamma: 2)
        let common = LevelsCurve(outputBlack: 0.09100380700547248, outputWhite: 0.7120575812412425)
        baseline.levels.red = common; baseline.levels.green = common; baseline.levels.blue = common
        let sample = LevelsPickerSample(red: 0.25, green: 0.25, blue: 0.25)
        let frozen = baseline
        let targetOutput = baseline.levels.master.inputBlack +
            0.5 * (baseline.levels.master.inputWhite - baseline.levels.master.inputBlack)
        let targetPower = (targetOutput - common.outputBlack) / (common.outputWhite - common.outputBlack)
        let gamma = log(0.25) / log(targetPower)
        let power: Float = pow(Float(0.25), 1 / Float(gamma))
        let black = Float(common.outputBlack), span = Float(common.outputWhite) - black
        let product = power * span
        let separate = black + product
        let fused = black.addingProduct(power, span)
        let masterBlack = Float(baseline.levels.master.inputBlack)
        let masterSpan = Float(baseline.levels.master.inputWhite) - masterBlack
        #expect((separate - masterBlack) / masterSpan == 0.5)
        #expect(abs((fused - masterBlack) / masterSpan - 0.5) > LevelsPickerProposal.neutralizationTargetTolerance)
        #expect(throws: LevelsPickerError.unreachableTarget) {
            try LevelsPickerProposal.applying(sample: sample, point: .gray, mode: .neutralizeRGB, to: baseline)
        }
        #expect(baseline == frozen)
    }

    @Test(arguments: LevelsPickerPoint.allCases)
    func unequalRGBOutputBoundsRejectTheEntireNeutralizingProposal(point: LevelsPickerPoint) throws {
        var baseline = fixture(); baseline.levels.blue.outputWhite = 0.9
        let frozen = baseline
        #expect(throws: LevelsPickerError.differentOutputBounds) {
            try LevelsPickerProposal.applying(sample: .init(red: 0.2, green: 0.3, blue: 0.4), point: point, mode: .neutralizeRGB, to: baseline)
        }
        #expect(baseline == frozen)
    }

    @Test func nonInvertibleAndUnreachableRGBGrayTargetsNeverPartiallyResetMaster() throws {
        let masters = [LevelsCurve(gamma: 2, outputBlack: 0.5, outputWhite: 0.5),
            .init(gamma: 2, outputBlack: 0.5, outputWhite: 0.500_000_001),
            .init(gamma: 2, outputBlack: 0.5, clampInput: true),
            .init(gamma: 2, outputBlack: 0.8, outputWhite: 0.9, clampInput: true),
            .init(gamma: 2, outputBlack: 0.8, outputWhite: 0.9)]
        for master in masters {
            var baseline = fixture(); baseline.levels.master = master
            let frozen = baseline
            #expect(throws: (any Error).self) {
                try LevelsPickerProposal.applying(sample: .init(red: 0.2, green: 0.3, blue: 0.4), point: .gray, mode: .neutralizeRGB, to: baseline)
            }
            #expect(baseline == frozen)
        }
        var constantChannels = fixture()
        constantChannels.levels.red.outputBlack = 0.5; constantChannels.levels.red.outputWhite = 0.5
        constantChannels.levels.green = constantChannels.levels.red; constantChannels.levels.blue = constantChannels.levels.red
        #expect(throws: LevelsPickerError.nonInvertibleTarget) {
            try LevelsPickerProposal.applying(sample: .init(red: 0.2, green: 0.3, blue: 0.4), point: .gray, mode: .neutralizeRGB, to: constantChannels)
        }
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonfiniteSamplesAreAlwaysRejected(value: Double) throws {
        for mode in LevelsPickerMode.allCases {
            for point in LevelsPickerPoint.allCases {
                #expect(throws: LevelsPickerError.invalidSample) {
                    try LevelsPickerProposal.applying(sample: .init(red: value, green: 0.3, blue: 0.4), point: point, mode: mode, to: fixture())
                }
            }
        }
    }

    @Test(arguments: [-0.1, 0.0, 0.000_001, 0.0001, 0.99, 0.999_999, 1, 4])
    func invalidMidtonesAndOutOfRangeGammaAreRejectedWithoutClamping(value: Double) throws {
        #expect(throws: (any Error).self) {
            try LevelsPickerProposal.applying(sample: .init(red: value, green: 0.4, blue: 0.5), point: .gray, mode: .setTone, channel: .red, to: fixture())
        }
    }

    @Test func crossedEndpointsAndAFloatCollapsedSpanAreRejected() throws {
        let baseline = fixture()
        for (point, sample) in [(LevelsPickerPoint.black, 1.0), (.white, 0.0), (.black, -0.1), (.white, 4)] {
            #expect(throws: LevelsPickerError.invalidEndpoints) {
                try LevelsPickerProposal.applying(sample: .init(red: sample, green: 0.2, blue: 0.3), point: point, mode: .setTone, channel: .red, to: baseline)
            }
        }
        var narrow = baseline
        let black = 0.0003
        narrow.levels.red.inputBlack = black
        #expect(throws: LevelsPickerError.invalidEndpoints) {
            try LevelsPickerProposal.applying(sample: .init(red: black + LevelsCurve.minimumInputSpan, green: 0.2, blue: 0.3), point: .white, mode: .setTone, channel: .red, to: narrow)
        }
    }

    private func fixture(version: ToneProcessingVersion = .legacyV1) -> EditSettings {
        .init(exposure: 0.7, contrast: 17, shadows: 12, texture: 10, naturalBalanceAmount: 23,
              developColor: .init(temperature: 7_500, tint: -8, profile: .vivid),
              developGeometry: .init(quarterTurns: 1, flipHorizontal: true), toneProcessingVersion: version)
    }

    private func referenceRGB(_ sample: LevelsPickerSample, levels: LevelsSettings) -> [Double] {
        [(sample.red, levels.red), (sample.green, levels.green), (sample.blue, levels.blue)].map {
            reference(reference($0.0, curve: $0.1), curve: levels.master)
        }
    }

    private func reference(_ value: Double, curve: LevelsCurve) -> Double {
        var u = (value - curve.inputBlack) / (curve.inputWhite - curve.inputBlack)
        if curve.clampInput { u = min(1, max(0, u)) }
        let v = u > 0 ? pow(u, 1 / curve.gamma) : u
        let y = curve.outputBlack + v * (curve.outputWhite - curve.outputBlack)
        return curve.clampOutput ? min(1, max(0, y)) : y
    }
}
