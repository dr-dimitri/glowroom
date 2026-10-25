import SwiftUI
import GlowroomCore

/// A display-only render. Persistence, export, scopes and history continue to
/// read the editor's accepted settings until the ordinary apply transaction.
struct AICorrectionPreview: Sendable {
    let snapshot: AIEditingSnapshot
    let settings: EditSettings
    let bitmap: PreviewBitmap

    func matches(_ current: AIEditingSnapshot?) -> Bool {
        guard let current else { return false }
        return current.assetID == snapshot.assetID && current.source == snapshot.source
            && current.settings == snapshot.settings && current.token == snapshot.token
            && current.persistedVersion?.storeEpoch == snapshot.persistedVersion?.storeEpoch
    }

    func matches(request: PreviewRequest, settings: EditSettings, revision: DevelopPreviewRevision?) -> Bool {
        guard let revision, let selection = revision.selection else { return false }
        return request.source == snapshot.source && settings == snapshot.settings.normalized
            && revision.intent == .currentEditing && revision.assetID == snapshot.assetID
            && revision.editorSessionID == snapshot.token.editSessionID
            && revision.editorGeneration == snapshot.token.editGeneration
            && selection.sessionID == snapshot.token.selectionSessionID
            && selection.generation == snapshot.token.selectionGeneration
    }
}

struct AICorrectionDisplay: Sendable {
    let preview: AICorrectionPreview
    let showsProposal: Bool
    var title: String { showsProposal ? "Vorschlag" : "Aktueller Stand" }
}

private struct AICorrectionDisplayKey: EnvironmentKey {
    static let defaultValue: AICorrectionDisplay? = nil
}

extension EnvironmentValues {
    var aiCorrectionDisplay: AICorrectionDisplay? {
        get { self[AICorrectionDisplayKey.self] }
        set { self[AICorrectionDisplayKey.self] = newValue }
    }
}

extension DevelopWorkspace {
    func correctionDisplay(library: LibraryModel, editor: EditingModel) -> AICorrectionDisplay? {
        guard library.isDeveloping, library.previewComparisonLayout == .single,
              !library.comparesOriginal, !library.comparesCurrentSourceWithoutSettings,
              tool == .basic, !picksWhiteBalance, !picksDetail, levelsPicker == nil,
              let preview = presetPreview ?? aiCorrectionPreview,
              preview.matches(editor.localEditingAnchorSnapshot(in: library)) else { return nil }
        return AICorrectionDisplay(preview: preview, showsProposal: showsAICorrectionProposal)
    }
}
