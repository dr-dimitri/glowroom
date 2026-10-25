import SwiftUI
import GlowroomCore

struct PhotoGridView: View {
    @ObservedObject var model: LibraryModel
    @EnvironmentObject private var editor: EditingModel
    var body: some View {
        GeometryReader { geometry in
        ScrollViewReader { reader in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: model.gridSize), spacing: 15)], spacing: 17) {
                    ForEach(model.visibleAssets) { asset in
                        PhotoCard(asset: asset, selected: model.selectedIDs.contains(asset.id), model: model)
                            .id(asset.id)
                    }
                }.padding(23)
            }
            .onAppear { if let id = model.selectedID { reader.scrollTo(id) } }
            .onChange(of: model.selectedID) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(id) } }
            }
        }
        .onAppear { updateColumns(width: geometry.size.width) }
        .onChange(of: geometry.size.width) { _, width in updateColumns(width: width) }
        .onChange(of: model.gridSize) { _, _ in updateColumns(width: geometry.size.width) }
        }
    }
    private func updateColumns(width: CGFloat) {
        model.gridColumnCount = max(1, Int((max(0, width - 46) + 15) / (model.gridSize + 15)))
    }
}

private struct PhotoCard: View {
    let asset: PhotoAsset
    let selected: Bool
    @ObservedObject var model: LibraryModel
    @EnvironmentObject private var editor: EditingModel
    @ViewState<Bool> private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Rectangle().fill(Color.black.opacity(0.2))
                EditingThumbnail(asset: asset, size: model.gridSize)
                    .padding(10)
                if asset.isFavorite || hovered {
                    Button { model.toggleFavorite(asset.id) } label: {
                        Image(systemName: asset.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 11)).foregroundStyle(asset.isFavorite ? Theme.accent : .white)
                            .padding(7).background(.black.opacity(0.55), in: Circle())
                    }.buttonStyle(.plain).help("Favorit umschalten · F").padding(9).disabled(!model.canModify)
                }
            }.aspectRatio(1.24, contentMode: .fit).clipped()
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Text(asset.fileName).font(.system(size: 11, weight: .medium)).foregroundStyle(selected ? Color.white : Color.white.opacity(0.8)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(editor.sourceFormat(for: asset)).font(.system(size: 7, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 4).padding(.vertical, 3).background(Theme.background, in: RoundedRectangle(cornerRadius: 3))
                }
                HStack {
                    RatingStars(rating: asset.rating, onChange: { model.setRating($0, for: asset.id) }).disabled(!model.canModify)
                    Spacer()
                    Text(editor.sourceDimensions(for: asset)).font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.muted)
                }
            }.padding(.horizontal, 11).padding(.vertical, 12)
        }
        .background(selected ? Theme.elevated : Theme.panel, in: RoundedRectangle(cornerRadius: 7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Theme.accent.opacity(0.8) : hovered ? Color.white.opacity(0.16) : Theme.line, lineWidth: selected ? 1.5 : 1) }
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { model.select(asset); model.showsDetail = true }
            .exclusively(before: photoSelectionGesture(asset: asset, model: model)))
        .onHover { hovered = $0 }
        .contextMenu { PhotoContextMenu(asset: asset, model: model) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(asset.fileName), \(asset.rating) Sterne\(selected ? ", ausgewählt" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
private func photoSelectionGesture(asset: PhotoAsset, model: LibraryModel) -> some Gesture {
    // Match the click event's modifiers. Reading NSEvent.modifierFlags in a
    // delayed single-click callback loses keys released during double-click detection.
    TapGesture().modifiers([.command, .shift])
        .onEnded { model.select(asset, extending: true, toggling: true) }
        .exclusively(before: TapGesture().modifiers(.shift)
            .onEnded { model.select(asset, extending: true) })
        .exclusively(before: TapGesture().modifiers(.command)
            .onEnded { model.select(asset, toggling: true) })
        .exclusively(before: TapGesture().onEnded { model.select(asset) })
}

private struct PhotoContextMenu: View {
    let asset: PhotoAsset
    @ObservedObject var model: LibraryModel
    @EnvironmentObject private var editor: EditingModel
    @EnvironmentObject private var exporter: JPEGExportModel

    private var exportCount: Int { model.selectedIDs.contains(asset.id) ? model.selectedIDs.count : 1 }

    var body: some View {
        Button("In Einzelbildansicht öffnen") { model.select(asset); model.showsDetail = true }
        Button("Als Referenz setzen") {
            editor.closeVariantPreview()
            Task { await model.pinPhotoReference(asset, editor: editor) }
        }.disabled(model.isPinningPhotoReference || editor.isLoading || editor.isRestoring)
        Button("Ähnliche Bilder finden") { model.select(asset); model.findSimilarImages() }
            .disabled(!model.hasSemanticService)
        Button(exportCount > 1 ? "\(exportCount) Fotos als JPEG exportieren …" : "Foto als JPEG exportieren …") {
            JPEGExportActions.present(using: exporter, library: model, editor: editor, contextAsset: asset)
        }.disabled(!model.canExportJPEG || model.isProjecting || editor.isLoading || editor.isRestoring || editor.isClosing || exporter.isPresented)
        Button("Im Finder anzeigen") { model.reveal(asset) }
        Divider()
        Button(asset.isFavorite ? "Aus Favoriten entfernen" : "Als Favorit markieren") { model.toggleFavorite(asset.id) }.disabled(!model.canModify)
        Menu("Bewertung") {
            ForEach(0...5, id: \.self) { value in
                Button(value == 0 ? "Keine Bewertung" : "\(value) Sterne") { model.setRating(value, for: asset.id) }
            }
        }.disabled(!model.canModify)
    }
}

struct DetailView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var photoViewport: PhotoViewportState
    @EnvironmentObject private var editor: EditingModel
    @EnvironmentObject private var layout: WorkspaceLayoutModel
    @Environment(\.workspaceCanvasMeasurement) private var measureCanvas
    private var zoomed: Bool { photoViewport.isZoomed }
    @ViewState private var showsCanvasRating = false
    @ViewState private var comparisonZoomAnchor = CGPoint(x: 0.5, y: 0.5)
    @ViewState private var photoHeaderHeight = CGFloat(30)
    @EnvironmentObject private var maskWorkspace: InlineMaskWorkspace
    @EnvironmentObject private var developWorkspace: DevelopWorkspace
    @Environment(\.aiCorrectionDisplay) private var correctionDisplay
    private var comparesBeforeAfter: Bool { model.previewComparisonLayout != .single && !maskWorkspace.isPresented }
    private var usesNativeCropInput: Bool {
        !comparesBeforeAfter && !model.isPhotoComparison && !editor.isViewingVariant && model.isDeveloping && developWorkspace.tool == .crop && model.editingRenderIntent == .currentEditing
            && !maskWorkspace.isPresented && !developWorkspace.picksWhiteBalance
    }
    private var usesPhotoNavigationInput: Bool {
        comparesBeforeAfter || (!maskWorkspace.isPresented && !developWorkspace.picksDetail && developWorkspace.levelsPicker == nil && (!model.isDeveloping || model.editingRenderIntent != .currentEditing
            || (developWorkspace.tool == .basic && !developWorkspace.picksWhiteBalance)))
    }
    private struct NavigationIdentity: Hashable {
        let asset: String
        let source: AISourceIdentity?
        let comparesOriginal: Bool
        let comparesSource: Bool
        let comparisonLayout: PreviewComparisonLayout
    }
    var body: some View {
        GeometryReader { available in
        VStack(spacing: 0) {
            if let asset = model.selectedAsset {
                DevelopPhotoHeader(asset: asset, previewLabel: previewLabel)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { photoHeaderHeight = $0 }
                GeometryReader { geometry in
                    if comparesBeforeAfter || model.isPhotoComparison || editor.isViewingVariant {
                        developCanvas(asset: asset)
                            .padding(18)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        PhotoCanvasViewport(state: photoViewport, imageAspectRatio: imageAspectRatio(for: asset)) {
                            developCanvas(asset: asset)
                        }
                    }
                }
                    // Only this threshold affects the controls. Publishing every
                    // resize pixel would invalidate the entire photo hierarchy.
                    .onGeometryChange(for: Bool.self) { $0.size.width >= 410 } action: { showsCanvasRating = $0 }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { measureCanvas?($0) }
                    .overlay {
                        InlineMaskViewportOverlays(workspace: maskWorkspace,
                            showsMaskList: layout.panels(developing: model.isDeveloping).showsTools
                                && developWorkspace.tool == .masks)
                        if !maskWorkspace.showsCalculationStatus {
                            if developWorkspace.repairBusy {
                                EditingProgressIndicator(cancelLabel: "Reparatur abbrechen") {
                                    developWorkspace.cancelRepairWork(clearCandidates: false)
                                }
                            } else if developWorkspace.isAutoStraightening {
                                EditingProgressIndicator().allowsHitTesting(false)
                            }
                        }
                    }
                    .environment(\.editingProgressIsCovered, maskWorkspace.showsCalculationStatus
                        || developWorkspace.repairBusy || developWorkspace.isAutoStraightening)
                    .contextMenu {
                        if !model.isPhotoComparison { PhotoContextMenu(asset: asset, model: model) }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Bildfläche")
                    .accessibilityIdentifier("workspace.canvas")
                if model.isPhotoComparison { photoComparisonControls(asset) }
                canvasControls(asset)
                if !model.isDeveloping, layout.panels(developing: false).showsFilmstrip {
                    // Include the actual header height when capture data wraps on narrow canvases.
                    let chromeHeight = photoHeaderHeight + 42 + 6
                    let height = layout.boundedFilmstripHeight(availableHeight: max(0, available.size.height - chromeHeight), developing: model.isDeveloping)
                    WorkspaceResizeHandle(horizontal: false, label: "Höhe des Filmstreifens", value: height, step: 1) { height in
                        layout.update(developing: model.isDeveloping) { $0.filmstripHeight = height }
                    }
                    PhotoFilmstrip(model: model, height: height)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(model.isDeveloping ? Theme.canvas : Theme.background)
            .onChange(of: model.selectedID) { _, _ in photoViewport.reset() }
            .onChange(of: navigatorAvailable) { _, value in photoViewport.setNavigationAvailable(value) }
            .onAppear { photoViewport.setNavigationAvailable(navigatorAvailable) }
        }
    }

    private func developCanvas(asset: PhotoAsset) -> some View {
        GeometryReader { viewport in
            let source = developWorkspace.sourceSize ?? CGSize(width: max(1, asset.pixelWidth), height: max(1, asset.pixelHeight))
            let angle = usesNativeCropInput && developWorkspace.isCropCanvasReady(
                for: editor.settings(for: asset.id).developGeometry.optics)
                ? editor.settings(for: asset.id).developGeometry.straightenAngle : 0
            let fit = DevelopCropCanvasPresentation.fittingScale(sourceSize: source, viewport: viewport.size, angle: angle)
            ZStack {
                if let viewing = editor.variantViewingState, viewing.mode == .preview {
                    FrozenVariantPreview(state: viewing)
                        .environment(\.developPreviewSink, nil).environment(\.developPreviewPending, nil)
                        .environment(\.aiCorrectionDisplay, nil)
                } else if model.isPhotoComparison, let reference = model.photoComparisonReference {
                    PhotoComparisonCanvas(referenceIdentity: reference.identity, candidateIdentity: asset.id,
                        referenceRatio: PhotoComparisonAspectRatio.ratio(asset: reference.asset, snapshot: reference.snapshot, source: reference.source),
                        candidateRatio: imageAspectRatio(for: asset), linked: model.photoComparisonZoomLinked) {
                        FrozenPhotoReferencePreview(reference: reference,
                            available: model.assets.contains(where: { $0.id == reference.asset.id && $0.modifiedAt == reference.asset.modifiedAt && $0.fileSize == reference.asset.fileSize }),
                            validationGeneration: model.aiSelectionGeneration)
                    } candidate: {
                        EditingPhotoPreview(asset: asset, intent: .currentEditing,
                            settingsOverride: editor.settings(for: asset.id), developing: true)
                    }
                } else if comparesBeforeAfter {
                    PreviewComparisonView(layout: model.previewComparisonLayout,
                        navigationIdentity: AnyHashable(NavigationIdentity(asset: asset.id,
                            source: developWorkspace.sourceIdentity, comparesOriginal: false,
                            comparesSource: false, comparisonLayout: model.previewComparisonLayout)),
                        zoomed: zoomed, zoomAnchor: comparisonZoomAnchor,
                        imageAspectRatio: imageAspectRatio(for: asset),
                        beforeImageAspectRatio: editor.variantViewingState.map { PhotoComparisonAspectRatio.ratio(asset: asset, snapshot: $0.variant.snapshot, source: $0.source) }
                            ?? CGFloat(max(1, asset.pixelWidth)) / CGFloat(max(1, asset.pixelHeight)),
                        onClick: { toggleZoom(at: $0) }) {
                        if let viewing = editor.variantViewingState, viewing.mode == .before {
                            FrozenVariantPreview(state: viewing).environment(\.aiCorrectionDisplay, nil)
                        } else { EditingPhotoPreview(asset: asset, intent: .importedOriginal, developing: true) }
                    } after: {
                        EditingPhotoPreview(asset: asset, intent: .currentEditing,
                            settingsOverride: editor.settings(for: asset.id), developing: true)
                    }
                } else {
                    EditingPhotoPreview(asset: asset, intent: model.editingRenderIntent,
                        settingsOverride: previewSettings(for: asset.id), developing: model.isDeveloping,
                        imageScale: fit, imageRotation: angle)
                        // Composite the cached source immediately while the crop tool is
                        // open. Only the photo rotates; the shared status stays upright.
                    if maskWorkspace.isPresented {
                        InlineMaskCanvas(workspace: maskWorkspace, isEnabled: developWorkspace.isOriginalCanvasReady)
                            .allowsHitTesting(developWorkspace.isOriginalCanvasReady)
                    } else if model.isDeveloping, model.editingRenderIntent == .currentEditing {
                        if developWorkspace.picksDetail {
                            DevelopDetailCanvas(workspace: developWorkspace,
                                geometry: editor.settings(for: asset.id).developGeometry)
                        } else {
                            let selection = DevelopSelectionIdentity(sessionID: model.aiSelectionSessionID,
                                                                    generation: model.aiSelectionGeneration)
                            DevelopCanvasInteraction(asset: asset, workspace: developWorkspace,
                                levelsSelection: selection,
                                levelsIsCurrent: {
                                    guard model.selectedID == asset.id && model.aiSelectionSessionID == selection.sessionID &&
                                    model.aiSelectionGeneration == selection.generation && model.canModify &&
                                    model.isDeveloping && model.editingRenderIntent == .currentEditing &&
                                    model.previewComparisonLayout == .single && !maskWorkspace.isPresented,
                                    let current = model.selectedAsset,
                                    let source = try? editor.resolvedSource(for: current, intent: .currentEditing) else { return false }
                                    return source.identity == developWorkspace.sourceIdentity
                                })
                        }
                    }
                    if developWorkspace.tool == .basic, !developWorkspace.picksWhiteBalance, developWorkspace.levelsPicker == nil,
                       correctionDisplay?.showsProposal != true,
                       let analysis = developWorkspace.analysis,
                       let overlay = analysis.clippingImage(shadows: developWorkspace.showsShadows, highlights: developWorkspace.showsHighlights),
                       developWorkspace.showsShadows || developWorkspace.showsHighlights {
                        Image(decorative: overlay, scale: 1).resizable().interpolation(.none)
                            .aspectRatio(contentMode: .fit).allowsHitTesting(false)
                    }
                }
                if usesPhotoNavigationInput && !comparesBeforeAfter && !model.isPhotoComparison && !editor.isViewingVariant {
                    DevelopCropInputSurface(onInput: { _ in }, onHover: { _ in }, isEnabled: true,
                        inputIdentity: AnyHashable(NavigationIdentity(asset: asset.id,
                            source: developWorkspace.sourceIdentity, comparesOriginal: model.comparesOriginal,
                            comparesSource: model.comparesCurrentSourceWithoutSettings,
                            comparisonLayout: model.previewComparisonLayout)),
                        cursor: { point in
                            let rect = displayedImageRect(for: asset, in: viewport.size)
                            return rect.contains(point) ? (zoomed ? .openHand : PhotoCanvasCursors.zoomIn) : .arrow
                        },
                        onClick: { point in
                            let rect = displayedImageRect(for: asset, in: viewport.size)
                            guard rect.contains(point), rect.width > 0, rect.height > 0 else { return }
                            toggleZoom(at: CGPoint(x: (point.x - rect.minX) / rect.width,
                                                   y: (point.y - rect.minY) / rect.height))
                        },
                        canvasLabel: zoomed ? "Vergrößertes Bild verschieben · Klick zum Einpassen" : "Bild · Klick zum Vergrößern",
                        pansWithPointer: true, canvasIdentifier: "workspace.photo-navigation",
                        allowsViewportHitFallback: true)
                }
            }
        }
    }

    private func toggleZoom(at point: CGPoint? = nil) {
        if !zoomed { comparisonZoomAnchor = point ?? CGPoint(x: 0.5, y: 0.5) }
        photoViewport.toggleZoom(at: point)
    }

    private var navigatorAvailable: Bool {
        !comparesBeforeAfter && !model.isPhotoComparison && !editor.isViewingVariant && !maskWorkspace.isPresented && !developWorkspace.tool.usesOriginalCanvas
            && !developWorkspace.picksWhiteBalance && model.editingRenderIntent == .currentEditing
    }

    private func imageAspectRatio(for asset: PhotoAsset) -> CGFloat {
        if let image = developWorkspace.navigatorImage,
           comparesBeforeAfter || (!developWorkspace.tool.usesOriginalCanvas && !developWorkspace.picksWhiteBalance
               && model.editingRenderIntent == .currentEditing) {
            return CGFloat(image.width) / CGFloat(max(1, image.height))
        }
        let size = developWorkspace.sourceSize ?? CGSize(width: max(1, asset.pixelWidth), height: max(1, asset.pixelHeight))
        return size.width / max(1, size.height)
    }

    private func displayedImageRect(for asset: PhotoAsset, in size: CGSize) -> CGRect {
        let ratio = imageAspectRatio(for: asset)
        let width = min(size.width, size.height * ratio)
        let height = width / ratio
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private var previewLabel: String {
        if let viewing = editor.variantViewingState { return " · " + (viewing.mode == .preview ? "Vorschau: " : "Vergleich: ") + viewing.variant.displayName }
        if model.isPhotoComparison { return " · Fotovergleich · rechts aktiv" }
        if let correctionDisplay { return " · " + correctionDisplay.title }
        if comparesBeforeAfter { return " · " + model.previewComparisonLayout.title }
        if model.comparesOriginal { return " · Importiertes Original" }
        if model.comparesCurrentSourceWithoutSettings { return " · Aktuelle Quelle ohne Regler" }
        return ""
    }

    private func previewSettings(for assetID: String) -> EditSettings {
        var settings = maskWorkspace.previewSettings ?? editor.settings(for: assetID)
        if developWorkspace.tool.usesOriginalCanvas || developWorkspace.picksWhiteBalance {
            settings.developGeometry.crop = nil
            settings.developGeometry.quarterTurns = 0
            settings.developGeometry.straightenAngle = 0
            settings.developGeometry.constrainToImage = true
            settings.developGeometry.flipHorizontal = false
            settings.developGeometry.flipVertical = false
            // Spatial tools retain their established complete source canvas.
            // Crop previews the optical canvas itself, before its final crop;
            // source painting/picking deliberately uses the identity mapping.
            if developWorkspace.tool == .crop && !developWorkspace.picksWhiteBalance {
                if !settings.developGeometry.optics.isNeutral { settings.developGeometry.constrainToImage = false }
            } else { settings.developGeometry.optics = .neutral }
        }
        return settings
    }

    private static let finderIcon: NSImage? = {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }()

    private func canvasControls(_ asset: PhotoAsset) -> some View {
        // Leave room for the native menu indicator at the minimum canvas width.
        HStack(spacing: 4) {
            Button { model.reveal(asset) } label: {
                Group {
                    if let icon = Self.finderIcon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                            .aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "folder")
                    }
                }.frame(width: 28, height: 30)
            }.buttonStyle(.plain).help("Originalbild im Finder anzeigen")
                .accessibilityLabel("Im Finder anzeigen")
                .accessibilityIdentifier("workspace.reveal-in-finder")
            Button { toggleZoom() } label: {
                Image(systemName: zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass")
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 28, height: 30)
            }.buttonStyle(.plain).help(zoomed ? "Einpassen · Klick auf das Bild · Drei-Finger-Ziehen zum Verschieben" : "Vergrößern · Klick auf das Bild")
                .accessibilityLabel(zoomed ? "Einpassen" : "Vergrößern")
                .accessibilityIdentifier("workspace.zoom")
                .disabled(model.isPhotoComparison || editor.isViewingVariant)
            Button { editor.closeVariantPreview(); model.showPreviewComparison(.single) } label: {
                Image(systemName: "rectangle").frame(width: 24, height: 30)
                    .foregroundStyle(!comparesBeforeAfter && model.editingRenderIntent == .currentEditing ? Theme.accent : Theme.text)
            }.buttonStyle(.plain).disabled(maskWorkspace.isPresented)
                .accessibilityLabel("Einzelbild · Aktuelle Bearbeitung").accessibilityIdentifier("workspace.single-preview")
                .help("Einzelbild · Aktuelle Bearbeitung")
            Button {
                editor.closeVariantPreview()
                model.showPreviewComparison(comparesBeforeAfter ? .single : model.lastPreviewComparisonLayout)
            } label: {
                Image(systemName: comparesBeforeAfter ? model.previewComparisonLayout.symbol : model.lastPreviewComparisonLayout.symbol)
                    .frame(width: 24, height: 30).foregroundStyle(comparesBeforeAfter ? Theme.accent : Theme.text)
            }.buttonStyle(.plain).disabled(maskWorkspace.isPresented)
                .accessibilityLabel("Vorher/Nachher").accessibilityValue(comparesBeforeAfter ? "Aktiv" : "Inaktiv")
                .accessibilityIdentifier("workspace.compare-toggle").help("Vorher/Nachher ein-/ausschalten")
            Menu {
                Button("Als Referenz setzen") {
                    editor.closeVariantPreview()
                    Task { await model.pinPhotoReference(asset, editor: editor) }
                }.disabled(model.isPinningPhotoReference)
                if let reference = model.photoComparisonReference {
                    Button("Fotovergleich öffnen") { editor.closeVariantPreview(); model.openPhotoComparison() }
                        .disabled(!model.canStartPhotoComparison)
                    Button("Referenz aktualisieren") {
                        Task {
                            guard let current = model.assets.first(where: { $0.id == reference.asset.id }) else {
                                model.notice = "Referenz nicht mehr in der Bibliothek"; return
                            }
                            await model.pinPhotoReference(current, editor: editor)
                        }
                    }.disabled(model.isPinningPhotoReference)
                    Button("Referenz austauschen") {
                        editor.closeVariantPreview()
                        Task { await model.pinPhotoReference(asset, editor: editor, startComparison: true) }
                    }.disabled(model.isPinningPhotoReference)
                    Button("Referenz entfernen") { model.closePhotoComparison(clearReference: true) }
                } else {
                    Text("Zuerst eine Referenz setzen und ein anderes Foto wählen")
                }
                if model.isPhotoComparison {
                    Button("Fotovergleich schließen") { model.closePhotoComparison() }.accessibilityIdentifier("workspace.photo-comparison.close")
                }
                Divider()
                ForEach(PreviewComparisonLayout.allCases.filter { $0 != .single }) { comparison in
                    Button { editor.closeVariantPreview(); model.showPreviewComparison(comparison) } label: {
                        Label(comparison.title, systemImage: model.previewComparisonLayout == comparison ? "checkmark" : comparison.symbol)
                    }
                }
                Divider()
                Button("Einzelbild · Aktuelle Bearbeitung") { editor.closeVariantPreview(); model.showPreviewComparison(.single) }
                Button { editor.closeVariantPreview(); model.comparesOriginal = true; model.comparesCurrentSourceWithoutSettings = false } label: {
                    Label("Importiertes Original", systemImage: model.comparesOriginal ? "checkmark" : "circle")
                }
                Button { editor.closeVariantPreview(); model.comparesOriginal = false; model.comparesCurrentSourceWithoutSettings = true } label: {
                    Label("Aktuelle Quelle ohne Regler", systemImage: model.comparesCurrentSourceWithoutSettings ? "checkmark" : "circle")
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9)).frame(width: 10, height: 30)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(maskWorkspace.isPresented)
                .accessibilityLabel("Vergleich").accessibilityValue(comparisonTitle)
                .accessibilityIdentifier("workspace.compare").help("Vergleich: " + comparisonTitle)
            Spacer(minLength: 0)
            if showsCanvasRating {
                RatingStars(rating: asset.rating, size: 11, onChange: { model.setRating($0) }).disabled(!model.canModify)
                IconButton(symbol: asset.isFavorite ? "heart.fill" : "heart", help: "Favorit · F", active: asset.isFavorite) { model.toggleFavorite() }.disabled(!model.canModify)
            }
            Spacer(minLength: 0)
            IconButton(symbol: "chevron.left", help: "Vorheriges Foto · ←") { model.navigate(-1) }
            IconButton(symbol: "chevron.right", help: "Nächstes Foto · →") { model.navigate(1) }
        }.padding(.horizontal, 10).frame(height: 42).background(Theme.panel)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func photoComparisonControls(_ asset: PhotoAsset) -> some View {
        // Two short rows keep every primary action visible in a narrow canvas;
        // no fit-dependent menu hides the zoom or review-advance controls.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { model.photoComparisonZoomLinked.toggle() } label: {
                    Label("Zoom koppeln", systemImage: model.photoComparisonZoomLinked ? "checkmark.circle.fill" : "circle")
                }.accessibilityIdentifier("workspace.photo-comparison.link-zoom")
                    .accessibilityValue(model.photoComparisonZoomLinked ? "Aktiv" : "Inaktiv")
                Button { model.advancesAfterPhotoRating.toggle() } label: {
                    Label("Nach Bewertung weiter", systemImage: model.advancesAfterPhotoRating ? "checkmark.circle.fill" : "circle")
                }.accessibilityIdentifier("workspace.photo-comparison.advance")
                    .accessibilityValue(model.advancesAfterPhotoRating ? "Aktiv" : "Inaktiv")
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Menu("Referenz") {
                    Button("Referenz austauschen") { Task { await model.pinPhotoReference(asset, editor: editor, startComparison: true) } }
                    Button("Referenz aktualisieren") {
                        guard let id = model.photoComparisonReference?.asset.id,
                              let reference = model.assets.first(where: { $0.id == id }) else {
                            model.notice = "Referenz nicht mehr in der Bibliothek"; return
                        }
                        Task { await model.pinPhotoReference(reference, editor: editor) }
                    }
                }.accessibilityIdentifier("workspace.photo-comparison.reference-actions")
                    .disabled(model.isPinningPhotoReference)
                Spacer(minLength: 0)
                Button("Fotovergleich schließen") { model.closePhotoComparison() }
                    .accessibilityIdentifier("workspace.photo-comparison.close")
            }
        }.font(.system(size: 13)).controlSize(.small).buttonStyle(.borderless)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.panel).accessibilityElement(children: .contain)
            .accessibilityIdentifier("workspace.photo-comparison-controls")
    }

    private var comparisonTitle: String {
        if model.isPhotoComparison { return "Fotovergleich" }
        if comparesBeforeAfter { return model.previewComparisonLayout.title }
        if model.comparesOriginal { return "Importiertes Original" }
        if model.comparesCurrentSourceWithoutSettings { return "Aktuelle Quelle ohne Regler" }
        return "Aktuelle Bearbeitung"
    }
}

/// Shared lazy strip spans the full developing workspace and reuses thumbnail caches.
struct PhotoFilmstrip: View {
    @ObservedObject var model: LibraryModel
    let height: Double

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(model.title).fontWeight(.medium).lineLimit(1)
                Text("\(model.visibleAssets.count) \(model.visibleAssets.count == 1 ? "Foto" : "Fotos")").foregroundStyle(Theme.muted).fixedSize()
                Spacer(minLength: 0)
                if model.isDeveloping {
                    Menu {
                        Picker("Bewertung", selection: $model.minimumRating) {
                            Text("Alle Bewertungen").tag(0)
                            ForEach(1...5, id: \.self) { Text("Mindestens \($0) Sterne").tag($0) }
                        }
                        Picker("Sortieren", selection: $model.sort) {
                            ForEach(PhotoSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: { Label("Filter & Sortierung", systemImage: "line.3.horizontal.decrease") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityIdentifier("filmstrip.filters")
                }
            }.font(.system(size: 13)).padding(.horizontal, 14).frame(height: 26).background(Theme.chrome)
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 2) {
                        ForEach(model.visibleAssets) { asset in
                            Button { model.select(asset) } label: {
                                EditingThumbnail(asset: asset, size: max(110, height * 1.4))
                                    .padding(6).frame(width: max(32, (height - 38) * 1.3), height: max(16, height - 38))
                                    .background(model.selectedIDs.contains(asset.id) ? Theme.elevated : Theme.panel)
                                    .overlay { Rectangle().strokeBorder(model.selectedIDs.contains(asset.id) ? Theme.accent : Theme.line, lineWidth: 1) }
                            }.buttonStyle(.plain).id(asset.id).help(asset.fileName)
                                .accessibilityLabel(asset.fileName)
                                .accessibilityAddTraits(model.selectedIDs.contains(asset.id) ? .isSelected : [])
                                .highPriorityGesture(photoSelectionGesture(asset: asset, model: model))
                                .contextMenu { PhotoContextMenu(asset: asset, model: model) }
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 6)
                }.clipped()
                    .onAppear { if let id = model.selectedID { reader.scrollTo(id, anchor: .center) } }
                    .onChange(of: model.selectedID) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(id, anchor: .center) } } }
            }
        }.frame(height: height).background(Theme.sidebar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workspace.filmstrip")
    }
}
