import AppKit
import SwiftUI
import GlowroomCore

/// Observe viewport positions locally, so a drag only updates the navigator
/// and native scroll view rather than rebuilding the full develop workspace.
struct DevelopPhotoNavigator: View {
    let asset: PhotoAsset
    let image: CGImage?
    @ObservedObject var viewport: PhotoViewportState
    @ObservedObject private var position: PhotoViewportPosition
    @ViewState private var dragOffset: CGPoint?
    private struct InputIdentity: Hashable {
        let asset: String
        let width: CGFloat
        let height: CGFloat
    }

    init(asset: PhotoAsset, image: CGImage?, viewport: PhotoViewportState) {
        self.asset = asset; self.image = image; self.viewport = viewport
        self.position = viewport.position
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Navigator").font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                Text(viewport.isZoomed ? "2×" : "Einpassen")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }.frame(height: 26)
            GeometryReader { available in
                if let image {
                    let imageFrame = PhotoViewportGeometry.fittedImage(in: available.size,
                        aspectRatio: CGFloat(image.width) / CGFloat(max(1, image.height)), padding: 0)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1).resizable().interpolation(.high)
                            .frame(width: imageFrame.width, height: imageFrame.height)
                        if viewport.isZoomed && viewport.navigationAvailable {
                            let rect = position.normalizedVisibleRect
                            Rectangle().stroke(.black.opacity(0.65), lineWidth: 3)
                                .overlay { Rectangle().stroke(.white, lineWidth: 1) }
                                .frame(width: max(1, imageFrame.width * rect.width),
                                       height: max(1, imageFrame.height * rect.height))
                                .offset(x: imageFrame.width * rect.minX, y: imageFrame.height * rect.minY)
                                .allowsHitTesting(false)
                            DevelopCropInputSurface(onInput: { navigate($0, size: imageFrame.size) },
                                onHover: { _ in }, isEnabled: true,
                                inputIdentity: AnyHashable(InputIdentity(asset: asset.id,
                                    width: imageFrame.width, height: imageFrame.height)),
                                cursor: { _ in dragOffset == nil ? .openHand : .closedHand },
                                canvasLabel: "Sichtbaren Bildausschnitt im Navigator verschieben",
                                onCancel: { dragOffset = nil }, canvasIdentifier: "workspace.navigator-input",
                                capturesEscapeWhileIdle: false)
                                .environment(\.photoCanvasPanning, false)
                        }
                    }.frame(width: imageFrame.width, height: imageFrame.height)
                        .position(x: imageFrame.midX, y: imageFrame.midY)
                } else {
                    Image(systemName: "photo").font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity).frame(height: 155)
                .padding(6).background(Theme.panel)
                .overlay { Rectangle().stroke(Theme.line) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Navigator: \(asset.fileName)")
                .accessibilityValue(viewport.isZoomed ? "Vergrößert, sichtbaren Ausschnitt verschieben" : "Ganzes Bild")
                .accessibilityIdentifier("workspace.navigator")
            Text(asset.fileName).font(.system(size: 13)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.middle)
        }.padding(.bottom, 16)
            .onChange(of: viewport.isZoomed) { _, _ in dragOffset = nil }
            .onChange(of: viewport.navigationAvailable) { _, _ in dragOffset = nil }
            .onChange(of: asset.id) { _, _ in dragOffset = nil }
    }

    private func navigate(_ event: DevelopCropInputEvent, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if event.phase == .cancelled { dragOffset = nil; return }
        let point = CGPoint(x: event.location.x / size.width, y: event.location.y / size.height)
        if event.phase == .began {
            let rect = position.normalizedVisibleRect
            // Preserve the exact grab position inside the rectangle. A click
            // outside it instead moves its center to the requested position.
            dragOffset = rect.contains(point)
                ? CGPoint(x: point.x - rect.midX, y: point.y - rect.midY) : .zero
        }
        guard let dragOffset else { return }
        viewport.moveVisibleCenter(to: CGPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y))
        if event.phase == .ended { self.dragOffset = nil }
    }
}
