import AppKit

@MainActor
enum JPEGExportActions {
    static func present(using exporter: JPEGExportModel, library: LibraryModel, editor: EditingModel) {
        guard let asset = library.selectedAsset, !exporter.isPresented,
              !editor.isLoading, !editor.isRestoring, !editor.isClosing else { return }
        // Commit a focused numeric adjustment before freezing the export's edits.
        NSApp.keyWindow?.makeFirstResponder(nil)
        editor.endEditing(assetID: asset.id)
        exporter.present(asset: asset, settings: editor.settings(for: asset.id),
                         protectedSourceURLs: library.assets.map(\.fileURL))
    }
}
