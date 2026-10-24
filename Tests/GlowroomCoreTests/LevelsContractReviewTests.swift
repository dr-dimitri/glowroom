import Foundation
import Testing
@testable import GlowroomCore

@Suite("Levels contract review regressions")
struct LevelsContractReviewTests {
    @Test func aConstantOutputDoesNotHideAnUnrepresentablePower() {
        let curve = LevelsCurve(inputWhite: 0.000_1, gamma: 0.1,
                                outputBlack: 0.5, outputWhite: 0.5)
        #expect(throws: LevelsValidationError.unrepresentableValue) {
            try curve.validatedOutputRange(for: 0...4)
        }
    }

    @Test func anOutputClampDoesNotHideAnUnrepresentablePower() {
        let curve = LevelsCurve(inputWhite: 0.000_1, gamma: 0.1, clampOutput: true)
        #expect(throws: LevelsValidationError.unrepresentableValue) {
            try curve.validatedOutputRange(for: 0...4)
        }
    }

    @Test func floatExponentRoundingIsIncludedInRangeCertification() {
        // The Double reference power is below Float.max. Rounded Float input,
        // gamma and reciprocal exponent overflow the actual Float operation.
        let input = 102_126.64
        let curve = LevelsCurve(gamma: 0.13)
        #expect(pow(input, 1 / curve.gamma) < Double(Float.greatestFiniteMagnitude))
        #expect(throws: LevelsValidationError.unrepresentableValue) {
            try curve.validatedOutputRange(for: 0...input)
        }
    }

    @Test(arguments: [0.000_3, 0.1, 0.3, 0.5, 0.9, 1.0])
    func normalizationLeavesAValidDoubleAndFloatInputSpan(black: Double) throws {
        let curve = LevelsCurve(inputBlack: black, inputWhite: black).normalized
        try curve.validate()
        #expect(curve.inputWhite - curve.inputBlack >= LevelsCurve.minimumInputSpan)
        #expect(Float(curve.inputWhite) - Float(curve.inputBlack) >= Float(LevelsCurve.minimumInputSpan))
        #expect(curve.normalized == curve)
    }

    @Test func inputValidationRejectsASpanThatShrinksBelowTheFloatMinimum() {
        let black = 0.000_3
        let curve = LevelsCurve(inputBlack: black,
                                inputWhite: black + LevelsCurve.minimumInputSpan)
        #expect(Float(curve.inputWhite) - Float(curve.inputBlack) < Float(LevelsCurve.minimumInputSpan))
        #expect(throws: LevelsValidationError.invalidCurve) { try curve.validate() }
    }
}
