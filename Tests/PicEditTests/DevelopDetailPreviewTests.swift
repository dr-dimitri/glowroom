import AppKit
import Foundation
import PicEditCore
import SwiftUI
import Testing
@testable import PicEdit

@Suite("Detail preview pixel geometry")
struct DevelopDetailPreviewGeometryTests {
    @Test(arguments: [1.0, 2.0])
    func retinaZoomMapsPreviewPixelsToPhysicalDisplayPixels(magnification: Double) {
        let geometry = DevelopDetailGeometry(imageSize: CGSize(width: 1_200, height: 800),
            viewport: CGSize(width: 260, height: 260), center: CGPoint(x: 0.5, y: 0.5),
            magnification: magnification, displayScale: 2)
        let frame = geometry.imageFrame
        #expect(abs(Double(frame.width) * 2 - 1_200 * magnification) < 0.000_001)
        #expect(abs(Double(frame.height) * 2 - 800 * magnification) < 0.000_001)
        #expect(frame.midX == 130 && frame.midY == 130)
        #expect(frame.minX * 2 == (frame.minX * 2).rounded())
        #expect(frame.minY * 2 == (frame.minY * 2).rounded())
    }

    @Test func edgeSelectionsKeepTheViewportCoveredAndAlignToDisplayPixels() {
        for (center, expected) in [
            (CGPoint(x: -0.2, y: -0.1), CGPoint.zero),
            (CGPoint(x: 1.2, y: 1.1), CGPoint(x: -340, y: -140))
        ] {
            let geometry = DevelopDetailGeometry(imageSize: CGSize(width: 1_200, height: 800),
                viewport: CGSize(width: 260, height: 260), center: center,
                magnification: 1, displayScale: 2)
            #expect(geometry.imageFrame.origin == expected)
            #expect(geometry.imageFrame.contains(CGRect(x: 0, y: 0, width: 260, height: 260)))
        }
        let fractional = DevelopDetailGeometry(imageSize: CGSize(width: 1_201, height: 801),
            viewport: CGSize(width: 260, height: 260), center: CGPoint(x: 0.317, y: 0.683),
            magnification: 1, displayScale: 2)
        #expect(fractional.imageFrame.minX * 2 == (fractional.imageFrame.minX * 2).rounded())
        #expect(fractional.imageFrame.minY * 2 == (fractional.imageFrame.minY * 2).rounded())
    }

    @Test func smallImagesRemainCenteredWithoutUpscalingToFillTheLoupe() {
        let geometry = DevelopDetailGeometry(imageSize: CGSize(width: 120, height: 80),
            viewport: CGSize(width: 260, height: 260), center: CGPoint(x: 0, y: 1),
            magnification: 1, displayScale: 2)
        #expect(geometry.imageFrame == CGRect(x: 100, y: 110, width: 60, height: 40))
        let invalidCenter = DevelopDetailGeometry(imageSize: CGSize(width: 1_200, height: 800),
            viewport: CGSize(width: 260, height: 260), center: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
            magnification: 1, displayScale: 2)
        #expect(invalidCenter.imageFrame.midX == 130 && invalidCenter.imageFrame.midY == 130)
    }

    @Test func normalizedSelectionRejectsLetterboxesAndNonfiniteInput() {
        let rect = CGRect(x: 100, y: 0, width: 400, height: 600)
        #expect(DevelopDetailGeometry.normalizedPoint(CGPoint(x: 200, y: 450), imageRect: rect)
            == CGPoint(x: 0.25, y: 0.75))
        for point in [
            CGPoint(x: 50, y: 300), CGPoint(x: 550, y: 300),
            CGPoint(x: 200, y: -1), CGPoint(x: 200, y: 601),
            CGPoint(x: CGFloat.nan, y: 300), CGPoint(x: 200, y: CGFloat.infinity)
        ] {
            #expect(DevelopDetailGeometry.normalizedPoint(point, imageRect: rect) == nil)
        }
        #expect(DevelopDetailGeometry.normalizedPoint(.zero, imageRect: .zero) == nil)
    }

    @Test func fittingShowsTheWholeImageIndependentOfThePreviousZoomAndCenter() {
        let geometry = DevelopDetailGeometry(imageSize: CGSize(width: 1_200, height: 800),
            viewport: CGSize(width: 260, height: 260), center: CGPoint(x: 0.1, y: 0.9),
            magnification: 2, displayScale: 2, fitsImage: true)
        #expect(abs(geometry.imageFrame.width - 260) < 0.000_001)
        #expect(abs(geometry.imageFrame.height - 520.0 / 3) < 0.000_001)
        #expect(abs(geometry.imageFrame.midX - 130) < 0.000_001)
        #expect(abs(geometry.imageFrame.midY - 130) < 0.000_001)
    }
}

