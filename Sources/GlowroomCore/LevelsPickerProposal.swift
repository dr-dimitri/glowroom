import Foundation

/// Independent, deterministic picker mathematics. The caller publishes this
/// complete value once, after checking its captured source/revision/session.
public enum LevelsPickerProposal {
    /// Numerical margin before either logarithm. This is rejection, not a
    /// silent adjustment to the sample or to the accepted gamma range.
    public static let logarithmEpsilon = 0.000_001
    /// The explicit RGB-gray target is also certified with the renderer's
    /// Float uniforms and arithmetic. Eight unit ULPs allow ordinary rounding,
    /// but reject narrow curves that amplify it into a different visible target.
    public static let neutralizationTargetTolerance = 8 * Float.ulpOfOne

    public static func applying(sample: LevelsPickerSample, point: LevelsPickerPoint,
                                mode: LevelsPickerMode, channel: LevelsChannel = .master,
                                to settings: EditSettings) throws -> EditSettings {
        try sample.validate()
        do { _ = try EditingSnapshot(settings: settings) }
        catch { throw LevelsPickerError.invalidSettings }
        var result = settings
        switch mode {
        case .setTone:
            let measured: Double
            switch channel {
            case .red: measured = sample.red
            case .green: measured = sample.green
            case .blue: measured = sample.blue
            case .master:
                // The unchanged individual curves precede master. Measuring
                // max(raw RGB) would target the wrong node when they are active.
                do {
                    let red = try settings.levels.red.value(for: sample.red)
                    let green = try settings.levels.green.value(for: sample.green)
                    let blue = try settings.levels.blue.value(for: sample.blue)
                    measured = max(red, max(green, blue))
                } catch { throw LevelsPickerError.invalidSample }
            }
            result.levels[channel] = try setting(point, measured: measured, curve: settings.levels[channel])
        case .neutralizeRGB:
            let levels = settings.levels
            guard levels.red.outputBlack == levels.green.outputBlack,
                  levels.red.outputBlack == levels.blue.outputBlack,
                  levels.red.outputWhite == levels.green.outputWhite,
                  levels.red.outputWhite == levels.blue.outputWhite else {
                throw LevelsPickerError.differentOutputBounds
            }
            switch point {
            case .black: result.levels.master.inputBlack = 0
            case .white: result.levels.master.inputWhite = 1
            case .gray: result.levels.master.gamma = 1
            }
            let target: Double
            if point == .gray {
                // Invert the PROPOSED complete master, with gamma already one.
                // Its other endpoints and both clamps remain active.
                let channelOutput = try inverseMasterHalf(result.levels.master)
                let outputSpan = levels.red.outputWhite - levels.red.outputBlack
                guard outputSpan > 0,
                      Float(levels.red.outputWhite) > Float(levels.red.outputBlack) else {
                    throw LevelsPickerError.nonInvertibleTarget
                }
                target = (channelOutput - levels.red.outputBlack) / outputSpan
                guard interior(target) else { throw LevelsPickerError.unreachableTarget }
            } else { target = 0.5 } // Unused by endpoint setters.
            result.levels.red = try setting(point, measured: sample.red, curve: levels.red, target: target)
            result.levels.green = try setting(point, measured: sample.green, curve: levels.green, target: target)
            result.levels.blue = try setting(point, measured: sample.blue, curve: levels.blue, target: target)
            if point == .gray { try validateFloatNeutralization(sample: sample, levels: result.levels) }
        }
        // Never normalize: invalid proposals must retain every old parameter.
        do { _ = try EditingSnapshot(settings: result) }
        catch { throw LevelsPickerError.invalidEndpoints }
        return result
    }

    private static func setting(_ point: LevelsPickerPoint, measured: Double,
                                curve: LevelsCurve, target: Double = 0.5) throws -> LevelsCurve {
        var proposed = curve
        switch point {
        case .black: proposed.inputBlack = measured
        case .white: proposed.inputWhite = measured
        case .gray:
            let normalized = (measured - curve.inputBlack) / (curve.inputWhite - curve.inputBlack)
            guard interior(normalized), interior(target) else { throw LevelsPickerError.degenerateMidtone }
            let gamma = log(normalized) / log(target)
            guard gamma.isFinite, LevelsCurve.gammaRange.contains(gamma) else {
                throw LevelsPickerError.gammaOutsideRange
            }
            proposed.gamma = gamma
        }
        do { try proposed.validate() }
        catch { throw LevelsPickerError.invalidEndpoints }
        return proposed
    }

    private static func inverseMasterHalf(_ master: LevelsCurve) throws -> Double {
        let span = master.outputWhite - master.outputBlack
        guard span > 0, Float(master.outputWhite) > Float(master.outputBlack) else {
            throw LevelsPickerError.nonInvertibleTarget
        }
        let normalized = (0.5 - master.outputBlack) / span
        guard normalized.isFinite else { throw LevelsPickerError.unreachableTarget }
        // An interior final target is never on an output-clamp plateau. An
        // input-clamp endpoint, however, has infinitely many inverse inputs.
        if master.clampInput {
            guard normalized >= 0, normalized <= 1 else { throw LevelsPickerError.unreachableTarget }
            guard Float(normalized) > 0, Float(normalized) < 1 else {
                throw LevelsPickerError.nonInvertibleTarget
            }
        }
        let value = master.inputBlack + normalized * (master.inputWhite - master.inputBlack)
        guard value.isFinite, Float(value).isFinite else { throw LevelsPickerError.unreachableTarget }
        return value
    }

    private static func interior(_ value: Double) -> Bool {
        value.isFinite && value > logarithmEpsilon && value < 1 - logarithmEpsilon
    }

    private static func validateFloatNeutralization(sample: LevelsPickerSample, levels: LevelsSettings) throws {
        // The analytic inverse uses Double, while CI receives Float uniforms.
        // A nonzero output span alone does not prove that 0.5 survives an
        // expansive master. Evaluate the COMPLETE proposed channel+master on
        // the encoded probe at that precision. Reject; never adjust the target,
        // endpoints or gamma. This complements the caller's full-graph finite
        // certificate rather than replacing it with a sampled overflow check.
        for (input, channel) in [(sample.red, levels.red), (sample.green, levels.green), (sample.blue, levels.blue)] {
            let outputs = floatValues(Float(input), curve: channel).flatMap { floatValues($0, curve: levels.master) }
            guard outputs.allSatisfy({ $0.isFinite && abs($0 - 0.5) <= neutralizationTargetTolerance }) else {
                throw LevelsPickerError.unreachableTarget
            }
        }
    }

    private static func floatValues(_ input: Float, curve: LevelsCurve) -> [Float] {
        let black = Float(curve.inputBlack), white = Float(curve.inputWhite)
        var normalized = (input - black) / (white - black)
        if curve.clampInput { normalized = min(max(normalized, 0), 1) }
        let curved = normalized > 0 ? pow(normalized, 1 / Float(curve.gamma)) : normalized
        let outputBlack = Float(curve.outputBlack)
        let span = Float(curve.outputWhite) - outputBlack
        let scaled = curved * span
        // CI may contract outputBlack + curved * span into an FMA. Enumerate
        // both rounding paths at BOTH curves: a one-ULP channel difference can
        // be magnified by a narrow master. The actual native point check also
        // covers backend pow/transfer-function precision before adoption.
        let outputs = [outputBlack + scaled, outputBlack.addingProduct(curved, span)]
        return curve.clampOutput ? outputs.map { min(max($0, 0), 1) } : outputs
    }
}
