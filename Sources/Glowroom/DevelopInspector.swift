import SwiftUI
import GlowroomCore

enum DevelopInspectorColumn {
    case navigation, adjustments
}

struct DevelopInspector: View {
    @ObservedObject var library: LibraryModel
    var focusedControl: FocusState<WorkspaceControlFocus?>.Binding
    var column: DevelopInspectorColumn = .adjustments
    @EnvironmentObject private var editor: EditingModel
    @EnvironmentObject private var photoMetadata: PhotoMetadataModel
    @EnvironmentObject private var layout: WorkspaceLayoutModel
    @EnvironmentObject private var maskWorkspace: InlineMaskWorkspace
    @EnvironmentObject private var developWorkspace: DevelopWorkspace
    @ViewState private var fulfilledReveal: UUID?

    private struct RevealFocusIdentity: Hashable {
        let request: UUID
        let assetID: String
        let canvasTool: DevelopCanvasTool
        let hasMaskDraft: Bool
    }

    private var panels: WorkspacePanels { layout.panels(developing: library.isDeveloping) }
    private var saveStatus: WorkspaceSaveStatus { WorkspaceSaveStatus(editor: editor) }

    private var groups: [WorkspaceTool] {
        column == .navigation ? [.metadata, .versions] : [.edit, .details]
    }

