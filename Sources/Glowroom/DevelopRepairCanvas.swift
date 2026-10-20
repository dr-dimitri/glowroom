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
    @ViewState private var revision: Int64?
    @ViewState private var session: UUID?
    @ViewState private var gestureRequest: UUID?
    @ViewState private var picksSource = false
    @ViewState private var pendingClick: Task<Void, Never>?

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
                    ForEach(workspace.repairCandidates) { candidate in
                        if let image = Self.maskImage(candidate.mask) {
                            let selected = workspace.repairSelectedCandidateIDs.contains(candidate.id)
                            (selected ? Color.orange : Color.gray).opacity(selected ? 0.4 : 0.15)
                                .frame(width: rect.width, height: rect.height)
                                .mask { Image(decorative: image, scale: 1).resizable().luminanceToAlpha() }
                                .position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
                        }
                    }
                }
                Canvas { context, _ in
                    if overlaysVisible {
                        for stroke in strokes {
                            let target = canvas(stroke.target, in: rect), source = canvas(stroke.source, in: rect)
                            var connection = Path(); connection.move(to: source); connection.addLine(to: target)
                            context.stroke(connection, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            pin(target, in: &context, filled: true)
                            pin(source, in: &context, filled: false)
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
                    if let hover, rect.contains(hover), !workspace.repairBusy {
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
                    cursor: { rect.contains($0) ? .crosshair : .arrow }, onDoubleClick: {
                        finish(); onDoubleClick?()
                    },
                    canvasLabel: "Reparieren auf dem Bild", onCancel: {
                        finish(); workspace.cancelRepairWork(clearCandidates: false)
                    }, onDoubleClickBegan: { finish() })
            }.onChange(of: viewport.size) { _, _ in finish() }
        }.opacity(workspace.isOriginalCanvasReady ? 1 : 0)
            .onChange(of: asset.id) { _, _ in finish() }
            .onChange(of: workspace.sourceIdentity) { _, _ in finish() }
            .onChange(of: workspace.repairMode) { _, _ in finish() }
            .onChange(of: editor.localRevision(for: asset.id)) { _, _ in finish() }
            .onDisappear { finish() }
    }

    private func input(_ event: DevelopCropInputEvent, in rect: CGRect) {
        if event.phase == .cancelled { finish(); return }
        guard event.kind == .pointer, editor.canEdit, workspace.isOriginalCanvasReady,
              !workspace.repairBusy else { return }
        if event.phase == .began {
            guard rect.contains(event.startLocation), let point = normalized(event.startLocation, in: rect) else { return }
            finish()
            revision = editor.localRevision(for: asset.id); session = editor.aiEditSessionID
            gestureRequest = workspace.repairRequest
            let usesAI = workspace.repairMode == .remove && workspace.repairUsesAI
            picksSource = (!usesAI && NSEvent.modifierFlags.contains(.option)) || (workspace.repairMode == .clone && workspace.repairSource == nil)
            path = [point]
        }
        guard let revision, let session, let gestureRequest, gestureRequest == workspace.repairRequest,
              revision == editor.localRevision(for: asset.id), session == editor.aiEditSessionID else { finish(); return }
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
            let sourceIdentity = workspace.sourceIdentity
            let request = workspace.repairRequest
            finish()
            let apply = {
                guard workspace.tool == .repair, workspace.sourceIdentity == sourceIdentity,
                      workspace.repairRequest == request,
                      editor.canEdit, workspace.isOriginalCanvasReady,
                      editor.localRevision(for: asset.id) == revision, editor.aiEditSessionID == session else { return }
                if selectsSource {
                    if let point = completed.first { workspace.repairSource = point; workspace.errorMessage = nil }
                } else {
                    workspace.applyRepair(path: completed, asset: asset, editor: editor, expectedRevision: revision, expectedSession: session)
                }
            }
            if pointClick {
                // Wait out the native second click, so zoom never commits the
                // first click as a repair. Dragged strokes need no such delay.
                pendingClick = Task {
                    do { try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval)); try Task.checkCancellation(); apply() }
                    catch { }
                }
            } else { apply() }
        }
    }

    private func finish() {
        pendingClick?.cancel(); pendingClick = nil
        path = []; revision = nil; session = nil; gestureRequest = nil; picksSource = false
    }
    private func normalized(_ point: CGPoint, in rect: CGRect) -> LocalMaskPoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        return try? LocalMaskPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)), y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
    private func canvas(_ point: LocalMaskPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }
    private func pin(_ center: CGPoint, in context: inout GraphicsContext, filled: Bool) {
        let dot = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
        context.stroke(dot, with: .color(.black), lineWidth: 3)
        if filled { context.fill(dot, with: .color(.white)) }
        else { context.stroke(dot, with: .color(.white), lineWidth: 1.5) }
    }
    private static func maskImage(_ mask: LocalMaskRaster) -> CGImage? {
        guard let provider = CGDataProvider(data: mask.bytes as CFData) else { return nil }
        return CGImage(width: mask.width, height: mask.height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: mask.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

private extension CGPoint {
    static func + (point: CGPoint, size: CGSize) -> CGPoint { CGPoint(x: point.x + size.width, y: point.y + size.height) }
}
