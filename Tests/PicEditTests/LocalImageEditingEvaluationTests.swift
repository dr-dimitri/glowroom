import CoreGraphics
import Darwin
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Local image-aware editing real model qualification v1", .serialized, .timeLimit(.minutes(10)))
struct LocalImageEditingEvaluationTests {
    @Test(.enabled("Requires PICEDIT_RUN_IMAGE_EDITING_EVALUATION=1 and a ready German local vision model") {
        await imageEditingEvaluationAvailable()
    })
    func actualAssistantUsesSyntheticPixelsForGlobalShadowRequest() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-ImageEditing-\(UUID().uuidString).png")
        try analysisPNG(imageEditingEvaluationScene()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try analysisFileRequest(url).snapshot
        let request = AIEditingRequest(prompt: "Helle die dunklen Bereiche etwas auf.", snapshot: snapshot)
        let coordinator = AIRequestCoordinator(provider: LocalAIEditingProviderFactory.makeAssistantProvider())
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await coordinator.proposal(for: request)
        guard case .changes(_, let settings) = result.validation else { Issue.record("Expected effective shadow correction"); return }
        #expect(settings.shadows > snapshot.settings.shadows)
        #expect(settings.highlights <= snapshot.settings.highlights)
        #expect(result.localAdjustments.isEmpty)
        #expect(settings.localAdjustments == snapshot.settings.localAdjustments)
        #expect(settings.developGeometry == snapshot.settings.developGeometry)
        imageEditingEvaluationMeasurement("synthetic global shadows", start: start)
    }

    @Test(.enabled("Requires PICEDIT_RUN_IMAGE_EDITING_EVALUATION=1, a ready local vision model, and the ignored local test_picture3.jpg fixture") {
        guard await imageEditingEvaluationAvailable() else { return false }
        let exists = FileManager.default.fileExists(atPath: imageEditingEvaluationFixture.path)
        if !exists { print("Image editing background qualification skipped: optional local fixture test_picture3.jpg is absent; it is not available in CI.") }
        return exists
    })
    func actualAssistantCreatesProductionBackgroundSelectionAndRetainsManualMask() async throws {
        let source = imageEditingEvaluationFixture
        let original = try Data(contentsOf: source)
        let originalSnapshot = try analysisFileRequest(source).snapshot
        let manual = try LocalAdjustment(name: "Unabhängige manuelle Maske", mask: .init(shape: .linear(
            start: .init(x: 0, y: 0), end: .init(x: 1, y: 1))), settings: .init(shadows: 5))
        let settings = EditSettings(localAdjustments: [manual])
        let snapshot = AIEditingSnapshot(assetID: originalSnapshot.assetID, source: originalSnapshot.source,
            settings: settings, token: originalSnapshot.token)
        let request = AIEditingRequest(prompt: "Korrigiere den überstrahlten Hintergrund.", snapshot: snapshot)
        let provider = LocalAIEditingProviderFactory.makeAssistantProvider()
        #expect(provider.capabilities.contains(.imageUnderstanding))
        let coordinator = AIRequestCoordinator(provider: provider)
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await coordinator.proposal(for: request)
        guard case .changes(let proposal, let target) = result.validation else { Issue.record("Expected regional correction"); return }
        let layer = try #require(result.localAdjustments.first)
        #expect(result.localAdjustments.count == 1)
        #expect(layer.mask.isInverted && layer.settings.highlights < 0)
        #expect(layer.settings.exposure <= 0)
        #expect(proposal.changes.isEmpty)
        #expect(Array(target.localAdjustments.prefix(settings.localAdjustments.count)) == settings.localAdjustments)
        #expect(target.localAdjustments.count == 2)
        #expect(target.exposure == settings.exposure && target.highlights == settings.highlights)
        guard case .subject(let raster) = layer.mask.shape else { Issue.record("Expected frozen native foreground matte inverted for background"); return }
        try ImageAwareEditingProvider.validateCoverage(raster)
        #expect(try Data(contentsOf: source) == original)
        imageEditingEvaluationMeasurement("production background and retained manual mask", start: start)
        try await imageEditingEvaluationExport(baseline: snapshot, target: target, layer: layer)
    }