@Suite("Detail loupe pointer gestures")
struct DevelopDetailLoupeInteractionTests {
    private let viewport = CGSize(width: 200, height: 200)
    private let zoomedFrame = CGRect(x: -100, y: -200, width: 600, height: 800)

    @Test func clickSwitchesToFitAndTheNextClickChoosesTheZoomCenter() {
        var interaction = DevelopDetailLoupeInteraction()
        let click = CGPoint(x: 40, y: 80)
        #expect(interaction.handle(event(.began, from: click, to: click),
            imageFrame: zoomedFrame, viewport: viewport, fitsImage: false) == nil)
        #expect(interaction.handle(event(.ended, from: click, to: click),
            imageFrame: zoomedFrame, viewport: viewport, fitsImage: false) == .fit)
        let fittedFrame = CGRect(x: 50, y: 0, width: 100, height: 200)
        let zoomClick = CGPoint(x: 75, y: 150)
        _ = interaction.handle(event(.began, from: zoomClick, to: zoomClick),
            imageFrame: fittedFrame, viewport: viewport, fitsImage: true)
        #expect(interaction.handle(event(.ended, from: zoomClick, to: zoomClick),
            imageFrame: fittedFrame, viewport: viewport, fitsImage: true) == .zoom(CGPoint(x: 0.25, y: 0.75)))
    }

    @Test func dragUsesItsVisibleBaselineDespiteIntermediateRendersAndClampsAtTheEdges() {
        var interaction = DevelopDetailLoupeInteraction()
        let start = CGPoint(x: 50, y: 50)
        _ = interaction.handle(event(.began, from: start, to: start),
            imageFrame: zoomedFrame, viewport: viewport, fitsImage: false)
        #expect(interaction.handle(event(.changed, from: start, to: CGPoint(x: 80, y: 70)),
            imageFrame: zoomedFrame, viewport: viewport, fitsImage: false) == .pan(CGPoint(x: 17.0 / 60, y: 0.35)))
        #expect(interaction.isDragging)
        // A render now reflects the first movement; the next event still uses
        // total translation from the original visible frame, without feedback.
        let intermediate = zoomedFrame.offsetBy(dx: 30, dy: 20)
        #expect(interaction.handle(event(.changed, from: start, to: CGPoint(x: 110, y: 90)),
            imageFrame: intermediate, viewport: viewport, fitsImage: false) == .pan(CGPoint(x: 7.0 / 30, y: 0.325)))
        #expect(interaction.handle(event(.ended, from: start, to: CGPoint(x: 10_050, y: -9_950)),
            imageFrame: intermediate, viewport: viewport, fitsImage: false) == .pan(CGPoint(x: 1.0 / 6, y: 0.875)))
        #expect(!interaction.isDragging)
    }

    @Test func returningADragToItsStartDoesNotTurnItIntoAClick() {
        var interaction = DevelopDetailLoupeInteraction()
        let start = CGPoint(x: 50, y: 50)
        _ = interaction.handle(event(.began, from: start, to: start),
            imageFrame: zoomedFrame, viewport: viewport, fitsImage: false)
        _ = interaction.handle(event(.changed, from: start, to: CGPoint(x: 80, y: 50)),
            imageFrame: zoomedFrame, viewport: viewport, fitsImage: false)
        #expect(interaction.handle(event(.ended, from: start, to: start),
            imageFrame: zoomedFrame, viewport: viewport, fitsImage: false) == .pan(CGPoint(x: 1.0 / 3, y: 0.375)))
    }

    @Test func cancellationAndFitLetterboxesDoNotProduceAnAction() {
        var interaction = DevelopDetailLoupeInteraction()
        let start = CGPoint(x: 50, y: 50)
        _ = interaction.handle(event(.began, from: start, to: start),
            imageFrame: zoomedFrame, viewport: viewport, fitsImage: false)
        _ = interaction.handle(event(.changed, from: start, to: CGPoint(x: 80, y: 50)),
            imageFrame: zoomedFrame, viewport: viewport, fitsImage: false)
        #expect(interaction.handle(event(.cancelled, from: start, to: start),
            imageFrame: zoomedFrame, viewport: viewport, fitsImage: false) == nil)
        #expect(!interaction.isDragging)
        #expect(interaction.handle(event(.ended, from: start, to: start),
            imageFrame: zoomedFrame, viewport: viewport, fitsImage: false) == nil)

        let fittedFrame = CGRect(x: 50, y: 0, width: 100, height: 200)
        let letterbox = CGPoint(x: 25, y: 100)
        _ = interaction.handle(event(.began, from: letterbox, to: letterbox),
            imageFrame: fittedFrame, viewport: viewport, fitsImage: true)
        #expect(interaction.handle(event(.ended, from: letterbox, to: CGPoint(x: 75, y: 100)),
            imageFrame: fittedFrame, viewport: viewport, fitsImage: true) == nil)
        let inside = CGPoint(x: 75, y: 100)
        _ = interaction.handle(event(.began, from: inside, to: inside),
            imageFrame: fittedFrame, viewport: viewport, fitsImage: true)
        _ = interaction.handle(event(.changed, from: inside, to: CGPoint(x: 90, y: 100)),
            imageFrame: fittedFrame, viewport: viewport, fitsImage: true)
        #expect(interaction.handle(event(.ended, from: inside, to: inside),
            imageFrame: fittedFrame, viewport: viewport, fitsImage: true) == nil,
            "Dragging the fitted overview must not unexpectedly zoom it")
    }

    @Test func draggingAnImageSmallerThanTheViewportKeepsItCentered() {
        var interaction = DevelopDetailLoupeInteraction()
        let frame = CGRect(x: 70, y: 80, width: 60, height: 40)
        let start = CGPoint(x: 100, y: 100)
        _ = interaction.handle(event(.began, from: start, to: start),
            imageFrame: frame, viewport: viewport, fitsImage: false)
        #expect(interaction.handle(event(.ended, from: start, to: CGPoint(x: 110, y: 105)),
            imageFrame: frame, viewport: viewport, fitsImage: false) == .pan(CGPoint(x: 0.5, y: 0.5)))
    }

    private func event(_ phase: DevelopCropInputEvent.Phase, from start: CGPoint, to end: CGPoint) -> DevelopCropInputEvent {
        DevelopCropInputEvent(phase: phase, kind: .pointer, startLocation: start, location: end)
    }
}

