#if GLOWROOM_EDITING_BENCHMARK
import Foundation
import GlowroomCore

/// Generated inputs only: the seed, dimensions and recipe are enough to recreate
/// every byte. Positions use native pixels, including the outer canvas boundary.
enum MaskBenchmarkFixtures {
    static let names = ["few-soft", "many-mixed", "narrow", "edges"]
    static let workloads = ["snapshot", "append", "active", "history"]
    static let recipeVersion = 1

    struct Sequence {
        let initial: MaskDocument?
        let documents: [MaskDocument]
    }

    struct Generator {
        var state: UInt64
        mutating func unit() -> Double {
            // SplitMix64 is fixed here, independent of Swift's randomized Hasher.
            state &+= 0x9e3779b97f4a7c15
            var value = state
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            return Double((value ^ (value >> 31)) >> 11) / 9_007_199_254_740_992
        }
    }

    static func document(name: String, size: ArtifactPixelSize, seed: UInt64) throws -> MaskDocument {
        guard names.contains(name) else { throw Benchmark.failure("Unknown mask fixture: \(name)") }
        var generator = Generator(state: seed)
        let short = Double(min(size.width, size.height))
        let count = name == "many-mixed" ? 96 : (name == "edges" ? 8 : 4)
        var strokes: [MaskStroke] = []
        for index in 0..<count {
            let narrow = name == "narrow" || (name == "many-mixed" && index.isMultiple(of: 3))
            let radius = narrow ? max(0.6, short / 1_024) : short * (name == "few-soft" ? 0.07 : 0.014)
            let hardness = narrow ? 1 : (index.isMultiple(of: 2) ? 0.15 : 0.7)
            let originX = generator.unit() * Double(size.width)
            let originY = generator.unit() * Double(size.height)
            var points: [MaskPoint] = []
            for step in 0..<8 {
                let fraction = Double(step) / 7
                var x = originX + (fraction - 0.5) * short * 0.12
                var y = originY + sin(fraction * .pi * 2 + Double(index)) * short * 0.025
                if name == "edges" {
                    // Corners, exact boundary points, clipped radii and all sides.
                    switch index % 4 {
                    case 0: x = fraction * Double(size.width); y = 0
                    case 1: x = Double(size.width); y = fraction * Double(size.height)
                    case 2: x = (1 - fraction) * Double(size.width); y = Double(size.height)
                    default: x = 0; y = (1 - fraction) * Double(size.height)
                    }
                }
                points.append(try MaskPoint(x: max(0, min(Double(size.width), x)),
                                            y: max(0, min(Double(size.height), y))))
            }
            strokes.append(try MaskStroke(points: points, radius: radius, hardness: hardness,
                                          mode: index % 5 == 4 || (name == "edges" && index >= 4) ? .erase : .brush))
        }
        let document = try MaskDocument(canvasSize: size, strokes: strokes)
        return name == "edges" ? document.inverted() : document
    }

    static func sequence(name: String, workload: String, size: ArtifactPixelSize, seed: UInt64) throws -> Sequence {
        let base = try document(name: name, size: size, seed: seed)
        let points = try (0..<8).map { index in
            try MaskPoint(x: Double(size.width) * (0.3 + Double(index) * 0.035),
                          y: Double(size.height) * (0.45 + Double(index % 3) * 0.02))
        }
        let radius = max(1, Double(min(size.width, size.height)) * 0.018)
        func appended(_ points: [MaskPoint], mode: MaskStrokeMode = .brush) throws -> MaskDocument {
            try base.appending(MaskStroke(points: points, radius: radius, hardness: 0.35, mode: mode))
        }
        switch workload {
        case "snapshot": return Sequence(initial: nil, documents: [base])
        case "append":
            var current = base
            var documents: [MaskDocument] = []
            for (index, point) in points.enumerated() {
                current = try current.appending(MaskStroke(points: [point], radius: radius, hardness: 0.35,
                                                         mode: index.isMultiple(of: 3) ? .erase : .brush))
                documents.append(current)
            }
            return Sequence(initial: base, documents: documents)
        case "active":
            return Sequence(initial: base, documents: try (1...points.count).map { try appended(Array(points.prefix($0))) })
        case "history":
            let brush = try appended(points)
            let erase = try brush.appending(MaskStroke(points: Array(points.reversed()), radius: radius * 0.6,
                                                      hardness: 0.75, mode: .erase))
            // Append, undo, redo, invert, invert back, clear and restore snapshot.
            return Sequence(initial: base, documents: [brush, erase, brush, erase, erase.inverted(), erase,
                                                       erase.cleared(), base])
        default: throw Benchmark.failure("Unknown mask workload: \(workload)")
        }
    }
}
#endif
