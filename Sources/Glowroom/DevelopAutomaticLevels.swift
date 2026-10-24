import Foundation
import GlowroomCore

extension DevelopWorkspace {
    /// Shares the precise picker's accepted frame, cancellation generation and
    /// existing analysis lane. No undo group or intermediate edit spans await.
    @discardableResult
    func applyAutomaticLevels(assetID: String, editor: EditingModel,
                              selection: DevelopSelectionIdentity,
                              isCurrent: @escaping @MainActor () -> Bool) -> Task<Void, Never>? {
        endLevelsPicker()
        cancelAutomaticTone()
        guard editor.canEdit, tool == .basic, isCurrent() else { return nil }
        picksWhiteBalance = false; picksDetail = false
        guard matchesLevelsDisplay(assetID: assetID, editor: editor, selection: selection),
              let display = levelsDisplay else {
            errorMessage = "Die aktuelle Bildvorschau wird noch aktualisiert. Versuche die automatische Tonwertkorrektur erneut, sobald sie fertig angezeigt wird."
            return nil
        }
        editor.selectEditingFunction(.adjustments, assetID: assetID)
        editor.endEditing(assetID: assetID)
        guard matchesLevelsDisplay(assetID: assetID, editor: editor, selection: selection) else { return nil }
        let baseline = editor.snapshot(for: assetID)
        let bitmap = display.frame.actualInput, source = display.decodedSource
        let request = UUID(); levelsRequest = request
        automaticLevelsBusy = true; levelsSampleDescription = nil; errorMessage = nil
        let stillCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return !Task.isCancelled && self.levelsRequest == request && self.levelsPicker == nil &&
                self.tool == .basic && editor.canEdit && isCurrent() &&
                self.levelsDisplay?.identity == display.identity &&
                self.levelsDisplay?.frame.actualInput.rangeSourceIdentity == bitmap.rangeSourceIdentity &&
                self.levelsDisplay?.decodedSource.rangeSourceIdentity == source.rangeSourceIdentity &&
                self.matchesLevelsDisplay(assetID: assetID, editor: editor, selection: selection) &&
                editor.snapshot(for: assetID) == baseline && !editor.hasActiveEditing(assetID: assetID)
        }
        let task = Task { [weak self, estimateLevels, validateLevels] in
            defer {
                if let self, self.levelsRequest == request {
                    self.automaticLevelsBusy = false; self.levelsTask = nil
                }
            }
            do {
                let estimate = try await estimateLevels(bitmap, source, baseline.settings)
                try Task.checkCancellation()
                guard stillCurrent(), let self else { return }
                guard case .value(let levels) = estimate else {
                    if case .noProposal(let reason) = estimate { self.errorMessage = reason.explanation }
                    return
                }
                try levels.validate()
                var proposed = baseline.settings
                proposed.levels = levels
                _ = try EditingSnapshot(settings: proposed)
                // Clipping is certified on the global path. This additional
                // proof includes the user's masks/retouch/geometry before an
                // accepted snapshot can enter normal persistence.
                try await validateLevels(bitmap, proposed, nil)
                try Task.checkCancellation()
                guard stillCurrent() else { return }
                editor.setSettings(proposed, for: assetID)
                self.levelsSampleDescription = "Gemeinsamer Tonwertbereich automatisch gesetzt; alle Levels-Kanäle wurden gemeinsam ersetzt."
            } catch is CancellationError { }
            catch {
                guard stillCurrent(), let self else { return }
                self.errorMessage = (error as? LocalizedError)?.errorDescription ??
                    "Der automatische Tonwertbereich konnte nicht sicher berechnet werden. Die bisherigen Levels bleiben erhalten."
            }
        }
        levelsTask = task
        return task
    }
}
