import AppKit
import Testing
@testable import Glowroom

/// These checks use real clip-view constraints. AppKit state stays ordered;
/// each check owns an independent scroll view and needs no visible window.
@Suite("Photo canvas panning", .serialized)
@MainActor
struct PhotoCanvasPanTests {
    @Test(arguments: [DevelopCropInputEvent.Kind.pointer, .threeFinger])
    func movesBothAxesFromTheGestureStartWithoutAccumulatingTranslation(kind: DevelopCropInputEvent.Kind) {
        let fixture = PhotoCanvasPanFixture(origin: CGPoint(x: 200, y: 120))
        let session = PhotoCanvasPanSession()

        session.handle(event(.began, kind: kind), in: fixture.scrollView)
        #expect(session.isActive)
        #expect(fixture.origin == CGPoint(x: 200, y: 120))

        session.handle(event(.changed, translation: CGSize(width: 40, height: -30), kind: kind), in: fixture.scrollView)
        #expect(fixture.origin == CGPoint(x: 160, y: 150), "The displayed image follows the fingers on both axes")

        session.handle(event(.changed, translation: CGSize(width: 10, height: 20), kind: kind), in: fixture.scrollView)
        #expect(fixture.origin == CGPoint(x: 190, y: 100), "Updates contain total travel, not a delta from the previous event")
        #expect(session.isActive)
    }

    @Test func clampsAllEdgesAndReturningFromAnEdgeRestoresTheOriginalOffset() {
        let fixture = PhotoCanvasPanFixture(origin: CGPoint(x: 230, y: 140))
        let session = PhotoCanvasPanSession()
        #expect(fixture.scrollView.contentSize == CGSize(width: 600, height: 400))

        session.handle(event(.began), in: fixture.scrollView)
        session.handle(event(.changed, translation: CGSize(width: 2_000, height: 2_000)), in: fixture.scrollView)
        #expect(fixture.origin == .zero)

        session.handle(event(.changed, translation: CGSize(width: -2_000, height: -2_000)), in: fixture.scrollView)
        #expect(fixture.origin == CGPoint(x: 600, y: 400))

        session.handle(event(.changed, translation: CGSize(width: 2_000, height: -2_000)), in: fixture.scrollView)
        #expect(fixture.origin == CGPoint(x: 0, y: 400))

        session.handle(event(.changed, translation: CGSize(width: -2_000, height: 2_000)), in: fixture.scrollView)
        #expect(fixture.origin == CGPoint(x: 600, y: 0))

        session.handle(event(.changed), in: fixture.scrollView)
        #expect(fixture.origin == CGPoint(x: 230, y: 140), "Clamping must not introduce drift into the gesture origin")
    }

    @Test func endingAppliesTheFinalPositionAndANewGestureStartsAtTheCurrentOffset() {
        let fixture = PhotoCanvasPanFixture(origin: CGPoint(x: 250, y: 180))
        let session = PhotoCanvasPanSession()

        session.handle(event(.changed, translation: CGSize(width: 90, height: 90)), in: fixture.scrollView)
        #expect(fixture.origin == CGPoint(x: 250, y: 180))
        #expect(!session.isActive)

        session.handle(event(.began), in: fixture.scrollView)
        session.handle(event(.changed, translation: CGSize(width: 10, height: 20)), in: fixture.scrollView)
        session.handle(event(.ended, translation: CGSize(width: 30, height: -40)), in: fixture.scrollView)
        #expect(fixture.origin == CGPoint(x: 220, y: 220))
        #expect(!session.isActive)

        session.handle(event(.changed, translation: CGSize(width: -80, height: -80)), in: fixture.scrollView)
        session.handle(event(.ended, translation: CGSize(width: -80, height: -80)), in: fixture.scrollView)
        #expect(fixture.origin == CGPoint(x: 220, y: 220))

        session.handle(event(.began), in: fixture.scrollView)
        session.handle(event(.ended, translation: CGSize(width: -25, height: 35)), in: fixture.scrollView)
        #expect(fixture.origin == CGPoint(x: 245, y: 185))
        #expect(!session.isActive)
    }

    @Test func cancelledInputKeepsTheLastAcceptedOffsetUntilANewGestureBegins() {
        let fixture = PhotoCanvasPanFixture(origin: CGPoint(x: 300, y: 200))
        let session = PhotoCanvasPanSession()
        session.handle(event(.began), in: fixture.scrollView)
        session.handle(event(.changed, translation: CGSize(width: 60, height: -20)), in: fixture.scrollView)
        #expect(fixture.origin == CGPoint(x: 240, y: 220))

        session.handle(event(.cancelled, translation: CGSize(width: -200, height: 200)), in: fixture.scrollView)
        #expect(!session.isActive)
        #expect(fixture.origin == CGPoint(x: 240, y: 220), "Cancellation must preserve the accepted view position")
        session.handle(event(.changed, translation: CGSize(width: -100, height: -100)), in: fixture.scrollView)
        session.handle(event(.ended, translation: CGSize(width: -100, height: -100)), in: fixture.scrollView)
        #expect(fixture.origin == CGPoint(x: 240, y: 220))

        session.handle(event(.began), in: fixture.scrollView)
        session.handle(event(.changed, translation: CGSize(width: -20, height: 10)), in: fixture.scrollView)
        #expect(fixture.origin == CGPoint(x: 260, y: 210))
        #expect(session.isActive)
    }

    @Test func explicitCancellationIsIdempotentAndDiscardsTheHeldGesture() {
        let fixture = PhotoCanvasPanFixture(origin: CGPoint(x: 180, y: 90))
        let session = PhotoCanvasPanSession()
        session.cancel()
        session.handle(event(.began), in: fixture.scrollView)
        session.handle(event(.changed, translation: CGSize(width: -50, height: -30)), in: fixture.scrollView)
        #expect(fixture.origin == CGPoint(x: 230, y: 120))

        session.cancel()
        session.cancel()
        #expect(!session.isActive)
        session.handle(event(.changed, translation: CGSize(width: 100, height: 100)), in: fixture.scrollView)
        session.handle(event(.ended, translation: CGSize(width: 100, height: 100)), in: fixture.scrollView)
        #expect(fixture.origin == CGPoint(x: 230, y: 120))

        session.handle(event(.began), in: fixture.scrollView)
        session.handle(event(.changed, translation: CGSize(width: 30, height: 20)), in: fixture.scrollView)
        #expect(fixture.origin == CGPoint(x: 200, y: 100))
        #expect(session.isActive)
    }

    private func event(_ phase: DevelopCropInputEvent.Phase, translation: CGSize = .zero,
                       kind: DevelopCropInputEvent.Kind = .threeFinger) -> DevelopCropInputEvent {
        let start = CGPoint(x: 160, y: 120)
        return DevelopCropInputEvent(phase: phase, kind: kind, startLocation: start,
            location: CGPoint(x: start.x + translation.width, y: start.y + translation.height))
    }
}

@MainActor
private struct PhotoCanvasPanFixture {
    let scrollView: NSScrollView
    var origin: CGPoint { scrollView.contentView.bounds.origin }

    init(origin: CGPoint) {
        _ = NSApplication.shared
        scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = .init()
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = PhotoCanvasPanDocument(frame: CGRect(x: 0, y: 0, width: 1_200, height: 800))
        scrollView.tile()
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

@MainActor
private final class PhotoCanvasPanDocument: NSView {
    override var isFlipped: Bool { true }
}
