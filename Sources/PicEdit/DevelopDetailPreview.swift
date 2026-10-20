import AppKit
import SwiftUI
import PicEditCore

/// Pixel geometry shared by the loupe and its tests. These few scalar
/// calculations stay with UI state; no decode, pixel copy or worker is needed.
struct DevelopDetailGeometry {
    let imageFrame: CGRect

    init(imageSize: CGSize, viewport: CGSize, center: CGPoint, magnification: Double, displayScale: CGFloat,
         fitsImage: Bool = false) {
        if fitsImage {
            imageFrame = DevelopCropCanvasPresentation.imageRect(sourceSize: imageSize, viewport: viewport)
            return
        }
        let scale = max(1, magnification) / max(1, displayScale)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        func origin(_ length: CGFloat, _ available: CGFloat, _ fraction: CGFloat) -> CGFloat {
            guard length > available else { return (available - length) / 2 }
            let position = fraction.isFinite ? min(1, max(0, fraction)) : 0.5
            // Align to display pixels so 100% shows the accepted preview's
            // pixels without interpolation, including on Retina displays.
            return (min(0, max(available - length, available / 2 - position * length))
                * max(1, displayScale)).rounded() / max(1, displayScale)
        }
        imageFrame = CGRect(x: origin(size.width, viewport.width, center.x),
                            y: origin(size.height, viewport.height, center.y),
                            width: size.width, height: size.height)
    }

    static func normalizedPoint(_ point: CGPoint, imageRect: CGRect) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, !imageRect.isEmpty,
              imageRect.contains(point) else { return nil }
        return CGPoint(x: (point.x - imageRect.minX) / imageRect.width,
                       y: (point.y - imageRect.minY) / imageRect.height)
    }
}

/// The drag baseline is the visible frame, rather than a possibly edge-clamped
/// requested center. This makes the picture follow the pointer immediately.
struct DevelopDetailLoupeInteraction {
    enum Action: Equatable {
        case pan(CGPoint), zoom(CGPoint), fit
    }
    private var initialFrame: CGRect?
    private var fitsImage = false
    private(set) var isDragging = false

    mutating func cancel() { initialFrame = nil; isDragging = false }

    mutating func handle(_ event: DevelopCropInputEvent, imageFrame: CGRect, viewport: CGSize,
                         fitsImage: Bool) -> Action? {
        guard event.kind == .pointer else { return nil }
        if event.phase == .cancelled { cancel(); return nil }
        if event.phase == .began {
            cancel()
            guard DevelopDetailGeometry.normalizedPoint(event.startLocation, imageRect: imageFrame) != nil else { return nil }
            initialFrame = imageFrame
            self.fitsImage = fitsImage
            return nil
        }
        guard let initialFrame else { return nil }
        if hypot(event.translation.width, event.translation.height) > 3 { isDragging = true }
        let dragged = isDragging
        if event.phase == .ended { cancel() }
        if dragged {
            guard !self.fitsImage else { return nil }
            func center(_ origin: CGFloat, _ length: CGFloat, _ available: CGFloat, _ translation: CGFloat) -> CGFloat {
                guard length > available else { return 0.5 }
                let inset = available / (2 * length)
                return min(1 - inset, max(inset, (available / 2 - origin - translation) / length))
            }
            return .pan(CGPoint(
                x: center(initialFrame.minX, initialFrame.width, viewport.width, event.translation.width),
                y: center(initialFrame.minY, initialFrame.height, viewport.height, event.translation.height)))
        }
        guard event.phase == .ended,
              let point = DevelopDetailGeometry.normalizedPoint(event.location, imageRect: initialFrame) else { return nil }
        return self.fitsImage ? .zoom(point) : .fit
    }
}

struct DevelopDetailPreview: View {
    @ObservedObject var workspace: DevelopWorkspace
    let isEnabled: Bool
    @Environment(\.displayScale) private var displayScale
    @ViewState private var interaction = DevelopDetailLoupeInteraction()