@Suite("Detail picker canvas and lifecycle", .serialized)
@MainActor
struct DevelopDetailPreviewTests {
    @Test(arguments: [1.0, 2.0])
    func hoveringFollowsTheDisplayedPhotoAndLeavesFitAtTheChosenMagnification(magnification: Double) async throws {
        let fixture = try DetailPreviewFixture.make()
        let workspace = fixture.workspace
        workspace.detailMagnification = magnification
        workspace.detailFitsImage = true
        let host = DetailPreviewCanvasHost()
        defer { host.close(); workspace.clear() }
        try await host.mount(fixture)
        let input = try host.inputView()

        #expect(workspace.detailFitsImage)
        try host.send(.mouseEntered, to: input, at: CGPoint(x: 200, y: 450))
        #expect(workspace.detailCenter == CGPoint(x: 0.25, y: 0.75))
        #expect(!workspace.detailFitsImage, "Following the photo must show the detail rather than the fitted overview")
        #expect(workspace.detailMagnification == magnification)
        #expect(workspace.picksDetail, "Hovering must keep following until an image click fixes the detail")

        try host.send(.mouseMoved, to: input, at: CGPoint(x: 400, y: 150))
        #expect(workspace.detailCenter == CGPoint(x: 0.75, y: 0.25))
        #expect(workspace.detailMagnification == magnification)
        #expect(workspace.picksDetail)
        #expect(workspace.navigatorImage === fixture.displayed.image)
    }

