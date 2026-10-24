import AppKit
import SwiftUI

/// All coordinates use the image's displayed orientation, with a top-left origin.
/// This constant-size geometry stays on the main actor with the native viewport;
/// decoding and rendering remain in the existing bounded preview pipeline.
struct PhotoViewportGeometry {
    static let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func fittedImage(in size: CGSize, aspectRatio: CGFloat, padding: CGFloat = 18) -> CGRect {
        let canvasWidth = size.width.isFinite ? max(0, size.width) : 0
        let canvasHeight = size.height.isFinite ? max(0, size.height) : 0
        let width = max(1, canvasWidth - padding * 2)
        let height = max(1, canvasHeight - padding * 2)
        let ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1
        let imageWidth = min(width, height * ratio)
        let imageHeight = imageWidth / ratio
        return CGRect(x: (canvasWidth - imageWidth) / 2, y: (canvasHeight - imageHeight) / 2,
                      width: imageWidth, height: imageHeight)
    }

    static func normalizedVisibleRect(image: CGRect, viewport: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return unitRect }
        let visible = image.intersection(viewport)
        guard !visible.isNull, !visible.isEmpty else { return .zero }
        return CGRect(x: (visible.minX - image.minX) / image.width,
                      y: (visible.minY - image.minY) / image.height,
                      width: visible.width / image.width, height: visible.height / image.height)
    }

    static func constrainedOrigin(_ proposed: CGPoint, viewport: CGSize, image: CGRect) -> CGPoint {
        func axis(_ value: CGFloat, visible: CGFloat, start: CGFloat, length: CGFloat) -> CGFloat {
            guard value.isFinite else { return start + (length - visible) / 2 }
            if visible >= length { return start + (length - visible) / 2 }
            return min(start + length - visible, max(start, value))
        }
        return CGPoint(x: axis(proposed.x, visible: viewport.width, start: image.minX, length: image.width),
                       y: axis(proposed.y, visible: viewport.height, start: image.minY, length: image.height))
    }

    static func clampedPoint(_ value: CGPoint) -> CGPoint {
        CGPoint(x: value.x.isFinite ? min(1, max(0, value.x)) : 0.5,
                y: value.y.isFinite ? min(1, max(0, value.y)) : 0.5)
    }
}

@MainActor
private protocol PhotoViewportDriving: AnyObject {
    func zoom(to enabled: Bool, anchor: CGPoint, animated: Bool)
    func moveCenter(to point: CGPoint)
}

/// Only views that need navigation observe these few scalars. In particular,
/// navigator drags never publish on DevelopWorkspace or request another RAW.
@MainActor
final class PhotoViewportPosition: ObservableObject {
    @Published fileprivate(set) var normalizedVisibleRect = PhotoViewportGeometry.unitRect
}

@MainActor
final class PhotoViewportState: ObservableObject {
    @Published private(set) var isZoomed = false
    let position = PhotoViewportPosition()
    var normalizedVisibleRect: CGRect { position.normalizedVisibleRect }
    @Published private(set) var navigationAvailable = true
    private weak var driver: (any PhotoViewportDriving)?
    private(set) var anchor = CGPoint(x: 0.5, y: 0.5)

    func toggleZoom(at normalizedPoint: CGPoint? = nil) {
        anchor = PhotoViewportGeometry.clampedPoint(normalizedPoint ?? CGPoint(x: 0.5, y: 0.5))
        isZoomed.toggle()
        if !isZoomed { position.normalizedVisibleRect = PhotoViewportGeometry.unitRect }
        driver?.zoom(to: isZoomed, anchor: anchor, animated: true)
    }

    func reset() {
        anchor = CGPoint(x: 0.5, y: 0.5)
        isZoomed = false
        position.normalizedVisibleRect = PhotoViewportGeometry.unitRect
        driver?.zoom(to: false, anchor: anchor, animated: false)
    }

    func moveVisibleCenter(to point: CGPoint) {
        guard isZoomed, navigationAvailable else { return }
        anchor = PhotoViewportGeometry.clampedPoint(point)
        driver?.moveCenter(to: anchor)
    }

