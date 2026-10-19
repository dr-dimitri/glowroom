/// Shared integer-only geometry for the fixed 800px local repair interface
/// and its independent LaMa evaluation.
/// Coordinates refer to top-left pixel rows. No scaling, rotation or color
/// conversion occurs here; this type does not load or enable a model.
struct LaMaEvaluationMapping: Sendable {
    static let edge = 800

    struct Point: Equatable, Sendable {
        let x: Int
        let y: Int
    }

    struct Sample: Equatable, Sendable {
        let sourceX: Int
        let sourceY: Int
        /// Native crop domain. Artificial context padding samples clamp RGB
        /// and model mask together; only this native domain is returned.
        let isInside: Bool
    }

    enum Failure: Error, Equatable { case invalidDimensions }

    let width: Int
    let height: Int
    let offsetX: Int
    let offsetY: Int

    init(width: Int, height: Int) throws {
        guard (1...Self.edge).contains(width), (1...Self.edge).contains(height) else {
            throw Failure.invalidDimensions
        }
        self.width = width
        self.height = height
        offsetX = (Self.edge - width) / 2
        offsetY = (Self.edge - height) / 2
    }

    func sample(modelX: Int, modelY: Int) -> Sample? {
        guard (0..<Self.edge).contains(modelX), (0..<Self.edge).contains(modelY) else { return nil }
        let x = modelX - offsetX
        let y = modelY - offsetY
        return Sample(sourceX: min(width - 1, max(0, x)), sourceY: min(height - 1, max(0, y)),
                      isInside: (0..<width).contains(x) && (0..<height).contains(y))
    }

    func modelPoint(sourceX: Int, sourceY: Int) -> Point? {
        guard (0..<width).contains(sourceX), (0..<height).contains(sourceY) else { return nil }
        return Point(x: sourceX + offsetX, y: sourceY + offsetY)
    }
}
