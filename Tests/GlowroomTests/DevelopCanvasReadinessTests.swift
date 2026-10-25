import Testing
import Foundation
import GlowroomCore
@testable import Glowroom

@Suite("Develop canvas readiness")
struct DevelopCanvasReadinessTests {
    @Test @MainActor
    func opticalCropInputsWaitForTheExactAcceptedDistortionAndSourceToolsStayUnwarped() throws {
        let workspace = DevelopWorkspace()
        let source = AISourceIdentity.original(.init(fileURL: URL(fileURLWithPath: "/tmp/optical-ready.jpg"), modifiedAt: .distantPast, fileSize: 4))
        workspace.bind(source: source)
        workspace.tool = .crop
        let first = try DevelopOpticsSettings(distortion: 30)
        let second = try DevelopOpticsSettings(distortion: 31)
        workspace.markDisplayed(source: source, settings: .neutral)
        #expect(workspace.isCropCanvasReady(for: .neutral))
        #expect(!workspace.isCropCanvasReady(for: first))
        let optical = EditSettings(developGeometry: .init(constrainToImage: false, optics: first))
        workspace.markDisplayed(source: source, settings: optical)
        #expect(workspace.isCropCanvasReady(for: first))
        #expect(!workspace.isCropCanvasReady(for: second))
        #expect(!workspace.isCropCanvasReady(for: .neutral))
        #expect(!workspace.isOriginalCanvasReady)
        workspace.tool = .repair
        #expect(!workspace.isOriginalCanvasReady)
        workspace.markDisplayed(source: source, settings: .neutral)
        #expect(workspace.isOriginalCanvasReady)
        workspace.clear()
        #expect(!workspace.isCropCanvasReady(for: .neutral))
    }

    @Test @MainActor
    func cropAndRotationMustFinishRenderingBeforeOriginalCanvasAcceptsInput() throws {
        let workspace = DevelopWorkspace()
        let source = AISourceIdentity.original(.init(fileURL: URL(fileURLWithPath: "/tmp/canvas-ready.jpg"), modifiedAt: .distantPast, fileSize: 4))
        workspace.bind(source: source)
        var cropped = EditSettings.neutral
        cropped.developGeometry.crop = try DevelopCropRect(x: 0.2, y: 0.1, width: 0.5, height: 0.7)
        cropped.developGeometry.quarterTurns = 1
        workspace.markDisplayed(source: source, settings: cropped)
        workspace.tool = .repair
        #expect(!workspace.isOriginalCanvasReady)
        workspace.markDisplayed(source: source, settings: .neutral)
        #expect(workspace.isOriginalCanvasReady)
        var corrected = EditSettings(exposure: 2)
        corrected.developGeometry.retouchStrokes = [try .init(source: LocalMaskPoint(x: 0.1, y: 0.2), target: LocalMaskPoint(x: 0.5, y: 0.5), radius: 0.1)]
        workspace.markDisplayed(source: source, settings: corrected)
        #expect(workspace.isOriginalCanvasReady)
        workspace.clear()
        workspace.markDisplayed(source: source, settings: .neutral)
        #expect(!workspace.isOriginalCanvasReady)
    }

    @Test
    func hdrRequestsCannotUseEmbeddedSDRAndKeepTheirIdentityWhenResized() {
        let request = PreviewRequest(url: URL(fileURLWithPath: "/tmp/hdr-input.heic"), modifiedAt: .distantPast,
            pixelSize: 2400, allowsEmbeddedPreview: true, allowsHDR: true)
        #expect(request.allowsHDR && !request.allowsEmbeddedPreview)
        #expect(request.resized(to: 512).allowsHDR)
        let sdr = PreviewRequest(url: URL(fileURLWithPath: "/tmp/hdr-input.heic"), modifiedAt: .distantPast,
            pixelSize: 2400, allowsEmbeddedPreview: false)
        #expect(!request.hasSameOriginal(as: sdr))
    }
}