    @Test func clickingFixesTheFollowedDetailAndReactivatingResumesFollowing() async throws {
        let fixture = try DetailPreviewFixture.make()
        let workspace = fixture.workspace
        let host = DetailPreviewCanvasHost()
        defer { host.close(); workspace.clear() }
        try await host.mount(fixture)
        let input = try host.inputView()

        try host.send(.mouseMoved, to: input, at: CGPoint(x: 400, y: 150))
        #expect(workspace.detailCenter == CGPoint(x: 0.75, y: 0.25))
        try host.click(input, at: CGPoint(x: 200, y: 450))
        #expect(!workspace.picksDetail)
        #expect(workspace.detailCenter == CGPoint(x: 0.25, y: 0.75))
        // The old native callback can still receive a movement before SwiftUI
        // disables the surface. Its live selection guard must keep the lock.
        try host.send(.mouseMoved, to: input, at: CGPoint(x: 400, y: 150))
        #expect(workspace.detailCenter == CGPoint(x: 0.25, y: 0.75))
        try await host.settle()
        #expect(!input.inputEnabled)

        workspace.picksDetail = true
        try await host.settle()
        #expect(input.inputEnabled)
        try host.send(.mouseMoved, to: input, at: CGPoint(x: 400, y: 150))
        #expect(workspace.detailCenter == CGPoint(x: 0.75, y: 0.25))
        #expect(workspace.picksDetail)
    }

    @Test func croppedAndRotatedPreviewCanBePickedWithoutAnOriginalCanvas() async throws {
        let fixture = try DetailPreviewFixture.make()
        let host = DetailPreviewCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        let input = try host.inputView()

        #expect(!fixture.workspace.isOriginalCanvasReady)
        #expect(fixture.workspace.picksDetail)
        #expect(input.inputEnabled)
        #expect(input.accessibilityIdentifier() == "develop.detail-canvas")
        #expect(input.cursor(CGPoint(x: 200, y: 450)) === NSCursor.crosshair)
        #expect(input.cursor(CGPoint(x: 50, y: 300)) === NSCursor.arrow)
        try host.click(input, at: CGPoint(x: 200, y: 450))
        #expect(fixture.workspace.detailCenter == CGPoint(x: 0.25, y: 0.75))
        #expect(!fixture.workspace.picksDetail, "One valid image click finishes the selection")
        #expect(input.cursor(CGPoint(x: 200, y: 450)) === NSCursor.arrow)
        #expect(fixture.workspace.navigatorImage === fixture.displayed.image)
    }

