import AppKit
import Combine
import Darwin
import QuartzCore
import Testing
@testable import PicEdit

/// Native image configuration and Combine publication share MainActor state.
/// The assertions run synchronously so a queued update cannot hide stale pixels.
@Suite("Native detail image", .serialized)
@MainActor
struct DevelopDetailNativeImageTests {
    @Test func publishedWillSetMovesTheImageToTheEmittedCenterSynchronously() throws {
        let position = DevelopDetailPosition()
        let image = try detailNativeBitmap(width: 1_200, height: 800)
        let view = DevelopDetailNativeImageView(frame: CGRect(x: 0, y: 0, width: 260, height: 260))
        defer { view.invalidate() }
        configure(view, position: position, image: image)
        #expect(view.visibleImageFrame == CGRect(x: -170, y: -70, width: 600, height: 400))

        var emittedCenter: CGPoint?
        var storedCenterDuringPublication: CGPoint?
        let observation = position.$center.dropFirst().sink { center in
            MainActor.assumeIsolated {
                emittedCenter = center
                storedCenterDuringPublication = position.center
            }
        }
        defer { observation.cancel() }
        position.center = CGPoint(x: 0.4, y: 0.6)

        #expect(emittedCenter == CGPoint(x: 0.4, y: 0.6))
        #expect(storedCenterDuringPublication == CGPoint(x: 0.5, y: 0.5),
            "Published emits before its stored value changes")
        #expect(view.visibleImageFrame == CGRect(x: -110, y: -110, width: 600, height: 400),
            "The image must use the emitted center before the setter returns")
    }

    @Test func rapidMovementAndReconfigurationReuseTheAcceptedNativeImage() throws {
        let position = DevelopDetailPosition()
        let image = try detailNativeBitmap(width: 1_200, height: 800)
        let view = DevelopDetailNativeImageView(frame: CGRect(x: 0, y: 0, width: 260, height: 260))
        defer { view.invalidate() }
        configure(view, position: position, image: image)
        let accepted = try #require(view.imageView.rootView.image)

        for index in 0..<120 {
            position.center = CGPoint(x: index.isMultiple(of: 2) ? 0.25 : 0.75, y: 0.5)
            #expect(view.imageView.rootView.image === accepted,
                "Pointer positions must not allocate another accepted bitmap")
        }
        #expect(view.visibleImageFrame == CGRect(x: -320, y: -70, width: 600, height: 400))
        configure(view, position: position, image: image)
        #expect(view.imageView.rootView.image === accepted,
            "An unchanged accepted CGImage must survive SwiftUI reconfiguration")

        let replacement = try detailNativeBitmap(width: 800, height: 1_200)
        configure(view, position: position, image: replacement)
        #expect(view.imageView.rootView.image !== accepted)
        #expect(view.imageView.rootView.image?.width == 800 && view.imageView.rootView.image?.height == 1_200)
        #expect(view.visibleImageFrame == CGRect(x: -140, y: -170, width: 400, height: 600))
    }

    @Test func replacingThePositionModelDisconnectsThePreviousSource() throws {
        let previous = DevelopDetailPosition()
        let replacement = DevelopDetailPosition()
        replacement.center = CGPoint(x: 0.4, y: 0.6)
        let image = try detailNativeBitmap(width: 1_200, height: 800)
        let view = DevelopDetailNativeImageView(frame: CGRect(x: 0, y: 0, width: 260, height: 260))
        defer { view.invalidate() }
        configure(view, position: previous, image: image)
        let accepted = try #require(view.imageView.rootView.image)

        configure(view, position: replacement, image: image)
        #expect(view.imageView.rootView.image === accepted)
        #expect(view.visibleImageFrame.origin == CGPoint(x: -110, y: -110))
        previous.center = CGPoint(x: 0.9, y: 0.1)
        #expect(view.visibleImageFrame.origin == CGPoint(x: -110, y: -110),
            "An obsolete workspace position must not move the current detail")
        replacement.center = CGPoint(x: 0.6, y: 0.4)
        #expect(view.visibleImageFrame.origin == CGPoint(x: -230, y: -30))
    }

    @Test func invalidationReleasesPixelsAndMakesFurtherUpdatesInert() throws {
        let position = DevelopDetailPosition()
        let image = try detailNativeBitmap(width: 1_200, height: 800)
        let view = DevelopDetailNativeImageView(frame: CGRect(x: 0, y: 0, width: 260, height: 260))
        configure(view, position: position, image: image)
        let acceptedFrame = view.visibleImageFrame
        view.invalidate()

        #expect(view.imageView.rootView.image == nil, "Dismantling must release the accepted pixels")
        position.center = CGPoint(x: 0.1, y: 0.9)
        #expect(view.visibleImageFrame == acceptedFrame)
        configure(view, position: DevelopDetailPosition(), image: image, magnification: 2)
        #expect(view.imageView.rootView.image == nil, "A dismantled view must not regain its pixels")
        #expect(view.visibleImageFrame == acceptedFrame)
        view.invalidate()
        #expect(view.imageView.rootView.image == nil)
    }

    @Test func zoomDisplayScaleFitAndViewportChangesConfigureTheVisibleFrame() throws {
        let position = DevelopDetailPosition()
        let image = try detailNativeBitmap(width: 1_200, height: 800)
        let view = DevelopDetailNativeImageView(frame: CGRect(x: 0, y: 0, width: 260, height: 260))
        defer { view.invalidate() }
        configure(view, position: position, image: image)
        let accepted = try #require(view.imageView.rootView.image)
        configure(view, position: position, image: image, magnification: 2)
        #expect(view.visibleImageFrame == CGRect(x: -470, y: -270, width: 1_200, height: 800))
        configure(view, position: position, image: image,
            viewport: CGSize(width: 300, height: 200), magnification: 2)
        #expect(view.visibleImageFrame == CGRect(x: -450, y: -300, width: 1_200, height: 800))
        configure(view, position: position, image: image,
            viewport: CGSize(width: 300, height: 200), displayScale: 1)
        #expect(view.visibleImageFrame == CGRect(x: -450, y: -300, width: 1_200, height: 800))
        configure(view, position: position, image: image,
            viewport: CGSize(width: 300, height: 200), fitsImage: true)
        #expect(view.visibleImageFrame == CGRect(x: 0, y: 0, width: 300, height: 200))
        configure(view, position: position, image: image,
            viewport: CGSize(width: 200, height: 200), fitsImage: true)
        let fitted = view.visibleImageFrame
        #expect(abs(fitted.minX) < 0.000_001 && abs(fitted.minY - 100.0 / 3) < 0.000_001)
        #expect(abs(fitted.width - 200) < 0.000_001 && abs(fitted.height - 400.0 / 3) < 0.000_001)
        position.center = CGPoint(x: 0.1, y: 0.9)
        #expect(view.visibleImageFrame == fitted, "Fitting must show the whole image independent of selection")
        #expect(view.imageView.rootView.image === accepted, "View geometry changes must reuse the accepted pixels")
        #expect(view.layer?.masksToBounds == true)
        #expect(view.hitTest(CGPoint(x: 130, y: 130)) == nil)
        #expect(view.imageView.hitTest(CGPoint(x: 130, y: 130)) == nil,
            "Decorative pixels must leave the bounded input surface in control")
    }

    @Test func fitAndHDRPoliciesUpdateWithoutReplacingAcceptedPixels() throws {
        let position = DevelopDetailPosition()
        let image = try detailNativeBitmap(width: 600, height: 400)
        let view = DevelopDetailNativeImageView(frame: CGRect(x: 0, y: 0, width: 260, height: 260))
        defer { view.invalidate() }
        configure(view, position: position, image: image)
        #expect(!view.imageView.rootView.fitsImage && !view.imageView.rootView.hdr)
        configure(view, position: position, image: image, fitsImage: true, hdr: true)
        #expect(view.imageView.rootView.fitsImage && view.imageView.rootView.hdr)
        #expect(view.imageView.rootView.image === image)
        configure(view, position: position, image: image, magnification: 2)
        #expect(!view.imageView.rootView.fitsImage && !view.imageView.rootView.hdr)
        #expect(view.imageView.rootView.image === image)
    }

    @Test(arguments: [1.0, 2.0])
    func renderedZoomAndFitPreserveTopAndBottomPixels(magnification: Double) throws {
        _ = NSApplication.shared
        let position = DevelopDetailPosition()
        let image = try detailNativeTopBottomBitmap()
        let viewport = CGSize(width: 40, height: 30)
        let view = DevelopDetailNativeImageView(frame: CGRect(origin: .zero, size: viewport))
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 40, height: 30),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = view
        window.orderBack(nil)
        defer { view.invalidate(); window.close() }

        configure(view, position: position, image: image, viewport: viewport,
            magnification: magnification, displayScale: 1)
        var capture = try displayedLayerSnapshot(view)
        try expectRed(at: 0.2, in: capture)
        try expectBlue(at: 0.8, in: capture)

        configure(view, position: position, image: image, viewport: viewport,
            magnification: magnification, displayScale: 1, fitsImage: true)
        capture = try displayedLayerSnapshot(view)
        try expectRed(at: 0.2, in: capture)
        try expectBlue(at: 0.8, in: capture)

        configure(view, position: position, image: image, viewport: viewport,
            magnification: magnification, displayScale: 1)
        position.center = CGPoint(x: 0.5, y: 0.25)
        try expectRed(at: 0.5, in: displayedLayerSnapshot(view))
        position.center = CGPoint(x: 0.5, y: 0.75)
        try expectBlue(at: 0.5, in: displayedLayerSnapshot(view))
    }

    @Test(arguments: [1.0, 2.0])
    func movingTheCachedLayerChangesVisiblePixelsWithoutRequestingAnotherDisplay(magnification: Double) throws {
        _ = NSApplication.shared
        let position = DevelopDetailPosition()
        position.center = CGPoint(x: 0.5, y: 0.25)
        let image = try detailNativeTopBottomBitmap()
        let viewport = CGSize(width: 40, height: 30)
        let view = DevelopDetailNativeImageView(frame: CGRect(origin: .zero, size: viewport))
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 40, height: 30),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = view
        window.orderBack(nil)
        defer { view.invalidate(); window.close() }
        configure(view, position: position, image: image, viewport: viewport,
            magnification: magnification, displayScale: 1)
        let accepted = try #require(view.imageView.rootView.image)
        // Populate the native backing once. The later captures only render
        // existing CALayer contents and never ask NSView to draw again.
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        try expectRed(at: 0.5, in: layerSnapshot(view))

        position.center = CGPoint(x: 0.5, y: 0.75)
        CATransaction.flush()
        try expectBlue(at: 0.5, in: layerSnapshot(view))
        #expect(view.imageView.rootView.image === accepted)

        if magnification == 2 {
            position.center = CGPoint(x: 0.5, y: 0.5)
            CATransaction.flush()
            let edge = try layerSnapshot(view)
            let column = try (0..<edge.pixelsHigh).map { y in
                try #require(edge.colorAt(x: edge.pixelsWide / 2, y: y)?.usingColorSpace(.sRGB))
            }
            #expect(column.contains { $0.redComponent > 0.95 } && column.contains { $0.blueComponent > 0.95 },
                "The centered cached layer must show both source halves")
            let mixed = column.enumerated().filter { _, color in
                color.alphaComponent < 0.95 || (color.redComponent > 0.05 && color.blueComponent > 0.05)
            }.map { row, color in "\(row): \(color)" }
            #expect(column.allSatisfy { color in
                color.alphaComponent > 0.95
                    && ((color.redComponent > 0.95 && color.blueComponent < 0.05)
                        || (color.blueComponent > 0.95 && color.redComponent < 0.05))
            },
                "200% pixel zoom must retain a sharp source edge; unexpected pixels: \(mixed)")
        }
    }

    /// Keep memory sampling opt-in and run this case alone for a meaningful
    /// process high-water mark. GPU/WindowServer allocations are not included.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PICEDIT_DETAIL_MEMORY_BENCHMARK"] == "1"))
    func benchmarkFullPreviewAt200Percent() throws {
        _ = NSApplication.shared
        let position = DevelopDetailPosition()
        let image = try detailNativeBitmap(width: 2_400, height: 1_600)
        let viewport = CGSize(width: 260, height: 260)
        let view = DevelopDetailNativeImageView(frame: CGRect(origin: .zero, size: viewport))
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 260, height: 260),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = view
        window.orderBack(nil)
        defer { view.invalidate(); window.close() }
        configure(view, position: position, image: image, viewport: viewport,
            magnification: 2, displayScale: window.backingScaleFactor)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let hostFrame = view.imageView.frame
        var before = rusage()
        getrusage(RUSAGE_SELF, &before)
        for index in 0..<1_200 {
            position.center = CGPoint(x: index.isMultiple(of: 2) ? 0.25 : 0.75,
                y: 0.2 + CGFloat(index % 11) * 0.06)
            CATransaction.flush()
        }
        var after = rusage()
        getrusage(RUSAGE_SELF, &after)
        #expect(view.imageView.rootView.image === image)
        #expect(view.imageView.frame == hostFrame,
            "Fast movement must not resize or reposition the native pixel host")
        let report: [String: Any] = [
            "preview_pixels": [2_400, 1_600], "zoom_percent": 200,
            "backing_scale": window.backingScaleFactor, "movements": 1_200,
            "process_peak_rss_before_bytes": before.ru_maxrss,
            "process_peak_rss_after_bytes": after.ru_maxrss,
            "excluded": "GPU and WindowServer memory; source decoding; other workspace controls"
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("PICEDIT_DETAIL_MEMORY_BENCHMARK \(String(decoding: data, as: UTF8.self))")
    }

    private func layerSnapshot(_ view: DevelopDetailNativeImageView) throws -> NSBitmapImageRep {
        let layer = try #require(view.layer)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        // Capture physical pixels. Downsampling a Retina backing into points
        // would blur edges in the test even when the on-screen zoom is sharp.
        let scale = view.window?.backingScaleFactor ?? 1
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        // CALayer's drawing context is bottom-left based; the inspector and
        // CGImage pixel rows use top-left coordinates.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    }

    private func displayedLayerSnapshot(_ view: DevelopDetailNativeImageView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.window?.displayIfNeeded()
        CATransaction.flush()
        return try layerSnapshot(view)
    }

    private func pixel(at verticalFraction: CGFloat, in image: NSBitmapImageRep) throws -> NSColor {
        try #require(image.colorAt(x: image.pixelsWide / 2,
            y: Int(CGFloat(image.pixelsHigh) * verticalFraction))?.usingColorSpace(.sRGB))
    }

    private func expectRed(at verticalFraction: CGFloat, in image: NSBitmapImageRep) throws {
        let color = try pixel(at: verticalFraction, in: image)
        #expect(color.alphaComponent > 0.95 && color.redComponent > 0.95 && color.blueComponent < 0.05,
            "The source's upper half must render opaque red at vertical fraction \(verticalFraction)")
    }

    private func expectBlue(at verticalFraction: CGFloat, in image: NSBitmapImageRep) throws {
        let color = try pixel(at: verticalFraction, in: image)
        #expect(color.alphaComponent > 0.95 && color.blueComponent > 0.95 && color.redComponent < 0.05,
            "The source's lower half must render opaque blue at vertical fraction \(verticalFraction)")
    }

    private func configure(_ view: DevelopDetailNativeImageView, position: DevelopDetailPosition,
                           image: CGImage, viewport: CGSize = CGSize(width: 260, height: 260),
                           magnification: Double = 1, displayScale: CGFloat = 2,
                           fitsImage: Bool = false, hdr: Bool = false) {
        view.configure(position: position, image: image, viewport: viewport,
            magnification: magnification, displayScale: displayScale, fitsImage: fitsImage, hdr: hdr)
    }
}

private func detailNativeBitmap(width: Int, height: Int) throws -> CGImage {
    let provider = try #require(CGDataProvider(data: Data(repeating: 255, count: width * height * 4) as CFData))
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

private func detailNativeTopBottomBitmap() throws -> CGImage {
    let width = 80, height = 60
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            pixels[offset] = y < height / 2 ? 255 : 0
            pixels[offset + 2] = y < height / 2 ? 0 : 255
            pixels[offset + 3] = 255
        }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}