    var body: some View {
        VStack(spacing: 0) {
            if let asset = library.selectedAsset {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if column == .navigation {
                                navigator(asset)
                                ForEach(groups, id: \.self) { tool in toolGroup(tool, asset: asset) }
                            } else {
                                DevelopHistogram(workspace: developWorkspace, asset: asset, library: library)
                                    .padding(.bottom, 5)
                                developToolStrip(asset).padding(.bottom, 5)
                                if developWorkspace.tool == .masks, maskWorkspace.isPresented {
                                    InlineMaskInspector(workspace: maskWorkspace)
                                } else if developWorkspace.tool != .basic {
                                    DevelopGeometryInspector(asset: asset, workspace: developWorkspace)
                                        .id(asset.id).id(developWorkspace.tool)
                                } else {
                                    ForEach(groups, id: \.self) { tool in toolGroup(tool, asset: asset) }
                                }
                            }
                        }.padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 12)
                    }
                    .task(id: RevealFocusIdentity(request: layout.revealRequest, assetID: asset.id,
                        canvasTool: developWorkspace.tool, hasMaskDraft: maskWorkspace.isPresented)) {
                        let request = layout.revealRequest
                        guard developWorkspace.tool == .basic, !maskWorkspace.isPresented,
                              fulfilledReveal != request, let tool = layout.revealedTool,
                              groups.contains(tool), panels.openGroups.contains(tool) else { return }
                        // Only the owning column scrolls and focuses a reveal.
                        // A preceding canvas-tool transition publishes its result first.
                        await Task.yield()
                        guard !Task.isCancelled, request == layout.revealRequest,
                              developWorkspace.tool == .basic, !maskWorkspace.isPresented,
                              library.selectedID == asset.id else { return }
                        withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(tool, anchor: .top) }
                        focusedControl.wrappedValue = .group(tool)
                        fulfilledReveal = request
                    }
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                editingHistory(assetID: asset.id)
            } else {
                Text("Wähle ein Foto zum Bearbeiten.").font(.callout).foregroundStyle(Theme.muted).padding(24)
                Spacer()
            }
        }.background(Theme.sidebar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(column == .navigation ? "develop.navigation" : "develop.adjustments")
    }

    private func navigator(_ asset: PhotoAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Navigator").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Text("Einpassen").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }.frame(height: 26)
            Group {
                if let image = developWorkspace.navigatorImage {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo").font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(Theme.muted)
                }
            }.frame(maxWidth: .infinity).frame(height: 155)
                .padding(6).background(Theme.panel)
                .overlay { Rectangle().stroke(Theme.line) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Navigator: \(asset.fileName)")
                .accessibilityIdentifier("workspace.navigator")
            Text(asset.fileName).font(.system(size: 10)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.middle)
        }.padding(.bottom, 16)
    }

    private func developToolStrip(_ asset: PhotoAsset) -> some View {
        HStack(spacing: 0) {
            ForEach(DevelopCanvasTool.allCases) { tool in
                Button {
                    finishInput(assetID: asset.id)
                    editor.selectEditingFunction(EditingFunction(tool), assetID: asset.id)
                    developWorkspace.tool = tool
                } label: {
                    Image(systemName: tool.symbol).font(.system(size: 16))
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .foregroundStyle(developWorkspace.tool == tool ? Color.white.opacity(0.9) : Theme.muted)
                        .background(developWorkspace.tool == tool ? Color.white.opacity(0.09) : .clear)
                }.buttonStyle(.plain).help(tool.title).accessibilityLabel(tool.title)
                    .accessibilityIdentifier("develop.tool.\(tool.rawValue)")
                    .accessibilityValue(developWorkspace.tool == tool ? "Aktiv" : "Inaktiv")
                    .disabled(!editor.canEdit || !library.canModify || library.comparesOriginal || library.comparesCurrentSourceWithoutSettings
                              || (maskWorkspace.model?.isGenerating ?? false))
            }
        }.padding(3).background(Theme.panel)
            .overlay { Rectangle().stroke(Theme.line) }
    }

    private func colorBasics(assetID: String) -> some View {
        let settings = editor.settings(for: assetID)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Toggle("S/W", isOn: colorBinding(assetID: assetID, keyPath: \.isMonochrome))
                    .toggleStyle(.button).help("Schwarzweiß ohne die vorherigen Farbregler zu verlieren")
                Toggle("HDR", isOn: colorBinding(assetID: assetID, keyPath: \.hdrEnabled))
                    .toggleStyle(.button).help("Erweiterten Dynamikumfang bearbeiten und auf HDR-fähigen Displays anzeigen")
            }.buttonStyle(.bordered).controlSize(.small)
            Picker("Profil", selection: Binding(get: { editor.settings(for: assetID).developColor.profile }, set: { profile in
                finishInput(assetID: assetID)
                var value = editor.settings(for: assetID); value.developColor.profile = profile
                setAdjustmentSettings(value, for: assetID)
            })) {
                ForEach(DevelopColorProfile.allCases, id: \.self) { Text($0.title).tag($0) }
            }.font(.system(size: 11))
            Divider()
            HStack {
                Button { developWorkspace.picksWhiteBalance.toggle() } label: {
                    Image(systemName: "eyedropper").font(.system(size: 16)).frame(width: 28, height: 24)
                }.buttonStyle(.plain).foregroundStyle(developWorkspace.picksWhiteBalance ? Theme.accent : Theme.muted)
                    .help("Weißabgleich: eine neutrale graue Fläche auf dem Bild anklicken")
                    .accessibilityIdentifier("develop.white-balance-picker")
                    .disabled(developWorkspace.sourceAnalysis == nil)
                Text("Weißabgleich").font(.system(size: 11))
                Spacer()
                Menu {
                    Button("Wie Aufnahme") { setWhiteBalance(6_500, assetID: assetID) }
                    Divider()
                    Button("Tageslicht") { setWhiteBalance(5_500, assetID: assetID) }
                    Button("Bewölkt") { setWhiteBalance(7_000, assetID: assetID) }
                    Button("Schatten") { setWhiteBalance(8_000, assetID: assetID) }
                    Button("Glühlampe") { setWhiteBalance(2_850, assetID: assetID) }
                    Button("Leuchtstoff") { setWhiteBalance(4_000, tint: 15, assetID: assetID) }
                } label: {
                    Text(settings.developColor.temperature == 6_500 && settings.developColor.tint == 0 ? "Wie Aufnahme" : "Benutzerdefiniert")
                }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            colorSlider("Temperatur", assetID: assetID, keyPath: \.temperature,
                        range: DevelopColorSettings.temperatureRange, neutral: 6_500, step: 50)
                .help("Relativer Weißabgleich auf entwickelten Pixeln. 6500 erhält den Kamera-/ImageIO-Weißabgleich unverändert.")
            colorSlider("Tönung", assetID: assetID, keyPath: \.tint,
                        range: DevelopColorSettings.tintRange, neutral: 0, step: 1)
            if developWorkspace.picksWhiteBalance {
                Text("Klicke eine neutrale graue Fläche an. Die Pipette verwendet die entwickelte Quelle vor den Farbkorrekturen.")
                    .font(.system(size: 10)).foregroundStyle(Theme.accent)
            }
            if settings.developColor.hdrEnabled {
                Text("HDR-Vorschau mit erweitertem Dynamikumfang. JPEG wird als SDR ausgegeben; HDR-Ausgabe über HEIF 10 Bit.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            if let error = developWorkspace.errorMessage {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
            }
        }.disabled(!editor.canEdit || !library.canModify || library.comparesOriginal || library.comparesCurrentSourceWithoutSettings)
    }

    private func setWhiteBalance(_ temperature: Double, tint: Double = 0, assetID: String) {
        finishInput(assetID: assetID)
        var value = editor.settings(for: assetID)
        value.developColor.temperature = temperature; value.developColor.tint = tint
        setAdjustmentSettings(value, for: assetID)
    }

    private func colorBinding(assetID: String, keyPath: WritableKeyPath<DevelopColorSettings, Bool>) -> Binding<Bool> {
        Binding(get: { editor.settings(for: assetID).developColor[keyPath: keyPath] }, set: { enabled in
            finishInput(assetID: assetID)
            var value = editor.settings(for: assetID); value.developColor[keyPath: keyPath] = enabled
            setAdjustmentSettings(value, for: assetID)
        })
    }
    private func colorSlider(_ title: String, assetID: String, keyPath: WritableKeyPath<DevelopColorSettings, Double>,
                             range: ClosedRange<Double>, neutral: Double, step: Double) -> some View {
        HStack(spacing: 7) {
            Text(title).font(.system(size: 10)).foregroundStyle(Theme.muted).frame(width: 68, alignment: .trailing)
            ResettableSlider(value: Binding(get: { editor.settings(for: assetID).developColor[keyPath: keyPath] }, set: { amount in
                var value = editor.settings(for: assetID); value.developColor[keyPath: keyPath] = amount
                setAdjustmentSettings(value, for: assetID)
            }), in: range, step: step, neutralValue: neutral, onEditingChanged: { editing in
                if editing { beginAdjustment(assetID: assetID) } else { editor.endEditing(assetID: assetID) }
            }).controlSize(.mini).accessibilityLabel(title)
            Text("\(Int(editor.settings(for: assetID).developColor[keyPath: keyPath]))")
                .monospacedDigit().font(.system(size: 10)).frame(width: 43, alignment: .trailing)
        }.frame(minHeight: 20)
    }

    private func toolGroup(_ tool: WorkspaceTool, asset: PhotoAsset) -> some View {
        let expanded = panels.openGroups.contains(tool)
        let groupStatus = status(for: tool, assetID: asset.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleGroup(tool, assetID: asset.id)
            } label: {
                toolGroupHeading(tool, expanded: expanded, status: groupStatus)
            }.buttonStyle(.plain)
                .workspaceFocusTarget(focusedControl, equals: .group(tool)) {
                    toggleGroup(tool, assetID: asset.id)
                }
                .accessibilityLabel(groupTitle(tool))
                .accessibilityIdentifier("workspace.group.\(tool.rawValue)")
                .accessibilityValue([expanded ? "Geöffnet" : "Geschlossen", groupStatus?.text].compactMap { $0 }.joined(separator: ", "))
                .accessibilityHint(expanded ? "Werkzeuggruppe zuklappen" : "Werkzeuggruppe aufklappen")
                .contextMenu {
                    Toggle("Nur eine Gruppe geöffnet", isOn: Binding(
                        get: { panels.singleGroup },
                        set: { enabled in
                            finishInput(assetID: asset.id)
                            layout.update(developing: library.isDeveloping) { $0.singleGroup = enabled }
                        }
                    ))
                }
            if expanded {
                if column == .navigation, maskWorkspace.isPresented {
                    Text("Zum Wechseln die Gruppenüberschrift anklicken und den Maskenentwurf übernehmen.")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true).padding(6)
                }
                toolContent(tool, asset: asset)
                    .disabled(column == .navigation && maskWorkspace.isPresented)
                    // Photo-bound controls reset on selection. Group preferences
                    // stay in the workspace model outside this identity boundary.
                    .id(asset.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 9)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
        }.padding(.bottom, 2).id(tool)
    }

    private func toolGroupHeading(_ tool: WorkspaceTool, expanded: Bool,
                                 status: (text: String, symbol: String, isError: Bool)?) -> some View {
        HStack(spacing: 8) {
            Text(groupTitle(tool)).font(.system(size: 12, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 3)
            if let status {
                Label(status.text, systemImage: status.symbol)
                    .font(.system(size: 9)).foregroundStyle(status.isError ? Color.orange : Theme.muted)
                    .labelStyle(.iconOnly).help(status.text)
            }
            Image(systemName: expanded ? "chevron.down" : "chevron.left")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
        }.padding(.horizontal, 7).frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
            .background(Theme.panel).contentShape(Rectangle())
    }

    @ViewBuilder private func toolContent(_ tool: WorkspaceTool, asset: PhotoAsset) -> some View {
        switch tool {
        case .edit:
            VStack(alignment: .leading, spacing: 5) {
                colorBasics(assetID: asset.id)
                naturalBalanceSection(assetID: asset.id)
                adjustmentSection("Tonwert", key: "tone", controls: Array(Adjustment.allCases.prefix(6)), assetID: asset.id)
                adjustmentSection("Präsenz", key: "presence", controls: Array(Adjustment.allCases.dropFirst(6).prefix(5)), assetID: asset.id)
            }
        case .details:
            VStack(alignment: .leading, spacing: 8) {
                DevelopDetailPreview(workspace: developWorkspace,
                    isEnabled: developWorkspace.tool == .basic && !maskWorkspace.isPresented
                        && !library.comparesOriginal && !library.comparesCurrentSourceWithoutSettings)
                adjustmentSection("Schärfen", key: "sharpening",
                    controls: [.sharpeningAmount, .sharpeningRadius, .sharpeningDetail, .sharpeningMasking], assetID: asset.id,
                    collapsible: false)
                adjustmentSection("Entrauschen", key: "noise", controls: Array(Adjustment.allCases.suffix(2)), assetID: asset.id,
                    collapsible: false)
            }
            .onDisappear { developWorkspace.picksDetail = false }
        case .aiDevelopment:
            EmptyView() // AI development owns its separate top-level workspace.
        case .metadata:
            VStack(alignment: .leading, spacing: 20) {
                PhotoMetadataSection(model: photoMetadata)
                photoDetails(asset)
            }
        case .versions:
            VStack(alignment: .leading, spacing: 13) {
                Text("Aktive Quelle: \(editor.snapshot(for: asset.id).source == .original ? "Importiertes Original" : "Generierter Bildstand")")
                    .font(.system(size: 11, weight: .medium))
                Button("Zum importierten Original zurückkehren") {
                    finishInput(assetID: asset.id)
                    editor.returnToOriginal(assetID: asset.id)
                    library.comparesOriginal = false
                    library.comparesCurrentSourceWithoutSettings = false
                }.disabled(!editor.canEdit || editor.snapshot(for: asset.id).source == .original)
                if let error = editor.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if let retry = saveStatus.retryAction {
                    Button(retry.title) {
                        switch retry {
                        case .acceptedArtifact(let id): _ = editor.retryAcceptedArtifactCommit(id)
                        case .pendingChanges: Task { _ = await editor.flush() }
                        case .reload: editor.retryLoading()
                        }
                    }.disabled(!saveStatus.canRetry)
                }
                ArtifactVariantsSection(assetID: asset.id)
            }
        }
    }

    private func editingHistory(assetID: String) -> some View {
        HStack(spacing: 8) {
            if column == .navigation {
                Button {
                    finishInput(assetID: assetID)
                    ResettableNativeSlider.cancelInputs(in: NSApp.keyWindow?.contentView)
                    if maskWorkspace.isPresented { maskWorkspace.undo() }
                    else { developWorkspace.cancelRepairWork(); editor.undo(assetID: assetID) }
                } label: { Label("Rückgängig", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity) }
                    .disabled(!editor.canEdit || (maskWorkspace.isPresented ? maskWorkspace.model?.canUndo != true : !editor.canUndo(assetID: assetID)))
                    .accessibilityIdentifier("workspace.undo")
                Button {
                    finishInput(assetID: assetID)
                    ResettableNativeSlider.cancelInputs(in: NSApp.keyWindow?.contentView)
                    if maskWorkspace.isPresented { maskWorkspace.redo() }
                    else { developWorkspace.cancelRepairWork(); editor.redo(assetID: assetID) }
                } label: { Label("Wiederholen", systemImage: "arrow.uturn.forward").frame(maxWidth: .infinity) }
                    .disabled(!editor.canEdit || (maskWorkspace.isPresented ? maskWorkspace.model?.canRedo != true : !editor.canRedo(assetID: assetID)))
                    .accessibilityIdentifier("workspace.redo")
            } else {
                Button("Zurücksetzen") {
                    finishInput(assetID: assetID)
                    editor.reset(assetID: assetID)
                }.frame(maxWidth: .infinity)
                    .disabled(maskWorkspace.isPresented || !editor.canEdit || editor.settings(for: assetID).isNeutral)
                    .accessibilityIdentifier("workspace.reset")
            }
        }.buttonStyle(.bordered).controlSize(.small).font(.system(size: 10))
            .padding(.horizontal, 8).frame(height: 38)
    }

    private func groupTitle(_ tool: WorkspaceTool) -> String {
        switch tool {
        case .edit: "Grundeinstellungen"
        case .versions: "Bildstände"
        default: tool.title
        }
    }

    private func toggleGroup(_ tool: WorkspaceTool, assetID: String) {
        finishInput(assetID: assetID)
        if tool == .details, panels.openGroups.contains(.details) {
            developWorkspace.picksDetail = false
        }
        if tool.isNavigationTool, developWorkspace.tool != .basic {
            // A supporting group can already be open when a canvas draft starts.
            // Use the same admission/acceptance path as an explicit group reveal.
            layout.reveal(tool, developing: library.isDeveloping)
        } else {
            if !panels.openGroups.contains(tool) {
                editor.selectEditingFunction(EditingFunction(tool), assetID: assetID)
            }
            layout.toggleGroup(tool, developing: library.isDeveloping)
        }
        focusedControl.wrappedValue = .group(tool)
    }

    private func toggleAdjustmentGroup(_ key: String, assetID: String) {
        finishInput(assetID: assetID)
        layout.update(developing: library.isDeveloping) { state in
            if state.openAdjustmentGroups.contains(key) { state.openAdjustmentGroups.remove(key) }
            else { state.openAdjustmentGroups.insert(key) }
        }
        focusedControl.wrappedValue = .adjustmentGroup(key)
    }

    private func setAdjustmentSettings(_ settings: EditSettings, for assetID: String) {
        editor.selectEditingFunction(.adjustments, assetID: assetID, cancelsActiveInput: false)
        editor.setSettings(settings, for: assetID)
    }

    private func beginAdjustment(assetID: String) {
        editor.selectEditingFunction(.adjustments, assetID: assetID, cancelsActiveInput: false)
        editor.beginEditing(assetID: assetID)
    }

    private func finishInput(assetID: String) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        editor.endEditing(assetID: assetID)
    }

    private func status(for tool: WorkspaceTool, assetID: String) -> (text: String, symbol: String, isError: Bool)? {
        switch tool {
        case .edit, .details:
            if editor.isReadOnly { return ("Fehler", "exclamationmark.triangle", true) }
            if editor.isSaving || editor.isLoading || editor.hasPendingChanges { return ("Läuft", "arrow.triangle.2.circlepath", false) }
            let settings = editor.settings(for: assetID)
            let changed = tool == .details
                ? settings.sharpeningAmount != 0 || settings.luminanceNoiseReduction != 0 || settings.colorNoiseReduction != 0
                : !settings.isNeutral
            if changed { return ("Geändert", "slider.horizontal.3", false) }
        case .aiDevelopment:
            return nil
        case .metadata:
            if photoMetadata.errorMessage != nil || photoMetadata.hasPendingRetry || photoMetadata.recovery != nil {
                return ("Fehler", "exclamationmark.triangle", true)
            }
            if photoMetadata.isSaving || photoMetadata.isLoading { return ("Läuft", "arrow.triangle.2.circlepath", false) }
            if photoMetadata.hasManualDraft {
                return ("Entwurf", "square.and.pencil", false)
            }
        case .versions:
            if editor.errorMessage != nil || editor.failedArtifactCommitID != nil { return ("Fehler", "exclamationmark.triangle", true) }
            if editor.isCommitting || editor.isLoadingVariants { return ("Läuft", "arrow.triangle.2.circlepath", false) }
        }
        return nil
    }

    private func photoDetails(_ asset: PhotoAsset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            SectionLabel(text: "Aufnahme")
            metadataRow("Kamera", asset.cameraModel ?? "—")
            metadataRow("Objektiv", asset.lensModel ?? "—")
            metadataRow("Blende", asset.aperture ?? "—")
            metadataRow("Zeit", asset.shutterSpeed ?? "—")
            metadataRow("ISO", asset.iso ?? "—")
            metadataRow("Brennweite", asset.focalLength ?? "—")
            metadataRow("Aufgenommen", asset.captureDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
            Divider()
            SectionLabel(text: "Datei")
            metadataRow("Abmessungen", "\(asset.pixelWidth) × \(asset.pixelHeight)")
            metadataRow("Auflösung", String(format: "%.1f MP", Double(asset.pixelWidth) * Double(asset.pixelHeight) / 1_000_000))
            metadataRow("Format", asset.format.uppercased())
            metadataRow("Größe", ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file))
            metadataRow("Geändert", asset.modifiedAt.formatted(date: .abbreviated, time: .omitted))
            Divider()
            SectionLabel(text: "Speicherort")
            Text(asset.fileURL.deletingLastPathComponent().path)
                .font(.system(size: 11)).foregroundStyle(Theme.muted).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button { library.reveal() } label: { Label("Im Finder anzeigen", systemImage: "arrow.up.right.square") }
                .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Theme.accent)
        }
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
    }

    private func naturalBalanceSection(assetID: String) -> some View {
        let settings = editor.settings(for: assetID)
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { editor.settings(for: assetID).naturalBalanceAmount > 0 },
                set: { enabled in
                    finishInput(assetID: assetID)
                    var settings = editor.settings(for: assetID)
                    settings.naturalBalanceAmount = enabled ? 70 : 0
                    if enabled { settings.autoToneAmount = 0 }
                    setAdjustmentSettings(settings, for: assetID)
                }
            )) {
                Label("Natürlicher Bildausgleich", systemImage: "wand.and.stars")
                    .font(.system(size: 11, weight: .medium))
            }.toggleStyle(.switch).controlSize(.small)
                .accessibilityIdentifier("develop.naturalBalance")
                .help("Analysiert dieses Foto lokal und gleicht Helligkeit, Lichter, Schatten und Farben zurückhaltend aus. Manuelle Regler bleiben zusätzlich wirksam.")

            if settings.naturalBalanceAmount > 0 {
                naturalBalanceSlider("Stärke", keyPath: \.naturalBalanceAmount, range: 0...100, assetID: assetID)
                naturalBalanceSlider("Farbe", keyPath: \.naturalBalanceColorAmount, range: 0...100, assetID: assetID)
                Text("Farbe 0: nur Tonwerte. Höhere Werte beleben zurückhaltend die Farben.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else if settings.autoToneAmount > 0 {
                Text("Bisherige Tonwert-Automatik aktiv (\(Int(settings.autoToneAmount)) %). Dein gespeicherter Bildstand bleibt erhalten. Einschalten ersetzt sie durch den natürlichen Bildausgleich.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Button("Bisherige Automatik ausschalten") {
                    finishInput(assetID: assetID)
                    var settings = editor.settings(for: assetID)
                    settings.autoToneAmount = 0
                    setAdjustmentSettings(settings, for: assetID)
                }.font(.system(size: 10))
            }
        }.disabled(!editor.canEdit || !library.canModify || library.comparesOriginal || library.comparesCurrentSourceWithoutSettings)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func naturalBalanceSlider(_ title: String, keyPath: WritableKeyPath<EditSettings, Double>,
                                      range: ClosedRange<Double>, assetID: String) -> some View {
        HStack(spacing: 7) {
            Text(title).font(.system(size: 10)).foregroundStyle(Theme.muted)
                .frame(width: 68, alignment: .trailing)
            ResettableSlider(value: Binding(
                get: { editor.settings(for: assetID)[keyPath: keyPath] },
                set: { newValue in
                    var settings = editor.settings(for: assetID)
                    settings[keyPath: keyPath] = newValue
                    setAdjustmentSettings(settings, for: assetID)
                }
            ), in: range, step: 1, neutralValue: keyPath == \EditSettings.naturalBalanceColorAmount ? 50 : 0, onEditingChanged: { editing in
                if editing { beginAdjustment(assetID: assetID) }
                else { editor.endEditing(assetID: assetID) }
            }).controlSize(.mini).accessibilityLabel("Bildausgleich · \(title)")
            Text("\(Int(editor.settings(for: assetID)[keyPath: keyPath])) %")
                .monospacedDigit().font(.system(size: 10)).foregroundStyle(Theme.accent)
                .frame(width: 43, alignment: .trailing)
        }.frame(minHeight: 20)
    }

    private func adjustmentSection(_ title: String, key: String, controls: [Adjustment], assetID: String,
                                   collapsible: Bool = true) -> some View {
        let expanded = !collapsible || panels.openAdjustmentGroups.contains(key)
        let readOnly = !editor.canEdit || !library.canModify || library.comparesOriginal || library.comparesCurrentSourceWithoutSettings
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                if collapsible {
                    Button {
                        toggleAdjustmentGroup(key, assetID: assetID)
                    } label: {
                        HStack(spacing: 8) {
                            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                            Spacer(minLength: 0)
                            Image(systemName: expanded ? "chevron.down" : "chevron.left")
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
                        }.frame(minHeight: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .workspaceFocusTarget(focusedControl, equals: .adjustmentGroup(key)) {
                            toggleAdjustmentGroup(key, assetID: assetID)
                        }
                        .accessibilityLabel(title).accessibilityValue(expanded ? "Geöffnet" : "Geschlossen")
                        .accessibilityHint(expanded ? "Reglergruppe zuklappen" : "Reglergruppe aufklappen")
                } else {
                    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("develop.adjustment-group.\(key)")
                }
                Button {
                    finishInput(assetID: assetID)
                    var settings = editor.settings(for: assetID)
                    for item in controls { settings[keyPath: item.keyPath] = item.neutralValue }
                    setAdjustmentSettings(settings, for: assetID)
                } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 11)).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("\(title) zurücksetzen")
                    .accessibilityLabel("\(title) zurücksetzen").disabled(readOnly)
            }
            if expanded {
                VStack(spacing: 2) {
                    ForEach(controls) { control in
                        AdjustmentSlider(control: control, value: Binding(
                            get: { editor.settings(for: assetID)[keyPath: control.keyPath] },
                            set: { newValue in
                                var settings = editor.settings(for: assetID)
                                settings[keyPath: control.keyPath] = newValue
                                setAdjustmentSettings(settings, for: assetID)
                            }
                        ), onAutomaticValue: control.automaticToneControl.map { toneControl in
                            {
                                finishInput(assetID: assetID)
                                let selectionSession = library.aiSelectionSessionID
                                let selectionGeneration = library.aiSelectionGeneration
                                developWorkspace.applyAutomaticTone(toneControl, assetID: assetID, editor: editor) {
                                    guard let selected = library.selectedAsset, selected.id == assetID,
                                          library.aiSelectionSessionID == selectionSession,
                                          library.aiSelectionGeneration == selectionGeneration,
                                          library.isDeveloping, library.canModify,
                                          !library.comparesOriginal, !library.comparesCurrentSourceWithoutSettings,
                                          !maskWorkspace.isPresented,
                                          let source = try? editor.resolvedSource(for: selected) else { return false }
                                    return source.identity == developWorkspace.sourceIdentity
                                }
                            }
                        }, onEditingChanged: { editing in
                            if editing { beginAdjustment(assetID: assetID) }
                            else { editor.endEditing(assetID: assetID) }
                        })
                        .disabled(control.isSharpeningPreference && editor.settings(for: assetID).sharpeningAmount == 0)
                    }
                    if key == "sharpening" {
                        Text("Betrag verstärkt Kanten, Radius bestimmt ihre Breite. Details betont feine Strukturen; Maskieren schützt glatte Flächen. Prüfe die Wirkung im Detailzoom.")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(3)
                    } else if key == "noise" {
                        Text("Luminanz reduziert Helligkeitsrauschen, Farbe reduziert Farbflecken. Der Detailzoom zeigt die Wirkung am gewählten Ausschnitt.")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(3)
                    }
                }.disabled(readOnly)
            }
        }.padding(.top, 4)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

