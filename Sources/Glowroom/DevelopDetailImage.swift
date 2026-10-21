import AppKit
import Combine
import QuartzCore
import SwiftUI

/// SwiftUI configures the accepted pixels and zoom, while the native view owns
/// the high-frequency position subscription. Hover never invalidates a body.
struct DevelopDetailImage: NSViewRepresentable {
    let position: DevelopDetailPosition
    let image: CGImage
    let viewport: CGSize
    let magnification: Double
    let displayScale: CGFloat
    let fitsImage: Bool
    let hdr: Bool

    func makeNSView(context: Context) -> DevelopDetailNativeImageView {
        let view = DevelopDetailNativeImageView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DevelopDetailNativeImageView, context: Context) {
        view.configure(position: position, image: image, viewport: viewport,
            magnification: magnification, displayScale: displayScale, fitsImage: fitsImage, hdr: hdr)
    }

    static func dismantleNSView(_ view: DevelopDetailNativeImageView, coordinator: ()) {
        view.invalidate()
    }
}

@MainActor
final class DevelopDetailNativeImageView: NSView {
    let imageView = DevelopDetailPixelHostingView(rootView: DevelopDetailPixels(image: nil, fitsImage: false, hdr: false))
    private(set) var visibleImageFrame = CGRect.zero
    private weak var position: DevelopDetailPosition?
    private var positionSubscription: AnyCancellable?
    private var acceptedImage: CGImage?
    private var viewport = CGSize.zero
    private var magnification = 1.0
    private var displayScale: CGFloat = 1
    private var fitsImage = false
    private var hdr = false
    private var isInvalidated = false

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizesSubviews = false
        clipsToBounds = true
        wantsLayer = true
        setAccessibilityElement(false)

        imageView.sizingOptions = []
        imageView.wantsLayer = true
        // The native view's geometry stays fixed during hover. Its accepted
        // pixels move only through the parent's sublayer transform.
        imageView.setAccessibilityElement(false)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The image can extend well beyond the loupe. Its separate bounded input
    // surface owns all gestures; decorative pixels never capture panel input.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        applyImageTranslation()
    }

    func configure(position: DevelopDetailPosition, image: CGImage, viewport: CGSize,
                   magnification: Double, displayScale: CGFloat, fitsImage: Bool, hdr: Bool) {
        guard !isInvalidated else { return }
        let replacesPosition = self.position !== position
        if replacesPosition {
            positionSubscription?.cancel()
            positionSubscription = nil
            self.position = position
        }
        let replacesImage = acceptedImage.map { ObjectIdentifier($0) } != ObjectIdentifier(image)
        let replacesPixels = replacesImage || self.fitsImage != fitsImage || self.hdr != hdr
        self.viewport = viewport
        self.magnification = magnification
        self.displayScale = displayScale
        self.fitsImage = fitsImage
        self.hdr = hdr

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if replacesImage { acceptedImage = image }
        if replacesPixels {
            imageView.rootView = DevelopDetailPixels(image: image, fitsImage: fitsImage, hdr: hdr)
        }
        let frame = geometry(center: position.center).imageFrame
        let imageViewFrame = CGRect(origin: .zero, size: frame.size)
        if imageView.frame != imageViewFrame { imageView.frame = imageViewFrame }
        visibleImageFrame = frame
        applyImageTranslation()
        CATransaction.commit()

        if replacesPosition {
            // DevelopDetailPosition is main-actor owned and Published delivers
            // synchronously. Use the emitted value: its stored center changes
            // after publication. No queue, task, or timer is needed per event.
            positionSubscription = position.$center.removeDuplicates().sink { [weak self] center in
                MainActor.assumeIsolated { self?.moveImage(to: center) }
            }
        }
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        positionSubscription?.cancel()
        positionSubscription = nil
        position = nil
        acceptedImage = nil
        imageView.rootView = DevelopDetailPixels(image: nil, fitsImage: fitsImage, hdr: hdr)
    }

    private func geometry(center: CGPoint) -> DevelopDetailGeometry {
        let imageSize = acceptedImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        return DevelopDetailGeometry(imageSize: imageSize, viewport: viewport, center: center,
            magnification: magnification, displayScale: displayScale, fitsImage: fitsImage)
    }

    private func moveImage(to center: CGPoint) {
        guard !isInvalidated, acceptedImage != nil else { return }
        let origin = geometry(center: center).imageFrame.origin
        guard visibleImageFrame.origin != origin else { return }
        visibleImageFrame.origin = origin
        // Changing an NSView's frame causes AppKit to rebuild tracking regions
        // and reset the cursor. Moving only its layer contents avoids that work
        // while keeping the accepted image and static SwiftUI pixels reusable.
        applyImageTranslation()
    }

    private func applyImageTranslation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayerTransform = CATransform3DMakeTranslation(
            visibleImageFrame.origin.x, visibleImageFrame.origin.y, 0)
        CATransaction.commit()
    }
}

/// Keep the established SwiftUI interpolation and HDR rendering, without
/// observing the frequently changing position in the image's view hierarchy.
struct DevelopDetailPixels: View {
    let image: CGImage?
    let fitsImage: Bool
    let hdr: Bool

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1).resizable()
                .interpolation(fitsImage ? .high : .none)
                .allowedDynamicRange(hdr ? .high : .standard)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

@MainActor
final class DevelopDetailPixelHostingView: NSHostingView<DevelopDetailPixels> {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