    @Test(.enabled("Requires PICEDIT_RUN_IMAGE_EDITING_EVALUATION=1, a ready local vision model, and the ignored local test_picture3.jpg fixture") {
        guard await imageEditingEvaluationAvailable() else { return false }
        let exists = FileManager.default.fileExists(atPath: imageEditingEvaluationFixture.path)
        if !exists { print("Image editing monochrome qualification skipped: optional local fixture test_picture3.jpg is absent; it is not available in CI.") }
        return exists
    }, arguments: ["mache den hintergrund schwarz weiss", "Mache den Hintergrund schwarzweiß.", "Mache den Hintergrund schwarz weiß."])
    func actualAssistantMakesOnlyBackgroundBlackAndWhite(_ prompt: String) async throws {
        let source = imageEditingEvaluationFixture
        let original = try Data(contentsOf: source)
        let snapshot = try analysisFileRequest(source).snapshot
        let request = AIEditingRequest(prompt: prompt, snapshot: snapshot)
        let coordinator = AIRequestCoordinator(provider: LocalAIEditingProviderFactory.makeAssistantProvider())
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await coordinator.proposal(for: request)
        guard case .changes(let proposal, let target) = result.validation else { Issue.record("Expected background desaturation"); return }
        let layer = try #require(result.localAdjustments.first)
        #expect(result.localAdjustments.count == 1)
        #expect(layer.mask.isInverted)
        #expect(layer.settings == LocalAdjustmentSettings(saturation: -100))
        #expect(proposal.changes.isEmpty)
        var globals = target
        globals.localAdjustments = snapshot.settings.localAdjustments
        #expect(globals == snapshot.settings)
        #expect(try Data(contentsOf: source) == original)
        imageEditingEvaluationMeasurement("production black-and-white background", start: start)
        if prompt == "mache den hintergrund schwarz weiss" {
            try await imageEditingEvaluationExport(baseline: snapshot, target: target, layer: layer, subdirectory: "monochrome")
        }
    }
}

private func imageEditingEvaluationAvailable() async -> Bool {
    guard ProcessInfo.processInfo.environment["PICEDIT_RUN_IMAGE_EDITING_EVALUATION"] == "1" else { return false }
    let provider = LocalAIEditingProviderFactory.makeAssistantProvider()
    guard provider.capabilities.contains(.imageUnderstanding) else {
        print("Image editing qualification unavailable: requires macOS 27 and FoundationModels 2 vision support.")
        return false
    }
    if case .unavailable(let reason) = await provider.availability() {
        print("Image editing qualification unavailable: \(reason.localizedDescription)")
        return false
    }
    return true
}
private var imageEditingEvaluationFixture: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/LocalTestImages/test_picture3.jpg")
}
private func imageEditingEvaluationScene() throws -> PreviewBitmap {
    let context = try #require(CGContext(data: nil, width: 512, height: 320, bitsPerComponent: 8, bytesPerRow: 512 * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 0.93, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 512, height: 320))
    context.setFillColor(CGColor(red: 0.025, green: 0.04, blue: 0.07, alpha: 1))
    context.fill(CGRect(x: 30, y: 25, width: 260, height: 270))
    context.setFillColor(CGColor(red: 0.07, green: 0.10, blue: 0.15, alpha: 1))
    context.fillEllipse(in: CGRect(x: 90, y: 60, width: 150, height: 190))
    context.setFillColor(CGColor(red: 0.6, green: 0.7, blue: 0.35, alpha: 1))
    context.fill(CGRect(x: 350, y: 100, width: 100, height: 120))
    return PreviewBitmap(image: try #require(context.makeImage()))
}
private func imageEditingEvaluationMeasurement(_ label: String, start: TimeInterval) {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    print("Image editing qualification v1 \(label): elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start))s, high-water-RSS=\(usage.ru_maxrss)B; direction/selection/schema checks only, no perceptual quality guarantee.")
}
private func imageEditingEvaluationExport(baseline: AIEditingSnapshot, target: EditSettings, layer: LocalAdjustment,
                                          subdirectory: String? = nil) async throws {
    // Photo-derived artifacts are created only for an explicitly requested local
    // evaluation destination. The ignored source fixture is never overwritten.
    guard let path = ProcessInfo.processInfo.environment["PICEDIT_IMAGE_EDITING_EVALUATION_OUTPUT"] else { return }
    guard path.hasPrefix("/") else { Issue.record("Evaluation output must be an absolute local directory"); return }
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let output = subdirectory.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let preparer = ImageAnalysisPreparer()
    let lifecycle = UUID()
    let before = try await preparer.prepare(ImageAnalysisRequest(snapshot: baseline, inputKind: .editedPreview, lifecycleID: lifecycle))
    let targetSnapshot = AIEditingSnapshot(assetID: baseline.assetID, source: baseline.source, settings: target,
        token: baseline.token, persistedVersion: baseline.persistedVersion)
    let after = try await preparer.prepare(ImageAnalysisRequest(snapshot: targetSnapshot, inputKind: .editedPreview, lifecycleID: lifecycle))
    try analysisPNG(before.bitmap).write(to: output.appendingPathComponent("current-before.png"), options: .atomic)
    try analysisPNG(after.bitmap).write(to: output.appendingPathComponent("current-after.png"), options: .atomic)
    let raster: LocalMaskRaster
    switch layer.mask.shape {
    case .subject(let value), .sky(let value): raster = value
    default: Issue.record("Expected automatic raster selection"); return
    }
    let coverage = layer.mask.isInverted ? Data(raster.bytes.map { 255 - $0 }) : raster.bytes
    let provider = try #require(CGDataProvider(data: coverage as CFData))
    let image = try #require(CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 8,
        bytesPerRow: raster.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    try analysisPNG(PreviewBitmap(image: image)).write(to: output.appendingPathComponent("selected-background.png"), options: .atomic)
}
