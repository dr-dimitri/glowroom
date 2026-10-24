import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Automatic Levels source and candidate admission")
struct AutomaticLevelsAdmissionTests {
    @Test func decodedRangeWitnessIsCountedSeparatelyFromAdaptiveInput() throws {
        let bitmap = try levelsTransactionBitmap(edge: 8)
        let original = try levelsTransactionBitmap(edge: 16)
        let settings = EditSettings.neutral
        let alias = try AutomaticToneEstimator.automaticLevelsAdditionalBytes(bitmap: bitmap, sourceBitmap: bitmap, settings: settings)
        let distinct = try AutomaticToneEstimator.automaticLevelsAdditionalBytes(bitmap: bitmap, sourceBitmap: original, settings: settings)
        let independentProof = 16 * 16 * 32 + original.byteCost * 4 + original.byteCost
        #expect(distinct - alias == Int64(independentProof))
        let base = try AutomaticToneEstimator.estimatedAdditionalBytes(sourceBytes: Int64(bitmap.byteCost),
            width: 8, height: 8, version: .consistentV2, ownsSource: false, levelsActive: true)
        let extraReadback = Int64(256 * 256 * 4 * MemoryLayout<Float>.stride)
        #expect(alias == base + extraReadback)
    }

    @Test(arguments: [ToneProcessingVersion.legacyV1, .consistentV2])
    func activeGlobalSharpeningIsIncludedWithoutLocalOrGeometryWork(version: ToneProcessingVersion) throws {
        let bitmap = try levelsTransactionBitmap(edge: 8)
        let neutral = EditSettings(toneProcessingVersion: version)
        var sharpened = neutral; sharpened.sharpeningAmount = 80; sharpened.sharpeningMasking = 60
        let baseline = try AutomaticToneEstimator.automaticLevelsAdditionalBytes(bitmap: bitmap, sourceBitmap: bitmap, settings: neutral)
        let actual = try AutomaticToneEstimator.automaticLevelsAdditionalBytes(bitmap: bitmap, sourceBitmap: bitmap, settings: sharpened)
        #expect(actual - baseline == Int64(8 * 8) * Int64(DevelopSharpening.additionalBytesPerPixel(settings: sharpened)))
        sharpened.developGeometry.quarterTurns = 1
        #expect(try AutomaticToneEstimator.automaticLevelsAdditionalBytes(bitmap: bitmap, sourceBitmap: bitmap, settings: sharpened) == actual,
            "Global analysis excludes geometry; final full-graph validation has its own admission")
    }

    @Test(arguments: [false, true], [false, true])
    func precisePresenceCountsBothPassesOfEachActiveGaussian(texture: Bool, clarity: Bool) throws {
        let bitmap = try levelsTransactionBitmap(edge: 8)
        let neutral = EditSettings(toneProcessingVersion: .consistentV2)
        var settings = neutral; settings.texture = texture ? 20 : 0; settings.clarity = clarity ? 10 : 0
        let baseline = try AutomaticToneEstimator.automaticLevelsAdditionalBytes(bitmap: bitmap, sourceBitmap: bitmap, settings: neutral)
        let actual = try AutomaticToneEstimator.automaticLevelsAdditionalBytes(bitmap: bitmap, sourceBitmap: bitmap, settings: settings)
        let passes = (texture ? 2 : 0) + (clarity ? 2 : 0)
        #expect(actual - baseline == Int64(8 * 8 * passes * 16))
        let neutralValidation = try AutomaticToneEstimator.levelsAnalysisAdditionalBytes(bitmap: bitmap, settings: neutral, validating: true)
        let validation = try AutomaticToneEstimator.levelsAnalysisAdditionalBytes(bitmap: bitmap, settings: settings, validating: true)
        #expect(validation - neutralValidation == Int64(8 * 8 * passes * 16),
            "The separate full-graph validation must count the same Gaussian intermediates")
    }
}
