import AppKit
import SwiftUI
import GlowroomCore

/// Session-only ownership: the immutable snapshot and artifact lease survive
/// candidate switches, while the existing bounded preview caches own the pixels.
struct PhotoComparisonReference {
    let identity = UUID()
    let asset: PhotoAsset
    let snapshot: EditingSnapshot
    let source: ResolvedEditingSource
    let sourceStamp: ImageAnalysisSourceStamp
    let lease: ArtifactLease?
}

enum PhotoComparisonAspectRatio {
    static func ratio(asset: PhotoAsset, snapshot: EditingSnapshot, source: ResolvedEditingSource? = nil) -> CGFloat {
        var width = max(1, asset.pixelWidth), height = max(1, asset.pixelHeight)
        if case .artifact(let fingerprint, _)? = source {
            width = fingerprint.raster.format.size.width; height = fingerprint.raster.format.size.height
        }
        let size = try? DevelopGeometryRenderer.outputSize(width: width, height: height, geometry: snapshot.settings.developGeometry)
        return CGFloat(size?.width ?? width) / CGFloat(max(1, size?.height ?? height))
    }
}

struct PhotoComparisonPosition: Equatable {
    var zoomed = false
    var center = CGPoint(x: 0.5, y: 0.5)
}

/// Zoom means twice the fitted preview, never an assertion of native 100%.
/// The same normalized center is clamped independently in each aspect ratio.
struct PhotoComparisonGeometry {
    let imageFrame: CGRect
    init(viewport: CGSize, aspectRatio: CGFloat, position: PhotoComparisonPosition) {
        let fit = PhotoViewportGeometry.fittedImage(in: viewport, aspectRatio: aspectRatio, padding: 0)
        let factor: CGFloat = position.zoomed ? 2 : 1
        let size = CGSize(width: fit.width * factor, height: fit.height * factor)
        let center = PhotoViewportGeometry.clampedPoint(position.center)
        func origin(_ available: CGFloat, _ length: CGFloat, _ fraction: CGFloat) -> CGFloat {
            length <= available ? (available - length) / 2 : min(0, max(available - length, available / 2 - fraction * length))
        }
        imageFrame = CGRect(x: origin(viewport.width, size.width, center.x),
            y: origin(viewport.height, size.height, center.y), width: size.width, height: size.height)
    }
}

struct PhotoComparisonCanvas<Reference: View, Candidate: View>: View {
    let referenceIdentity: UUID
    let candidateIdentity: String
    let referenceRatio: CGFloat
    let candidateRatio: CGFloat
    let linked: Bool
    private let reference: Reference
    private let candidate: Candidate
    @ViewState private var leftPosition = PhotoComparisonPosition()
    @ViewState private var rightPosition = PhotoComparisonPosition()

    init(referenceIdentity: UUID, candidateIdentity: String, referenceRatio: CGFloat,
         candidateRatio: CGFloat, linked: Bool,
         @ViewBuilder reference: () -> Reference, @ViewBuilder candidate: () -> Candidate) {
        self.referenceIdentity = referenceIdentity; self.candidateIdentity = candidateIdentity
        self.referenceRatio = referenceRatio; self.candidateRatio = candidateRatio; self.linked = linked
        self.reference = reference(); self.candidate = candidate()
    }
    var body: some View {
        HStack(spacing: 1) {
            PhotoComparisonPane(identity: AnyHashable(referenceIdentity), label: "Referenz · Betrachtung",
                aspectRatio: referenceRatio, position: leftPosition, changed: { update($0, left: true) }) {
                reference.environment(\.developPreviewSink, nil).environment(\.developPreviewPending, nil)
                    .environment(\.aiCorrectionDisplay, nil)
            }
            PhotoComparisonPane(identity: AnyHashable(candidateIdentity), label: "Aktives Foto · Bearbeitung",
                aspectRatio: candidateRatio, position: rightPosition, changed: { update($0, left: false) }) { candidate }
                .overlay { Rectangle().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1).allowsHitTesting(false) }
        }
        .onChange(of: linked) { _, value in if value { leftPosition = rightPosition } }
        .onChange(of: referenceIdentity) { _, _ in
            leftPosition = linked ? rightPosition : PhotoComparisonPosition()
        }
        .onChange(of: candidateIdentity) { _, _ in
            if !linked { rightPosition = PhotoComparisonPosition() }
        }
    }
    private func update(_ position: PhotoComparisonPosition, left: Bool) {
        if left || linked { leftPosition = position }
        if !left || linked { rightPosition = position }
    }
}

