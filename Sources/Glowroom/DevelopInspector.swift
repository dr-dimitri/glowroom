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
    @ViewState private var showsCompactHistogram = false
    @ViewState private var showsAdjustmentHelp = false
    @ViewState private var toneMigrationTarget: ToneMigrationTarget?

    private struct ToneMigrationTarget: Identifiable {
        let id = UUID()
        let assetID: String
        let revision: Int64
        let snapshot: EditingSnapshot
    }
    @ViewState private var showsAdvancedVersions = false

    private struct RevealFocusIdentity: Hashable {
        let request: UUID
        let assetID: String
        let canvasTool: DevelopCanvasTool
        let hasMaskDraft: Bool
    }

    private var panels: WorkspacePanels { layout.panels(developing: library.isDeveloping) }
    private var saveStatus: WorkspaceSaveStatus { WorkspaceSaveStatus(editor: editor) }

    private var groups: [WorkspaceTool] {
        column == .navigation ? [.metadata, .versions] : [.aiDevelopment, .edit, .color, .details]
    }

    var body: some View {
        GeometryReader { available in
            VStack(spacing: 0) {
                if let asset = library.selectedAsset {
                    if column == .adjustments {
                        // Keep navigation controls mounted while long palettes scroll.
                        VStack(spacing: 5) {
                            if available.size.height < 600 {
                                DisclosureGroup("Histogramm", isExpanded: $showsCompactHistogram) {
                                    DevelopHistogram(workspace: developWorkspace, asset: asset, library: library)
                                }.font(.system(size: 13))
                                    .accessibilityIdentifier("develop.compact-histogram")
                            } else {
                                DevelopHistogram(workspace: developWorkspace, asset: asset, library: library)
                            }
                            developToolStrip(asset)
                        }.padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 5)
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                if column == .navigation {
                                    navigator(asset)
                                    ForEach(groups, id: \.self) { tool in toolGroup(tool, asset: asset) }
                                } else {
                                    if developWorkspace.tool == .masks, maskWorkspace.isPresented {
                                        InlineMaskInspector(workspace: maskWorkspace)
                                    } else if developWorkspace.tool != .basic {
                                        DevelopGeometryInspector(asset: asset, workspace: developWorkspace)
                                            .id(asset.id).id(developWorkspace.tool.isRepairTool ? .repair : developWorkspace.tool)
                                    } else {
                                        DevelopPresetsPanel(library: library)
                                        adjustmentNavigation
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
                    Label("Kein Foto ausgewählt", systemImage: "photo")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted).padding(24)
                    if column == .adjustments {
                        Button("Foto auswählen") { WorkspaceActions.showGrid(layout, library: library) }
                            .accessibilityIdentifier("ai-development.select-photo")
                        Button("KI-Modelle …") { library.aiModelsDestination = .overview }
                            .font(.system(size: 13))
                            .accessibilityIdentifier("ai-models.open")
                    }
                    Spacer()
                }
            }.background(Theme.sidebar)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(column == .navigation ? "develop.navigation" : "develop.adjustments")
                .sheet(isPresented: $showsAdjustmentHelp) { DevelopAdjustmentsHelp() }
                .sheet(item: $toneMigrationTarget) { target in
                    ToneProcessingMigrationView(canMigrate: canMigrate(target)) {
                        guard canMigrate(target) else { return }
                        finishInput(assetID: target.assetID)
                        editor.upgradeToneProcessing(assetID: target.assetID)
                        toneMigrationTarget = nil
                    }
                }
                .onChange(of: library.selectedID) { _, _ in toneMigrationTarget = nil }
        }
    }

    private func navigator(_ asset: PhotoAsset) -> some View {
        DevelopPhotoNavigator(asset: asset, image: developWorkspace.navigatorImage,
                              viewport: developWorkspace.photoViewport)
    }

    private func developToolStrip(_ asset: PhotoAsset) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
            ForEach(DevelopCanvasTool.toolbarCases) { tool in
                Button {
                    finishInput(assetID: asset.id)
                    if tool == .repair {
                        let mode = developWorkspace.repairMode
                        editor.selectEditingFunction(.repair, assetID: asset.id)
                        developWorkspace.selectRepairMode(mode)
                    } else {
                        editor.selectEditingFunction(EditingFunction(tool), assetID: asset.id)
                        developWorkspace.tool = tool
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tool.symbol).font(.system(size: 16))
                        Text(tool.title).font(.system(size: 13)).lineLimit(2)
                    }.frame(maxWidth: .infinity).frame(height: 58)
                        .foregroundStyle(toolIsActive(tool) ? Color.white.opacity(0.9) : Theme.muted)
                        .background(toolIsActive(tool) ? Color.white.opacity(0.09) : .clear)
                        .overlay(alignment: .topTrailing) {
                            if toolIsActive(tool) {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
                                    .padding(3).accessibilityHidden(true)
                            }
                        }
                }.buttonStyle(.plain).help(tool.title).accessibilityLabel(tool.title)
                    .accessibilityIdentifier("develop.tool.\(tool.rawValue)")
                    .accessibilityValue(toolIsActive(tool) ? "Aktiv" : "Inaktiv")
                    .disabled(!editor.canEdit || !library.canModify || library.comparesOriginal || library.comparesCurrentSourceWithoutSettings
                              || (maskWorkspace.model?.isGenerating ?? false))
            }
        }.padding(3).background(Theme.panel)
            .overlay { Rectangle().stroke(Theme.line) }
    }

    private func toolIsActive(_ tool: DevelopCanvasTool) -> Bool {
        tool == .repair ? developWorkspace.tool.isRepairTool : developWorkspace.tool == tool
    }

    private var adjustmentNavigation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Globale Korrekturen").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Button { showsAdjustmentHelp = true } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.plain).accessibilityLabel("Hilfe zu Korrekturen")
                    .accessibilityIdentifier("develop.adjustments.help")
            }
            Toggle("Einzelgruppenmodus", isOn: Binding(get: { panels.singleGroup }, set: { enabled in
                if let assetID = library.selectedID { finishInput(assetID: assetID) }
                layout.update(developing: library.isDeveloping) { $0.singleGroup = enabled }
            })).toggleStyle(.checkbox).font(.system(size: 13))
                .accessibilityIdentifier("develop.single-group")
        }.padding(.horizontal, 7).padding(.vertical, 8)
    }

    private func hdrSection(assetID: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("HDR · erweiterter Tonwertbereich", isOn: colorBinding(assetID: assetID, keyPath: \.hdrEnabled))
                .toggleStyle(.checkbox).font(.system(size: 13))
                .accessibilityIdentifier("develop.hdr")
                .disabled(!editor.canEdit || !library.canModify || library.comparesOriginal || library.comparesCurrentSourceWithoutSettings)
            if editor.settings(for: assetID).developColor.hdrEnabled {
                Label(developWorkspace.hdrDisplayed ? "HDR-Verarbeitung aktiv" : "HDR-Vorschau wird vorbereitet …", systemImage: "circle.lefthalf.filled")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Button("HDR und Export erklären") { showsAdjustmentHelp = true }.font(.system(size: 13))
            }
        }.padding(.vertical, 8)
    }

    private func automaticToneMenu(assetID: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu("Einzelregler automatisch setzen") {
                ForEach(Array(Adjustment.allCases.prefix(6))) { control in
                    if let toneControl = control.automaticToneControl {
                        Button("\(control.label) automatisch setzen") { applyAutomaticTone(toneControl, assetID: assetID) }
                    }
                }
            }.font(.system(size: 13)).accessibilityIdentifier("develop.automatic-tone")
                .disabled(!editor.canEdit || !library.canModify || library.comparesOriginal || library.comparesCurrentSourceWithoutSettings)
            if developWorkspace.automaticToneTask != nil {
                ProgressView("Einzelregler wird berechnet …").font(.system(size: 13))
            }
            if let error = developWorkspace.errorMessage {
                Text(error).font(.system(size: 13)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func applyAutomaticTone(_ toneControl: AutomaticToneControl, assetID: String) {
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

    private func colorBasics(assetID: String) -> some View {
        let settings = editor.settings(for: assetID)
        return VStack(alignment: .leading, spacing: 4) {
            Toggle("Schwarzweiß", isOn: colorBinding(assetID: assetID, keyPath: \.isMonochrome))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 13))
                .accessibilityIdentifier("develop.monochrome")
            Picker("Profil", selection: Binding(get: { editor.settings(for: assetID).developColor.profile }, set: { profile in
                finishInput(assetID: assetID)
                var value = editor.settings(for: assetID); value.developColor.profile = profile
                setAdjustmentSettings(value, for: assetID)
            })) {
                ForEach(DevelopColorProfile.allCases, id: \.self) { Text($0.title).tag($0) }
            }.font(.system(size: 13))
            Divider()
            HStack {
                Button { developWorkspace.picksWhiteBalance.toggle() } label: {
                    Label(developWorkspace.picksWhiteBalance ? "Neutralgrau wählen · aktiv" : "Neutralgrau wählen",
                        systemImage: developWorkspace.picksWhiteBalance ? "checkmark.circle.fill" : "eyedropper").font(.system(size: 13))
                }.buttonStyle(.plain).foregroundStyle(developWorkspace.picksWhiteBalance ? Theme.accent : Theme.muted)
                    .help("Neutralgrau im Foto wählen")
                    .accessibilityIdentifier("develop.white-balance-picker")
                    .disabled(developWorkspace.sourceAnalysis == nil)
                Spacer(minLength: 0)
            }
            HStack {
                Text("Weißabgleich").font(.system(size: 13))
                Spacer(minLength: 0)
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
                }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            colorSlider("Temperatur", assetID: assetID, keyPath: \.temperature,
                        range: DevelopColorSettings.temperatureRange, neutral: 6_500, step: 50)
                .help("Relative Farbtemperatur")
            colorSlider("Tönung", assetID: assetID, keyPath: \.tint,
                        range: DevelopColorSettings.tintRange, neutral: 0, step: 1)
            if let error = developWorkspace.errorMessage {
                Text(error).font(.system(size: 13)).foregroundStyle(.orange)
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
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.muted).frame(width: 90, alignment: .leading)
            ResettableSlider(value: Binding(get: { editor.settings(for: assetID).developColor[keyPath: keyPath] }, set: { amount in
                var value = editor.settings(for: assetID); value.developColor[keyPath: keyPath] = amount
                setAdjustmentSettings(value, for: assetID)
            }), in: range, step: step, neutralValue: neutral, onEditingChanged: { editing in
                if editing { beginAdjustment(assetID: assetID) } else { editor.endEditing(assetID: assetID) }
            }).controlSize(.mini).accessibilityLabel(title)
            Text("\(Int(editor.settings(for: assetID).developColor[keyPath: keyPath]))")
                .monospacedDigit().font(.system(size: 13)).frame(width: 43, alignment: .trailing)
        }.frame(minHeight: 28)
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
            Text(groupTitle(tool)).font(.system(size: 13, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 3)
            if let status {
                Label(status.text, systemImage: status.symbol)
                    .font(.system(size: 13)).foregroundStyle(status.isError ? Color.orange : Theme.muted)
                    .help(status.text)
            }
            Image(systemName: expanded ? "chevron.down" : "chevron.left")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
        }.padding(.horizontal, 7).frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
            .background(Theme.panel).contentShape(Rectangle())
    }

    @ViewBuilder private func toolContent(_ tool: WorkspaceTool, asset: PhotoAsset) -> some View {
        switch tool {
        case .edit:
            VStack(alignment: .leading, spacing: 5) {
                naturalBalanceSection(assetID: asset.id)
                automaticToneMenu(assetID: asset.id)
                adjustmentSection("Lichtregler", key: "tone", controls: Array(Adjustment.allCases.prefix(6)), assetID: asset.id)
                hdrSection(assetID: asset.id)
                LevelsInspector(assetID: asset.id, library: library, workspace: developWorkspace,
                    initialExpanded: false, isExpanded: Binding(
                        get: { panels.openAdjustmentGroups.contains("levels") },
                        set: { expanded in
                            finishInput(assetID: asset.id)
                            layout.update(developing: library.isDeveloping) {
                                if expanded { $0.openAdjustmentGroups.insert("levels") }
                                else { $0.openAdjustmentGroups.remove("levels") }
                            }
                        }))
                    .id("levels-\(asset.id)")
                let curvesSource = editor.snapshot(for: asset.id).source
                DisclosureGroup("Kurven", isExpanded: Binding(
                    get: { panels.openAdjustmentGroups.contains("curves") },
                    set: { expanded in
                        finishInput(assetID: asset.id)
                        layout.update(developing: library.isDeveloping) {
                            if expanded { $0.openAdjustmentGroups.insert("curves") }
                            else { $0.openAdjustmentGroups.remove("curves") }
                        }
                    })) {
                    ToneCurveEditor(settings: Binding(
                        get: { editor.settings(for: asset.id).toneCurves },
                        set: { curves in
                            guard editor.canEdit, library.canModify, library.selectedID == asset.id,
                                  editor.snapshot(for: asset.id).source == curvesSource,
                                  !library.comparesOriginal, !library.comparesCurrentSourceWithoutSettings,
                                  (try? curves.validate()) != nil else { return }
                            developWorkspace.endLevelsPicker()
                            editor.selectEditingFunction(.adjustments, assetID: asset.id, cancelsActiveInput: false)
                            var next = editor.settings(for: asset.id); next.toneCurves = curves
                            editor.setSettings(next, for: asset.id)
                        }), onEditingChanged: { editing in
                            if editing { beginAdjustment(assetID: asset.id) }
                            else { editor.endEditing(assetID: asset.id) }
                        })
                    .disabled(!editor.canEdit || !library.canModify || library.comparesOriginal || library.comparesCurrentSourceWithoutSettings)
                    .id("curves-\(asset.id)")
                    .id(curvesSource)
                }
                .font(.system(size: 13)).padding(.vertical, 6)
                .accessibilityIdentifier("develop.curves")
            }
        case .color:
            VStack(alignment: .leading, spacing: 5) {
                colorBasics(assetID: asset.id)
                adjustmentSection("Farbintensität", key: "color", controls: [.vibrance, .saturation], assetID: asset.id, collapsible: false)
            }
        case .details:
            VStack(alignment: .leading, spacing: 8) {
                adjustmentSection("Präsenz", key: "presence", controls: [.texture, .clarity, .dehaze], assetID: asset.id)
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
            AICorrectionInspector(library: library)
        case .metadata:
            VStack(alignment: .leading, spacing: 20) {
                PhotoMetadataSection(model: photoMetadata)
                photoDetails(asset)
            }
        case .versions:
            VStack(alignment: .leading, spacing: 13) {
                Text("Aktive Quelle: \(editor.snapshot(for: asset.id).source == .original ? "Importiertes Original" : "Generierter Bildstand")")
                    .font(.system(size: 13, weight: .medium))
                Button("Zum importierten Original zurückkehren") {
                    finishInput(assetID: asset.id)
                    editor.returnToOriginal(assetID: asset.id)
                    library.comparesOriginal = false
                    library.comparesCurrentSourceWithoutSettings = false
                }.disabled(!editor.canEdit || editor.snapshot(for: asset.id).source == .original)
                if let error = editor.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13)).foregroundStyle(.orange)
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
                DisclosureGroup(isExpanded: $showsAdvancedVersions) {
                    toneProcessingSection(assetID: asset.id).padding(.top, 8)
                } label: {
                    // A container ID would override the migration button's AX ID.
                    Text("Erweitert").accessibilityIdentifier("develop.versions.advanced")
                }
                .font(.system(size: 13))
            }
        }
    }

    private func editingHistory(assetID: String) -> some View {
        let allowed = editor.developCommands.availability(in: library, permitsActiveInput: true,
            permitsToolHistory: true).isAvailable
        return HStack(spacing: 8) {
            if column == .navigation {
                Button {
                    finishInput(assetID: assetID)
                    ResettableNativeSlider.cancelInputs(in: NSApp.keyWindow?.contentView)
                    if maskWorkspace.isPresented { maskWorkspace.undo() }
                    else {
                        developWorkspace.cancelRepairWork()
                        if developWorkspace.tool == .basic { editor.developCommands.performHistory(.undo, in: library) }
                        else { editor.undo(assetID: assetID) }
                    }
                } label: { Label("Rückgängig", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity) }
                    .disabled(!allowed || (maskWorkspace.isPresented ? maskWorkspace.model?.canUndo != true : !editor.canUndo(assetID: assetID)))
                    .accessibilityIdentifier("workspace.undo")
                Button {
                    finishInput(assetID: assetID)
                    ResettableNativeSlider.cancelInputs(in: NSApp.keyWindow?.contentView)
                    if maskWorkspace.isPresented { maskWorkspace.redo() }
                    else {
                        developWorkspace.cancelRepairWork()
                        if developWorkspace.tool == .basic { editor.developCommands.performHistory(.redo, in: library) }
                        else { editor.redo(assetID: assetID) }
                    }
                } label: { Label("Wiederholen", systemImage: "arrow.uturn.forward").frame(maxWidth: .infinity) }
                    .disabled(!allowed || (maskWorkspace.isPresented ? maskWorkspace.model?.canRedo != true : !editor.canRedo(assetID: assetID)))
                    .accessibilityIdentifier("workspace.redo")
            } else {
                Button("Alle Bildkorrekturen zurücksetzen") {
                    finishInput(assetID: assetID)
                    if developWorkspace.tool == .basic { editor.developCommands.performHistory(.reset, in: library) }
                    else { editor.reset(assetID: assetID) }
                }.frame(maxWidth: .infinity)
                    .disabled(maskWorkspace.isPresented || !allowed || editor.settings(for: assetID).isNeutral)
                    .accessibilityIdentifier("workspace.reset")
            }
        }.buttonStyle(.bordered).controlSize(.small).font(.system(size: 13))
            .padding(.horizontal, 8).frame(height: 38)
    }

    private func groupTitle(_ tool: WorkspaceTool) -> String {
        switch tool {
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
        editor.developCommands.applyNumericSettings(settings, assetID: assetID, in: library)
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
        case .edit, .color, .details:
            if editor.isReadOnly { return ("Fehler", "exclamationmark.triangle", true) }
            if editor.isSaving || editor.isLoading || editor.hasPendingChanges { return ("Läuft", "arrow.triangle.2.circlepath", false) }
            let settings = editor.settings(for: assetID)
            let changed: Bool
            switch tool {
            case .edit:
                changed = settings.exposure != 0 || settings.contrast != 0
                    || settings.highlights != 0 || settings.shadows != 0
                    || settings.whites != 0 || settings.blacks != 0
                    || settings.autoToneAmount != 0 || settings.naturalBalanceAmount != 0
                    || !settings.levels.isNeutral || !settings.toneCurves.isNeutral || settings.developColor.hdrEnabled
            case .color:
                var color = settings.developColor
                color.hdrEnabled = false
                changed = !color.isNeutral || settings.vibrance != 0 || settings.saturation != 0
            case .details:
                changed = settings.texture != 0 || settings.clarity != 0 || settings.dehaze != 0
                    || settings.sharpeningAmount != 0 || settings.luminanceNoiseReduction != 0
                    || settings.colorNoiseReduction != 0
            default:
                changed = false
            }
            if changed { return ("Geändert", "slider.horizontal.3", false) }
        case .aiDevelopment:
            return nil
        case .metadata:
            if photoMetadata.errorMessage != nil || photoMetadata.hasPendingRetry || photoMetadata.recovery != nil {
                return ("Fehler", "exclamationmark.triangle", true)
            }
            if photoMetadata.isSaving || photoMetadata.isLoading || photoMetadata.isAnalyzing { return ("Läuft", "arrow.triangle.2.circlepath", false) }
            if photoMetadata.hasManualDraft || photoMetadata.record?.draft != nil {
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
                .font(.system(size: 13)).foregroundStyle(Theme.muted).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button { library.reveal() } label: { Label("Im Finder anzeigen", systemImage: "arrow.up.right.square") }
                .font(.system(size: 13)).buttonStyle(.plain).foregroundStyle(Theme.accent)
        }
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
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
                    .font(.system(size: 13, weight: .medium))
            }.toggleStyle(.switch).controlSize(.small)
                .accessibilityIdentifier("develop.naturalBalance")
                .help("Natürlichen Bildausgleich einschalten")

            if settings.naturalBalanceAmount > 0 {
                naturalBalanceSlider("Stärke", keyPath: \.naturalBalanceAmount, range: 0...100, assetID: assetID)
                naturalBalanceSlider("Farbe", keyPath: \.naturalBalanceColorAmount, range: 0...100, assetID: assetID)
            } else if settings.autoToneAmount > 0 {
                Text("Bisherige Tonwert-Automatik: \(Int(settings.autoToneAmount)) %")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Button("Bisherige Automatik ausschalten") {
                    finishInput(assetID: assetID)
                    var settings = editor.settings(for: assetID)
                    settings.autoToneAmount = 0
                    setAdjustmentSettings(settings, for: assetID)
                }.font(.system(size: 13))
            }
        }.disabled(!editor.canEdit || !library.canModify || library.comparesOriginal || library.comparesCurrentSourceWithoutSettings)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func canMigrate(_ target: ToneMigrationTarget) -> Bool {
        editor.canEdit && library.canModify && library.selectedID == target.assetID
            && !library.comparesOriginal && !library.comparesCurrentSourceWithoutSettings
            && editor.localRevision(for: target.assetID) == target.revision
            && editor.snapshot(for: target.assetID) == target.snapshot
            && target.snapshot.settings.toneProcessingVersion == .legacyV1
    }

    private func toneProcessingSection(assetID: String) -> some View {
        let version = editor.settings(for: assetID).toneProcessingVersion
        return VStack(alignment: .leading, spacing: 5) {
            if version == .legacyV1 {
                Text("Bisherige Tonwertverarbeitung").font(.system(size: 13)).foregroundStyle(Theme.muted)
                Button("Tonwertverarbeitung umstellen …") {
                    finishInput(assetID: assetID)
                    toneMigrationTarget = ToneMigrationTarget(assetID: assetID,
                        revision: editor.localRevision(for: assetID), snapshot: editor.snapshot(for: assetID))
                }
                .font(.system(size: 13))
                .help("Umstellung auf sRGB Float (V2) prüfen")
                .accessibilityIdentifier("develop.tone-processing.upgrade")
            } else {
                Label("Tonwertverarbeitung: sRGB Float (V2)", systemImage: "checkmark.circle")
                    .font(.system(size: 13))
            }
        }.disabled(!editor.canEdit || !library.canModify || library.comparesOriginal || library.comparesCurrentSourceWithoutSettings)
    }

    private func naturalBalanceSlider(_ title: String, keyPath: WritableKeyPath<EditSettings, Double>,
                                      range: ClosedRange<Double>, assetID: String) -> some View {
        HStack(spacing: 7) {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.muted)
                .frame(width: 90, alignment: .leading)
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
                .monospacedDigit().font(.system(size: 13)).foregroundStyle(Theme.accent)
                .frame(width: 43, alignment: .trailing)
        }.frame(minHeight: 28)
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
                            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                            Spacer(minLength: 0)
                            Image(systemName: expanded ? "chevron.down" : "chevron.left")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                        }.frame(minHeight: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .workspaceFocusTarget(focusedControl, equals: .adjustmentGroup(key)) {
                            toggleAdjustmentGroup(key, assetID: assetID)
                        }
                        .accessibilityLabel(title).accessibilityValue(expanded ? "Geöffnet" : "Geschlossen")
                        .accessibilityHint(expanded ? "Reglergruppe zuklappen" : "Reglergruppe aufklappen")
                } else {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("develop.adjustment-group.\(key)")
                }
                Button {
                    finishInput(assetID: assetID)
                    var settings = editor.settings(for: assetID)
                    for item in controls { settings[keyPath: item.keyPath] = item.neutralValue }
                    setAdjustmentSettings(settings, for: assetID)
                } label: { Text("Zurücksetzen").font(.system(size: 13)) }
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
                                applyAutomaticTone(toneControl, assetID: assetID)
                            }
                        }, onEditingChanged: { editing in
                            if editing { beginAdjustment(assetID: assetID) }
                            else { editor.endEditing(assetID: assetID) }
                        })
                        .disabled(control.isSharpeningPreference && editor.settings(for: assetID).sharpeningAmount == 0)
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
            Text(control.label).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                .frame(width: 98, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .onTapGesture(count: 2, perform: resetValue)
                .highPriorityGesture(TapGesture(count: 2).modifiers(.shift).onEnded { _ in
                    guard isEnabled else { return }
                    if let onAutomaticValue { onEditingChanged(false); onAutomaticValue() }
                    else { resetValue() }
                }).help("\(control.label) zurücksetzen")
            ResettableSlider(value: $value, in: control.range, step: control.step, neutralValue: control.neutralValue,
                             onAutomaticValue: onAutomaticValue,
                             onEditingChanged: onEditingChanged)
                .controlSize(.mini).accessibilityLabel(control.label).help("\(control.label) zurücksetzen")
                .accessibilityHint(onAutomaticValue == nil ? "Doppelklick setzt zurück" : "Umschalt-Doppelklick setzt automatisch")
            TextField(control.label, value: numericValue,
                      format: .number.precision(.fractionLength(control.fractionDigits)))
                .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(value == control.neutralValue ? Theme.muted : Theme.accent)
                .frame(width: 44).accessibilityLabel("\(control.label) Wert")
                .focused($valueFocused)
                .onSubmit { onEditingChanged(false) }
                .onChange(of: valueFocused) { _, focused in if !focused { onEditingChanged(false) } }
                .onDisappear { onEditingChanged(false) }
        }.frame(minHeight: 28)
            .accessibilityIdentifier("develop.adjustment.\(control.rawValue)")
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
