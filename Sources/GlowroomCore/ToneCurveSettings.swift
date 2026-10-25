import Foundation

/// Version 1: channel curves then master, after Levels, in straight signed-sRGB.
public enum ToneCurveVersion: Int, Codable, Hashable, Sendable { case v1 = 1 }
public enum ToneCurveValidationError: Error, Equatable, Sendable {
    case invalidPoints
    case unrepresentableValue
}

public struct ToneCurvePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Monotone cubic Hermite curve with Fritsch–Carlson tangent limiting. Points
/// are deliberately not repaired on decode: accepting a malformed curve could
/// silently change a saved image. UI mutations validate before publication.
public struct ToneCurve: Codable, Hashable, Sendable {
    public static let minimumPointSpacing = 0.001
    public static let maximumPointCount = 16
    public var points: [ToneCurvePoint]

    public init(points: [ToneCurvePoint] = [.init(x: 0, y: 0), .init(x: 1, y: 1)]) {
        self.points = points
    }
    public static let neutral = Self()
    /// Extra points on y=x are also an exact identity and can be omitted.
    public var isNeutral: Bool { (try? validate()) != nil && points.allSatisfy { $0.x == $0.y } }
    public var normalized: Self { (try? validate()) == nil ? .neutral : self }

    public func validate() throws {
        guard (2...Self.maximumPointCount).contains(points.count),
              points.first?.x == 0, points.last?.x == 1,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            throw ToneCurveValidationError.invalidPoints
        }
        for index in 1..<points.count {
            let previous = points[index - 1], current = points[index]
            guard current.x - previous.x >= Self.minimumPointSpacing,
                  Float(current.x) > Float(previous.x), current.y >= previous.y else {
                throw ToneCurveValidationError.invalidPoints
            }
        }
    }

    public struct Segment: Hashable, Sendable {
        public let x0: Double
        public let x1: Double
        public let y0: Double
        public let y1: Double
        /// Tangents scaled to the unit segment domain, avoiding large shader
        /// coefficients when adjacent knots are only .001 apart.
        public let tangent0: Double
        public let tangent1: Double
    }

    /// This bounded preparation (at most 16 points) stays serial; parallel work
    /// happens over pixels in the caller's existing Core Image render graph.
    public func segments() throws -> [Segment] {
        try validate()
        let count = points.count
        let secants = (0..<(count - 1)).map {
            (points[$0 + 1].y - points[$0].y) / (points[$0 + 1].x - points[$0].x)
        }
        var tangents = [Double](repeating: 0, count: count)
        tangents[0] = secants[0]; tangents[count - 1] = secants[count - 2]
        if count > 2 {
            for index in 1..<(count - 1) { tangents[index] = (secants[index - 1] + secants[index]) / 2 }
        }
        for index in 0..<(count - 1) {
            let slope = secants[index]
            if slope == 0 {
                tangents[index] = 0; tangents[index + 1] = 0
            } else {
                let a = tangents[index] / slope, b = tangents[index + 1] / slope
                let length = hypot(a, b)
                if length > 3 {
                    let scale = 3 / length
                    tangents[index] = scale * a * slope
                    tangents[index + 1] = scale * b * slope
                }
            }
        }
        return (0..<(count - 1)).map { index in
            let first = points[index], last = points[index + 1], width = last.x - first.x
            return Segment(x0: first.x, x1: last.x, y0: first.y, y1: last.y,
                           tangent0: tangents[index] * width, tangent1: tangents[index + 1] * width)
        }
    }

    /// Independent Double scalar path. The production Float kernel uses the
    /// equivalent Bernstein polynomial, not this Hermite-basis evaluation.
    public func value(for input: Double) throws -> Double {
        let segments = try segments()
        guard input.isFinite, abs(input) <= Double(Float.greatestFiniteMagnitude) else {
            throw ToneCurveValidationError.unrepresentableValue
        }
        if isNeutral { return input }
        if input < 0 { return points[0].y + input }
        if input > 1 { return points[points.count - 1].y + (input - 1) }
        let segment = segments.first { input <= $0.x1 }!
        let t = (input - segment.x0) / (segment.x1 - segment.x0)
        let square = t * t, cube = square * t
        return (2 * cube - 3 * square + 1) * segment.y0
            + (cube - 2 * square + t) * segment.tangent0
            + (-2 * cube + 3 * square) * segment.y1
            + (cube - square) * segment.tangent1
    }

    public func validatedOutputRange(for input: ClosedRange<Double>) throws -> ClosedRange<Double> {
        let lower = try value(for: input.lowerBound), upper = try value(for: input.upperBound)
        guard lower.isFinite, upper.isFinite, abs(lower) <= Double(Float.greatestFiniteMagnitude),
              abs(upper) <= Double(Float.greatestFiniteMagnitude) else { throw ToneCurveValidationError.unrepresentableValue }
        return lower...upper
    }

    private enum CodingKeys: String, CodingKey { case points }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(points: try container.decode([ToneCurvePoint].self, forKey: .points))
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
    }
}

public struct ToneCurveSettings: Codable, Hashable, Sendable {
    public var master: ToneCurve
    public var red: ToneCurve
    public var green: ToneCurve
    public var blue: ToneCurve
    public var transferFunction: LevelsTransferFunction
    public var version: ToneCurveVersion

    public init(master: ToneCurve = .neutral, red: ToneCurve = .neutral, green: ToneCurve = .neutral,
                blue: ToneCurve = .neutral, transferFunction: LevelsTransferFunction = .signedSRGB,
                version: ToneCurveVersion = .v1) {
        self.master = master; self.red = red; self.green = green; self.blue = blue
        self.transferFunction = transferFunction; self.version = version
    }
    public static let neutral = Self()
    public var isNeutral: Bool { master.isNeutral && red.isNeutral && green.isNeutral && blue.isNeutral }
    public var normalized: Self {
        let result = Self(master: master.normalized, red: red.normalized, green: green.normalized, blue: blue.normalized,
                          transferFunction: transferFunction, version: version)
        // EditSettings omits a neutral component. Its typed value must therefore
        // match the two-point value obtained when that absent field is decoded.
        return result.isNeutral ? .neutral : result
    }
    public subscript(channel: LevelsChannel) -> ToneCurve {
        get { switch channel { case .master: master; case .red: red; case .green: green; case .blue: blue } }
        set { switch channel { case .master: master = newValue; case .red: red = newValue; case .green: green = newValue; case .blue: blue = newValue } }
    }
    public func validate() throws { try master.validate(); try red.validate(); try green.validate(); try blue.validate() }
    public func rgb(red: Double, green: Double, blue: Double) throws -> (red: Double, green: Double, blue: Double) {
        (try master.value(for: self.red.value(for: red)), try master.value(for: self.green.value(for: green)),
         try master.value(for: self.blue.value(for: blue)))
    }
    public func validatedOutputRanges(red: ClosedRange<Double>, green: ClosedRange<Double>, blue: ClosedRange<Double>) throws
        -> (red: ClosedRange<Double>, green: ClosedRange<Double>, blue: ClosedRange<Double>) {
        try validate()
        return (try master.validatedOutputRange(for: self.red.validatedOutputRange(for: red)),
                try master.validatedOutputRange(for: self.green.validatedOutputRange(for: green)),
                try master.validatedOutputRange(for: self.blue.validatedOutputRange(for: blue)))
    }
}