struct AdjustmentSlider: View {
    let control: Adjustment
    @Binding var value: Double
    var onAutomaticValue: (() -> Void)? = nil
    let onEditingChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var valueFocused: Bool

    private var numericValue: Binding<Double> {
        Binding(get: { value }, set: { newValue in
            // TextField parses valid prefixes while typing (3, then 35). Keep
            // the complete entry in one undo group until submit or focus loss.
            onEditingChanged(true)
            value = newValue
        })
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(control.label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                .frame(width: 76, alignment: .trailing)
                .onTapGesture(count: 2, perform: resetValue)
                .highPriorityGesture(TapGesture(count: 2).modifiers(.shift).onEnded { _ in
                    guard isEnabled else { return }
                    if let onAutomaticValue { onEditingChanged(false); onAutomaticValue() }
                    else { resetValue() }
                }).help(gestureHelp)
            ResettableSlider(value: $value, in: control.range, step: control.step, neutralValue: control.neutralValue,
                             onAutomaticValue: onAutomaticValue,
                             onEditingChanged: onEditingChanged)
                .controlSize(.mini).accessibilityLabel(control.label).help(gestureHelp)
                .accessibilityHint(gestureHelp)
            TextField(control.label, value: numericValue,
                      format: .number.precision(.fractionLength(control.fractionDigits)))
                .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(value == control.neutralValue ? Theme.muted : Theme.accent)
                .frame(width: 38).accessibilityLabel("\(control.label) Wert")
                .focused($valueFocused)
                .onSubmit { onEditingChanged(false) }
                .onChange(of: valueFocused) { _, focused in if !focused { onEditingChanged(false) } }
                .onDisappear { onEditingChanged(false) }
        }.frame(minHeight: 20)
            .accessibilityIdentifier("develop.adjustment.\(control.rawValue)")
    }

