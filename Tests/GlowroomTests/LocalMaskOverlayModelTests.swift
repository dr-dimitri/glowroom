import AppKit
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Live mask overlay scheduling")
@MainActor
struct LocalMaskOverlayModelTests {
    @Test func rapidInputKeepsCompletedFrameAndOnlyNewestPendingRequest() async throws {
        let fake = OverlayRenderGate()
        let model = LocalMaskOverlayModel(renderer: { try await fake.render($0) })
        defer { model.update(nil); fake.close() }
        let first = try request()
        model.update(first)
        try await fake.started.wait("first overlay") { $0.count == 1 }
        var newest = first
        for index in 1...100 {
            newest = try request(layerID: first.layerID, opacity: Double(index) / 101)
            model.update(newest)
        }
        #expect(fake.started.value.count == 1)
        let firstImage = try image(width: 2)
        fake.complete(0, with: .success(firstImage))
        try await fake.started.wait("coalesced overlay") { $0.count == 2 }
        #expect(model.image === firstImage, "Continuous input must not starve completed frames")
        #expect(fake.started.value.last == newest)
        let finalImage = try image(width: 3)
        fake.complete(1, with: .success(finalImage))
        await model.waitForRendering()
        #expect(model.image === finalImage)
        model.update(newest)
        #expect(fake.started.value.count == 2, "Identical input needs no new render")
        model.update(try request(layerID: first.layerID, opacity: 0.1))
        #expect(model.image === finalImage, "Keep the last frame while its replacement renders")
    }

    @Test(arguments: ["source", "layer", "canvas", "hide"])
    func changedCanvasRejectsLateNativeFrameAndKeepsItsSlotUntilReturn(_ change: String) async throws {
        let fake = OverlayRenderGate()
        let model = LocalMaskOverlayModel(renderer: { try await fake.render($0) })
        defer { model.update(nil); fake.close() }
        let first = try request()
        model.update(first)
        try await fake.started.wait("old canvas render") { $0.count == 1 }
        let next = try request(layerID: change == "layer" ? UUID() : first.layerID,
            sourceName: change == "source" ? "second" : "first", width: change == "canvas" ? 64 : 32)
        model.update(change == "hide" ? nil : next)
        #expect(model.image == nil)
        #expect(fake.started.value.count == 1, "Cancellation cannot release occupied native work")
        // Deliberately ignore cancellation like a synchronous native renderer.
        fake.complete(0, with: .success(try image(width: 2)))
        if change == "hide" {
            await model.waitForRendering()
            #expect(fake.started.value.count == 1)
        } else {
            try await fake.started.wait("new canvas render") { $0.count == 2 }
            #expect(model.image == nil, "The old source/layer must never flash onto the new canvas")
            fake.complete(1, with: .success(try image(width: 3)))
            await model.waitForRendering()
            #expect(model.image?.width == 3)
        }
    }

    @Test func hiddenAndReopenedSameCanvasRejectsPreviousGenerationAndErrorsRecover() async throws {
        let fake = OverlayRenderGate()
        let model = LocalMaskOverlayModel(renderer: { try await fake.render($0) })
        defer { model.update(nil); fake.close() }
        let first = try request()
        model.update(first)
        try await fake.started.wait("original generation") { $0.count == 1 }
        model.update(nil)
        model.update(first)
        fake.complete(0, with: .failure(EditRenderError.unavailable))
        try await fake.started.wait("reopened generation") { $0.count == 2 }
        #expect(model.errorMessage == nil && model.image == nil)
        fake.complete(1, with: .failure(EditRenderError.unavailable))
        await model.waitForRendering()
        #expect(model.errorMessage != nil)
        model.update(try request(layerID: first.layerID, opacity: 0.5))
        try await fake.started.wait("recovery") { $0.count == 3 }
        fake.complete(2, with: .success(try image(width: 4)))
        await model.waitForRendering()
        #expect(model.errorMessage == nil && model.image?.width == 4)
    }

    private func request(layerID: UUID = UUID(), sourceName: String = "first", width: Int = 32,
                         opacity: Double = 1) throws -> LocalMaskOverlayRequest {
        .init(source: .original(.init(fileURL: URL(fileURLWithPath: "/nonexistent/\(sourceName)"),
                                     modifiedAt: .distantPast, fileSize: 1)),
              canvas: try .init(width: width, height: 16), layerID: layerID,
              mask: try .init(shape: .linear(start: .init(x: 0, y: 0), end: .init(x: 1, y: 1)), opacity: opacity))
    }

    private func image(width: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }
}

/// No blocking waits: native completion is held until the test releases it.
private final class OverlayRenderGate: @unchecked Sendable {
    let started = TestStateSignal<[LocalMaskOverlayRequest]>([])
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<CGImage, Error>] = [:]
    private var closed = false
    private var count = 0

    func render(_ request: LocalMaskOverlayRequest) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let accepted = lock.withLock {
                guard !closed else { return false }
                continuations[count] = continuation
                count += 1
                return true
            }
            if accepted { started.update { $0.append(request) } }
            else { continuation.resume(throwing: CancellationError()) }
        }
    }

    func complete(_ index: Int, with result: Result<CGImage, Error>) {
        lock.withLock { continuations.removeValue(forKey: index) }?.resume(with: result)
    }

    func close() {
        let pending = lock.withLock {
            closed = true
            let pending = Array(continuations.values)
            continuations.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }
}
