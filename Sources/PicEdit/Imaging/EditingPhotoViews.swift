import SwiftUI
import PicEditCore

/// Resolution uses the already loaded descriptor map. A missing artifact is an
/// explicit error, never a request for the imported original.
struct EditingThumbnail: View {
    let asset: PhotoAsset
    var size: CGFloat = 320
    @EnvironmentObject private var editor: EditingModel
    var body: some View {
        if let source = try? editor.resolvedSource(for: asset) {
            AssetThumbnail(url: asset.fileURL, modifiedAt: asset.modifiedAt, size: size, fileSize: asset.fileSize,
                settings: source.settings, source: source.identity)
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
    @EnvironmentObject private var editor: EditingModel
    var body: some View {
        if let source = try? editor.resolvedSource(for: asset, intent: intent) {
            PhotoPreview(url: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize,
                settings: intent == .currentEditing ? settingsOverride ?? source.settings : .neutral,
                source: source.identity, developing: developing)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Gespeicherte Bildquelle nicht verfügbar")
                Text("Prüfe das Bearbeitungspaket oder stelle eine vollständige Sicherung wieder her.").font(.caption)
            }.padding().accessibilityLabel("Gespeicherte Bildquelle nicht verfügbar")
        }
    }
}