    func setNavigationAvailable(_ available: Bool) {
        guard navigationAvailable != available else { return }
        navigationAvailable = available
        if !available { position.normalizedVisibleRect = PhotoViewportGeometry.unitRect }
    }

    fileprivate func attach(_ value: any PhotoViewportDriving) { driver = value }
    fileprivate func detach(_ value: any PhotoViewportDriving) {
        if driver === value { driver = nil }
    }

    fileprivate func reportVisibleRect(_ rect: CGRect) {
        let value = isZoomed && navigationAvailable ? rect : PhotoViewportGeometry.unitRect
        if normalizedVisibleRect != value { position.normalizedVisibleRect = value }
    }
}

/// Native magnification animates the accepted pixels and retains NSScrollView
/// navigation for wheel, trackpad and the existing hand/three-finger adapter.
struct PhotoCanvasViewport<Content: View>: NSViewRepresentable {
    @ObservedObject var state: PhotoViewportState
    let imageAspectRatio: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let content: Content

    init(state: PhotoViewportState, imageAspectRatio: CGFloat, @ViewBuilder content: () -> Content) {
        self.state = state; self.imageAspectRatio = imageAspectRatio; self.content = content()
    }

    func makeNSView(context: Context) -> PhotoCanvasScrollView {
        let view = PhotoCanvasScrollView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PhotoCanvasScrollView, context: Context) {
        view.configure(state: state, aspectRatio: imageAspectRatio, reduceMotion: reduceMotion,
                       content: AnyView(content.padding(18).environment(\.photoCanvasPanning, state.isZoomed)
                           .environment(\.photoCanvasMagnification, state.isZoomed ? 2 : 1)
                           .environment(\.self, context.environment)))
    }

    static func dismantleNSView(_ view: PhotoCanvasScrollView, coordinator: ()) { view.invalidate() }
}

@MainActor
private final class PhotoViewportClipView: NSClipView {
    var imageFrame = CGRect.zero
    override var isFlipped: Bool { true }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return super.constrainBoundsRect(proposedBounds) }
        var result = proposedBounds
        result.origin = PhotoViewportGeometry.constrainedOrigin(proposedBounds.origin,
            viewport: proposedBounds.size, image: imageFrame)
        return result
    }


}

/// AppKit also scrolls its clip view while adjusting document layout. Finish
/// zoom at actual scrollbar input, before AppKit captures drag coordinates.
@MainActor
private final class PhotoViewportScroller: NSScroller {
    var onNavigationBegan: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onNavigationBegan?()
        super.mouseDown(with: event)
    }
}

