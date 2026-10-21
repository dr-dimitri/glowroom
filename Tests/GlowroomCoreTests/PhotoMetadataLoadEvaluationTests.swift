import Darwin
import Foundation
import Testing
@testable import GlowroomCore

/// Isolated, serial storage measurement; no photos, model or default catalog.
/// Stream fixture entries to avoid a whole-document graph in the baseline.
@Suite("Opt-in durable metadata load evaluation", .serialized, .timeLimit(.minutes(10)))
struct PhotoMetadataLoadEvaluationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_RUN_METADATA_LOAD_EVALUATION"] == "1"))
    func realRepositoryImportRestartExportAndLimits() async throws {
        let parent = ProcessInfo.processInfo.environment["GLOWROOM_METADATA_EVALUATION_OUTPUT"] ?? NSTemporaryDirectory()
        let output = URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent("Glowroom-Metadata-Evaluation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var report = MetadataLoadReport()
        do { try await run(output: output, report: &report) }
        catch {
            report.failure = String(describing: error)
            report.highWaterRSSBytes = highWaterRSS()
            try write(report, output: output)
            print("Metadata load failure report: \(output.appendingPathComponent("results.json").path)")
            throw error
        }
        report.highWaterRSSBytes = highWaterRSS()
        try write(report, output: output)
        print("Metadata load evaluation: \(output.appendingPathComponent("results.json").path)")
    }

    private func run(output: URL, report: inout MetadataLoadReport) async throws {
        let p = MetadataFileProtectionSnapshot(originalURLs: [], managedFileURLs: [], managedDirectoryURLs: [])
        let source = output.appendingPathComponent("ten-thousand.json")
        try fixture(source, count: 10_000, large: false)
        report.inputBytes = try byteCount(source)
        report.baseRSSBytes = residentRSS()
        report.highWaterBeforeImportBytes = highWaterRSS()
        let store = PhotoMetadataRepository(directory: output.appendingPathComponent("store", isDirectory: true))
        var start = ContinuousClock.now
        let review = try await store.prepareImport(source: source, protection: p)
        report.reviewMilliseconds = milliseconds(since: start)
        #expect(review.entryCount == 10_000 && review.missingCount == 10_000 && review.unassignedCount == 10_000)
        start = .now
        let operation = MetadataImportOperation(reviewID: review.id, reviewContentSHA256: review.contentSHA256, decisions: [])
        let committed = try await store.commitImport(operation)
        report.commitMilliseconds = milliseconds(since: start)
        report.committedCount = committed.receipt.affected.count
        #expect(report.committedCount == 10_000)
        #expect(try await store.commitImport(operation).receipt.disposition == .replayed)
        let export = output.appendingPathComponent("confirmed-export.json")
        start = .now
        let exported = try await store.exportConfirmed(destination: export, protection: p)
        report.exportMilliseconds = milliseconds(since: start)
        report.exportBytes = try byteCount(export)
        report.exportedCount = exported.entryCount
        #expect(exported.entryCount == 10_000)
        let restarted = PhotoMetadataRepository(directory: output.appendingPathComponent("store", isDirectory: true))
        start = .now
        for ordinal in [0, 5_000, 9_999] {
            let record = try #require(try await restarted.record(assetID: id(ordinal)))
            #expect(record.confirmed == entry(ordinal, large: false).fields)
            #expect(record.confirmedRevision == 1 && record.isOrphaned)
        }
        report.restartSampleMilliseconds = milliseconds(since: start)
        // A second actual store validates the complete produced export and
        // commits every row. Sample checks alone do not prove its entry count.
        let roundtrip = PhotoMetadataRepository(directory: output.appendingPathComponent("roundtrip", isDirectory: true))
        start = .now
        let again = try await roundtrip.prepareImport(source: export, protection: p)
        let restored = try await roundtrip.commitImport(.init(reviewID: again.id, reviewContentSHA256: again.contentSHA256, decisions: []))
        report.roundtripMilliseconds = milliseconds(since: start)
        report.roundtripCount = restored.receipt.affected.count
        #expect(again.entryCount == 10_000 && restored.receipt.affected.count == 10_000)
        for ordinal in [0, 5_000, 9_999] {
            #expect(try await roundtrip.record(assetID: id(ordinal))?.confirmed == entry(ordinal, large: false).fields)
        }
        let saved = await store.finishSaving(), reopened = await restarted.finishSaving(), copied = await roundtrip.finishSaving()
        #expect(saved && reopened && copied)

        let limits = PhotoMetadataRepository(directory: output.appendingPathComponent("limits-store", isDirectory: true))
        let large = output.appendingPathComponent("large-valid.json")
        let encodedEntrySize = try PhotoMetadataPortableJSON.encoder().encode(entry(0, large: true)).count
        let largeCount = min(25_000, (55 * 1_024 * 1_024) / (encodedEntrySize + 1))
        try fixture(large, count: largeCount, large: true)
        report.largeInputBytes = try byteCount(large); report.largeEntryCount = largeCount
        #expect(report.largeInputBytes < Int64(PhotoMetadataLimits.maximumJSONDocumentBytes))
        start = .now
        do {
            let bigReview = try await limits.prepareImport(source: large, protection: p)
            #expect(bigReview.entryCount == largeCount)
            report.largeReviewResult = "accepted review; deliberately discarded without writes"
            await limits.discardImport(reviewID: bigReview.id)
        } catch PhotoMetadataError.limitExceeded(.importReview) {
            report.largeReviewResult = "safely rejected at accounted 128 MiB review budget"
        }
        report.largeReviewMilliseconds = milliseconds(since: start)
        #expect(try await limits.record(assetID: id(0)) == nil)
        let tooMany = output.appendingPathComponent("over-entry-limit.json")
        try fixture(tooMany, count: 25_001, large: false, small: true)
        report.overEntryLimitRejected = await rejected(.limitExceeded(.jsonEntries)) { _ = try await limits.prepareImport(source: tooMany, protection: p) }
        #expect(try await limits.record(assetID: id(25_000)) == nil)
        let tooBig = output.appendingPathComponent("over-byte-limit.json")
        try fixture(tooBig, count: 1, large: false, small: true)
        let handle = try FileHandle(forWritingTo: tooBig)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        let block = Data(repeating: 32, count: 65_536)
        while try handle.offset() <= UInt64(PhotoMetadataLimits.maximumJSONDocumentBytes) { try handle.write(contentsOf: block) }
        try handle.synchronize()
        report.overByteLimitRejected = await rejected(.limitExceeded(.jsonDocument)) { _ = try await limits.prepareImport(source: tooBig, protection: p) }
        let invalid = output.appendingPathComponent("late-unknown-field.json")
        try fixture(invalid, count: 10_000, large: false, small: true, invalidLast: true)
        let invalidRejected = await rejected(.validation(.unknownField)) { _ = try await limits.prepareImport(source: invalid, protection: p) }
        #expect(try await limits.record(assetID: id(0)) == nil)
        #expect(try await limits.record(assetID: id(9_999)) == nil)
        let firstAbsent = try await limits.record(assetID: id(0)) == nil
        let lastAbsent = try await limits.record(assetID: id(9_999)) == nil
        report.lateInvalidEntryRejectedWithoutWrites = invalidRejected && firstAbsent && lastAbsent

        // Multiple individually bounded, fully validated imports can grow a
        // durable store beyond one portable document. Export must preserve an
        // existing destination when its actual streamed byte limit is reached.
        let overflowStore = PhotoMetadataRepository(directory: output.appendingPathComponent("overflow-store", isDirectory: true))
        start = .now
        for batch in 0..<10 {
            let batchURL = output.appendingPathComponent("export-seed-\(batch).json")
            try fixture(batchURL, count: 1_000, large: true, startOrdinal: batch * 1_000)
            let batchReview = try await overflowStore.prepareImport(source: batchURL, protection: p)
            let batchCommit = try await overflowStore.commitImport(.init(reviewID: batchReview.id,
                reviewContentSHA256: batchReview.contentSHA256, decisions: []))
            #expect(batchCommit.receipt.affected.count == 1_000)
            report.overflowSeededCount += batchCommit.receipt.affected.count
        }
        report.overflowSeedMilliseconds = milliseconds(since: start)
        let oldTarget = output.appendingPathComponent("existing-overflow-target.json")
        let sentinel = Data("keep previous complete export".utf8)
        try sentinel.write(to: oldTarget)
        start = .now
        report.oversizedExportRejected = await rejected(.limitExceeded(.jsonDocument)) {
            _ = try await overflowStore.exportConfirmed(destination: oldTarget, protection: p)
        }
        report.oversizedExportMilliseconds = milliseconds(since: start)
        report.existingExportBytesPreserved = try Data(contentsOf: oldTarget) == sentinel
        #expect(report.existingExportBytesPreserved)
        #expect(await overflowStore.finishSaving())
    }

    private func id(_ index: Int) -> String { String(format: "synthetic-metadata-%05d", index) }
    private func entry(_ index: Int, large: Bool, small: Bool = false) -> MetadataJSONEntry {
        let tags = large ? (0..<20).map { "tag-\($0)-" + String(repeating: "x", count: 40) } : ["synthetic", "batch-\(index % 10)"]
        let fields = PhotoTextFields(title: "Synthetic title \(index)",
            description: small ? "" : String(repeating: large ? "ä" : "x", count: large ? 1_900 : 768), tags: tags)
        return .init(assetID: id(index), fields: fields, originalRevision: 1,
            confirmedAt: Date(timeIntervalSince1970: 1_700_000_000),
            provenance: .init(tags: tags.map { .init(value: $0, origin: .manual) }))
    }
    private func fixture(_ url: URL, count: Int, large: Bool, small: Bool = false, invalidLast: Bool = false, startOrdinal: Int = 0) throws {
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        let header = "{\"schemaVersion\":1,\"normalizationVersion\":1,\"exportID\":\"\(UUID().uuidString)\",\"exportedAt\":1700000000,\"entries\":["
        try file.write(contentsOf: Data(header.utf8))
        let encoder = PhotoMetadataPortableJSON.encoder()
        // One bounded entry at a time; serialization is ordered by JSON syntax.
        for index in 0..<count {
            try autoreleasepool {
                if index > 0 { try file.write(contentsOf: Data([44])) }
                var bytes = try encoder.encode(entry(startOrdinal + index, large: large, small: small))
                if invalidLast && index == count - 1 {
                    bytes.removeLast(); bytes.append(contentsOf: Data(",\"unexpected\":true}".utf8))
                }
                try file.write(contentsOf: bytes)
            }
        }
        try file.write(contentsOf: Data("]}".utf8)); try file.synchronize()
    }
    private func rejected(_ expected: PhotoMetadataError, operation: () async throws -> Void) async -> Bool {
        do { try await operation(); Issue.record("Expected \(expected)"); return false }
        catch { let matches = error as? PhotoMetadataError == expected; #expect(matches); return matches }
    }
    private func byteCount(_ url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
    }
    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) * 1_000 + Double(d.attoseconds) / 1e15
    }
    private func highWaterRSS() -> UInt64? {
        var usage = rusage(); guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return UInt64(max(0, usage.ru_maxrss))
    }
    private func residentRSS() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
    private func write(_ report: MetadataLoadReport, output: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output.appendingPathComponent("results.json"), options: .atomic)
    }
}
private struct MetadataLoadReport: Codable {
    var scope = "Synthetic orphan metadata only; no photos, RAW, model or GUI. Process RSS high-water is cumulative, not an exact review-budget cap."
    var debugBuild = _isDebugAssertConfiguration()
    var inputBytes: Int64 = 0, exportBytes: Int64 = 0, largeInputBytes: Int64 = 0
    var committedCount = 0, exportedCount = 0, roundtripCount = 0, largeEntryCount = 0
    var reviewMilliseconds = 0.0, commitMilliseconds = 0.0, exportMilliseconds = 0.0, restartSampleMilliseconds = 0.0
    var roundtripMilliseconds = 0.0, largeReviewMilliseconds = 0.0
    var largeReviewResult: String?, failure: String?
    var overflowSeededCount = 0
    var overflowSeedMilliseconds = 0.0, oversizedExportMilliseconds = 0.0
    var oversizedExportRejected = false, existingExportBytesPreserved = false
    var overEntryLimitRejected = false, overByteLimitRejected = false, lateInvalidEntryRejectedWithoutWrites = false
    var baseRSSBytes: UInt64?, highWaterBeforeImportBytes: UInt64?, highWaterRSSBytes: UInt64?
}
