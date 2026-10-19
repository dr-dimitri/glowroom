import SwiftUI

/// Geometry stays independent of the photo's fitted bounds: moving a palette
/// never changes the source coordinates used by mask and brush gestures.
struct InlineMaskPaletteLayout {
    static let inset: CGFloat = 10
    static let preferredWidth: CGFloat = 250
    static let chromeHeight: CGFloat = 69

    let viewport: CGSize

    var width: CGFloat { max(0, min(Self.preferredWidth, viewport.width - 2 * Self.inset)) }
    var maximumHeight: CGFloat { max(0, viewport.height - 2 * Self.inset) }

    func listHeight(layerCount: Int) -> CGFloat {
        Self.listHeight(layerCount: layerCount, maximumHeight: maximumHeight)
    }

    static func listHeight(layerCount: Int, maximumHeight: CGFloat) -> CGFloat {
        min(max(0, CGFloat(min(layerCount, 4) * 31 - 3)), max(28, maximumHeight - chromeHeight))
    }

    func size(layerCount: Int) -> CGSize {
        CGSize(width: width, height: min(maximumHeight, Self.chromeHeight + listHeight(layerCount: layerCount)))
    }

    func defaultOrigin(paletteSize: CGSize) -> CGPoint {
        clamp(CGPoint(x: viewport.width - paletteSize.width - Self.inset, y: Self.inset), paletteSize: paletteSize)
    }

    func clamp(_ origin: CGPoint, paletteSize: CGSize) -> CGPoint {
        // A very small viewport may have less space than the ordinary inset.
        let horizontalSpace = max(0, viewport.width - paletteSize.width)
        let verticalSpace = max(0, viewport.height - paletteSize.height)
        let horizontalInset = min(Self.inset, horizontalSpace / 2)
        let verticalInset = min(Self.inset, verticalSpace / 2)
        return CGPoint(x: min(max(horizontalInset, origin.x), horizontalSpace - horizontalInset),
            y: min(max(verticalInset, origin.y), verticalSpace - verticalInset))
    }

    func translatedOrigin(_ origin: CGPoint, by translation: CGSize, paletteSize: CGSize) -> CGPoint {
        clamp(CGPoint(x: origin.x + translation.width, y: origin.y + translation.height), paletteSize: paletteSize)
    }
}

/// The palette can move independently; the shared busy hint stays in the image
/// center, above the palette, without reserving layout space in the photograph.
@MainActor
struct InlineMaskViewportOverlays: View {
    @ObservedObject var workspace: InlineMaskWorkspace
    var showsMaskList = true
    @ViewState private var paletteOrigin: CGPoint?
    @ViewState private var dragOrigin: CGPoint?

    var body: some View {
        GeometryReader { viewport in
            let layout = InlineMaskPaletteLayout(viewport: viewport.size)
            let paletteSize = layout.size(layerCount: workspace.model?.settings.localAdjustments.count ?? 0)
            let origin = layout.clamp(paletteOrigin ?? layout.defaultOrigin(paletteSize: paletteSize), paletteSize: paletteSize)
            ZStack(alignment: .topLeading) {
                if showsMaskList {
                    InlineMaskList(workspace: workspace, maximumHeight: layout.maximumHeight,
                        onDragChanged: { translation in
                            if dragOrigin == nil { dragOrigin = origin }
                            paletteOrigin = layout.translatedOrigin(dragOrigin ?? origin, by: translation, paletteSize: paletteSize)
                        }, onDragEnded: { dragOrigin = nil })
                        .frame(width: layout.width)
                        .offset(x: origin.x, y: origin.y)
                }
                InlineMaskCalculationStatus(workspace: workspace)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .coordinateSpace(name: "local-mask.viewport")
            .onChange(of: viewport.size) { _, _ in
                if paletteOrigin != nil { paletteOrigin = origin }
                dragOrigin = nil
            }
            .onChange(of: paletteSize) { _, _ in
                if paletteOrigin != nil { paletteOrigin = origin }
                dragOrigin = nil
            }
            .onChange(of: workspace.isPresented) { _, presented in
                if !presented { paletteOrigin = nil; dragOrigin = nil }
            }
        }
    }
}