@MainActor
final class PhotoCanvasScrollView: NSScrollView, PhotoViewportDriving {
    private let photoClip = PhotoViewportClipView()
    private let hosting = PhotoViewportHostingView(rootView: AnyView(EmptyView()))
    private weak var viewportState: PhotoViewportState?
    private var aspectRatio: CGFloat = 1
    private var documentSize = CGSize.zero
    private var lastViewportSize = CGSize.zero
    private var reduceMotion = false
    private var hasConfigured = false
    private var laysOutDocument = false
    private var boundsObserver: NSObjectProtocol?
    private var animation: Timer?
    private var animationTargetScale: CGFloat?
    private var animationTargetDocumentSize: CGSize?
    private var zoomTransitionIsActive = false
    private var pendingInitialZoomAnchor: CGPoint?
    private var reportPending = false
    private var isValid = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = photoClip
        drawsBackground = false
        photoClip.drawsBackground = false
        hasHorizontalScroller = true; hasVerticalScroller = true
        let horizontal = PhotoViewportScroller(frame: CGRect(x: 0, y: 0, width: 100, height: 12))
        let vertical = PhotoViewportScroller(frame: CGRect(x: 0, y: 0, width: 12, height: 100))
        horizontal.onNavigationBegan = { [weak self] in self?.prepareForManualNavigation() }
        vertical.onNavigationBegan = { [weak self] in self?.prepareForManualNavigation() }
        horizontalScroller = horizontal; verticalScroller = vertical
        scrollerStyle = .overlay; autohidesScrollers = true
        horizontalScrollElasticity = .none; verticalScrollElasticity = .none
        allowsMagnification = false
        minMagnification = 1; maxMagnification = 2
        hosting.sizingOptions = []
        documentView = hosting
        photoClip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: photoClip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleVisibleRectReport() }
            }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(state: PhotoViewportState, aspectRatio: CGFloat, reduceMotion: Bool, content: AnyView) {
        viewportState = state; state.attach(self)
        self.reduceMotion = reduceMotion
        let changedRatio = self.aspectRatio != aspectRatio
        self.aspectRatio = aspectRatio
        hosting.rootView = content
        if !hasConfigured {
            hasConfigured = true
            layoutDocument()
            if state.isZoomed { zoom(to: true, anchor: state.anchor, animated: false) }
        } else if changedRatio {
            let center = visibleCenter
            layoutDocument()
            moveCenter(to: center)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layoutDocument()
    }

    private func layoutDocument() {
        guard !laysOutDocument else { return }
        let size = photoClip.frame.size
        guard size.width > 0, size.height > 0 else { return }
        laysOutDocument = true
        defer { laysOutDocument = false }
        let initializesZoom = documentSize == .zero && viewportState?.isZoomed == true
        let center = pendingInitialZoomAnchor ?? (initializesZoom ? viewportState?.anchor : nil) ?? visibleCenter
        let resizing = size != lastViewportSize
        lastViewportSize = size
        if resizing, animation != nil { finishAnimation() }
        if (viewportState?.isZoomed != true && !zoomTransitionIsActive) || documentSize == .zero { documentSize = size }
        hosting.frame = CGRect(origin: .zero, size: documentSize)
        photoClip.imageFrame = PhotoViewportGeometry.fittedImage(in: documentSize, aspectRatio: aspectRatio)
        if initializesZoom {
            magnification = 2
            pendingInitialZoomAnchor = nil
        }
        if resizing || !photoClip.imageFrame.contains(photoClip.bounds) {
            scrollCenter(to: viewportState?.isZoomed == true ? center : CGPoint(x: 0.5, y: 0.5))
        }
        scheduleVisibleRectReport()
    }

    private var visibleCenter: CGPoint {
        let image = photoClip.imageFrame
        guard image.width > 0, image.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return PhotoViewportGeometry.clampedPoint(CGPoint(x: (photoClip.bounds.midX - image.minX) / image.width,
                                                          y: (photoClip.bounds.midY - image.minY) / image.height))
    }

    func zoom(to enabled: Bool, anchor: CGPoint, animated: Bool) {
        guard isValid else { return }
        stopAnimation()
        if documentSize == .zero, photoClip.frame.width <= 0 || photoClip.frame.height <= 0 {
            pendingInitialZoomAnchor = enabled ? PhotoViewportGeometry.clampedPoint(anchor) : nil
            return
        }
        // Keep the captured canvas until the fit transition has finished. A
        // panel resize while zoomed must not make the image jump on zoom-out.
        zoomTransitionIsActive = true
        layoutDocument()
        let startDocumentSize = documentSize
        let endDocumentSize = enabled ? documentSize : photoClip.frame.size
        let startScale = magnification
        let endScale: CGFloat = enabled ? 2 : 1
        let startCenter = visibleCenter
        let endCenter = enabled ? PhotoViewportGeometry.clampedPoint(anchor) : CGPoint(x: 0.5, y: 0.5)
        guard animated, !reduceMotion, abs(startScale - endScale) > 0.001 else {
            applyDocumentSize(endDocumentSize)
            apply(scale: endScale, center: endCenter)
            zoomTransitionIsActive = false
            if !enabled { layoutDocument() }
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        animationTargetScale = endScale
        animationTargetDocumentSize = endDocumentSize
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isValid else { timer.invalidate(); return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.24)
                let eased = CGFloat(progress * progress * (3 - 2 * progress))
                self.applyDocumentSize(CGSize(
                    width: startDocumentSize.width + (endDocumentSize.width - startDocumentSize.width) * eased,
                    height: startDocumentSize.height + (endDocumentSize.height - startDocumentSize.height) * eased))
                self.apply(scale: startScale + (endScale - startScale) * eased,
                    center: CGPoint(x: startCenter.x + (endCenter.x - startCenter.x) * eased,
                                    y: startCenter.y + (endCenter.y - startCenter.y) * eased))
                if progress >= 1 {
                    self.stopAnimation()
                    if !enabled { self.layoutDocument() }
                }
            }
        }
        if let animation { RunLoop.main.add(animation, forMode: .common) }
    }

    private func applyDocumentSize(_ size: CGSize) {
        documentSize = size
        hosting.frame = CGRect(origin: .zero, size: size)
        photoClip.imageFrame = PhotoViewportGeometry.fittedImage(in: size, aspectRatio: aspectRatio)
    }

    private func apply(scale: CGFloat, center: CGPoint) {
        magnification = scale
        scrollCenter(to: center)
        scheduleVisibleRectReport()
    }

    /// Finish magnification before native input captures its coordinate space.
    func prepareForManualNavigation() {
        guard isValid else { return }
        finishAnimation()
    }

    func moveCenter(to point: CGPoint) {
        guard isValid else { return }
        finishAnimation()
        scrollCenter(to: point)
    }

    private func scrollCenter(to point: CGPoint) {
        let image = photoClip.imageFrame
        let target = CGPoint(x: image.minX + point.x * image.width - photoClip.bounds.width / 2,
                             y: image.minY + point.y * image.height - photoClip.bounds.height / 2)
        let origin = PhotoViewportGeometry.constrainedOrigin(target, viewport: photoClip.bounds.size, image: image)
        photoClip.scroll(to: origin)
        reflectScrolledClipView(photoClip)
        scheduleVisibleRectReport()
    }

    override func scrollWheel(with event: NSEvent) {
        finishAnimation()
        super.scrollWheel(with: event)
    }

    private func scheduleVisibleRectReport() {
        guard !reportPending, isValid else { return }
        reportPending = true
        // Bounds can change while SwiftUI installs a new accepted preview. The
        // next main-loop pass avoids publishing into its current view update.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isValid else { return }
            self.reportPending = false
            self.viewportState?.reportVisibleRect(PhotoViewportGeometry.normalizedVisibleRect(
                image: self.photoClip.imageFrame, viewport: self.photoClip.bounds))
        }
    }

    private func finishAnimation() {
        let target = animationTargetScale
        let targetDocumentSize = animationTargetDocumentSize
        let center = visibleCenter
        stopAnimation()
        // A quick hand/navigator gesture must not leave a fractional zoom
        // behind while the toolbar and navigator correctly report 2×.
        if let target {
            if let targetDocumentSize { applyDocumentSize(targetDocumentSize) }
            apply(scale: target, center: center)
        }
    }

    private func stopAnimation() {
        animation?.invalidate(); animation = nil; animationTargetScale = nil
        animationTargetDocumentSize = nil; zoomTransitionIsActive = false
    }

    func invalidate() {
        isValid = false
        viewportState?.detach(self)
        stopAnimation()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
    }
}

