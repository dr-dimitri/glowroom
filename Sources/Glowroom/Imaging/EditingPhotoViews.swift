import SwiftUI
import GlowroomCore

/// Resolution uses the already loaded descriptor map. A missing artifact is an
/// explicit error, never a request for the imported original.
struct EditingThumbnail: View {
    let asset: PhotoAsset
    var size: CGFloat = 320
    var priority: PreviewPriority = .thumbnail
    @EnvironmentObject private var editor: EditingModel
    var body: some View {
        if let source = try? editor.resolvedSource(for: asset) {
            AssetThumbnail(url: asset.fileURL, modifiedAt: asset.modifiedAt, size: size, fileSize: asset.fileSize,
                priority: priority, settings: source.settings, source: source.identity)
                .overlay(alignment: .bottomLeading) {
                    if editor.showsImportedOriginalFallback {
                        Text("Original").font(.system(size: 13)).padding(4).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .help("Original ohne Bearbeitungen. Die Bearbeitungsdatenbank ist nicht verfügbar; gespeicherte Bearbeitungen bleiben erhalten.")
                    }
                }
        } else {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                .help("Die gespeicherte Bildquelle ist nicht verfügbar. Das Original wird nicht ersatzweise angezeigt.")
        }
    }
}

struct EditingPhotoPreview: View {
    let asset: PhotoAsset
    let intent: EditingRenderIntent
    var settingsOverride: EditSettings?
    var developing = false
    var imageScale: CGFloat = 1
    var imageRotation: Double = 0
    @EnvironmentObject private var editor: EditingModel
    @Environment(\.developSelectionIdentity) private var selectionIdentity
    var body: some View {
        if let source = try? editor.resolvedSource(for: asset, intent: intent) {
            PhotoPreview(url: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize,
                settings: editor.showsImportedOriginalFallback ? .neutral : intent == .currentEditing ? settingsOverride ?? source.settings : .neutral,
                source: source.identity, developing: developing, imageScale: imageScale, imageRotation: imageRotation,
                revision: DevelopPreviewRevision(assetID: asset.id, editorSessionID: editor.aiEditSessionID,
                    editorGeneration: editor.aiEditGeneration, localRevision: editor.localRevision(for: asset.id),
                    selection: selectionIdentity, intent: intent))
                .overlay(alignment: .top) {
                    if editor.showsImportedOriginalFallback, intent != .importedOriginal {
                        Text("Original ohne Bearbeitungen · Bearbeitungsdatenbank nicht verfügbar")
                            .font(.system(size: 13)).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(8)
                    }
                }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Gespeicherte Bildquelle nicht verfügbar")
                Text("Prüfe das Bearbeitungspaket oder stelle eine vollständige Sicherung wieder her.").font(.system(size: 13))
            }.padding().accessibilityLabel("Gespeicherte Bildquelle nicht verfügbar")
        }
    }
}