    @Test func letterboxesAndExitingKeepTheLastDetailWithoutFixingIt() async throws {
        let fixture = try DetailPreviewFixture.make()
        let host = DetailPreviewCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        let input = try host.inputView()
        try host.send(.mouseMoved, to: input, at: CGPoint(x: 400, y: 150))
        let previous = fixture.workspace.detailCenter
        #expect(previous == CGPoint(x: 0.75, y: 0.25))
        try host.send(.mouseMoved, to: input, at: CGPoint(x: 50, y: 300))
        try host.send(.mouseExited, to: input, at: CGPoint(x: -1, y: 300))
        #expect(fixture.workspace.picksDetail)
        #expect(fixture.workspace.detailCenter == previous)
        try host.click(input, at: CGPoint(x: 50, y: 300))
        #expect(fixture.workspace.picksDetail)
        #expect(fixture.workspace.detailCenter == previous)

        // Releasing inside resumes following, but an outside press cannot fix it.
        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 50, y: 300))
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 200, y: 450))
        #expect(fixture.workspace.picksDetail)
        #expect(fixture.workspace.detailCenter == CGPoint(x: 0.25, y: 0.75))
        try host.click(input, at: CGPoint(x: 200, y: 450))
        #expect(!fixture.workspace.picksDetail)
        #expect(fixture.workspace.detailCenter == CGPoint(x: 0.25, y: 0.75))
    }

    @Test func cancellationUsesTheEscapePathAndDiscardsAHeldClick() async throws {
        let fixture = try DetailPreviewFixture.make()
        let host = DetailPreviewCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        let input = try host.inputView()
        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 200, y: 450))
        let previous = fixture.workspace.detailCenter
        #expect(previous == CGPoint(x: 0.25, y: 0.75))
        #expect(input.cancelForEscape())
        #expect(!fixture.workspace.picksDetail)
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 400, y: 150))
        #expect(fixture.workspace.detailCenter == previous)
        #expect(input.cursor(CGPoint(x: 200, y: 450)) === NSCursor.arrow)
    }

    @Test func escapeEndsTheMainImagePickerEvenBeforeAPointerGesture() async throws {
        let fixture = try DetailPreviewFixture.make()
        let host = DetailPreviewCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        #expect(try host.inputView().cancelForEscape())
        #expect(!fixture.workspace.picksDetail)
        #expect(fixture.workspace.detailCenter == CGPoint(x: 0.4, y: 0.6))
    }

    @Test func togglingThePickerOffDiscardsAHeldClick() async throws {
        let fixture = try DetailPreviewFixture.make()
        let host = DetailPreviewCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        let input = try host.inputView()
        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 200, y: 450))
        let previous = fixture.workspace.detailCenter
        #expect(previous == CGPoint(x: 0.25, y: 0.75))
        fixture.workspace.picksDetail = false
        try await host.settle()
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 400, y: 150))
        #expect(fixture.workspace.detailCenter == previous)
        #expect(!fixture.workspace.picksDetail)
    }

    @Test(arguments: ["source", "geometry", "resolution"])
    func changingTheInputIdentityDiscardsAHeldClick(change: String) async throws {
        let fixture = try DetailPreviewFixture.make()
        let host = DetailPreviewCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        let input = try host.inputView()
        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 200, y: 450))
        var expected = fixture.workspace.detailCenter
        switch change {
        case "source":
            let replacement = DetailPreviewFixture.source("replacement")
            fixture.workspace.bind(source: replacement)
            fixture.workspace.receive(fixture.displayed, sourceBitmap: fixture.original)
            fixture.workspace.markDisplayed(source: replacement, settings: fixture.settings)
            expected = CGPoint(x: 0.5, y: 0.5)
        case "geometry":
            // The requested crop changed, while the previous frame is still visible.
            var geometry = fixture.settings.developGeometry
            geometry.flipHorizontal.toggle()
            host.presentation.geometry = geometry
        default:
            fixture.workspace.receive(try DetailPreviewFixture.bitmap(width: 160, height: 240),
                sourceBitmap: fixture.original)
        }
        try await host.settle()
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 200, y: 450))
        #expect(fixture.workspace.detailCenter == expected)
        #expect(!fixture.workspace.picksDetail)
    }

    @Test func aStaleSpatialMappingCannotMoveTheDetailWhileFollowing() async throws {
        let fixture = try DetailPreviewFixture.make()
        let host = DetailPreviewCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        var pendingGeometry = fixture.settings.developGeometry
        pendingGeometry.flipHorizontal.toggle()
        host.presentation.geometry = pendingGeometry
        try await host.settle()
        let input = try host.inputView()
        #expect(!input.inputEnabled)

        // Keep selection requested to distinguish the mapping guard from the
        // cancellation caused by replacing the previous input identity.
        fixture.workspace.picksDetail = true
        try await host.settle()
        let previous = fixture.workspace.detailCenter
        #expect(!input.inputEnabled)
        try host.send(.mouseMoved, to: input, at: CGPoint(x: 400, y: 150))
        #expect(fixture.workspace.detailCenter == previous)
        #expect(fixture.workspace.picksDetail)
    }

    @Test func acceptingANewSpatialMappingResetsTheSelectionButToneChangesKeepIt() throws {
        let fixture = try DetailPreviewFixture.make()
        defer { fixture.workspace.clear() }
        let point = fixture.workspace.detailCenter
        var tone = fixture.settings
        tone.exposure = 0.75
        fixture.workspace.markDisplayed(source: fixture.source, settings: tone)
        #expect(fixture.workspace.detailCenter == point)
        #expect(fixture.workspace.picksDetail)
        var spatial = tone
        spatial.developGeometry.quarterTurns = 2
        fixture.workspace.markDisplayed(source: fixture.source, settings: spatial)
        #expect(fixture.workspace.detailCenter == CGPoint(x: 0.5, y: 0.5))
        #expect(!fixture.workspace.picksDetail)
    }

    @Test func toolWhiteBalanceAndClearEndSelection() throws {
        let fixture = try DetailPreviewFixture.make()
        let workspace = fixture.workspace
        defer { workspace.clear() }
        workspace.tool = .crop
        #expect(!workspace.picksDetail)
        workspace.tool = .basic
        workspace.picksDetail = true
        workspace.picksWhiteBalance = true
        #expect(!workspace.picksDetail && workspace.picksWhiteBalance)
        workspace.picksDetail = true
        #expect(workspace.picksDetail && !workspace.picksWhiteBalance)
        workspace.clear()
        #expect(!workspace.picksDetail)
        #expect(workspace.navigatorImage == nil)
        #expect(workspace.detailCenter == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func nativeLoupeStaysClippedAndSupportsFitZoomAndDragging() async throws {
        let fixture = try DetailPreviewFixture.make()
        let bitmap = try DetailPreviewFixture.patternedBitmap()
        let workspace = fixture.workspace
        workspace.receive(bitmap, sourceBitmap: bitmap)
        workspace.picksDetail = false
        workspace.detailCenter = CGPoint(x: 0.5, y: 0.5)
        let host = DetailPreviewLoupeHost()
        defer { host.close(); workspace.clear() }
        try await host.mount(workspace)
        let input = try host.inputView()
        #expect(abs(input.bounds.width - 260) < 0.01)
        #expect(abs(input.bounds.height - 260) < 0.01,
            "The zoomed image must not enlarge the native hit surface beyond the clipped loupe")
        #expect(input.cursor(CGPoint(x: 130, y: 130)) === NSCursor.openHand)
        try host.captureIfRequested(name: "zoom")

        try host.click(input, at: CGPoint(x: 130, y: 130))
        try await host.settle()
        #expect(workspace.detailFitsImage)
        let overview = try host.inputView()
        #expect(overview.cursor(CGPoint(x: 130, y: 130)) === NSCursor.crosshair)
        #expect(overview.cursor(CGPoint(x: 130, y: 10)) === NSCursor.arrow)
        try host.click(overview, at: CGPoint(x: 130, y: 10))
        #expect(workspace.detailFitsImage, "Clicking overview letterboxes keeps the overview visible")
        let overviewFrame = DevelopDetailGeometry(imageSize: CGSize(width: 1_200, height: 800),
            viewport: overview.bounds.size, center: workspace.detailCenter,
            magnification: 1, displayScale: 2, fitsImage: true).imageFrame
        let chosen = CGPoint(x: overviewFrame.minX + overviewFrame.width * 0.25,
            y: overviewFrame.minY + overviewFrame.height * 0.75)
        try host.captureIfRequested(name: "fit")
        try host.click(overview, at: chosen)
        try await host.settle()
        #expect(!workspace.detailFitsImage)
        #expect(abs(workspace.detailCenter.x - 0.25) < 0.000_001)
        #expect(abs(workspace.detailCenter.y - 0.75) < 0.000_001)
        #expect(workspace.detailMagnification == 1)

        let zoomed = try host.inputView()
        // Both coordinates begin within the movable range, making a 20-point
        // drag equal 40 image pixels on the explicitly configured Retina view.
        workspace.detailCenter = CGPoint(x: 0.5, y: 0.5)
        try await host.settle()
        try host.send(.leftMouseDown, to: zoomed, at: CGPoint(x: 130, y: 130))
        try host.send(.leftMouseDragged, to: zoomed, at: CGPoint(x: 150, y: 150))
        try await host.settle()
        #expect(abs(workspace.detailCenter.x - 7.0 / 15) < 0.000_001)
        #expect(abs(workspace.detailCenter.y - 0.45) < 0.000_001)
        try host.send(.leftMouseDragged, to: zoomed, at: CGPoint(x: 170, y: 170))
        try await host.settle()
        #expect(abs(workspace.detailCenter.x - 13.0 / 30) < 0.000_001)
        #expect(abs(workspace.detailCenter.y - 0.4) < 0.000_001)
        try host.send(.leftMouseUp, to: zoomed, at: CGPoint(x: 170, y: 170))
        #expect(!workspace.detailFitsImage, "Ending a drag must not also toggle to the overview")
        try await host.settle()
        #expect(abs(try host.inputView().bounds.width - 260) < 0.01)
        try host.captureIfRequested(name: "dragged")
    }

    @Test func nativeLoupeYieldsIdleEscapeAndCancelsDragsOnEscapeOrANewMapping() async throws {
        let fixture = try DetailPreviewFixture.make()
        let workspace = fixture.workspace
        let bitmap = try DetailPreviewFixture.bitmap(width: 1_200, height: 800)
        workspace.receive(bitmap, sourceBitmap: bitmap)
        workspace.picksDetail = false
        workspace.detailCenter = CGPoint(x: 0.5, y: 0.5)
        let host = DetailPreviewLoupeHost()
        defer { host.close(); workspace.clear() }
        try await host.mount(workspace)
        let input = try host.inputView()
        #expect(!input.cancelForEscape(), "An idle loupe must leave Escape for the active canvas tool")
        #expect(workspace.detailCenter == CGPoint(x: 0.5, y: 0.5))
        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 130, y: 130))
        try host.send(.leftMouseDragged, to: input, at: CGPoint(x: 150, y: 150))
        try await host.settle()
        let beforeCancel = workspace.detailCenter
        #expect(input.cancelForEscape())
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 200, y: 200))
        #expect(workspace.detailCenter == beforeCancel)
        #expect(!workspace.detailFitsImage)
        #expect(!input.cancelForEscape())

        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 130, y: 130))
        try host.send(.leftMouseDragged, to: input, at: CGPoint(x: 150, y: 150))
        try await host.settle()
        var mirrored = fixture.settings
        mirrored.developGeometry.flipHorizontal.toggle()
        workspace.markDisplayed(source: fixture.source, settings: mirrored)
        #expect(workspace.detailCenter == CGPoint(x: 0.5, y: 0.5))
        try await host.settle()
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 210, y: 210))
        #expect(workspace.detailCenter == CGPoint(x: 0.5, y: 0.5),
            "A held drag for the old mapping cannot overwrite the new frame's reset center")
        #expect(!workspace.detailFitsImage)
    }
}

