import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("AI development source-bound pixels", .timeLimit(.minutes(1)))
struct AIDevelopmentServiceTests {
    @Test func replacedFileCannotRelabelOldPreviewAndUnchangedRequestsReuseCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-AISource-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("photo.png")
        let red = try analysisPNG(analysisRaster(red: true)), blue = try analysisPNG(analysisRaster(red: false))
        let count = max(red.count, blue.count) + 64
        try (red + Data(repeating: 0, count: count - red.count)).write(to: url)
        let request = try analysisFileRequest(url, kind: .editedPreview)
        guard case .original(let fingerprint) = request.snapshot.source else { Issue.record("Missing original"); return }
        let counter = AIDevelopmentDecodeCounter()
        let pipeline = ImagePreviewPipeline(decoder: { request in
            counter.record(); return try PreviewDecoder.decode(request)
        })
        let service = AIDevelopmentService(preparer: ImageAnalysisPreparer(imagePipeline: pipeline,
            renderPipeline: AdjustedPreviewPipeline()))
        // A normal workspace cache entry deliberately has no native revision.
        let oldWorkspace = try await pipeline.image(for: PreviewRequest(source: request.snapshot.source, pixelSize: 1_024))
        let first = try await service.prepare(snapshot: request.snapshot)
        #expect(counter.count == 2)
        try (blue + Data(repeating: 0, count: count - blue.count)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: fingerprint.modifiedAt], ofItemAtPath: url.path)
        let current = try await service.prepare(snapshot: request.snapshot)
        #expect(current.sourceStamp != first.sourceStamp)
        #expect(current.rasterSHA256 != first.rasterSHA256)
        #expect(current.rasterSHA256 != (try ImageAnalysisPreparer.describeRaster(oldWorkspace)).digest)
        #expect(current.sourceStamp == (try await service.preparer.sourceStamp(for: request)))
        #expect(counter.count == 3)
        let reused = try await service.prepare(snapshot: request.snapshot)
        #expect(reused.rasterSHA256 == current.rasterSHA256 && reused.sourceStamp == current.sourceStamp)
        #expect(counter.count == 3, "Repeated explicit requests reuse the validated source cache")
    }

    @Test func replacementDuringPreparationRejectsBeforeInference() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-AISource-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("photo.png")
        try Data([1, 2, 3, 4]).write(to: url)
        let request = try analysisFileRequest(url, kind: .editedPreview)
        guard case .original(let fingerprint) = request.snapshot.source else { Issue.record("Missing original"); return }
        let pipeline = ImagePreviewPipeline(decoder: { _ in
            try Data([4, 3, 2, 1]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: fingerprint.modifiedAt], ofItemAtPath: url.path)
            return try analysisRaster(red: true)
        })
        let service = AIDevelopmentService(preparer: ImageAnalysisPreparer(imagePipeline: pipeline,
            renderPipeline: AdjustedPreviewPipeline()))
        await #expect(throws: ImageAnalysisError.staleSource) { _ = try await service.prepare(snapshot: request.snapshot) }
    }
}

private final class AIDevelopmentDecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func record() { lock.lock(); value += 1; lock.unlock() }
}
