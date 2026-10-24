import Foundation
import GlowroomCore
import SwiftUI

/// Selection generations distinguish A → B → A even when the decoded source
/// and all settings are unchanged. They do not participate in source decoding.
struct DevelopSelectionIdentity: Hashable, Sendable {
    let sessionID: UUID
    let generation: UInt64
}

/// Captured before starting a render. A completed frame never receives the
/// editor's newer revision at handoff time.
struct DevelopPreviewRevision: Hashable, Sendable {
    let assetID: String
    let editorSessionID: UUID
    let editorGeneration: UInt64
    let localRevision: Int64
    let selection: DevelopSelectionIdentity?
    let intent: EditingRenderIntent
}

struct DevelopPreviewRenderIdentity: Hashable, Sendable {
    let request: PreviewRequest
    let settings: EditSettings
    let revision: DevelopPreviewRevision?
    let sourceToken: UUID?
    let finalSourceReady: Bool
}

struct DevelopPreviewHandoff: Sendable {
    let identity: DevelopPreviewRenderIdentity
    let frame: AdjustedPreviewFrame
    // The original decoded basis remains available to the existing WB,
    // horizon and automatic-tone consumers. Levels uses frame.actualInput.
    let decodedSource: PreviewBitmap
}

typealias DevelopPreviewPending = @MainActor (DevelopPreviewRenderIdentity) -> Void

private struct DevelopSelectionIdentityKey: EnvironmentKey {
    static let defaultValue: DevelopSelectionIdentity? = nil
}

private struct DevelopPreviewPendingKey: EnvironmentKey {
    static let defaultValue: DevelopPreviewPending? = nil
}

extension EnvironmentValues {
    var developSelectionIdentity: DevelopSelectionIdentity? {
        get { self[DevelopSelectionIdentityKey.self] }
        set { self[DevelopSelectionIdentityKey.self] = newValue }
    }

    var developPreviewPending: DevelopPreviewPending? {
        get { self[DevelopPreviewPendingKey.self] }
        set { self[DevelopPreviewPendingKey.self] = newValue }
    }
}
