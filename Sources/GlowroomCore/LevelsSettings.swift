import Foundation

/// Levels operate on straight RGB in the explicitly encoded, sign-preserving
/// sRGB domain. This identifies the levels node, not the surrounding tone graph.
public enum LevelsTransferFunction: String, Codable, Hashable, Sendable {
    case signedSRGB
}

public enum LevelsVersion: Int, Codable, Hashable, Sendable {
    case v1 = 1
}

public enum LevelsChannel: String, Codable, CaseIterable, Hashable, Sendable {
    case master, red, green, blue
}

public enum LevelsValidationError: Error, Equatable, Sendable {
    case invalidCurve
    case unrepresentableValue
}

/// A monotone point curve. Input and output clamps are independent opt-ins;
/// without them negative values and highlight headroom are retained. Gamma > 1
/// brightens midtones. Equal output endpoints intentionally produce a constant.
public struct LevelsCurve: Codable, Hashable, Sendable {
    public static let parameterRange = 0.0...1.0
    public static let gammaRange = 0.1...10.0
    public static let minimumInputSpan = 0.000_1

    public var inputBlack: Double
    public var inputWhite: Double
    public var gamma: Double
    public var outputBlack: Double
    public var outputWhite: Double
    public var clampInput: Bool
    public var clampOutput: Bool

    public init(inputBlack: Double = 0, inputWhite: Double = 1, gamma: Double = 1,
                outputBlack: Double = 0, outputWhite: Double = 1,
                clampInput: Bool = false, clampOutput: Bool = false) {
        self.inputBlack = inputBlack; self.inputWhite = inputWhite; self.gamma = gamma
        self.outputBlack = outputBlack; self.outputWhite = outputWhite
        self.clampInput = clampInput; self.clampOutput = clampOutput
    }

    public static let neutral = Self()
    public var isNeutral: Bool { self == .neutral }

    /// UI edits should retain their last valid pair when endpoints cross.
    /// This fallback is for deterministic normalization of programmatic values;
    /// decoding instead rejects invalid persisted parameters.
    public var normalized: Self {
        func bounded(_ value: Double, fallback: Double, range: ClosedRange<Double>) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        var black = min(bounded(inputBlack, fallback: 0, range: Self.parameterRange), 1 - Self.minimumInputSpan)
        if 1 - black < Self.minimumInputSpan { black = black.nextDown }
        var white = max(bounded(inputWhite, fallback: 1, range: Self.parameterRange), black + Self.minimumInputSpan)
        if white - black < Self.minimumInputSpan { white = white.nextUp }
        // Uniforms are Float. A mathematically sufficient Double span may round
        // below the minimum when its two endpoints are converted separately.
        if Float(white) - Float(black) < Float(Self.minimumInputSpan) {
            // Float addition can already round to one, whose nextUp lies
            // outside the domain. One leaves a valid span with bounded black.
            white = min(1, max(white, Double((Float(black) + Float(Self.minimumInputSpan)).nextUp)))
        }
        let outputBlack = bounded(outputBlack, fallback: 0, range: Self.parameterRange)
        return Self(inputBlack: black, inputWhite: white,
                    gamma: bounded(gamma, fallback: 1, range: Self.gammaRange),
                    outputBlack: outputBlack,
                    outputWhite: max(outputBlack, bounded(outputWhite, fallback: 1, range: Self.parameterRange)),
                    clampInput: clampInput, clampOutput: clampOutput)
    }

    public func validate() throws {
        guard [inputBlack, inputWhite, outputBlack, outputWhite].allSatisfy({ $0.isFinite && Self.parameterRange.contains($0) }),
              gamma.isFinite, Self.gammaRange.contains(gamma),
              inputWhite >= inputBlack + Self.minimumInputSpan,
              inputWhite - inputBlack >= Self.minimumInputSpan,
              Float(inputWhite) - Float(inputBlack) >= Float(Self.minimumInputSpan),
              outputWhite >= outputBlack else { throw LevelsValidationError.invalidCurve }
    }

    /// Independent scalar reference, with no transfer conversion or alpha work.
    /// A renderer must unpremultiply first and reapply the original alpha after
    /// all three channel curves and the master curve have been evaluated.
    public func value(for input: Double) throws -> Double {
        try validate()
        try Self.requireFloat(input)
        let offset = input - inputBlack
        try Self.requireFloat(offset)
        var normalized = offset / (inputWhite - inputBlack)
        try Self.requireFloat(normalized)
        if clampInput { normalized = min(max(normalized, 0), 1) }
        let curved = normalized > 0 ? pow(normalized, 1 / gamma) : normalized
        try Self.requireFloat(curved)
        let scaled = curved * (outputWhite - outputBlack)
        try Self.requireFloat(scaled)
        let result = outputBlack + scaled
        try Self.requireFloat(result)
        return clampOutput ? min(max(result, 0), 1) : result
    }