/// Native scroll magnification can make SwiftUI discard the lower part of an
/// otherwise visible representable's hit region. Keep normal SwiftUI targets;
/// only recover explicitly eligible native canvas input when it returns this
/// empty host. Eligibility must mirror the caller's SwiftUI hit-test gate.
@MainActor
private final class PhotoViewportHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        guard result === self, let scroll = enclosingScrollView, scroll.magnification > 1 else { return result }
        let local = convert(point, from: superview)
        guard visibleRect.contains(local) else { return result }
        // A photo document has a bounded native subtree. Preserve front-to-back
        // ordering and ignore hidden/disabled input without touching rendering.
        var pending = Array(subviews)
        while let view = pending.popLast() {
            guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0 else { continue }
            if view is NSControl {
                let controlPoint = convert(local, to: view)
                if view.visibleRect.contains(controlPoint), view.bounds.contains(controlPoint) {
                    // Keep an unresolved foreground control's SwiftUI gate;
                    // never reroute its location into an edit underneath it.
                    return result
                }
            }
            if let input = view as? DevelopCropNativeInputView, input.acceptsViewportHitFallback {
                let inputPoint = convert(local, to: input)
                if input.visibleRect.contains(inputPoint), input.bounds.contains(inputPoint) {
                    return input.hitTest(convert(local, to: input.superview))
                }
            }
            pending.append(contentsOf: view.subviews)
        }
        return result
    }
}
