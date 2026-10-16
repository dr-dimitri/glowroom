import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("JPEG export controller", .serialized)
@MainActor
struct JPEGExportModelTests {
    @Test
    func exportFreezesEditingSettingsOptionsAndDestination() async throws {
        let probe = ExportProbe()
        let model = JPEGExportModel(preferences: nil, export: { try await probe.export($0) })
        let first = asset("first.CR3", width: 6000, height: 4000)
        let protected = [first.fileURL, asset("other.jpg").fileURL]
        var edits = EditSettings.neutral
        edits.exposure = 0.7
        edits.autoToneAmount = 65
        model.present(asset: first, settings: edits, protectedSourceURLs: protected)
        edits.exposure = -2
        model.destinationDirectory = URL(fileURLWithPath: "/tmp/picedit-export-model-output", isDirectory: true)
        model.qualityText = "84"
        model.sizeMode = .fit
        model.widthText = "1920"
        model.heightText = "1080"
        #expect(model.estimatedSize?.width == 1620)
        #expect(model.estimatedSize?.height == 1080)
        model.startExport()
        #expect(model.isExporting && model.isPresented)
        // A new library selection must not replace the accepted export.
        model.present(asset: asset("second.jpg"), settings: edits)
        model.filename = "later.jpg"
        model.qualityText = "10"
        try await wait { await probe.count == 1 }
        let request = try #require(await probe.lastRequest)
        #expect(request.sourceURL == first.fileURL)
        #expect(request.destinationURL.lastPathComponent == "first-bearbeitet.jpg")
        #expect(request.options.quality == 84)
        #expect(request.settings.exposure == 0.7)
        #expect(request.settings.autoToneAmount == 65)
        #expect(request.protectedSourceURLs == protected)
        #expect(!request.overwriteExisting)
        await probe.succeed(width: 1620, height: 1080)
        try await wait { !model.isExporting }
        #expect(model.result?.url == request.destinationURL)
        #expect(model.result?.width == 1620)
        #expect(model.isPresented)
        model.cancel()
        #expect(!model.isPresented)
    }

    @Test
    func cancelKeepsLifecycleOpenUntilExporterActuallyStops() async throws {
        let probe = ExportProbe()
        let model = JPEGExportModel(preferences: nil, export: { try await probe.export($0) })
        model.present(asset: asset("first.jpg"), settings: .neutral)
        model.startExport()
        try await wait { await probe.count == 1 }
        model.cancel()
        model.cancel()
        #expect(model.isCancelling && model.isExporting && model.isPresented)
        model.startExport()
        model.present(asset: asset("replacement.jpg"), settings: .neutral)
        #expect(model.sourceName == "first.jpg")
        #expect(await probe.count == 1)
        await probe.fail(CancellationError())
        try await wait { !model.isExporting }
        #expect(!model.isPresented && !model.isCancelling)
        #expect(model.result == nil && model.errorMessage == nil)
        model.present(asset: asset("replacement.jpg"), settings: .neutral)
        #expect(model.sourceName == "replacement.jpg" && model.canExport)
    }

    @Test
    func lateCancellationReportsAFileThatAlreadyCommitted() async throws {
        let probe = ExportProbe()
        let model = JPEGExportModel(preferences: nil, export: { try await probe.export($0) })
        model.present(asset: asset("late.jpg"), settings: .neutral)
        model.startExport()
        try await wait { await probe.count == 1 }
        model.cancel()
        // Deliberately ignore cancellation, as an atomic commit may have won.
        await probe.succeed(width: 600, height: 400)
        try await wait { !model.isExporting }
        #expect(model.result?.url.lastPathComponent == "late-bearbeitet.jpg")
        #expect(model.isPresented && !model.isCancelling)
    }

    @Test
    func overwriteRequiresExplicitConfirmationAndRetriesTheFrozenRequest() async throws {
        let probe = ExportProbe()
        let model = JPEGExportModel(preferences: nil, export: { try await probe.export($0) })
        var settings = EditSettings.neutral
        settings.shadows = 25
        model.present(asset: asset("existing.jpg"), settings: settings)
        model.filename = "chosen.jpg"
        model.qualityText = "77"
        model.startExport()
        try await wait { await probe.count == 1 }
        let initial = try #require(await probe.lastRequest)
        await probe.fail(JPEGExportError.destinationExists)
        try await wait { model.needsOverwriteConfirmation }
        #expect(!model.isExporting && !model.canExport)
        #expect(model.overwriteFilename == "chosen.jpg")
        model.filename = "different.jpg"
        model.qualityText = "1"
        // SwiftUI can write false to the presentation binding before the action.
        model.dismissOverwritePrompt()
        #expect(!model.canExport)
        model.confirmOverwrite()
        try await wait { await probe.count == 2 }
        let retry = try #require(await probe.lastRequest)
        #expect(retry.overwriteExisting)
        #expect(retry.destinationURL == initial.destinationURL)
        #expect(retry.sourceURL == initial.sourceURL)
        #expect(retry.options.quality == 77)
        #expect(retry.settings == initial.settings)
        await probe.succeed(width: 600, height: 400)
        try await wait { !model.isExporting }
        #expect(model.result?.url == initial.destinationURL)
    }

