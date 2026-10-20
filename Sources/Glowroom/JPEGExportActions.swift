import AppKit
import GlowroomCore

@MainActor
enum JPEGExportActions {
    static func present(using exporter: JPEGExportModel, library: LibraryModel, editor: EditingModel,
                        contextAsset: PhotoAsset? = nil) {
        guard !exporter.isPresented, library.canExportJPEG, !library.isProjecting, !editor.isLoading, !editor.isRestoring, !editor.isClosing else { return }
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
        guard assets.allSatisfy({ editor.snapshot(for: $0.id).source == .original }) else {
            editor.errorMessage = "Der Export generierter Bildquellen wird noch nicht unterstützt. Sichere den vollständigen Bildstand als Bearbeitungspaket."
            return
        }
        for asset in assets { editor.endEditing(assetID: asset.id) }
        let settings = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, editor.settings(for: $0.id)) })
        let protection = library.photoMetadataFileProtection()
        exporter.present(assets: assets, settingsByAsset: settings,
                         protectedSourceURLs: protection.originalURLs + protection.managedFileURLs + protection.managedDirectoryURLs
                            + editor.cloudProtectedURLs + editor.semanticProtectedURLs,
                         protectedDirectoryFamilies: protection.managedDirectoryFamilies.map {
                            ManagedDirectoryFamily(parent: $0.parent, childNamePrefix: $0.childNamePrefix)
                         } + editor.semanticProtectedDirectoryFamilies,
                         catalogProtection: library.jpegExportProtection)
    }
}
