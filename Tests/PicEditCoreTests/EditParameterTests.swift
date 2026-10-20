import Foundation
import Testing
@testable import PicEditCore

@Suite("Persisted numeric editing controls")
struct EditParameterTests {
    private let baseline = EditSettings(
        exposure: 1.25, contrast: -22.5, highlights: 11.5, shadows: 10,
        whites: -13, blacks: 14, texture: 15, clarity: -16, dehaze: 17,
        vibrance: -18, saturation: 19, luminanceNoiseReduction: 20,
        colorNoiseReduction: 21, autoToneAmount: 22,
        naturalBalanceAmount: 23, naturalBalanceColorAmount: 24
    )

    @Test(arguments: EditParameter.allCases)
    func persistedIDsAndScalarBoundariesPreserveOtherControls(_ parameter: EditParameter) throws {
        let encoded = try JSONEncoder().encode(baseline)
        let persisted = try JSONDecoder().decode([String: Double].self, from: encoded)
        #expect(parameter.value(in: baseline) == persisted[parameter.rawValue])
        let expectedRange: ClosedRange<Double>
        switch parameter {
        case .exposure: expectedRange = -5...5
        case .luminanceNoiseReduction, .colorNoiseReduction, .autoToneAmount,
             .naturalBalanceAmount, .naturalBalanceColorAmount: expectedRange = 0...100
        default: expectedRange = -100...100
        }
        #expect(parameter.range == expectedRange)
        for value in [expectedRange.lowerBound, expectedRange.upperBound, 0.125] {
            let target = try parameter.applying(value, to: baseline)
            #expect(parameter.value(in: target) == value)
            for untouched in EditParameter.allCases where untouched != parameter {
                #expect(untouched.value(in: target) == untouched.value(in: baseline))
            }
        }
        for value in [expectedRange.lowerBound - 0.001, expectedRange.upperBound + 0.001] {
            #expect(throws: ArtifactContractError.invalidValue("edit parameter out of range")) {
                try parameter.applying(value, to: baseline)
            }
        }
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(throws: ArtifactContractError.invalidValue("nonfinite edit parameter")) {
                try parameter.applying(value, to: baseline)
            }
        }
    }

    @Test func scalarIDsAreUniqueAndMatchPersistedNumericSettings() throws {
        let persisted = try JSONDecoder().decode([String: Double].self, from: JSONEncoder().encode(baseline))
        #expect(EditParameter.allCases.count == 16)
        #expect(Set(EditParameter.allCases.map(\.rawValue)) == Set(persisted.keys))
    }
}