    @Test
    func declinedOverwriteAndFailuresLeaveSettingsAvailableForCorrection() async throws {
        let probe = ExportProbe()
        let model = JPEGExportModel(preferences: nil, export: { try await probe.export($0) })
        model.present(asset: asset("retry.jpg"), settings: .neutral)
        model.startExport()
        try await wait { await probe.count == 1 }
        await probe.fail(JPEGExportError.destinationExists)
        try await wait { model.needsOverwriteConfirmation }
        model.declineOverwrite()
        model.confirmOverwrite()
        #expect(await probe.count == 1)
        #expect(model.canExport && model.isPresented)
        model.startExport()
        try await wait { await probe.count == 2 }
        await probe.fail(ExportProbeError.failed)
        try await wait { !model.isExporting }
        #expect(model.errorMessage != nil && model.canExport && model.isPresented)
        model.filename = "new.jpg"
        model.startExport()
        try await wait { await probe.count == 3 }
        #expect(model.errorMessage == nil)
        await probe.succeed(width: 600, height: 400)
        try await wait { !model.isExporting }
        #expect(model.result?.url.lastPathComponent == "new.jpg")
    }

    @Test
    func filenamesAndNumericInputsValidateWithoutTouchingDisk() async throws {
        let probe = ExportProbe()
        let model = JPEGExportModel(preferences: nil, export: { try await probe.export($0) })
        model.present(asset: asset("input.jpg"), settings: .neutral)
        for filename in ["", "../image.jpg", "/tmp/image.jpg", "folder\\image.jpg", ".jpg", "image.png", "bad\u{0}.jpg"] {
            model.filename = filename
            #expect(!model.canExport)
            model.startExport()
            #expect(!model.isExporting)
        }
        #expect(await probe.count == 0)
        model.filename = "valid.JPEG"
        #expect(model.canExport)
        model.qualityText = "101"
        #expect(!model.canExport)
        model.qualityText = "90.5"
        #expect(!model.canExport)
        model.qualityText = "0"
        #expect(model.canExport)
        model.sizeMode = .longEdge
        model.longEdgeText = "0"
        #expect(!model.canExport)
        model.longEdgeText = "65536"
        #expect(!model.canExport)
        model.sizeMode = .original
        #expect(model.canExport, "Unused dimension fields must not block original-size export")
        model.resolutionText = "1201"
        #expect(!model.canExport)
        model.resolutionText = "300"
        #expect(model.canExport)
    }

    @Test
    func missingMetadataShowsNoInventedDimensionsAndDoesNotBlockExport() async throws {
        let probe = ExportProbe()
        let model = JPEGExportModel(preferences: nil, export: { try await probe.export($0) })
        model.present(asset: asset("unknown.jpg", width: 0, height: 0), settings: .neutral)
        #expect(model.estimatedSize == nil)
        #expect(model.sourceDimensions.contains("ermittelt"))
        #expect(model.canExport)
        model.startExport()
        try await wait { await probe.count == 1 }
        await probe.succeed(width: 321, height: 123)
        try await wait { !model.isExporting }
        #expect(model.result?.width == 321 && model.result?.height == 123)
    }

    private func asset(_ name: String, width: Int = 600, height: Int = 400) -> PhotoAsset {
        PhotoAsset(folderID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/picedit-export-model-input/\(name)"),
                   pixelWidth: width, pixelHeight: height)
    }

    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw ExportProbeError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum ExportProbeError: Error { case timeout, failed }

private actor ExportProbe {
    private var requests: [JPEGExportRequest] = []
    private var waiter: CheckedContinuation<JPEGExportResult, Error>?
    var count: Int { requests.count }
    var lastRequest: JPEGExportRequest? { requests.last }

    func export(_ request: JPEGExportRequest) async throws -> JPEGExportResult {
        requests.append(request)
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func succeed(width: Int, height: Int) {
        guard let request = requests.last else { return }
        let continuation = waiter
        waiter = nil
        continuation?.resume(returning: JPEGExportResult(url: request.destinationURL, width: width, height: height))
    }

    func fail(_ error: Error) {
        let continuation = waiter
        waiter = nil
        continuation?.resume(throwing: error)
    }
}
