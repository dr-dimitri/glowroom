import AppKit
import PicEditCore

@MainActor
enum JPEGExportActions {
    static func present(using exporter: JPEGExportModel, library: LibraryModel, editor: EditingModel,
                        contextAsset: PhotoAsset? = nil) {
        guard !exporter.isPresented, !library.isProjecting, !editor.isLoading, !editor.isRestoring, !editor.isClosing else { return }
        // Commit a focused numeric adjustment before changing the active photo
        // or freezing any of the selected photos' edits.
        NSApp.keyWindow?.makeFirstResponder(nil)
        if let activeID = library.selectedID { editor.endEditing(assetID: activeID) }
        if let contextAsset, !library.selectedIDs.contains(contextAsset.id) {
            library.select(contextAsset)
            guard library.selectedIDs.contains(contextAsset.id) else { return }
        }
        let assets = library.selectedAssets
        guard !assets.isEmpty else { return }
        for asset in assets { editor.endEditing(assetID: asset.id) }
        let settings = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, editor.settings(for: $0.id)) })
        exporter.present(assets: assets, settingsByAsset: settings,
                         protectedSourceURLs: library.assets.map(\.fileURL) + editor.semanticProtectedURLs)
    }
}
