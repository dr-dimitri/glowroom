import Testing
import PicEditCore
@testable import PicEdit

@Suite("Sharpening inspector contract")
struct SharpeningAdjustmentTests {
    @Test(arguments: [Adjustment.sharpeningAmount, .sharpeningRadius, .sharpeningDetail, .sharpeningMasking])
    func inspectorAndPersistedScalarContractAgree(_ control: Adjustment) throws {
        let parameter = try #require(EditParameter(rawValue: control.rawValue))
        #expect(control.range == parameter.range)
        #expect(control.neutralValue == parameter.value(in: .neutral))
        var settings = EditSettings(exposure: 1.25)
        let target = (control.range.lowerBound + control.range.upperBound) / 2
        settings[keyPath: control.keyPath] = target
        #expect(settings == (try parameter.applying(target, to: EditSettings(exposure: 1.25))))
        #expect(control.automaticToneControl == nil)
        if control == .sharpeningRadius {
            #expect(control.step == 0.1 && control.fractionDigits == 1)
        } else {
            #expect(control.step == 1 && control.fractionDigits == 0)
        }
    }
}
