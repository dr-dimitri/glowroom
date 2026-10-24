import SwiftUI
import GlowroomCore

struct DevelopGeometryInspector: View {
    let asset: PhotoAsset
    @ObservedObject var workspace: DevelopWorkspace
    @EnvironmentObject private var editor: EditingModel
    private var geometry: DevelopGeometry { editor.settings(for: asset.id).developGeometry }
    var body: some View {
        if workspace.tool == .crop {
            DevelopCropInspector(asset: asset, workspace: workspace)
        } else if workspace.tool == .repair {
            DevelopRepairInspector(asset: asset, workspace: workspace)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(workspace.tool.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Schließen") { workspace.tool = .basic }.buttonStyle(.bordered).controlSize(.small)
                }
                Text("Unbeschnittene Quelle · Änderungen werden nicht destruktiv gespeichert.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                switch workspace.tool {
                case .redEye: redEyeControls
                default: EmptyView()
                }
                if let error = workspace.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
            }.padding(.vertical, 8)
        }
    }
    private var redEyeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ziehe eine Ellipse um die rote Pupille. Nur rotdominante Pixel innerhalb der Auswahl werden abgedunkelt.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            toolSlider("Stärke", value: $workspace.redEyeStrength, range: 0...1, neutral: 1)
            Text("\(geometry.redEyeCorrections.count) Augenkorrekturen")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
            HStack {
                Button("Letzte entfernen") { update { if !$0.redEyeCorrections.isEmpty { $0.redEyeCorrections.removeLast() } } }
                Button("Alle löschen") { update { $0.redEyeCorrections = [] } }
            }.controlSize(.small).disabled(geometry.redEyeCorrections.isEmpty)
        }
    }
    private func toolSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, neutral: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue * 100)) %").monospacedDigit() }.font(.system(size: 10))
            ResettableSlider(value: value, in: range, neutralValue: neutral).accessibilityLabel(title)
        }
    }
    private func update(_ change: (inout DevelopGeometry) -> Void) {
        editor.endEditing(assetID: asset.id)
        var settings = editor.settings(for: asset.id); change(&settings.developGeometry)
        settings = settings.normalized
        do { _ = try EditingSnapshot(settings: settings); editor.setSettings(settings, for: asset.id); workspace.errorMessage = nil }
        catch { workspace.errorMessage = error.localizedDescription }
    }
}

struct DevelopCanvasInteraction: View {
    let asset: PhotoAsset
    @ObservedObject var workspace: DevelopWorkspace
    var onDoubleClick: (() -> Void)? = nil
    var levelsSelection: DevelopSelectionIdentity? = nil
    var levelsIsCurrent: @MainActor () -> Bool = { false }
    @EnvironmentObject private var editor: EditingModel
    @ViewState private var start: CGPoint?
    @ViewState private var current: CGPoint?
    @ViewState private var originalCrop: DevelopCropRect?
    @ViewState private var cropAction: DevelopCropDragAction?
    @ViewState private var straighteningGesture = false
    @ViewState private var expectedCropRevision: Int64?
    @ViewState private var expectedCropSession: UUID?
    private var sourceSize: CGSize { workspace.sourceSize ?? CGSize(width: max(1, asset.pixelWidth), height: max(1, asset.pixelHeight)) }
    private var geometry: DevelopGeometry { editor.settings(for: asset.id).developGeometry }

    private struct CropInputIdentity: Hashable {
        let asset: String
        let source: AISourceIdentity?
        let angle: Double
        let straightening: Bool
    }
    private struct WhiteBalanceInputIdentity: Hashable {
        let asset: String
        let source: AISourceIdentity?
    }
    private struct LevelsInputIdentity: Hashable {
        let display: DevelopPreviewRenderIdentity?
        let picker: DevelopLevelsPickerSelection?
        let selection: DevelopSelectionIdentity?
    }
    private var levelsReady: Bool {
        guard let levelsSelection else { return false }
        return workspace.levelsPicker != nil && editor.canEdit && levelsIsCurrent() &&
            workspace.matchesLevelsDisplay(assetID: asset.id, editor: editor, selection: levelsSelection)
    }

