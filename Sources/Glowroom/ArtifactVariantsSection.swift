import SwiftUI
import GlowroomCore

struct ArtifactVariantsSection: View {
    let assetID: String
    @EnvironmentObject private var editor: EditingModel
    var body: some View {
        if let library = editor.library { ArtifactVariantsContent(assetID: assetID, editor: editor, library: library) }
    }
}

private struct ArtifactVariantsContent: View {
    let assetID: String
    @ObservedObject var editor: EditingModel
    @ObservedObject var library: LibraryModel
    @ViewState private var offset = 0
    @ViewState private var showsName = false
    @ViewState private var name = ""
    @ViewState private var renaming: EditingVariant?
    private var currentVariants: [EditingVariant] { editor.variants.filter { $0.assetID == assetID } }
    private var page: [EditingVariant] { Array(currentVariants.reversed().dropFirst(offset).prefix(100)) }
    private var loadIdentity: ArtifactVariantsLoadIdentity { editor.variantsLoadIdentity(assetID: assetID, expanded: true) }
    private var validName: Bool { (try? EditingVariantName.validated(name)) != nil }
    var body: some View {
        // The containing Bildstände workspace group owns disclosure and focus.
        // A second nested disclosure would hide the primary save action.
        VStack(alignment: .leading, spacing: 10) {
            Button("Bildstand sichern …", systemImage: "plus") {
                renaming = nil; name = ""; showsName = true
            }.disabled(!editor.canEdit || editor.isManagingVariants)
                .accessibilityIdentifier("variants.save")
            if let viewing = editor.variantViewingState, viewing.variant.assetID == assetID {
                Text(viewing.mode == .preview ? "Vorschau: \(viewing.variant.displayName)" : "Vorher: \(viewing.variant.displayName)")
                    .font(.system(size: 13, weight: .medium))
                Button("Vorschau schließen") { editor.closeVariantPreview() }
                    .accessibilityIdentifier("variants.close-preview")
            }
            if !loadIdentity.isReady || editor.isLoadingVariants { ProgressView("Bildstände werden geladen …") }
            else if currentVariants.isEmpty { Text("Keine Bildstände gespeichert.") }
            else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(page, id: \.id) { variant in row(variant) }
                }
                HStack {
                    if offset > 0 { Button("Neuere") { offset = max(0, offset - 100) } }
                    if offset + 100 < currentVariants.count { Button("Ältere") { offset += 100 } }
                }
            }
        }.font(.system(size: 13))
            .task(id: loadIdentity) {
                let identity = loadIdentity
                offset = 0
                if identity.expanded && identity.isReady { await editor.loadVariants(identity) }
            }
            .onChange(of: assetID) { _, _ in showsName = false; renaming = nil }
            .sheet(isPresented: $showsName) { nameSheet }
    }
    private func row(_ variant: EditingVariant) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                if let asset = library.selectedAsset, asset.id == assetID {
                    VariantThumbnail(variant: variant, asset: asset, editor: editor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(variant.displayName).fontWeight(.medium).lineLimit(3).help(variant.displayName)
                    Text(variant.displayTimestamp).foregroundStyle(Theme.muted)
                    Text(variant.snapshot.source == .original ? "Original" : "Gespeicherte Rasterquelle").foregroundStyle(Theme.muted)
                    if variant.snapshot == editor.snapshot(for: assetID) {
                        Label("Aktueller Stand", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button("Vorschau") { Task { await editor.viewVariant(variant, mode: .preview) } }
                    .accessibilityLabel("Vorschau von \(variant.displayName)")
                    .accessibilityIdentifier("variants.preview." + variant.id.canonicalString)
                Menu("Aktionen") {
                    Button("Als Vorher vergleichen") { Task { await editor.viewVariant(variant, mode: .before) } }
                        .accessibilityIdentifier("variants.before." + variant.id.canonicalString)
                    Button("Wiederherstellen") { Task { await editor.selectVariant(variant) } }
                        .accessibilityIdentifier("variants.restore." + variant.id.canonicalString)
                        .disabled(!editor.canRetainLocalEditingAnchor)
                    Button("Umbenennen …") { renaming = variant; name = variant.displayName; showsName = true }
                        .disabled(!editor.canRetainLocalEditingAnchor || editor.isManagingVariants)
                    if variant.creationKind == .named {
                        Button("Benannten Bildstand entfernen", role: .destructive) { Task { await editor.removeNamedVariant(variant) } }
                            .disabled(!editor.canRetainLocalEditingAnchor || editor.isManagingVariants)
                    }
                }.accessibilityLabel("Aktionen für \(variant.displayName)")
                    .accessibilityIdentifier("variants.actions." + variant.id.canonicalString)
            }.controlSize(.small)
        }.accessibilityElement(children: .contain)
    }
    private var nameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(renaming == nil ? "Bildstand sichern" : "Bildstand umbenennen").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Bildstandname").accessibilityIdentifier("variants.name")
            if !name.isEmpty, !validName { Text("1–120 Zeichen und höchstens 512 UTF-8-Bytes").foregroundStyle(.orange) }
            HStack {
                Button("Abbrechen") { showsName = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Sichern") {
                    let capturedName = name, capturedID = assetID, capturedVariant = renaming
                    showsName = false
                    Task {
                        if let capturedVariant { await editor.renameVariant(capturedVariant, name: capturedName) }
                        else { await editor.saveNamedVariant(name: capturedName, assetID: capturedID) }
                    }
                }.keyboardShortcut(.defaultAction).disabled(!validName)
                    .accessibilityIdentifier("variants.confirm-name")
            }
        }.padding(24).frame(width: 380)
    }
}

extension EditingVariant {
    /// Duplicate names must remain distinguishable even during a quick edit.
    var displayTimestamp: String {
        createdAt.formatted(.dateTime.year().month(.abbreviated).day().hour().minute()
            .second().secondFraction(.fractional(3)))
    }
}
