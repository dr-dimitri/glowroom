import Foundation
import GlowroomCore

extension DevelopWorkspace {
    /// A single outstanding request coalesces repeated gestures. The estimator's
    /// actor bounds bitmap/render work; UI and accepted edits stay on MainActor.
    @discardableResult
    func applyAutomaticTone(_ control: AutomaticToneControl, assetID: String, editor: EditingModel,
                            isCurrent: @escaping @MainActor () -> Bool) -> Task<Void, Never>? {
        cancelAutomaticTone()
        guard editor.canEdit, tool == .basic, isCurrent() else { return nil }
        guard let bitmap = originalBitmap, let source = sourceIdentity else {
            errorMessage = "Die Bildvorschau wird noch geladen. Versuche Shift-Doppelklick erneut, sobald sie sichtbar ist."
            return nil
        }
        editor.selectEditingFunction(.adjustments, assetID: assetID)
        editor.endEditing(assetID: assetID)
        let baseline = editor.snapshot(for: assetID)
        let revision = editor.localRevision(for: assetID)
        let session = editor.aiEditSessionID, generation = editor.aiEditGeneration
        let baseID = ObjectIdentifier(bitmap.image), request = UUID()
        automaticToneIdentity = request; errorMessage = nil

        let task = Task { [weak self, estimateTone] in
            defer {
                if let self, self.automaticToneIdentity == request { self.automaticToneTask = nil }
            }
            do {
                let value = try await estimateTone(control, bitmap, baseline.settings)
                try Task.checkCancellation()
                guard let self, self.automaticToneIdentity == request,
                      self.sourceIdentity == source, self.tool == .basic,
                      self.originalBitmap.map({ ObjectIdentifier($0.image) }) == baseID,
                      editor.canEdit, isCurrent(),
                      editor.snapshot(for: assetID) == baseline,
                      editor.localRevision(for: assetID) == revision,
                      editor.aiEditSessionID == session, editor.aiEditGeneration == generation,
                      !editor.hasActiveEditing(assetID: assetID), value.isFinite else { return }
                var settings = baseline.settings
                settings[keyPath: control.keyPath] = min(control.range.upperBound, max(control.range.lowerBound, value))
                // No group stays open across the asynchronous estimate. This
                // accepted one-parameter replacement is exactly one undo step.
                editor.setSettings(settings, for: assetID)
            } catch is CancellationError { }
            catch {
                guard let self, self.automaticToneIdentity == request, !Task.isCancelled,
                      self.sourceIdentity == source, isCurrent(),
                      editor.localRevision(for: assetID) == revision,
                      editor.aiEditSessionID == session, editor.aiEditGeneration == generation else { return }
                self.errorMessage = "Der automatische Tonwert konnte nicht berechnet werden. Der bisherige Wert bleibt erhalten."
            }
        }
        automaticToneTask = task
        return task
    }

    func cancelAutomaticTone() {
        automaticToneIdentity = UUID()
        automaticToneTask?.cancel(); automaticToneTask = nil
    }
}
