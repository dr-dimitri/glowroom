import CoreGraphics
import Foundation
import Vision

/// One native request at a time, off MainActor. Vision performs its own
/// parallel inference; extra photo workers would compete with preview renders.
actor DevelopHorizonEstimator {
    static let shared = DevelopHorizonEstimator()

    func estimate(_ bitmap: PreviewBitmap) async throws -> Double? {
        try Task.checkCancellation()
        let cancellation = DevelopHorizonCancellation()
        return try await withTaskCancellationHandler {
            try autoreleasepool {
                let image = try Self.proxy(bitmap.image)
                try Task.checkCancellation()
                let request = VNDetectHorizonRequest()
                try cancellation.register(request)
                try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
                try Task.checkCancellation()
                guard let observation = request.results?.first, observation.confidence >= 0.3 else { return nil }
                // Vision's correction uses image coordinates (counterclockwise
                // radians); the persisted UI angle uses clockwise degrees.
                return Self.clockwiseDegrees(correctionRadians: Double(observation.angle))
            }
        } onCancel: { cancellation.cancel() }
    }

    static func clockwiseDegrees(correctionRadians: Double) -> Double? {
        guard correctionRadians.isFinite else { return nil }
        let degrees = -correctionRadians * 180 / .pi
        guard (-45...45).contains(degrees) else { return nil }
        return degrees
    }

    private static func proxy(_ image: CGImage) throws -> CGImage {
        let scale = min(1, 1_024.0 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditRenderError.unavailable }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let proxy = context.makeImage() else { throw EditRenderError.unavailable }
        return proxy
    }
}

private final class DevelopHorizonCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var cancelled = false
    func register(_ request: VNRequest) throws {
        lock.lock(); self.request = request; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { request.cancel(); throw CancellationError() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let request = request; lock.unlock()
        request?.cancel()
    }
}
