import CoreGraphics
import Darwin
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Local image analysis real raster smoke v1", .serialized, .timeLimit(.minutes(5)))
struct LocalImageAnalysisEvaluationTests {
    @Test(.enabled("Requires PICEDIT_RUN_IMAGE_ANALYSIS_EVALUATION=1 and a ready German local vision model") {
        guard ProcessInfo.processInfo.environment["PICEDIT_RUN_IMAGE_ANALYSIS_EVALUATION"] == "1" else { return false }
        if case .unavailable(let reason) = await LocalImageAnalysisFactory.makeProvider().availability() {
            print("Image analysis smoke unavailable: \(reason.localizedDescription)")
            return false
        }
        return true
    })
    func twoDistinctSyntheticRastersUseNativeAttachmentAndBoundedCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Synthetic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ImageAnalysisEvaluationCounter(provider: LocalImageAnalysisFactory.makeProvider())
        let preparer = ImageAnalysisPreparer(imagePipeline: ImagePreviewPipeline(), renderPipeline: AdjustedPreviewPipeline())
        let service = ImageAnalysisService(provider: provider, preparer: preparer, budget: .shared)
        var hashes: Set<String> = []
        for index in 0..<2 {
            // Neither the filename nor the prompt discloses expected content.
            let url = directory.appendingPathComponent(UUID().uuidString + ".png")
            let raster = try syntheticAnalysisShapes(alternate: index == 1)
            try analysisPNG(raster).write(to: url)
            let request = try analysisFileRequest(url)
            let start = ProcessInfo.processInfo.systemUptime
            let result = try await service.analyze(request)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let text = ([result.suggestions.description] + result.suggestions.attributes.map(\.value)).joined(separator: " ").lowercased()
            // These checks depend on unseen pixels. A merely schema-valid generic
            // caption or a constant response cannot satisfy both test images.
            let colors = index == 0 ? text.contains("rot") && text.contains("blau") : text.contains("grün") && text.contains("gelb")
            let shapes = index == 0 ? (text.contains("kreis") || text.contains("rund")) && (text.contains("quadrat") || text.contains("rechteck"))
                : text.contains("dreieck") && (text.contains("kreis") || text.contains("oval") || text.contains("rund"))
            #expect(colors && shapes, "Synthetic pixel-dependent colors/shapes must be recognized")
            #expect(result.request == request)
            #expect(result.provenance.pixelWidth == 512 && result.provenance.pixelHeight == 320)
            #expect(result.provenance.byteCount <= ImageAnalysisPreparer.maximumRasterBytes)
            #expect(result.provenance.providerID == provider.descriptor.providerID)
            #expect(try await result.provenance.rasterSHA256 == preparer.prepare(request).rasterSHA256)
            hashes.insert(result.provenance.rasterSHA256)
            let warmStart = ProcessInfo.processInfo.systemUptime
            let cached = try await service.analyze(request)
            let warm = ProcessInfo.processInfo.systemUptime - warmStart
            #expect(cached.provenance == result.provenance)
            #expect(await provider.callCount == index + 1)
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            print("Image analysis smoke v1 case \(index + 1): pixels/colors/shapes=\(colors && shapes), native-call=\(String(format: "%.3f", elapsed))s, cached=\(String(format: "%.4f", warm))s, raster=512x320, high-water-RSS=\(usage.ru_maxrss)B")
        }
        #expect(hashes.count == 2)
        #expect(await provider.callCount == 2)
    }
}

private actor ImageAnalysisEvaluationCounter: ImageAnalysisProvider {
    nonisolated let descriptor: ImageAnalysisProviderDescriptor
    private let provider: any ImageAnalysisProvider
    private(set) var callCount = 0
    init(provider: any ImageAnalysisProvider) { self.provider = provider; descriptor = provider.descriptor }
    func availability() async -> ImageAnalysisAvailability { await provider.availability() }
    func analyze(_ input: PreparedImageAnalysisInput) async throws -> Data { callCount += 1; return try await provider.analyze(input) }
}
private func syntheticAnalysisShapes(alternate: Bool) throws -> PreviewBitmap {
    let context = try #require(CGContext(data: nil, width: 512, height: 320, bitsPerComponent: 8, bytesPerRow: 512 * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 512, height: 320))
    if alternate {
        context.setFillColor(CGColor(red: 0, green: 0.7, blue: 0, alpha: 1))
        context.move(to: CGPoint(x: 50, y: 80)); context.addLine(to: CGPoint(x: 220, y: 80)); context.addLine(to: CGPoint(x: 135, y: 250)); context.closePath(); context.fillPath()
        context.setFillColor(CGColor(red: 1, green: 0.9, blue: 0, alpha: 1)); context.fillEllipse(in: CGRect(x: 300, y: 90, width: 150, height: 150))
    } else {
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fillEllipse(in: CGRect(x: 50, y: 80, width: 160, height: 160))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 300, y: 80, width: 150, height: 150))
    }
    return PreviewBitmap(image: try #require(context.makeImage()))
}