private struct PhotoComparisonPane<Content: View>: View {
    let identity: AnyHashable
    let label: String
    let aspectRatio: CGFloat
    let position: PhotoComparisonPosition
    let changed: (PhotoComparisonPosition) -> Void
    @ViewState private var dragFrame: CGRect?
    private let content: Content
    init(identity: AnyHashable, label: String, aspectRatio: CGFloat, position: PhotoComparisonPosition,
         changed: @escaping (PhotoComparisonPosition) -> Void, @ViewBuilder content: () -> Content) {
        self.identity = identity; self.label = label; self.aspectRatio = aspectRatio
        self.position = position; self.changed = changed; self.content = content()
    }
    var body: some View {
        GeometryReader { viewport in
            let frame = PhotoComparisonGeometry(viewport: viewport.size, aspectRatio: aspectRatio, position: position).imageFrame
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.2)
                content.frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY).allowsHitTesting(false)
                DevelopCropInputSurface(onInput: { event in
                    if event.phase == .cancelled { dragFrame = nil; return }
                    if event.phase == .began { dragFrame = frame }
                    guard position.zoomed, let original = dragFrame else { return }
                    if event.phase == .changed {
                        changed(PhotoComparisonPosition(zoomed: true, center: CGPoint(
                            x: (viewport.size.width / 2 - original.minX - event.translation.width) / original.width,
                            y: (viewport.size.height / 2 - original.minY - event.translation.height) / original.height)))
                    }
                    if event.phase == .ended { dragFrame = nil }
                }, onHover: { _ in }, isEnabled: true, inputIdentity: identity,
                cursor: { _ in position.zoomed ? .openHand : PhotoCanvasCursors.zoomIn },
                onClick: { point in
                    guard frame.contains(point) else { return }
                    changed(PhotoComparisonPosition(zoomed: !position.zoomed, center: CGPoint(
                        x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)))
                }, canvasLabel: label + (position.zoomed ? " · Ziehen zum Verschieben, Klick zum Einpassen" : " · Klick zum Vergrößern der Vorschau"),
                onCancel: { dragFrame = nil }, pansWithPointer: false,
                canvasIdentifier: "workspace.photo-comparison." + (label.hasPrefix("Referenz") ? "reference" : "candidate"),
                capturesEscapeWhileIdle: false)
                .environment(\.photoCanvasPanning, false)
                HStack(alignment: .top, spacing: 6) {
                    Text(label).lineLimit(2).allowsHitTesting(false)
                    Spacer(minLength: 0)
                    Button(position.zoomed ? "Einpassen" : "Vergrößern") {
                        changed(PhotoComparisonPosition(zoomed: !position.zoomed, center: position.center))
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("workspace.photo-comparison." + (label.hasPrefix("Referenz") ? "reference" : "candidate") + ".zoom")
                }.font(.system(size: 13, weight: .medium)).padding(6)
                    .background(Theme.canvas.opacity(0.85), in: RoundedRectangle(cornerRadius: 4)).padding(8)
            }.frame(width: viewport.size.width, height: viewport.size.height).clipped()
        }
        .accessibilityElement(children: .contain).accessibilityLabel(label)
        .accessibilityAction(named: position.zoomed ? "Einpassen" : "Vorschau vergrößern") {
            changed(PhotoComparisonPosition(zoomed: !position.zoomed, center: position.center))
        }
    }
}

struct FrozenPhotoReferencePreview: View {
    let reference: PhotoComparisonReference
    let available: Bool
    let validationGeneration: UInt64
    var body: some View {
        if available {
            VariantSnapshotImage(source: reference.source, expectedStamp: reference.sourceStamp,
                identity: reference.identity.uuidString, pixelSize: 2400, priority: .selected,
                validationGeneration: validationGeneration)
        } else { Text("Referenz nicht mehr in der Bibliothek oder Quelle verändert").padding().foregroundStyle(.orange) }
    }
}
