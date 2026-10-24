import Foundation
import GlowroomCore

/// Native revisions belong to the decoded pixels, not just the catalog's
/// size/date fingerprint. Metadata IO runs off MainActor and is checked before
/// and after decoding by the caller so a replaced source cannot be relabeled.
enum PreviewSourceStamp {
    static func capture(for request: PreviewRequest) async throws -> ImageAnalysisSourceStamp {
        try Task.checkCancellation()
        if case .artifact(let fingerprint) = request.source { return .artifact(fingerprint) }
        guard case .original(let fingerprint) = request.source else { throw ImageAnalysisError.invalidRequest }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: fingerprint.standardizedPath)
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let stamp = ImageAnalysisNativeSourceStamp.capture(url),
                  stamp.byteCount == fingerprint.fileSize else { throw ImageAnalysisError.staleSource }
            let modified = Double(stamp.modifiedSeconds) + Double(stamp.modifiedNanoseconds) / 1_000_000_000
            // Match ImageAnalysisPreparer's tolerance for Foundation's date
            // conversion rounding; an ordinary file modification is rejected.
            guard abs(modified - fingerprint.modifiedAt.timeIntervalSince1970) <= 0.000_005 else {
                throw ImageAnalysisError.staleSource
            }
            try Task.checkCancellation()
            return ImageAnalysisSourceStamp.original(stamp)
        }
        return try await withTaskCancellationHandler {
            let stamp = try await worker.value
            try Task.checkCancellation()
            return stamp
        } onCancel: { worker.cancel() }
    }

    static func stampedRequest(_ request: PreviewRequest, stamp: ImageAnalysisSourceStamp) -> PreviewRequest {
        let revision = stamp.cacheRevision + (request.sourceRevision.map { "|" + $0 } ?? "")
        return PreviewRequest(source: request.source, pixelSize: request.pixelSize,
            allowsEmbeddedPreview: request.allowsEmbeddedPreview, sourceRevision: revision,
            allowsHDR: request.allowsHDR)
    }
}
