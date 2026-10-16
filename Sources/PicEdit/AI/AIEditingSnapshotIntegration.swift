import PicEditCore

extension EditingModel {
    /// Copy existing catalog metadata only. Symlink resolution, stat, decoding
    /// and model work must remain outside MainActor and outside this boundary.
    func aiSnapshot(in library: LibraryModel) -> AIEditingSnapshot? {
        guard canEdit, library.canModify, !library.isImporting, !library.isProjecting,
              let asset = library.selectedAsset, !asset.id.isEmpty else { return nil }
        return AIEditingSnapshot(
            assetID: asset.id,
            source: .original(AIOriginalSourceFingerprint(fileURL: asset.fileURL,
                                                       modifiedAt: asset.modifiedAt,
                                                       fileSize: asset.fileSize)),
            settings: settings(for: asset.id),
            token: AIEditingToken(editSessionID: aiEditSessionID,
                                  editGeneration: aiEditGeneration,
                                  selectionSessionID: library.aiSelectionSessionID,
                                  selectionGeneration: library.aiSelectionGeneration)
        )
    }

    /// Use at request start, before displaying a result, and immediately before
    /// applying it. A model response is never a source of trusted context.
    func isCurrentAISnapshot(_ snapshot: AIEditingSnapshot, in library: LibraryModel) -> Bool {
        aiSnapshot(in: library) == snapshot
    }
}