    private struct LoupeIdentity: Hashable {
        let source: AISourceIdentity?
        let mapping: DevelopCanvasMapping?
        let width: Int
        let height: Int
        let fitsImage: Bool
        let magnification: Double
        let viewportWidth: CGFloat
        let viewportHeight: CGFloat
    }

    private var zoom: Binding<Double> {
        Binding(get: { workspace.detailFitsImage ? 0 : workspace.detailMagnification }, set: { value in
            workspace.detailFitsImage = value == 0
            if value > 0 { workspace.detailMagnification = value }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    workspace.picksDetail.toggle()
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 17))
                        .frame(width: 28, height: 28)
                        .background(workspace.picksDetail ? Color.white.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 3))
                }.buttonStyle(.plain)
                    .foregroundStyle(workspace.picksDetail ? Color.white : Theme.muted)
                    .accessibilityLabel("Detailbereich auswählen")
                    .accessibilityValue(workspace.picksDetail ? "Aktiv" : "Inaktiv")
                    .accessibilityIdentifier("develop.detail-picker")
                    .help("Detailvorschau folgt dem Mauszeiger im Foto. Ein Klick im Foto fixiert den Ausschnitt. Erneutes Klicken auf das Fadenkreuz oder Escape beendet die Auswahl.")
                    .disabled(!isEnabled || workspace.navigatorImage == nil)
                Text("Detailvorschau").font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
                Picker("Vorschauzoom", selection: zoom) {
                    Text("Einpassen").tag(0.0)
                    Text("100 %").tag(1.0)
                    Text("200 %").tag(2.0)
                }.labelsHidden().fixedSize().controlSize(.small)
                    .accessibilityLabel("Detailvorschau Vergrößerung")
                    .accessibilityIdentifier("develop.detail-zoom")
            }
            GeometryReader { viewport in
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.3)
                    if let image = workspace.navigatorImage {
                        // Resolve the current position when input arrives. The
                        // input surface no longer rebuilds for image movement.
                        let geometry = {
                            DevelopDetailGeometry(imageSize: CGSize(width: image.width, height: image.height),
                                viewport: viewport.size, center: workspace.detailCenter,
                                magnification: workspace.detailMagnification, displayScale: displayScale,
                                fitsImage: workspace.detailFitsImage)
                        }
                        DevelopDetailImage(position: workspace.detailPosition, image: image,
                            viewport: viewport.size, magnification: workspace.detailMagnification,
                            displayScale: displayScale, fitsImage: workspace.detailFitsImage,
                            hdr: workspace.hdrDisplayed)
                            .frame(width: viewport.size.width, height: viewport.size.height)
                            .allowsHitTesting(false)
                        DevelopCropInputSurface(onInput: { event in
                            guard let action = interaction.handle(event, imageFrame: geometry().imageFrame,
                                viewport: viewport.size, fitsImage: workspace.detailFitsImage) else { return }
                            switch action {
                            case .pan(let point): workspace.detailCenter = point
                            case .zoom(let point):
                                workspace.detailCenter = point
                                workspace.detailFitsImage = false
                            case .fit: workspace.detailFitsImage = true
                            }
                        }, onHover: { point in if point == nil { NSCursor.arrow.set() } }, isEnabled: true,
                            inputIdentity: AnyHashable(LoupeIdentity(source: workspace.sourceIdentity,
                                mapping: workspace.displayedMapping,
                                width: image.width, height: image.height, fitsImage: workspace.detailFitsImage,
                                magnification: workspace.detailMagnification,
                                viewportWidth: viewport.size.width, viewportHeight: viewport.size.height)),
                            cursor: { point in
                                guard geometry().imageFrame.contains(point) else { return .arrow }
                                return workspace.detailFitsImage ? .crosshair : interaction.isDragging ? .closedHand : .openHand
                            },
                            canvasLabel: workspace.detailFitsImage
                                ? "Detailvorschau · Klicken zum Vergrößern"
                                : "Detailvorschau · Ziehen zum Verschieben, Klicken zur Gesamtansicht",
                            onCancel: { interaction.cancel() },
                            canvasIdentifier: "develop.detail-loupe", capturesEscapeWhileIdle: false)
                            .environment(\.photoCanvasPanning, false)
                            .frame(width: viewport.size.width, height: viewport.size.height)
                    } else {
                        Text("Vorschau wird geladen …")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
                    // Clipping pixels alone leaves the enlarged image's hit
                    // area over the header's picker and crosshair button.
                    .contentShape(Rectangle())
                    .clipped()
            }.aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 260)
                .overlay { Rectangle().stroke(Theme.line) }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Vergrößerter Ausschnitt der bearbeiteten Vorschau")
                .accessibilityIdentifier("develop.detail-preview")
            Text(workspace.picksDetail
                 ? "Bewege den Mauszeiger im Foto. Klicken fixiert den Ausschnitt; Escape beendet die Auswahl."
                 : "Klicken: Zoom / Gesamtansicht · Ziehen: Ausschnitt verschieben.")
                .font(.system(size: 10))
                .foregroundStyle(workspace.picksDetail ? Color.white.opacity(0.9) : Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: isEnabled) { _, enabled in if !enabled { workspace.picksDetail = false } }
        .onDisappear { workspace.picksDetail = false }
    }
}