    var body: some View {
        GeometryReader { viewport in
            let rect = DevelopCropCanvasPresentation.imageRect(sourceSize: sourceSize, viewport: viewport.size)
            let angle = geometry.straightenAngle
            let fit = DevelopCropCanvasPresentation.fittingScale(sourceSize: sourceSize, viewport: viewport.size, angle: angle)
            ZStack(alignment: .topLeading) {
                if workspace.levelsPicker != nil {
                    let outputSize = workspace.levelsDisplay.map {
                        CGSize(width: $0.frame.output.image.width, height: $0.frame.output.image.height)
                    } ?? .zero
                    let levelsRect = DevelopCropCanvasPresentation.imageRect(sourceSize: outputSize, viewport: viewport.size)
                    DevelopCropInputSurface(onInput: { levelsInput($0, rect: levelsRect) }, onHover: { _ in },
                        isEnabled: levelsReady,
                        inputIdentity: AnyHashable(LevelsInputIdentity(display: workspace.levelsDisplay?.identity,
                            picker: workspace.levelsPicker, selection: levelsSelection)),
                        cursor: { levelsReady && levelsRect.contains($0) ? .crosshair : .arrow },
                        canvasLabel: "Bildfläche für Tonwertpipette wählen · Escape beendet die Pipette")
                        .accessibilityIdentifier("develop.levels.canvas")
                } else if workspace.picksWhiteBalance {
                    DevelopCropInputSurface(onInput: { whiteBalanceInput($0, rect: rect) }, onHover: { _ in },
                        isEnabled: editor.canEdit && workspace.isOriginalCanvasReady,
                        inputIdentity: AnyHashable(WhiteBalanceInputIdentity(asset: asset.id, source: workspace.sourceIdentity)),
                        cursor: { DevelopWhiteBalanceCursor.cursor(at: $0, in: rect,
                            isEnabled: workspace.picksWhiteBalance && editor.canEdit && workspace.isOriginalCanvasReady) },
                        canvasLabel: "Neutrale Fläche für Weißabgleich wählen")
                } else if workspace.tool == .crop {
                    cropOutline(rect, displayScale: fit)
                        .scaleEffect(fit).rotationEffect(.degrees(angle))
                        .opacity(workspace.isOriginalCanvasReady ? 1 : 0)
                    // Native input remains in viewport coordinates. Inverse-map
                    // it once, rather than relying on AppKit layer transforms.
                    DevelopCropInputSurface(onInput: { event in
                        cropInput(event, rect: rect, viewport: viewport.size, angle: angle, scale: fit)
                    }, onHover: { point in
                        if point == nil { NSCursor.arrow.set() }
                    }, isEnabled: editor.canEdit && workspace.isOriginalCanvasReady,
                        inputIdentity: AnyHashable(CropInputIdentity(asset: asset.id, source: workspace.sourceIdentity,
                            angle: angle, straightening: workspace.isStraightening)),
                        cursor: { point in cropCursor(at: point, rect: rect, viewport: viewport.size, angle: angle, scale: fit) },
                        onDoubleClick: onDoubleClick)
                        .accessibilityLabel(workspace.isStraightening ? "Bezugslinie zum Ausrichten auf dem Bild ziehen" : workspace.tool.title + " auf dem Bild")
                        .accessibilityIdentifier("develop.interactive-canvas")
                } else if workspace.tool == .repair {
                    DevelopRepairCanvas(asset: asset, workspace: workspace, onDoubleClick: onDoubleClick)
                } else {
                    if workspace.tool == .redEye, let start, let current {
                        Ellipse().stroke(.white, style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .frame(width: abs(current.x - start.x) * rect.width, height: abs(current.y - start.y) * rect.height)
                            .position(x: rect.minX + (current.x + start.x) / 2 * rect.width, y: rect.minY + (current.y + start.y) / 2 * rect.height)
                            .allowsHitTesting(false)
                    }
                    if workspace.tool != .basic {
                        Color.clear.contentShape(Rectangle()).gesture(drag(rect))
                            .accessibilityLabel(workspace.tool.title + " auf dem Bild")
                            .accessibilityIdentifier("develop.interactive-canvas")
                    }
                }
            }
            .onChange(of: viewport.size) { _, _ in finishGesture() }
        }.allowsHitTesting(workspace.levelsPicker != nil || (workspace.isOriginalCanvasReady && (workspace.tool != .basic || workspace.picksWhiteBalance)))
            .onChange(of: workspace.tool) { _, _ in finishGesture() }
            .onChange(of: workspace.picksWhiteBalance) { _, _ in finishGesture() }
            .onChange(of: workspace.levelsPicker) { _, _ in finishGesture() }
            .onChange(of: workspace.isStraightening) { _, _ in finishGesture() }
            .onChange(of: asset.id) { _, _ in finishGesture() }
            .onChange(of: sourceSize) { _, _ in finishGesture() }
            .onChange(of: workspace.sourceIdentity) { _, _ in finishGesture() }
            .onChange(of: workspace.isOriginalCanvasReady) { _, ready in if !ready { finishGesture() } }
            .onChange(of: editor.canEdit) { _, canEdit in if !canEdit { finishGesture() } }
            .onDisappear { finishGesture(); NSCursor.arrow.set() }
    }
    private func levelsInput(_ event: DevelopCropInputEvent, rect: CGRect) {
        if event.phase == .cancelled { workspace.endLevelsPicker(); return }
        guard event.kind == .pointer, event.phase == .ended, levelsReady,
              let selection = levelsSelection, let display = workspace.levelsDisplay,
              let output = normalized(event.location, rect: rect),
              normalized(event.startLocation, rect: rect) != nil else { return }
        do {
            let input = display.frame.actualInput
            let plan = try DevelopGeometryPlan(sourceExtent: CGRect(x: 0, y: 0,
                width: input.image.width, height: input.image.height), geometry: display.identity.settings.developGeometry)
            guard plan.outputSize.width == display.frame.output.image.width,
                  plan.outputSize.height == display.frame.output.image.height,
                  let pixel = plan.inputPoint(fromOutputTopLeft: CGPoint(
                    x: output.x * CGFloat(display.frame.output.image.width),
                    y: output.y * CGFloat(display.frame.output.image.height))) else {
                workspace.errorMessage = "Wähle eine Bildfläche innerhalb des gedrehten Bildes; transparente Rotationsränder sind keine Messquelle."
                return
            }
            workspace.applyLevelsPicker(at: CGPoint(x: pixel.x / CGFloat(input.image.width),
                                                     y: pixel.y / CGFloat(input.image.height)),
                assetID: asset.id, editor: editor, selection: selection, isCurrent: levelsIsCurrent)
        } catch {
            workspace.errorMessage = "Diese Vorschau kann der Messquelle noch nicht eindeutig zugeordnet werden. Warte auf die aktuelle Bildvorschau."
        }
    }
    private func normalized(_ point: CGPoint, rect: CGRect, clamp: Bool = false) -> CGPoint? {
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)), y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
    private func cropOutline(_ rect: CGRect, displayScale: CGFloat) -> some View {
        let box = DevelopCropInteraction.box(crop: geometry.crop, imageRect: rect)
        return Canvas { context, _ in
            var shade = Path(rect); shade.addRect(box)
            context.fill(shade, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
            context.stroke(Path(box), with: .color(.white), lineWidth: 1 / displayScale)
            var grid = Path()
            for fraction in [1.0 / 3, 2.0 / 3] {
                grid.move(to: CGPoint(x: box.minX + box.width * fraction, y: box.minY)); grid.addLine(to: CGPoint(x: box.minX + box.width * fraction, y: box.maxY))
                grid.move(to: CGPoint(x: box.minX, y: box.minY + box.height * fraction)); grid.addLine(to: CGPoint(x: box.maxX, y: box.minY + box.height * fraction))
            }
            context.stroke(grid, with: .color(.white.opacity(0.5)), lineWidth: 0.5 / displayScale)
            for handle in DevelopCropHandle.allCases {
                let point = handle.position(in: box), radius = 4 / displayScale
                let dot = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                context.stroke(dot, with: .color(.black.opacity(0.8)), lineWidth: 2 / displayScale)
                context.fill(dot, with: .color(.white))
            }
            if straighteningGesture, let start, let current {
                var line = Path()
                line.move(to: CGPoint(x: rect.minX + start.x * rect.width, y: rect.minY + start.y * rect.height))
                line.addLine(to: CGPoint(x: rect.minX + current.x * rect.width, y: rect.minY + current.y * rect.height))
                context.stroke(line, with: .color(.black), lineWidth: 4 / displayScale)
                context.stroke(line, with: .color(.white), lineWidth: 2 / displayScale)
            }
        }.allowsHitTesting(false)
    }

    private func cropInput(_ event: DevelopCropInputEvent, rect: CGRect, viewport: CGSize, angle: Double, scale: CGFloat) {
        if event.phase == .cancelled { finishGesture(); return }
        guard editor.canEdit, workspace.isOriginalCanvasReady,
              let location = DevelopCropCanvasPresentation.canvasPoint(from: event.location, viewport: viewport, angle: angle, scale: scale),
              let initial = DevelopCropCanvasPresentation.canvasPoint(from: event.startLocation, viewport: viewport, angle: angle, scale: scale) else { return }
        if event.phase == .began {
            let action = DevelopCropInteraction.dragAction(at: initial, crop: geometry.crop, imageRect: rect,
                forceMove: event.kind == .threeFinger || NSEvent.modifierFlags.contains(.command), hitRadius: DevelopCropInteraction.hitRadius / scale)
            let touchesHandle: Bool
            if case .resize = action { touchesHandle = true } else { touchesHandle = false }
            guard let point = normalized(initial, rect: rect, clamp: touchesHandle) else { return }
            start = point; current = point; originalCrop = geometry.crop
            straighteningGesture = workspace.isStraightening && event.kind == .pointer
            cropAction = straighteningGesture ? nil : action
            editor.endEditing(assetID: asset.id); editor.beginEditing(assetID: asset.id)
            expectedCropRevision = editor.localRevision(for: asset.id)
            expectedCropSession = editor.aiEditSessionID
        }
        guard expectedCropRevision == editor.localRevision(for: asset.id), expectedCropSession == editor.aiEditSessionID else {
            finishGesture()
            return
        }
        guard let start, let point = normalized(location, rect: rect, clamp: true) else { return }
        current = point
        if !straighteningGesture {
            updateCrop(point, translation: CGSize(width: (location.x - initial.x) / rect.width,
                                                  height: (location.y - initial.y) / rect.height))
            expectedCropRevision = editor.localRevision(for: asset.id)
        }
        if event.phase == .ended {
            if straighteningGesture,
               hypot(event.translation.width, event.translation.height) >= 12,
               let correction = DevelopCropCanvasPresentation.straighteningAngle(from: start, to: point, sourceSize: sourceSize) {
                update { $0.straightenAngle = (correction * 100).rounded() / 100 }
                workspace.isStraightening = false
            }
            finishGesture()
        }
    }

    private func updateCrop(_ end: CGPoint, translation: CGSize) {
        guard let start, let cropAction else { return }
        let ratio = workspace.cropAspectLocked
            ? (workspace.cropAspect == "free" ? workspace.lockedCropRatio : workspace.cropRatio(source: sourceSize)) : nil
        let crop: DevelopCropRect?
        switch cropAction {
        case .move: crop = DevelopCropInteraction.moved(crop: originalCrop, translation: translation)
        case .resize(let handle): crop = DevelopCropInteraction.resized(crop: originalCrop, handle: handle,
            translation: translation, sourceSize: sourceSize, aspectRatio: ratio)
        case .create: crop = DevelopCropInteraction.created(from: start, to: end, sourceSize: sourceSize, aspectRatio: ratio)
        }
        if let crop { update { $0.crop = crop } }
    }

    private func cropCursor(at point: CGPoint, rect: CGRect, viewport: CGSize, angle: Double, scale: CGFloat) -> NSCursor {
        guard editor.canEdit, workspace.isOriginalCanvasReady,
              let location = DevelopCropCanvasPresentation.canvasPoint(from: point, viewport: viewport, angle: angle, scale: scale) else { return .arrow }
        if straighteningGesture || workspace.isStraightening { return .crosshair }
        let action = cropAction ?? DevelopCropInteraction.dragAction(at: location, crop: geometry.crop, imageRect: rect,
            forceMove: false, hitRadius: DevelopCropInteraction.hitRadius / scale)
        switch action {
        case .resize(let handle): return DevelopCropCursor.cursor(for: handle, angle: angle)
        case .move: return start == nil ? .openHand : .closedHand
        case .create: return rect.contains(location) ? .crosshair : .arrow
        }
    }

    private func drag(_ rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            guard editor.canEdit, workspace.isOriginalCanvasReady,
                  let point = normalized(value.location, rect: rect, clamp: start != nil) else { return }
            if start == nil {
                guard let initial = normalized(value.startLocation, rect: rect) else { return }
                start = initial; current = initial
                editor.endEditing(assetID: asset.id); editor.beginEditing(assetID: asset.id)

            }
            current = point

        }.onEnded { value in
            defer { finishGesture() }
            guard let start, let end = normalized(value.location, rect: rect, clamp: true) else { return }
            if workspace.tool == .redEye {
                let center = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                do {
                    let correction = try DevelopRedEyeCorrection(center: LocalMaskPoint(x: center.x, y: center.y),
                        radiusX: max(0.005, abs(end.x - start.x) / 2), radiusY: max(0.005, abs(end.y - start.y) / 2), strength: workspace.redEyeStrength)
                    update { $0.redEyeCorrections.append(correction) }
                } catch { workspace.errorMessage = error.localizedDescription }
            }
        }
    }
    private func whiteBalanceInput(_ event: DevelopCropInputEvent, rect: CGRect) {
        if event.phase == .cancelled { finishGesture(); return }
        guard event.kind == .pointer, workspace.picksWhiteBalance,
              editor.canEdit, workspace.isOriginalCanvasReady else { return }
        if event.phase == .began {
            guard let initial = normalized(event.startLocation, rect: rect) else { return }
            start = initial
            editor.endEditing(assetID: asset.id); editor.beginEditing(assetID: asset.id)
        }
        if event.phase == .ended {
            defer { finishGesture() }
            guard start != nil, let end = normalized(event.location, rect: rect, clamp: true) else { return }
            pickWhiteBalance(end)
        }
    }
    private func pickWhiteBalance(_ point: CGPoint) {
        guard let rgb = workspace.sourceAnalysis?.rgb(at: point),
              let correction = DevelopWhiteBalance.neutralizing(sRGBRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: rgb.3) else {
            workspace.errorMessage = "Wähle eine mittlere, deckende graue Fläche ohne ausgefressene Lichter oder tiefes Schwarz."
            return
        }
        editor.selectEditingFunction(.adjustments, assetID: asset.id)
        var settings = editor.settings(for: asset.id)
        settings.developColor.temperature = correction.temperature; settings.developColor.tint = correction.tint
        editor.setSettings(settings, for: asset.id)
        workspace.picksWhiteBalance = false
        workspace.errorMessage = correction.isClamped ? "Die Farbkorrektur wurde auf den verfügbaren Reglerbereich begrenzt." : nil
    }
    private func update(_ change: (inout DevelopGeometry) -> Void) {
        var settings = editor.settings(for: asset.id); change(&settings.developGeometry)
        settings = settings.normalized
        do { _ = try EditingSnapshot(settings: settings); editor.setSettings(settings, for: asset.id); workspace.errorMessage = nil }
        catch { workspace.errorMessage = error.localizedDescription }
    }
    private func finishGesture() {
        if start != nil { editor.endEditing(assetID: asset.id) }
        start = nil; current = nil; originalCrop = nil; cropAction = nil; straighteningGesture = false
        expectedCropRevision = nil; expectedCropSession = nil
        // The native picker owns hover cursor updates. Finishing a gesture
        // while it is active must not replace its stationary eyedropper.
        if !workspace.picksWhiteBalance || !workspace.isOriginalCanvasReady || !editor.canEdit { NSCursor.arrow.set() }
    }
}
