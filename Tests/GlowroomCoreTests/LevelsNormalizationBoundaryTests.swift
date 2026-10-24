import Testing
@testable import GlowroomCore

@Suite("Levels normalization at Float endpoint boundaries")
struct LevelsNormalizationBoundaryTests {
    @Test(arguments: [0.999_899_953_6, 0.999_899_96, 0.999_899_97, 0.999_9, 1.0])
    func aFloatSpanCorrectionNeverPromotesWhitePastOne(black: Double) throws {
        let value = LevelsCurve(inputBlack: black, inputWhite: black).normalized
        try value.validate()
        #expect((0...1).contains(value.inputWhite))
        #expect(value.inputWhite - value.inputBlack >= LevelsCurve.minimumInputSpan)
        #expect(Float(value.inputWhite) - Float(value.inputBlack) >= Float(LevelsCurve.minimumInputSpan))
        #expect(value.normalized == value)
    }

    @Test func normalizedEndpointNeighborhoodsRemainValidAndIdempotent() throws {
        for index in 0...1_024 {
            let black = 0.999_89 + Double(index) * 0.000_000_02
            let value = LevelsCurve(inputBlack: black, inputWhite: black + 0.000_099_999).normalized
            try value.validate()
            #expect(value.normalized == value)
        }
    }
}