    /// Certifies the entire supplied input interval before constructing a lazy
    /// Float kernel. Every arithmetic intermediate must fit Float, including
    /// powers that a later output clamp might otherwise hide. Monotonicity makes
    /// endpoint propagation sufficient; this tiny bounded reduction stays serial.
    /// Callers must supply a proven input range or reject the render.
    public func validatedOutputRange(for input: ClosedRange<Double>) throws -> ClosedRange<Double> {
        try validate()
        try Self.requireFloat(input.lowerBound); try Self.requireFloat(input.upperBound)
        // Use the actual uniform precision, and round every interval outward to
        // Float after each operation. A Double-only estimate can miss overflow
        // after a rounded gamma exponent or narrowly separated input endpoints.
        let black = Double(Float(inputBlack))
        let exponent = Double(1 / Float(gamma))
        let span = Double(Float(inputWhite) - Float(inputBlack))
        var range = try Self.floatBounds(input.lowerBound, input.upperBound)
        range = try Self.floatBounds(range.lowerBound - black, range.upperBound - black)
        range = try Self.floatBounds(range.lowerBound / span, range.upperBound / span)
        if clampInput { range = min(max(range.lowerBound, 0), 1)...min(max(range.upperBound, 0), 1) }
        func power(_ value: Double) -> Double { value > 0 ? pow(value, exponent) : value }
        range = try Self.floatBounds(power(range.lowerBound), power(range.upperBound))
        let outputSpan = Double(Float(outputWhite) - Float(outputBlack))
        range = try Self.floatBounds(range.lowerBound * outputSpan, range.upperBound * outputSpan)
        let outputBlack = Double(Float(outputBlack))
        range = try Self.floatBounds(range.lowerBound + outputBlack, range.upperBound + outputBlack)
        if clampOutput { range = min(max(range.lowerBound, 0), 1)...min(max(range.upperBound, 0), 1) }
        // Keep validation of the independent Double reference too. The shader's
        // Float parameters are not allowed to hide an invalid reference curve.
        _ = try value(for: input.lowerBound); _ = try value(for: input.upperBound)
        return range
    }

    private static func floatBounds(_ lower: Double, _ upper: Double) throws -> ClosedRange<Double> {
        try requireFloat(lower); try requireFloat(upper)
        var low = Float(lower), high = Float(upper)
        if Double(low) > lower { low = low.nextDown }
        if Double(high) < upper { high = high.nextUp }
        try requireFloat(Double(low)); try requireFloat(Double(high))
        return Double(low)...Double(high)
    }

    private static func requireFloat(_ value: Double) throws {
        guard value.isFinite, abs(value) <= Double(Float.greatestFiniteMagnitude) else {
            throw LevelsValidationError.unrepresentableValue
        }
    }

    private enum CodingKeys: String, CodingKey {
        case inputBlack, inputWhite, gamma, outputBlack, outputWhite, clampInput, clampOutput
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(inputBlack: try values.decode(Double.self, forKey: .inputBlack),
                  inputWhite: try values.decode(Double.self, forKey: .inputWhite),
                  gamma: try values.decode(Double.self, forKey: .gamma),
                  outputBlack: try values.decode(Double.self, forKey: .outputBlack),
                  outputWhite: try values.decode(Double.self, forKey: .outputWhite),
                  clampInput: try values.decode(Bool.self, forKey: .clampInput),
                  clampOutput: try values.decode(Bool.self, forKey: .clampOutput))
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(inputBlack, forKey: .inputBlack); try values.encode(inputWhite, forKey: .inputWhite)
        try values.encode(gamma, forKey: .gamma)
        try values.encode(outputBlack, forKey: .outputBlack); try values.encode(outputWhite, forKey: .outputWhite)
        try values.encode(clampInput, forKey: .clampInput); try values.encode(clampOutput, forKey: .clampOutput)
    }
}

/// Global levels only: independent R/G/B curves run first, followed by the same
/// master curve on every component. The master curve does not preserve hue.
/// Omission of a neutral component in EditSettings preserves historical bytes.
public struct LevelsSettings: Codable, Hashable, Sendable {
    public var master: LevelsCurve
    public var red: LevelsCurve
    public var green: LevelsCurve
    public var blue: LevelsCurve
    public var transferFunction: LevelsTransferFunction
    public var version: LevelsVersion

    public init(master: LevelsCurve = .neutral, red: LevelsCurve = .neutral,
                green: LevelsCurve = .neutral, blue: LevelsCurve = .neutral,
                transferFunction: LevelsTransferFunction = .signedSRGB, version: LevelsVersion = .v1) {
        self.master = master; self.red = red; self.green = green; self.blue = blue
        self.transferFunction = transferFunction; self.version = version
    }
    public static let neutral = Self()
    public var isNeutral: Bool { self == .neutral }
    public var normalized: Self {
        Self(master: master.normalized, red: red.normalized, green: green.normalized, blue: blue.normalized,
             transferFunction: transferFunction, version: version)
    }
    public subscript(channel: LevelsChannel) -> LevelsCurve {
        get {
            switch channel { case .master: master; case .red: red; case .green: green; case .blue: blue }
        }
        set {
            switch channel { case .master: master = newValue; case .red: red = newValue; case .green: green = newValue; case .blue: blue = newValue }
        }
    }
    public func validate() throws {
        try master.validate(); try red.validate(); try green.validate(); try blue.validate()
    }
    public func rgb(red: Double, green: Double, blue: Double) throws -> (red: Double, green: Double, blue: Double) {
        try validate()
        return (try master.value(for: self.red.value(for: red)),
                try master.value(for: self.green.value(for: green)),
                try master.value(for: self.blue.value(for: blue)))
    }
    /// Bounds are in this node's encoded straight-RGB domain. A renderer must
    /// validate each channel then master; validating only one curve is unsafe.
    public func validatedOutputRanges(red: ClosedRange<Double>, green: ClosedRange<Double>, blue: ClosedRange<Double>) throws
        -> (red: ClosedRange<Double>, green: ClosedRange<Double>, blue: ClosedRange<Double>) {
        try validate()
        return (try master.validatedOutputRange(for: self.red.validatedOutputRange(for: red)),
                try master.validatedOutputRange(for: self.green.validatedOutputRange(for: green)),
                try master.validatedOutputRange(for: self.blue.validatedOutputRange(for: blue)))
    }
}
