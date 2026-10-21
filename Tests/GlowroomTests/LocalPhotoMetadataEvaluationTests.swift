import CoreGraphics
import Darwin
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Local photo metadata real raster smoke v1", .serialized, .timeLimit(.minutes(5)))
struct LocalPhotoMetadataEvaluationTests {
    @Test(.enabled("Requires explicit GLOWROOM_RUN_PHOTO_METADATA_EVALUATION=1; an unavailable native model fails the opted-in gate") {
        ProcessInfo.processInfo.environment["GLOWROOM_RUN_PHOTO_METADATA_EVALUATION"] == "1"
    })
    func twoUnlabeledSyntheticImagesProduceNativeMetadataAndExplicitFreshness() async throws {
        // A background is not a round object: the old substring "rund"
        // accidentally matched "Hintergrund" and could admit a missing shape.
        #expect(!metadataSmokeFeatures("Ein grünes Dreieck und eine gelbe Fläche vor weißem Hintergrund.", alternate: true).shapes)
        #expect(!metadataSmokeFeatures("Rotes Quadrat und blaues Rechteck vor weißem Hintergrund.", alternate: false).shapes)
        #expect(metadataSmokeFeatures("Grünes Dreieck und gelbe Scheibe.", alternate: true).shapes)
        let clock = ContinuousClock()
        let native = LocalImageAnalysisFactory.makeProvider()
        if case .unavailable(let reason) = await native.availability() {
            Issue.record("Native metadata smoke unavailable: \(reason.localizedDescription)")
            throw ImageAnalysisError.unavailable(reason)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-Metadata-Synthetic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = MetadataNativeEvaluationCounter(provider: native)
        let preparer = ImageAnalysisPreparer(imagePipeline: ImagePreviewPipeline(), renderPipeline: AdjustedPreviewPipeline())
        let service = ImageAnalysisService(provider: provider, preparer: preparer, budget: .shared)
        let suggestor = LocalPhotoMetadataSuggestor(service: service)
        var sources: [PhotoMetadataSelectionContext] = []
        var results: [PhotoMetadataSuggestionResult] = []
        for index in 0..<2 {
            // Random filenames and the production prompt reveal no expected colors or shapes.
            let url = directory.appendingPathComponent(UUID().uuidString + ".png")
            try analysisPNG(metadataSyntheticShapes(alternate: index == 1)).write(to: url)
            let analysis = try analysisFileRequest(url)
            guard case .original(let source) = analysis.snapshot.source else { throw ImageAnalysisError.invalidRequest }
            let token = analysis.snapshot.token
            let context = PhotoMetadataSelectionContext(assetID: url.path, source: source,
                selectionSessionID: token.selectionSessionID, selectionGeneration: token.selectionGeneration,
                catalogSessionID: token.editSessionID, catalogGeneration: 1, canModify: true, isClosing: false)
            let request = PhotoMetadataSuggestionRequest(context: context, lifecycleID: UUID(), formGeneration: 0, expectedVersion: .absent)
            let start = clock.now
            let result = try await suggestor.suggest(request)
            let elapsed = metadataSmokeSeconds(start.duration(to: clock.now))
            let fields = result.fields
            #expect(result.request.id == request.id && result.source.original == .metadata(source))
            #expect(try PhotoTextNormalization.normalize(fields, requireSuggestionContent: true) == fields)
            #expect(!fields.title.isEmpty && !fields.description.isEmpty && !fields.tags.isEmpty && fields.language == "de_DE")
            let text = ([fields.title, fields.description] + fields.tags).joined(separator: " ")
            let (colors, shapes) = metadataSmokeFeatures(text, alternate: index == 1)
            #expect(colors && shapes, "A schema-valid constant caption cannot satisfy both unseen input rasters")
            let provenance = try #require(result.source.analyzedRaster)
            #expect(provenance.providerID == provider.descriptor.providerID && provenance.modelID == provider.descriptor.modelID)
            #expect(provenance.raster.pixelWidth == 512 && provenance.raster.pixelHeight == 320)
            #expect(provenance.raster.byteCount <= ImageAnalysisPreparer.maximumRasterBytes)
            #expect(provenance.metadataPromptVersion == 1 && provenance.metadataSchemaVersion == 1)
            let cachedStart = clock.now
            let cached = try await suggestor.suggest(PhotoMetadataSuggestionRequest(context: context, lifecycleID: UUID(),
                formGeneration: 1, expectedVersion: .absent))
            let cachedTime = metadataSmokeSeconds(cachedStart.duration(to: clock.now))
            #expect(cached.fields == fields && cached.source == result.source)
            #expect(await provider.metadataCalls == index + 1)
            #expect(await provider.analysisCalls == 0)
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            print("Photo metadata smoke v1 case \(index + 1): pixels/colors/shapes=\(colors && shapes), native-call=\(String(format: "%.3f", elapsed))s, cached=\(String(format: "%.4f", cachedTime))s, raster=512x320, process-high-water-RSS=\(usage.ru_maxrss)B")
            print("Photo metadata smoke v1 fields: \(String(decoding: try JSONEncoder().encode(fields), as: UTF8.self))")
            sources.append(context); results.append(result)
        }
        #expect(Set(results.compactMap { $0.source.analyzedRaster?.raster.sha256 }).count == 2)
        #expect(results[0].fields != results[1].fields)
        // One further explicitly fresh proposal must call the actual metadata
        // adapter again, although identical pixels correctly keep the same hash.
        let fresh = try await suggestor.suggest(PhotoMetadataSuggestionRequest(context: sources[0], lifecycleID: UUID(),
            formGeneration: 2, expectedVersion: .absent, rasterPolicy: .refreshRaster))
        #expect(fresh.source.analyzedRaster?.raster.sha256 == results[0].source.analyzedRaster?.raster.sha256)
        #expect(await provider.metadataCalls == 3)
        #expect(await provider.maximumActive == 1)
        #expect(await provider.analysisCalls == 0)
        print("Photo metadata smoke v1: native metadata calls=3, analysis calls=0, explicit refresh completed; no confirmation or metadata persistence requested")
    }
}

private actor MetadataNativeEvaluationCounter: ImageAnalysisProvider {
    nonisolated let descriptor: ImageAnalysisProviderDescriptor
    private let provider: any ImageAnalysisProvider
    private(set) var metadataCalls = 0
    private(set) var analysisCalls = 0
    private(set) var maximumActive = 0
    private var active = 0
    init(provider: any ImageAnalysisProvider) { self.provider = provider; descriptor = provider.descriptor }
    func availability() async -> ImageAnalysisAvailability { await provider.availability() }
    func analyze(_ input: PreparedImageAnalysisInput) async throws -> Data {
        analysisCalls += 1
        return try await provider.analyze(input)
    }
    func metadata(_ input: PreparedImageAnalysisInput) async throws -> Data {
        metadataCalls += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        return try await provider.metadata(input)
    }
}

private func metadataSyntheticShapes(alternate: Bool) throws -> PreviewBitmap {
    let context = try #require(CGContext(data: nil, width: 512, height: 320, bitsPerComponent: 8, bytesPerRow: 512 * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 512, height: 320))
    if alternate {
        context.setFillColor(CGColor(red: 0, green: 0.7, blue: 0, alpha: 1))
        context.move(to: CGPoint(x: 50, y: 80)); context.addLine(to: CGPoint(x: 220, y: 80)); context.addLine(to: CGPoint(x: 135, y: 250))
        context.closePath(); context.fillPath()
        context.setFillColor(CGColor(red: 1, green: 0.9, blue: 0, alpha: 1))
        context.fillEllipse(in: CGRect(x: 300, y: 90, width: 150, height: 150))
    } else {
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fillEllipse(in: CGRect(x: 50, y: 80, width: 160, height: 160))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 300, y: 80, width: 150, height: 150))
    }
    return PreviewBitmap(image: try #require(context.makeImage()))
}

private func metadataSmokeFeatures(_ text: String, alternate: Bool) -> (colors: Bool, shapes: Bool) {
    let words = text.lowercased().split(whereSeparator: { !$0.isLetter })
    func has(_ stems: [String]) -> Bool { words.contains { word in stems.contains { word.hasPrefix($0) } } }
    if alternate {
        return (has(["grün"]) && has(["gelb"]), has(["dreieck"]) && has(["kreis", "oval", "rund", "scheib"]))
    }
    return (has(["rot"]) && has(["blau"]), has(["kreis", "rund"]) && has(["quadrat", "rechteck"]))
}
private func metadataSmokeSeconds(_ duration: Duration) -> Double {
    let value = duration.components
    return Double(value.seconds) + Double(value.attoseconds) / 1_000_000_000_000_000_000
}
