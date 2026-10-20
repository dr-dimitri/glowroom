import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Workspace save progress and recovery")
struct WorkspaceSaveStatusTests {
    @Test
    func onlyAnIdleEditorWithoutErrorsOrPendingWorkReportsSaved() {
        let saved = WorkspaceSaveStatus()
        #expect(saved.phase == .saved)
        #expect(saved.text == "Alle Änderungen gespeichert")
        #expect(!saved.isBusy && !saved.hasError)
        #expect(saved.retryAction == nil && !saved.canRetry)

        let pending = WorkspaceSaveStatus(hasPendingChanges: true)
        #expect(pending.phase == .pending && pending.isBusy)
        #expect(pending.text == "Änderungen werden gesichert …")
        #expect(!pending.hasError && pending.retryAction == nil)
    }

    @Test
    func activeWorkHasSpecificProgressEvenWithoutPendingSettings() {
        let states: [(WorkspaceSaveStatus, WorkspaceSaveStatus.Phase, String)] = [
            (.init(isLoading: true), .loading, "Bearbeitungen werden geladen …"),
            (.init(isRestoring: true), .restoring, "Sicherung wird wiederhergestellt …"),
            (.init(isBackingUp: true), .backingUp, "Sicherung wird erstellt …"),
            (.init(isCommitting: true), .committing, "Bildstand wird gespeichert …"),
            (.init(isSaving: true), .saving, "Wird gespeichert …")
        ]
        for (status, phase, text) in states {
            #expect(status.phase == phase && status.text == text)
            #expect(status.isBusy && !status.hasError && !status.canRetry)
        }
    }

    @Test
    func progressDuringRecoveryKeepsTheErrorReachableAndPreventsAnotherRetry() {
        let id = EditingCommitID()
        let states = [
            WorkspaceSaveStatus(isLoading: true, errorMessage: "Fehler"),
            WorkspaceSaveStatus(isRestoring: true, isReadOnly: true),
            WorkspaceSaveStatus(isBackingUp: true, errorMessage: "Fehler"),
            WorkspaceSaveStatus(isCommitting: true, failedArtifactCommitID: id),
            WorkspaceSaveStatus(isSaving: true, hasPendingChanges: true, isReadOnly: true)
        ]
        for status in states {
            #expect(status.isBusy && status.hasError)
            #expect(status.retryAction != nil && !status.canRetry)
        }
    }

    @Test
    func maintenanceAndArtifactCommitsKeepTheirMeaningWhileDrainingSettings() {
        #expect(WorkspaceSaveStatus(isRestoring: true, isSaving: true).phase == .restoring)
        #expect(WorkspaceSaveStatus(isBackingUp: true, isSaving: true).phase == .backingUp)
        #expect(WorkspaceSaveStatus(isCommitting: true, isSaving: true).phase == .committing)
    }

    @Test
    func errorsOutrankPendingWorkAndChooseTheOwnedRecoveryOperation() {
        let id = EditingCommitID()
        let artifact = WorkspaceSaveStatus(hasPendingChanges: true, isReadOnly: true,
                                          errorMessage: "Fehler", failedArtifactCommitID: id)
        #expect(artifact.phase == .failed && artifact.hasError && !artifact.isBusy)
        #expect(artifact.retryAction == .acceptedArtifact(id) && artifact.canRetry)

        let pending = WorkspaceSaveStatus(hasPendingChanges: true, isReadOnly: true)
        #expect(pending.phase == .readOnly && !pending.isBusy)
        #expect(pending.retryAction == .pendingChanges && pending.canRetry)

        let readOnly = WorkspaceSaveStatus(isReadOnly: true)
        #expect(readOnly.phase == .readOnly && readOnly.hasError)
        #expect(readOnly.retryAction == .reload && readOnly.canRetry)

        let failure = WorkspaceSaveStatus(errorMessage: "Fehler")
        #expect(failure.phase == .failed && failure.hasError)
        #expect(failure.retryAction == .reload && failure.canRetry)
    }

    @Test
    func closingDoesNotOfferNewRecoveryWork() {
        let status = WorkspaceSaveStatus(hasPendingChanges: true, isReadOnly: true, isClosing: true)
        #expect(status.hasError && status.retryAction == .pendingChanges)
        #expect(!status.canRetry)
    }
}