@MainActor
private struct DetailPreviewFixture {
    let workspace: DevelopWorkspace
    let source: AISourceIdentity
    let settings: EditSettings
    let original: PreviewBitmap
    let displayed: PreviewBitmap

    static func make() throws -> Self {
        let workspace = DevelopWorkspace(analyze: { _ in
            DevelopPreviewAnalysis(width: 1, height: 1, pixels: [80, 120, 160, 255],
                channels: [[Int]](repeating: [Int](repeating: 0, count: 128), count: 3),
                shadows: 0, highlights: 0)
        })
        let source = source("original")
        var settings = EditSettings.neutral
        settings.developGeometry.crop = try DevelopCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        settings.developGeometry.quarterTurns = 1
        settings.developGeometry.flipHorizontal = true
        let original = try bitmap(width: 240, height: 160)
        let displayed = try bitmap(width: 80, height: 120)
        workspace.bind(source: source)
        workspace.markDisplayed(source: source, settings: settings)
        workspace.receive(displayed, sourceBitmap: original)
        workspace.detailCenter = CGPoint(x: 0.4, y: 0.6)
        workspace.picksDetail = true
        return Self(workspace: workspace, source: source, settings: settings,
            original: original, displayed: displayed)
    }

    static func source(_ name: String) -> AISourceIdentity {
        .original(.init(fileURL: URL(fileURLWithPath: "/tmp/picedit-detail-\(name).png"),
            modifiedAt: .distantPast, fileSize: 4))
    }