/// Select in the final displayed image, including its crop, flips and rotation.
/// Follow the pointer until a click locks the detail. The normal navigation
/// surface yields while this picker is active.
struct DevelopDetailCanvas: View {
    @ObservedObject var workspace: DevelopWorkspace
    let geometry: DevelopGeometry

    private struct InputIdentity: Hashable {
        let source: AISourceIdentity?
        let geometry: DevelopGeometry
        let width: Int
        let height: Int
        let viewportWidth: CGFloat
        let viewportHeight: CGFloat
    }

    var body: some View {
        GeometryReader { viewport in
            if let image = workspace.navigatorImage {
                let rect = DevelopCropCanvasPresentation.imageRect(
                    sourceSize: CGSize(width: image.width, height: image.height), viewport: viewport.size)
                let ready = workspace.picksDetail && workspace.tool == .basic
                    && workspace.displayedMapping == DevelopCanvasMapping(geometry)
                DevelopCropInputSurface(onInput: { event in
                    guard ready, workspace.picksDetail, event.kind == .pointer, event.phase == .ended,
                          DevelopDetailGeometry.normalizedPoint(event.startLocation, imageRect: rect) != nil,
                          let point = DevelopDetailGeometry.normalizedPoint(event.location, imageRect: rect) else { return }
                    workspace.detailCenter = point
                    workspace.detailFitsImage = false
                    workspace.picksDetail = false
                    NSCursor.arrow.set()
                }, onHover: { location in
                    guard let location else { NSCursor.arrow.set(); return }
                    guard ready, workspace.picksDetail,
                          let point = DevelopDetailGeometry.normalizedPoint(location, imageRect: rect) else { return }
                    // Only move the existing image layer; pointer updates need
                    // no render/decode work or asynchronous worker per event.
                    if workspace.detailCenter != point { workspace.detailCenter = point }
                    if workspace.detailFitsImage { workspace.detailFitsImage = false }
                }, isEnabled: ready,
                    inputIdentity: AnyHashable(InputIdentity(source: workspace.sourceIdentity, geometry: geometry,
                        width: image.width, height: image.height,
                        viewportWidth: viewport.size.width, viewportHeight: viewport.size.height)),
                    cursor: { point in
                        ready && workspace.picksDetail && rect.contains(point) ? .crosshair : .arrow
                    },
                    canvasLabel: "Detailvorschau folgt dem Mauszeiger im Foto · Klicken fixiert den Ausschnitt",
                    onCancel: { workspace.picksDetail = false },
                    canvasIdentifier: "develop.detail-canvas")
            }
        }.onDisappear { NSCursor.arrow.set() }
    }
}
