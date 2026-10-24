import SwiftUI
import GlowroomCore

/// Only the bounded pointer path lives on MainActor. The completed gesture is
/// handed to the source-bound worker; inference never runs during mouseMoved.
struct DevelopRepairCanvas: View {
    let asset: PhotoAsset
    @ObservedObject var workspace: DevelopWorkspace
    var onDoubleClick: (() -> Void)?
    @EnvironmentObject private var editor: EditingModel
    @ViewState private var path: [LocalMaskPoint] = []
    @ViewState private var hover: CGPoint?
    @ViewState private var picksSource = false
    @ViewState private var replacesCanvasForZoom = false
    @ViewState private var editDrag: EditDrag?
    private var inputQueue: DevelopRepairInputQueue { workspace.repairInputQueue }

    private struct EditDrag {
        let stroke: DevelopRetouchStroke
        let handle: DevelopRepairEditHandle
        let bounds: CGRect
        let source: AISourceIdentity?
        let revision: Int64
        let session: UUID
        let request: UUID
        var translation = CGSize.zero
    }

    private struct InputIdentity: Hashable {
        let asset: String
        let source: AISourceIdentity?
        let mode: DevelopRepairMode
    }
    private var sourceSize: CGSize { workspace.sourceSize ?? CGSize(width: max(1, asset.pixelWidth), height: max(1, asset.pixelHeight)) }
    private var strokes: [DevelopRetouchStroke] { editor.settings(for: asset.id).developGeometry.retouchStrokes }
    private var overlaysVisible: Bool {
        workspace.repairOverlay == .always || (workspace.repairOverlay == .automatic && (hover != nil || !path.isEmpty))
    }