    static func bitmap(width: Int, height: Int) throws -> PreviewBitmap {
        let provider = try #require(CGDataProvider(data: Data(repeating: 255, count: width * height * 4) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return PreviewBitmap(image: try #require(CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)))
    }

    static func patternedBitmap() throws -> PreviewBitmap {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 1_200, height: 800,
            bitsPerComponent: 8, bytesPerRow: 1_200 * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Procedural colored tiles make scale, clipping, and movement visible
        // in optional screenshots without depending on private test pictures.
        for row in 0..<8 {
            for column in 0..<12 {
                context.setFillColor(CGColor(red: CGFloat(column + 1) / 12,
                    green: CGFloat(row + 1) / 8, blue: (row + column).isMultiple(of: 2) ? 0.25 : 0.65, alpha: 1))
                context.fill(CGRect(x: column * 100, y: row * 100, width: 98, height: 98))
            }
        }
        return PreviewBitmap(image: try #require(context.makeImage()))
    }
}

@MainActor
private final class DetailPreviewPresentation: ObservableObject {
    @Published var geometry = DevelopGeometry.neutral
}

@MainActor
private struct DetailPreviewHostView: View {
    let workspace: DevelopWorkspace
    @ObservedObject var presentation: DetailPreviewPresentation
    var body: some View {
        DevelopDetailCanvas(workspace: workspace, geometry: presentation.geometry)
            .frame(width: 600, height: 600)
    }
}

@MainActor
private final class DetailPreviewCanvasHost {
    let presentation = DetailPreviewPresentation()
    private let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderBack(nil)
    }