    private var gestureHelp: String {
        onAutomaticValue == nil ? "Doppelklick setzt den Wert zurück" :
            "Shift-Doppelklick berechnet diesen Tonwert automatisch. Doppelklick setzt den Wert zurück."
    }

    private func resetValue() {
        guard isEnabled else { return }
        onEditingChanged(false); onEditingChanged(true); value = control.neutralValue; onEditingChanged(false)
    }
}

enum Adjustment: String, CaseIterable, Identifiable {
    case exposure, contrast, highlights, shadows, whites, blacks
    case texture, clarity, dehaze, vibrance, saturation
    case sharpeningAmount, sharpeningRadius, sharpeningDetail, sharpeningMasking
    case luminanceNoiseReduction, colorNoiseReduction
    var id: String { rawValue }
    var automaticToneControl: AutomaticToneControl? { AutomaticToneControl(rawValue: rawValue) }
    var label: String {
        switch self {
        case .exposure: return "Belichtung"
        case .contrast: return "Kontrast"
        case .highlights: return "Lichter"
        case .shadows: return "Tiefen"
        case .whites: return "Weiß"
        case .blacks: return "Schwarz"
        case .texture: return "Struktur"
        case .clarity: return "Klarheit"
        case .dehaze: return "Dunst entfernen"
        case .vibrance: return "Dynamik"
        case .saturation: return "Sättigung"
        case .sharpeningAmount: return "Betrag"
        case .sharpeningRadius: return "Radius"
        case .sharpeningDetail: return "Details"
        case .sharpeningMasking: return "Maskieren"
        case .luminanceNoiseReduction: return "Luminanz"
        case .colorNoiseReduction: return "Farbe"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .exposure: return -5...5
        case .sharpeningAmount: return 0...150
        case .sharpeningRadius: return 0.5...3
        case .luminanceNoiseReduction, .colorNoiseReduction, .sharpeningDetail, .sharpeningMasking: return 0...100
        default: return -100...100
        }
    }
    var neutralValue: Double {
        switch self {
        case .sharpeningRadius: 1
        case .sharpeningDetail: 25
        default: 0
        }
    }
    var step: Double {
        switch self {
        case .exposure: 0.05
        case .sharpeningRadius: 0.1
        default: 1
        }
    }
    var fractionDigits: Int {
        switch self {
        case .exposure: 2
        case .sharpeningRadius: 1
        default: 0
        }
    }
    var isSharpeningPreference: Bool {
        self == .sharpeningRadius || self == .sharpeningDetail || self == .sharpeningMasking
    }
    var keyPath: WritableKeyPath<EditSettings, Double> {
        switch self {
        case .exposure: return \.exposure
        case .contrast: return \.contrast
        case .highlights: return \.highlights
        case .shadows: return \.shadows
        case .whites: return \.whites
        case .blacks: return \.blacks
        case .texture: return \.texture
        case .clarity: return \.clarity
        case .dehaze: return \.dehaze
        case .vibrance: return \.vibrance
        case .saturation: return \.saturation
        case .sharpeningAmount: return \.sharpeningAmount
        case .sharpeningRadius: return \.sharpeningRadius
        case .sharpeningDetail: return \.sharpeningDetail
        case .sharpeningMasking: return \.sharpeningMasking
        case .luminanceNoiseReduction: return \.luminanceNoiseReduction
        case .colorNoiseReduction: return \.colorNoiseReduction
        }
    }
}
