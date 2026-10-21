import GlowroomCore

extension EditingModel {
    func aiSnapshot(in library: LibraryModel, intent: EditingRenderIntent = .currentEditing) -> AIEditingSnapshot? {
        editingSnapshot(in: library, intent: intent, permitsAutomaticBackupMaintenance: false)
    }
    func localEditingAnchorSnapshot(in library: LibraryModel) -> AIEditingSnapshot? {
        editingSnapshot(in: library, intent: .currentEditing, permitsAutomaticBackupMaintenance: true)
    }
    private func editingSnapshot(in library: LibraryModel, intent: EditingRenderIntent, permitsAutomaticBackupMaintenance: Bool) -> AIEditingSnapshot? {
        self.library = library
        guard (permitsAutomaticBackupMaintenance ? canRetainLocalEditingAnchor : canEdit),
              library.canModify, !library.isImporting, !library.isProjecting,
              let asset = library.selectedAsset, !asset.id.isEmpty,
              let resolved = try? resolvedSource(for: asset, intent: intent) else { return nil }
        return AIEditingSnapshot(assetID: asset.id, source: resolved.identity, settings: resolved.settings,
            token: AIEditingToken(editSessionID: aiEditSessionID, editGeneration: aiEditGeneration,
                selectionSessionID: library.aiSelectionSessionID, selectionGeneration: library.aiSelectionGeneration),
            persistedVersion: intent == .importedOriginal ? nil : persistedState(for: asset.id))
    }
    func isCurrentAISnapshot(_ snapshot: AIEditingSnapshot, in library: LibraryModel) -> Bool {
        aiSnapshot(in: library) == snapshot
    }
}