    func mount(_ fixture: DetailPreviewFixture) async throws {
        presentation.geometry = fixture.settings.developGeometry
        hosting.rootView = AnyView(DetailPreviewHostView(workspace: fixture.workspace, presentation: presentation))
        try await settle()
        #expect(fixture.workspace.picksDetail, "Mounting the picker must not cancel the user's selection mode")
        #expect(try inputView().inputEnabled)
    }

    func click(_ input: DevelopCropNativeInputView, at point: CGPoint) throws {
        try send(.leftMouseDown, to: input, at: point)
        try send(.leftMouseUp, to: input, at: point)
    }

    func send(_ type: NSEvent.EventType, to input: DevelopCropNativeInputView, at point: CGPoint) throws {
        let location = input.convert(point, to: nil)
        let event: NSEvent
        if type == .mouseEntered || type == .mouseExited {
            event = try #require(NSEvent.enterExitEvent(with: type, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        } else {
            event = try #require(NSEvent.mouseEvent(with: type, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        switch type {
        case .mouseEntered: input.mouseEntered(with: event)
        case .mouseMoved: input.mouseMoved(with: event)
        case .mouseExited: input.mouseExited(with: event)
        case .leftMouseDown: input.mouseDown(with: event)
        case .leftMouseUp: input.mouseUp(with: event)
        default: Issue.record("Unsupported detail picker input event: \(type)")
        }
    }

    func settle() async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
    }

    func inputView() throws -> DevelopCropNativeInputView {
        var pending: [NSView] = [hosting]
        while let view = pending.popLast() {
            if let input = view as? DevelopCropNativeInputView { return input }
            pending.append(contentsOf: view.subviews)
        }
        return try #require(nil as DevelopCropNativeInputView?, "Missing native detail picker surface")
    }

    func close() { window.close() }
}

@MainActor
private final class DetailPreviewLoupeHost {
    private let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 340, height: 360),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderBack(nil)
    }

    func mount(_ workspace: DevelopWorkspace) async throws {
        hosting.rootView = AnyView(DevelopDetailPreview(workspace: workspace, isEnabled: true)
            .environment(\.displayScale, 2)
            .padding(12).frame(width: 340, height: 360)
            .background(Color(white: 0.16)))
        try await settle()
        #expect(try inputView().inputEnabled)
    }

    func click(_ input: DevelopCropNativeInputView, at point: CGPoint) throws {
        try send(.leftMouseDown, to: input, at: point)
        try send(.leftMouseUp, to: input, at: point)
    }

    func send(_ type: NSEvent.EventType, to input: DevelopCropNativeInputView, at point: CGPoint) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: input.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: input.mouseDown(with: event)
        case .leftMouseDragged: input.mouseDragged(with: event)
        case .leftMouseUp: input.mouseUp(with: event)
        default: Issue.record("Unsupported loupe input event: \(type)")
        }
    }

    func settle() async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
    }

    func inputView() throws -> DevelopCropNativeInputView {
        var pending: [NSView] = [hosting]
        while let view = pending.popLast() {
            if let input = view as? DevelopCropNativeInputView,
               input.accessibilityIdentifier() == "develop.detail-loupe" { return input }
            pending.append(contentsOf: view.subviews)
        }
        return try #require(nil as DevelopCropNativeInputView?, "Missing native detail loupe surface")
    }

    func captureIfRequested(name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["PICEDIT_DETAIL_SCREENSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Force unchanged SwiftUI content to repaint alongside the image and
        // picker; otherwise repeated offscreen captures can omit cached layers.
        var pending: [NSView] = [hosting]
        while let view = pending.popLast() {
            view.needsDisplay = true
            pending.append(contentsOf: view.subviews)
        }
        hosting.displayIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("picedit-details-\(name).png"))
    }

    func close() { window.close() }
}
