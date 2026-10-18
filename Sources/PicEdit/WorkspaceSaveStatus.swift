import PicEditCore

/// Shared presentation state for the inspector and the always visible status bar.
/// Derivation is a short, ordered UI-state read; it starts no persistence work.
struct WorkspaceSaveStatus: Equatable {
    enum Phase: Equatable {
        case loading, restoring, backingUp, committing, saving, pending, failed, readOnly, saved
    }

    enum RetryAction: Equatable {
        case acceptedArtifact(EditingCommitID)
        case pendingChanges
        case reload

        var title: String {
            switch self {
            case .acceptedArtifact: return "Angenommenen Bildstand erneut speichern"
            case .pendingChanges: return "Änderungen erneut speichern"
            case .reload: return "Bearbeitungen erneut laden"
            }
        }
    }

    let phase: Phase
    let hasError: Bool
    let retryAction: RetryAction?
    let canRetry: Bool

    var text: String {
        switch phase {
        case .loading: return "Bearbeitungen werden geladen …"
        case .restoring: return "Sicherung wird wiederhergestellt …"
        case .backingUp: return "Sicherung wird erstellt …"
        case .committing: return "Bildstand wird gespeichert …"
        case .saving: return "Wird gespeichert …"
        case .pending: return "Änderungen werden gesichert …"
        case .failed: return "Speicherfehler · Prüfen"
        case .readOnly: return "Speichern nicht verfügbar"
        case .saved: return "Alle Änderungen gespeichert"
        }
    }

    var isBusy: Bool {
        switch phase {
        case .loading, .restoring, .backingUp, .committing, .saving, .pending: return true
        case .failed, .readOnly, .saved: return false
        }
    }

    @MainActor
    init(editor: EditingModel) {
        self.init(isLoading: editor.isLoading, isRestoring: editor.isRestoring,
            isBackingUp: editor.isBackingUp, isCommitting: editor.isCommitting,
            isSaving: editor.isSaving, hasPendingChanges: editor.hasPendingChanges,
            isReadOnly: editor.isReadOnly, errorMessage: editor.errorMessage,
            failedArtifactCommitID: editor.failedArtifactCommitID, isClosing: editor.isClosing)
    }

    init(isLoading: Bool = false, isRestoring: Bool = false, isBackingUp: Bool = false,
         isCommitting: Bool = false, isSaving: Bool = false, hasPendingChanges: Bool = false,
         isReadOnly: Bool = false, errorMessage: String? = nil,
         failedArtifactCommitID: EditingCommitID? = nil, isClosing: Bool = false) {
        hasError = isReadOnly || errorMessage != nil || failedArtifactCommitID != nil

        // An active retry keeps its progress text while the previous error is
        // still visible through hasError. Otherwise errors outrank queued work.
        if isLoading { phase = .loading }
        else if isRestoring { phase = .restoring }
        else if isBackingUp { phase = .backingUp }
        else if isCommitting { phase = .committing }
        else if isSaving { phase = .saving }
        else if failedArtifactCommitID != nil || errorMessage != nil { phase = .failed }
        else if isReadOnly { phase = .readOnly }
        else if hasPendingChanges { phase = .pending }
        else { phase = .saved }

        if !hasError { retryAction = nil }
        else if let id = failedArtifactCommitID { retryAction = .acceptedArtifact(id) }
        else if hasPendingChanges { retryAction = .pendingChanges }
        else { retryAction = .reload }
        canRetry = retryAction != nil && !isLoading && !isRestoring && !isBackingUp
            && !isCommitting && !isSaving && !isClosing
    }
}
