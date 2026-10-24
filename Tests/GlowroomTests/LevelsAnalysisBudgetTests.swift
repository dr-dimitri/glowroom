import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Levels picker full-graph admission")
struct LevelsAnalysisBudgetTests {
    @Test(arguments: [ToneProcessingVersion.legacyV1, .consistentV2], [0.0, 50.0])
    func fullValidationIncludesSharpeningButSamplingExcludesTheSuffix(version: ToneProcessingVersion, masking: Double) throws {
        let bitmap = try levelsTransactionBitmap(edge: 16)
        var settings = EditSettings(levels: .init(master: .init(gamma: 1.1)), toneProcessingVersion: version)
        let baseline = try AutomaticToneEstimator.levelsAnalysisAdditionalBytes(bitmap: bitmap, settings: settings, validating: true)
        let sampleBaseline = try AutomaticToneEstimator.levelsAnalysisAdditionalBytes(bitmap: bitmap, settings: settings, validating: false)
        settings.sharpeningAmount = 80; settings.sharpeningMasking = masking
        let full = try AutomaticToneEstimator.levelsAnalysisAdditionalBytes(bitmap: bitmap, settings: settings, validating: true)
        #expect(full - baseline == Int64(16 * 16) * Int64(DevelopSharpening.additionalBytesPerPixel(settings: settings)))
        #expect(try AutomaticToneEstimator.levelsAnalysisAdditionalBytes(bitmap: bitmap, settings: settings, validating: false) == sampleBaseline)
    }
}

@Suite("Levels native gray target certificate")
struct LevelsNeutralizationValidationTests {
    @Test(arguments: [false, true])
    func actualBackendVerifiesTheProposedTargetAndRejectsAWrongTarget(softwarePreference: Bool) throws {
        let sample = LevelsPickerSample(red: 0.25, green: 0.2, blue: 0.3)
        let initial = EditSettings(levels: .init(master: .init(inputBlack: 0.1, inputWhite: 0.9, gamma: 2)))
        let proposal = try LevelsPickerProposal.applying(sample: sample, point: .gray,
            mode: .neutralizeRGB, channel: .master, to: initial)
        let session = EditRenderer.Session(lowPriority: true, softwareRenderer: softwarePreference)
        let context = session.context(for: proposal)
        try LevelsRenderer.validateNeutralGray(sample: sample, settings: proposal.levels, context: context)
        var wrong = proposal.levels; wrong.master.gamma = 2
        #expect(throws: LevelsPickerError.unreachableTarget) {
            try LevelsRenderer.validateNeutralGray(sample: sample, settings: wrong, context: context)
        }
    }
}
