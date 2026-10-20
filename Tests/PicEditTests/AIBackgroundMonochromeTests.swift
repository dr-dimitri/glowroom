import CoreGraphics
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Assistant background monochrome rendering", .timeLimit(.minutes(1)))
struct AIBackgroundMonochromeTests {
    @Test
    func backgroundBecomesGrayWhileSubjectAndExistingEditsStayIntact() async throws {
        let bitmap = try monochromeScene()
        let manual = try LocalAdjustment(name: "Meine manuelle Maske", mask: .init(shape: .linear(
            start: .init(x: 0, y: 0), end: .init(x: 1, y: 1))), settings: .init(shadows: 9))
        let baseline = EditSettings(exposure: 0.3, contrast: 8, saturation: 12, localAdjustments: [manual])
        let snapshot = AIEditingSnapshot(assetID: "synthetic-background-monochrome",
            source: .original(AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: "/private/PicEdit-Monochrome-Regression.png"),
                modifiedAt: .distantPast, fileSize: 100)), settings: baseline,
            token: AIEditingToken(editSessionID: UUID(), editGeneration: 0, selectionSessionID: UUID(), selectionGeneration: 0))
        let request = AIEditingRequest(prompt: "mache den hintergrund schwarz weiss", snapshot: snapshot)
        let runtime = MonochromePlanRuntime()
        let preparer = MonochromeScenePreparer(bitmap: bitmap)
        // Frozen subject selection: green background on the left, red subject on
        // the right. Samples below stay far from the interpolation boundary.
        let matte = try LocalMaskRaster(width: 4, height: 2,
            bytes: Data([0, 0, 255, 255, 0, 0, 255, 255]))
        let budget = AIResourceBudget()
        let provider = ImageAwareEditingProvider(runtime: runtime, preparer: preparer, budget: budget,
            maskGenerator: { _, kind in
                #expect(kind == .subject)
                return matte
            })
        let result = try await AIRequestCoordinator(provider: provider, budget: budget).proposal(for: request)
        guard case .changes(let proposal, let target) = result.validation else {
            Issue.record("Expected an effective background correction")
            return
        }
        #expect(result.request == request)
        #expect(await runtime.request == request)
        #expect(proposal.changes.isEmpty)
        #expect(result.localAdjustments.count == 1)
        #expect(target.localAdjustments.first == manual)
        #expect(target.localAdjustments.count == 2)
        var globals = target
        globals.localAdjustments = baseline.localAdjustments
        #expect(globals == baseline)
        #expect(request.snapshot.settings == baseline)
        let layer = try #require(result.localAdjustments.first)
        #expect(layer.mask.shape == .subject(matte))
        #expect(layer.mask.isInverted)
        #expect(layer.settings.saturation == -100)

        let before = try monochromePixels(EditRenderer.render(bitmap, settings: baseline).image)
        let after = try monochromePixels(EditRenderer.render(bitmap, settings: target).image)
        for y in [8, 24, 40] {
            let backgroundBefore = monochromeRGB(before, width: bitmap.image.width, x: 12, y: y)
            let backgroundAfter = monochromeRGB(after, width: bitmap.image.width, x: 12, y: y)
            #expect(monochromeSpread(backgroundBefore) > 50)
            #expect(monochromeSpread(backgroundAfter) <= 2)
            let subjectBefore = monochromeRGB(before, width: bitmap.image.width, x: 84, y: y)
            let subjectAfter = monochromeRGB(after, width: bitmap.image.width, x: 84, y: y)
            #expect(monochromeSpread(subjectAfter) > 50)
            for channel in 0..<3 {
                #expect(abs(subjectAfter[channel] - subjectBefore[channel]) <= 2)
            }
        }
    }
}

private actor MonochromePlanRuntime: ImageEditingModelRuntime {
    private(set) var request: AIEditingRequest?
    func availability() -> AIAvailability { .available }
    func generate(_ request: AIEditingRequest, input: PreparedImageAnalysisInput) -> ImageEditingPlan {
        self.request = request
        return .init(status: .proposal, changes: [], regions: [
            .init(target: .background, changes: [.init(parameter: .saturation, value: -100)])
        ], explanation: "Den Hintergrund vollständig entsättigen; das Motiv bleibt farbig.")
    }
}

private actor MonochromeScenePreparer: ImageAnalysisPreparing {
    let bitmap: PreviewBitmap
    private let stamp = ImageAnalysisSourceStamp(device: 1, inode: 2, byteCount: 100,
        modifiedSeconds: 3, modifiedNanoseconds: 0, changedSeconds: 3, changedNanoseconds: 0)
    init(bitmap: PreviewBitmap) { self.bitmap = bitmap }
    func sourceStamp(for request: ImageAnalysisRequest) -> ImageAnalysisSourceStamp { stamp }
    func prepare(_ request: ImageAnalysisRequest) throws -> PreparedImageAnalysisInput {
        .init(bitmap: try EditRenderer.render(bitmap, settings: request.snapshot.settings), sourceStamp: stamp,
            rasterSHA256: String(repeating: "a", count: 64), colorProfile: "sRGB", colorProfileSHA256: nil)
    }
}

private func monochromeScene() throws -> PreviewBitmap {
    let width = 96, height = 48
    var bytes = [UInt8]()
    bytes.reserveCapacity(width * height * 4)
    for _ in 0..<height {
        for x in 0..<width { bytes += x < width / 2 ? [35, 145, 65, 255] : [175, 45, 30, 255] }
    }
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    return PreviewBitmap(image: image)
}

private func monochromePixels(_ image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
        let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}

private func monochromeRGB(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> [Int] {
    let offset = (y * width + x) * 4
    return bytes[offset..<(offset + 3)].map(Int.init)
}

private func monochromeSpread(_ rgb: [Int]) -> Int { rgb.max()! - rgb.min()! }