    var body: some View {
        GeometryReader { viewport in
            let rect = DevelopCropCanvasPresentation.imageRect(sourceSize: sourceSize, viewport: viewport.size)
            ZStack(alignment: .topLeading) {
                if workspace.repairVisualizesSpots, let image = workspace.repairSpotImage {
                    Image(decorative: image, scale: 1).resizable().interpolation(.none)
                        .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
                if overlaysVisible {
                    ForEach(strokes) { stroke in
                        if let mask = stroke.mask, let image = Self.maskImage(mask) {
                            let delta = targetTranslation(for: stroke)
                            (workspace.repairSelectedStrokeID == stroke.id ? Theme.accent : Color.white)
                                .opacity(workspace.repairSelectedStrokeID == stroke.id ? 0.35 : 0.13)
                                .frame(width: rect.width, height: rect.height)
                                .mask { Image(decorative: image, scale: 1).resizable() }
                                .position(x: rect.midX + delta.width * rect.width, y: rect.midY + delta.height * rect.height)
                                .allowsHitTesting(false)
                        }
                    }
                    ForEach(workspace.repairCandidates) { candidate in
                        if let image = Self.maskImage(candidate.mask) {
                            let selected = workspace.repairSelectedCandidateIDs.contains(candidate.id)
                            (selected ? Color.orange : Color.gray).opacity(selected ? 0.4 : 0.15)
                                .frame(width: rect.width, height: rect.height)
                                .mask { Image(decorative: image, scale: 1).resizable() }
                                .position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
                        }
                    }
                }
                Canvas { context, _ in
                    if overlaysVisible {
                        for stroke in strokes {
                            let delta = targetTranslation(for: stroke)
                            let offset = CGSize(width: delta.width * rect.width, height: delta.height * rect.height)
                            let target = canvas(stroke.target, in: rect) + offset
                            let sourceDelta = editDrag?.stroke.id == stroke.id && editDrag?.handle == .source
                                ? editDrag?.translation ?? .zero : .zero
                            let source = canvas(stroke.source, in: rect)
                                + CGSize(width: sourceDelta.width * rect.width, height: sourceDelta.height * rect.height)
                            let selected = workspace.repairSelectedStrokeID == stroke.id
                            if stroke.mask == nil {
                                var footprint = Path(); footprint.move(to: target)
                                for point in stroke.path { footprint.addLine(to: canvas(point, in: rect) + offset) }
                                if stroke.path.isEmpty || stroke.path.allSatisfy({ $0 == stroke.target }) {
                                    footprint.addLine(to: target + CGSize(width: 0.01, height: 0))
                                }
                                context.stroke(footprint, with: .color((selected ? Theme.accent : .white).opacity(selected ? 0.3 : 0.12)),
                                    style: StrokeStyle(lineWidth: 2 * stroke.radius * min(rect.width, rect.height), lineCap: .round, lineJoin: .round))
                            }
                            if stroke.replacement == nil {
                                var connection = Path(); connection.move(to: source); connection.addLine(to: target)
                                context.stroke(connection, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                pin(source, in: &context, filled: false, selected: selected)
                            }
                            pin(target, in: &context, filled: true, selected: selected)
                        }
                        if let source = workspace.repairSource {
                            let center = canvas(source, in: rect), radius = workspace.repairRadius * min(rect.width, rect.height)
                            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)),
                                with: .color(Theme.accent), lineWidth: 1)
                            pin(center, in: &context, filled: false)
                        }
                    }
                    if !path.isEmpty {
                        var painted = Path(); painted.move(to: canvas(path[0], in: rect))
                        for point in path.dropFirst() { painted.addLine(to: canvas(point, in: rect)) }
                        if path.count == 1 { painted.addLine(to: canvas(path[0], in: rect) + CGSize(width: 0.01, height: 0)) }
                        context.stroke(painted, with: .color(Theme.accent.opacity(0.45)),
                            style: StrokeStyle(lineWidth: 2 * workspace.repairRadius * min(rect.width, rect.height), lineCap: .round, lineJoin: .round))
                    }
                    if let hover, rect.contains(hover), !workspace.repairBusy, editDrag == nil,
                       hit(at: hover, in: rect) == nil {
                        let radius = workspace.repairRadius * min(rect.width, rect.height)
                        let circle = Path(ellipseIn: CGRect(x: hover.x - radius, y: hover.y - radius, width: 2 * radius, height: 2 * radius))
                        context.stroke(circle, with: .color(.black.opacity(0.9)), lineWidth: 2.5)
                        context.stroke(circle, with: .color(.white), lineWidth: 1)
                        if workspace.repairMode != .remove || (!workspace.repairUsesAI && !workspace.repairObjectDetection) {
                            let inner = radius * (1 - workspace.repairFeather)
                            context.stroke(Path(ellipseIn: CGRect(x: hover.x - inner, y: hover.y - inner, width: 2 * inner, height: 2 * inner)),
                                with: .color(.white.opacity(0.65)), style: StrokeStyle(lineWidth: 0.7, dash: [2, 3]))
                        }
                    }
                }.allowsHitTesting(false)
                DevelopCropInputSurface(onInput: { input($0, in: rect) }, onHover: { hover = $0 },
                    isEnabled: editor.canEdit && workspace.isOriginalCanvasReady,
                    inputIdentity: AnyHashable(InputIdentity(asset: asset.id, source: workspace.sourceIdentity, mode: workspace.repairMode)),
                    cursor: { point in
                        if editDrag != nil { return .closedHand }
                        return hit(at: point, in: rect) != nil ? .openHand : rect.contains(point) ? .crosshair : .arrow
                    }, onDoubleClick: onDoubleClick.map { action in {
                        finishPointer(); inputQueue.cancelPending()
                        // DetailView replaces its native canvas when zooming.
                        // Keep earlier independent commands in the workspace.
                        replacesCanvasForZoom = true; action()
                    } },
                    canvasLabel: "Reparieren auf dem Bild · Maske oder Punkt ziehen · Löschtaste entfernt die Auswahl", onCancel: {
                        finish(); workspace.cancelRepairWork(clearCandidates: false)
                    }, onDoubleClickBegan: onDoubleClick == nil ? nil : { finishPointer(); inputQueue.cancelPending() },
                    onTeardown: { teardown() },
                    allowsViewportHitFallback: workspace.isOriginalCanvasReady && workspace.tool == .repair,
                    onDelete: { deleteSelected() })
            }.onChange(of: viewport.size) { _, _ in teardown() }
        }.opacity(workspace.isOriginalCanvasReady ? 1 : 0)
            .onChange(of: asset.id) { _, _ in finish(); workspace.repairSelectedStrokeID = nil }
            .onChange(of: workspace.sourceIdentity) { _, _ in finish() }
            .onChange(of: workspace.repairMode) { _, _ in finish() }
            .onChange(of: workspace.repairOverlay) { _, _ in finishPointer() }
            .onChange(of: workspace.isOriginalCanvasReady) { _, ready in if !ready { finish() } }
            .onChange(of: editor.canEdit) { _, ready in if !ready { finish() } }
            .onChange(of: editor.localRevision(for: asset.id)) { _, _ in invalidateIfNeeded() }
            .onChange(of: workspace.repairRequest) { _, _ in invalidateIfNeeded() }
            .onDisappear { teardown() }
    }

    private func input(_ event: DevelopCropInputEvent, in rect: CGRect) {
        if event.phase == .cancelled { finish(); return }
        guard event.kind == .pointer, editor.canEdit, workspace.isOriginalCanvasReady,
              (!workspace.repairBusy || inputQueue.isProcessing) else { return }
        if event.phase == .began {
            guard rect.contains(event.startLocation), let point = normalized(event.startLocation, in: rect) else { return }
            finishPointer()
            let choosesSource = workspace.repairChoosesSource || NSEvent.modifierFlags.contains(.option)
                || (workspace.repairMode == .clone && workspace.repairSource == nil && !inputQueue.hasScheduledSource)
            if !choosesSource, let hit = hit(at: event.startLocation, in: rect),
               let stroke = strokes.first(where: { $0.id == hit.id }) {
                workspace.cancelRepairWork(clearCandidates: false)
                workspace.repairSelectedStrokeID = stroke.id
                editDrag = EditDrag(stroke: stroke, handle: hit.handle,
                    bounds: DevelopRepairEditing.translationBounds(for: stroke, handle: hit.handle),
                    source: workspace.sourceIdentity, revision: editor.localRevision(for: asset.id),
                    session: editor.aiEditSessionID, request: workspace.repairRequest)
                return
            }
            workspace.repairSelectedStrokeID = nil
            guard inputQueue.begin(asset: asset, workspace: workspace, editor: editor) else { return }
            let usesAI = workspace.repairMode == .remove && workspace.repairUsesAI
            picksSource = (!usesAI && (workspace.repairChoosesSource || NSEvent.modifierFlags.contains(.option))) || (workspace.repairMode == .clone && workspace.repairSource == nil && !inputQueue.hasScheduledSource)
            path = [point]
        }
        if var drag = editDrag {
            guard editIsCurrent(drag) else { finishPointer(); return }
            // Keep the image render stable during pointer motion. Only cheap
            // overlay coordinates change; one background edit follows mouseUp.
            drag.translation = CGSize(width: min(drag.bounds.maxX, max(drag.bounds.minX, event.translation.width / rect.width)),
                height: min(drag.bounds.maxY, max(drag.bounds.minY, event.translation.height / rect.height)))
            if drag.handle == .target, let mask = drag.stroke.mask {
                drag.translation.width = (drag.translation.width * CGFloat(mask.width)).rounded() / CGFloat(mask.width)
                drag.translation.height = (drag.translation.height * CGFloat(mask.height)).rounded() / CGFloat(mask.height)
            }
            editDrag = drag
            if event.phase == .ended {
                finishPointer()
                if hypot(event.translation.width, event.translation.height) >= 3 {
                    workspace.moveRepair(id: drag.stroke.id, handle: drag.handle, translation: drag.translation,
                        asset: asset, editor: editor, expectedRevision: drag.revision, expectedSession: drag.session)
                }
            }
            return
        }
        guard !path.isEmpty else { return }
        guard inputQueue.isCurrent(asset: asset, workspace: workspace, editor: editor) else { finish(); return }
        if !picksSource, let point = normalized(event.location, in: rect) {
            if let last = path.last {
                let distance = hypot((point.x - last.x) * rect.width, (point.y - last.y) * rect.height)
                if distance >= 1 || event.phase == .ended, point != last {
                    if path.count >= DevelopRetouchStroke.maximumPathPoints { path = path.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil } }
                    path.append(point)
                }
            }
        }
        if event.phase == .ended {
            let completed = path
            let selectsSource = picksSource
            let first = completed.first
            let pointClick = hypot(event.translation.width, event.translation.height) < 3 && completed.allSatisfy { point in
                guard let first else { return true }
                return hypot((point.x - first.x) * rect.width, (point.y - first.y) * rect.height) < 3
            }
            finishPointer()
            inputQueue.submit(path: completed, selectsSource: selectsSource,
                brush: DevelopRepairBrush(workspace), pointClick: pointClick)
        }
    }

    private func invalidateIfNeeded() {
        if let selected = workspace.repairSelectedStrokeID, !strokes.contains(where: { $0.id == selected }) {
            workspace.repairSelectedStrokeID = nil
        }
        if let drag = editDrag {
            if !editIsCurrent(drag) { finishPointer() }
            return
        }
        if !inputQueue.isCurrent(asset: asset, workspace: workspace, editor: editor) { finish() }
    }
    private func editIsCurrent(_ drag: EditDrag) -> Bool {
        drag.source == workspace.sourceIdentity && drag.revision == editor.localRevision(for: asset.id)
            && drag.session == editor.aiEditSessionID && drag.request == workspace.repairRequest
            && workspace.tool == .repair && workspace.isOriginalCanvasReady && editor.canEdit
    }
    private func targetTranslation(for stroke: DevelopRetouchStroke) -> CGSize {
        guard let drag = editDrag, drag.stroke.id == stroke.id, drag.handle == .target else { return .zero }
        return drag.translation
    }
    private func hit(at point: CGPoint, in rect: CGRect) -> (id: UUID, handle: DevelopRepairEditHandle)? {
        guard overlaysVisible, rect.contains(point) else { return nil }
        return DevelopRepairEditing.hit(at: point, strokes: strokes, imageRect: rect, handleRadius: 8)
    }
    private func deleteSelected() {
        guard let id = workspace.repairSelectedStrokeID else { return }
        finishPointer()
        workspace.removeRepair(id: id, asset: asset, editor: editor)
    }
    private func finish() {
        inputQueue.cancel(); finishPointer()
    }
    private func teardown() {
        if replacesCanvasForZoom { finishPointer(); inputQueue.cancelPending() }
        else { finish() }
    }
    private func finishPointer() {
        path = []; picksSource = false; editDrag = nil
    }
    private func normalized(_ point: CGPoint, in rect: CGRect) -> LocalMaskPoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        return try? LocalMaskPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)), y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
    private func canvas(_ point: LocalMaskPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }
    private func pin(_ center: CGPoint, in context: inout GraphicsContext, filled: Bool, selected: Bool = false) {
        let dot = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
        if selected {
            context.stroke(Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)),
                with: .color(Theme.accent), lineWidth: 2)
        }
        context.stroke(dot, with: .color(.black), lineWidth: 3)
        if filled { context.fill(dot, with: .color(.white)) }
        else { context.stroke(dot, with: .color(.white), lineWidth: 1.5) }
    }
    static func maskImage(_ mask: LocalMaskRaster) -> CGImage? {
        guard let provider = CGDataProvider(data: mask.bytes as CFData) else { return nil }
        // Native alpha coverage keeps zero cells transparent even in an AppKit
        // compositor without SwiftUI's luminance filter. Reuse the existing
        // bounded bytes; no RGBA conversion or image-sized CPU pass is needed.
        return CGImage(maskWidth: mask.width, height: mask.height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: mask.width, provider: provider, decode: [1, 0], shouldInterpolate: true)
    }
}

private extension CGPoint {
    static func + (point: CGPoint, size: CGSize) -> CGPoint { CGPoint(x: point.x + size.width, y: point.y + size.height) }
}
