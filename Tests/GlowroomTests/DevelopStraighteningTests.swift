import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Develop straightening readiness and cancellation")
struct DevelopStraighteningTests {
    @Test @MainActor func spatialReadinessIncludesStraighteningAndItsCanvasConstraint() {
        let workspace = DevelopWorkspace()
        let source = identity("mapping")
        workspace.bind(source: source)
        workspace.markDisplayed(source: source, settings: .init(developGeometry: .init(straightenAngle: 5)))
        #expect(!workspace.isOriginalCanvasReady)
        workspace.markDisplayed(source: source, settings: .init(developGeometry: .init(constrainToImage: false)))
        #expect(!workspace.isOriginalCanvasReady)
        workspace.markDisplayed(source: source, settings: .neutral)
        #expect(workspace.isOriginalCanvasReady)
    }

    @Test func horizonCorrectionUsesClockwiseDegreesAndRejectsUnsupportedAngles() throws {
        #expect(abs(try #require(DevelopHorizonEstimator.clockwiseDegrees(correctionRadians: .pi / 6)) + 30) < 1e-9)
        #expect(abs(try #require(DevelopHorizonEstimator.clockwiseDegrees(correctionRadians: -.pi / 4)) - 45) < 1e-9)
        #expect(DevelopHorizonEstimator.clockwiseDegrees(correctionRadians: .pi / 2) == nil)
        #expect(DevelopHorizonEstimator.clockwiseDegrees(correctionRadians: .nan) == nil)
    }

    @Test @MainActor func autoUsesTheDecodedOriginalAndRejectsResultsAfterSourceReplacement() async throws {
        let gate = HorizonGate()
        let workspace = makeWorkspace(gate)
        let original = try bitmap(width: 20), adjusted = try bitmap(width: 80)
        workspace.bind(source: identity("a"))
        workspace.receive(adjusted, sourceBitmap: original)
        let request = Task { await workspace.autoStraighten() }
        try await wait { await gate.widths == [20] }
        #expect(workspace.isAutoStraightening)
        workspace.bind(source: identity("b"))
        #expect(!workspace.isAutoStraightening)
        await gate.release(12)
        #expect(await request.value == nil)
        #expect(workspace.errorMessage == nil)
    }

    @Test @MainActor func autoCancellationClearsBusyStateAndCannotPublishAnAngle() async throws {
        let gate = HorizonGate()
        let workspace = makeWorkspace(gate)
        let original = try bitmap(width: 20)
        workspace.bind(source: identity("cancel")); workspace.receive(original, sourceBitmap: original)
        let request = Task { await workspace.autoStraighten() }
        try await wait { await gate.widths.count == 1 }
        request.cancel(); await gate.release(8)
        #expect(await request.value == nil)
        #expect(!workspace.isAutoStraightening && workspace.errorMessage == nil)
        let second = Task { await workspace.autoStraighten() }
        try await wait { await gate.widths.count == 2 }
        await gate.release(nil)
        #expect(await second.value == nil)
        #expect(!workspace.isAutoStraightening && workspace.errorMessage != nil)
        workspace.clear()
    }

    @Test @MainActor func autoRejectsAResultForAnObsoleteDecodedBaseOfTheSameSource() async throws {
        let gate = HorizonGate()
        let workspace = makeWorkspace(gate)
        let first = try bitmap(width: 20), second = try bitmap(width: 40)
        workspace.bind(source: identity("same-source")); workspace.receive(first, sourceBitmap: first)
        let request = Task { await workspace.autoStraighten() }
        try await wait { await gate.widths == [20] }
        workspace.receive(second, sourceBitmap: second)
        await gate.release(9)
        #expect(await request.value == nil)
        #expect(!workspace.isAutoStraightening && workspace.errorMessage == nil)
        workspace.clear()
    }

    @MainActor private func makeWorkspace(_ gate: HorizonGate) -> DevelopWorkspace {
        DevelopWorkspace(analyze: { _ in
            DevelopPreviewAnalysis(width: 1, height: 1, pixels: [0, 0, 0, 255],
                channels: [[Int]](repeating: [Int](repeating: 0, count: 128), count: 3), shadows: 0, highlights: 0)
        }, estimateHorizon: { await gate.estimate($0) })
    }

    private func identity(_ name: String) -> AISourceIdentity {
        .original(.init(fileURL: URL(fileURLWithPath: "/tmp/straightening-\(name).jpg"), modifiedAt: .distantPast, fileSize: 4))
    }

    private func bitmap(width: Int) throws -> PreviewBitmap {
        let provider = try #require(CGDataProvider(data: Data(repeating: 255, count: width * 4) as CFData))
        return PreviewBitmap(image: try #require(CGImage(width: width, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)))
    }

    @MainActor private func wait(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await predicate())
    }
}

private actor HorizonGate {
    private(set) var widths: [Int] = []
    private var pending: [CheckedContinuation<Double?, Never>] = []
    func estimate(_ bitmap: PreviewBitmap) async -> Double? {
        widths.append(bitmap.image.width)
        return await withCheckedContinuation { pending.append($0) }
    }
    func release(_ angle: Double?) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: angle)
    }
}
