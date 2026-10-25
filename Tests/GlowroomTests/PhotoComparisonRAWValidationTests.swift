import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import GlowroomCore
import ImageIO
import Testing
@testable import Glowroom

/// Opt-in local diagnostic. CI neither has nor searches for private originals.
@Suite("Optional two-photo comparison RAW validation", .serialized)
struct PhotoComparisonRAWValidationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_COMPARISON_RAW_INPUTS"] != nil,
                   "Requires three explicit, newline-separated local camera RAW paths"), .timeLimit(.minutes(10)))
    func pinnedReferenceAndCandidateRoundtripReuseTheirDecodedSources() async throws {
        let paths = try #require(ProcessInfo.processInfo.environment["GLOWROOM_COMPARISON_RAW_INPUTS"])
            .split(separator: "\n").map(String.init)
        try #require(paths.count == 3, "Supply A (reference), B and C as three separate existing RAWs")
        let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        try #require(Set(urls).count == 3)
        let before = try urls.map(hash)
        let requests = try urls.enumerated().map { index, url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let descriptor = try #require(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
            let type = try #require(CGImageSourceGetType(descriptor)) as String
            try #require(PreviewDecoder.isCameraRAWTypeIdentifier(type))
            return PreviewRequest(url: url, modifiedAt: values.contentModificationDate ?? .distantPast,
                pixelSize: 2400, fileSize: Int64(values.fileSize ?? 0), allowsEmbeddedPreview: false,
                sourceRevision: index == 0 ? "frozen-reference" : nil)
        }
        let counts = ComparisonRAWDecodeCounts()
        let originals = ImagePreviewPipeline(concurrencyLimit: 3, diskCache: nil, decoder: { request in
            counts.decode(request.source)
            return try PreviewDecoder.decode(request)
        })
        let adjusted = AdjustedPreviewPipeline(maximumConcurrentRenders: 2)
        func render(_ index: Int) async throws -> PreviewBitmap {
            let source = try await originals.image(for: requests[index], priority: .selected)
            return try await adjusted.image(source, request: requests[index], settings: .newEditingSettings,
                priority: .selected, maximumOutputPixelSize: 2400)
        }
        var measurements: [[String: Any]] = []
        var reference: PreviewBitmap?
        for (phase, index) in [("B_cold", 1), ("C_cold", 2), ("B_warm", 1)] {
            let started = ContinuousClock.now
            // The mounted reference retains its accepted pixels across candidate
            // changes; it does not ask to decode A on each B/C navigation.
            let candidate: PreviewBitmap
            if reference == nil {
                async let fixed = render(0)
                async let active = render(index)
                let frames = try await (fixed, active)
                reference = frames.0; candidate = frames.1
            } else { candidate = try await render(index) }
            let duration = started.duration(to: .now).components
            measurements.append(["phase": phase,
                "visible_pair_ms": Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15,
                "candidate_width": candidate.image.width, "candidate_height": candidate.image.height])
        }
        #expect(counts.total == 3, "A stays fixed and B→C→B reuses B's decoded base")
        for request in requests { #expect(counts.count(request.source) == 1) }
        #expect(try urls.map(hash) == before)
        var usage = rusage()
        let peak = getrusage(RUSAGE_SELF, &usage) == 0 ? usage.ru_maxrss : -1
        let report: [String: Any] = ["schema_version": 1, "source_sha256": before,
            "requested_long_edge": 2400, "decode_count": counts.total,
            "process_cumulative_peak_rss_bytes": peak, "measurements": measurements,
            "originals_unchanged": true,
            "scope": "Three explicitly supplied local RAWs, existing bounded pipelines, fresh app memory caches, no disk cache or embedded previews. First pair cold, C cold, then B warm with fixed A. OS/ImageIO/GPU caches are not flushed. Latency covers two materialized preview frames, not native input-to-display. Darwin ru_maxrss is the whole test-process cumulative high-water, not isolated stage allocations. No speedup, pixel quality or cross-device claim. No original or rendered photo is copied, saved or uploaded."]
        let url = URL(fileURLWithPath: "/tmp/glowroom-photo-comparison-raw-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        print("Photo comparison RAW validation: \(url.path)")
    }
    private func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let bytes = try file.read(upToCount: 1048576), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class ComparisonRAWDecodeCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AISourceIdentity: Int] = [:]
    func decode(_ source: AISourceIdentity) { lock.lock(); defer { lock.unlock() }; values[source, default: 0] += 1 }
    func count(_ source: AISourceIdentity) -> Int { lock.lock(); defer { lock.unlock() }; return values[source, default: 0] }
    var total: Int { lock.lock(); defer { lock.unlock() }; return values.values.reduce(0, +) }
}
