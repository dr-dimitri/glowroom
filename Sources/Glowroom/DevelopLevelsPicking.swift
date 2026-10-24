import Foundation
import GlowroomCore

struct DevelopLevelsPickerSelection: Hashable, Sendable {
    let point: LevelsPickerPoint
    let mode: LevelsPickerMode
    let channel: LevelsChannel
}

extension DevelopWorkspace {
    /// The revision originates in the render task, before any await. A matching
    /// value alone is insufficient after Undo/Redo or an A→B→A selection change.
    func matchesLevelsDisplay(assetID: String, editor: EditingModel,
                              selection: DevelopSelectionIdentity) -> Bool {
        guard let display = levelsDisplay, let revision = display.identity.revision,
              display.identity.finalSourceReady, display.identity.sourceToken != nil,
              !display.identity.request.allowsEmbeddedPreview,
              revision.assetID == assetID, revision.intent == .currentEditing,
              revision.editorSessionID == editor.aiEditSessionID,
              revision.editorGeneration == editor.aiEditGeneration,
              revision.localRevision == editor.localRevision(for: assetID),
              revision.selection == selection,
              display.identity.request.source == sourceIdentity,
              display.identity.settings == editor.settings(for: assetID).normalized else { return false }
        return true
    }

    func receiveLevelsDisplay(_ display: DevelopPreviewHandoff) {
        if levelsDisplay?.identity != display.identity ||
            levelsDisplay?.frame.actualInput.rangeSourceIdentity != display.frame.actualInput.rangeSourceIdentity {
            cancelLevelsRequest()
        }
        levelsDisplay = display
    }

    func invalidateLevelsDisplay() {
        endLevelsPicker(); levelsDisplay = nil
    }

    func beginLevelsPicker(_ picker: DevelopLevelsPickerSelection, assetID: String, editor: EditingModel,
                           selection: DevelopSelectionIdentity, isCurrent: Bool) {
        endLevelsPicker()
        guard editor.canEdit, isCurrent else { return }
        tool = .basic; picksWhiteBalance = false; picksDetail = false
        guard matchesLevelsDisplay(assetID: assetID, editor: editor, selection: selection) else {
            errorMessage = "Die aktuelle Bildvorschau wird noch aktualisiert. Aktiviere die Tonwertpipette, sobald sie fertig angezeigt wird."
            return
        }
        levelsPicker = picker; levelsSampleDescription = nil; errorMessage = nil
    }

    func endLevelsPicker() {
        levelsPicker = nil
        cancelLevelsRequest()
    }

    func cancelLevelsRequest() {
        levelsRequest = UUID(); levelsTask?.cancel(); levelsTask = nil
    }

    /// Point is already inverse-mapped through the exact accepted geometry
    /// plan, in top-left normalized coordinates of its actual adaptive input.
    @discardableResult
    func applyLevelsPicker(at point: CGPoint, assetID: String, editor: EditingModel,
                           selection: DevelopSelectionIdentity,
                           isCurrent: @escaping @MainActor () -> Bool) -> Task<Void, Never>? {
        cancelLevelsRequest()
        guard let picker = levelsPicker, editor.canEdit, tool == .basic, isCurrent(),
              matchesLevelsDisplay(assetID: assetID, editor: editor, selection: selection),
              let display = levelsDisplay else { return nil }
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        editor.selectEditingFunction(.adjustments, assetID: assetID)
        editor.endEditing(assetID: assetID)
        // Finishing a pending editor may itself change the revision. Never
        // attach that newer revision to the preceding displayed pixels.
        guard matchesLevelsDisplay(assetID: assetID, editor: editor, selection: selection) else { return nil }
        let baseline = editor.snapshot(for: assetID)
        let request = UUID(); levelsRequest = request; errorMessage = nil
        let bitmap = display.frame.actualInput
        let stillCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return !Task.isCancelled && self.levelsRequest == request && self.levelsPicker == picker &&
                self.tool == .basic && editor.canEdit && isCurrent() &&
                self.levelsDisplay?.identity == display.identity &&
                self.levelsDisplay?.frame.actualInput.rangeSourceIdentity == bitmap.rangeSourceIdentity &&
                self.matchesLevelsDisplay(assetID: assetID, editor: editor, selection: selection) &&
                editor.snapshot(for: assetID) == baseline && !editor.hasActiveEditing(assetID: assetID)
        }
        let task = Task { [weak self, sampleLevels, validateLevels] in
            defer { if let self, self.levelsRequest == request { self.levelsTask = nil } }
            do {
                let report = try await sampleLevels(bitmap, baseline.settings, point)
                try Task.checkCancellation()
                guard stillCurrent(), let self else { return }
                let proposed = try LevelsPickerProposal.applying(sample: report.sample, point: picker.point,
                    mode: picker.mode, channel: picker.channel, to: baseline.settings)
                _ = try EditingSnapshot(settings: proposed)
                // The selected patch alone cannot certify the rest of the
                // image: reject a valid parameter set if other pixels or later
                // stages would overflow. The same bounded actor performs this
                // GPU reduction; no full CPU raster or extra RAW read is made.
                let neutralGray = picker.mode == .neutralizeRGB && picker.point == .gray ? report.sample : nil
                try await validateLevels(bitmap, proposed, neutralGray)
                try Task.checkCancellation()
                guard stillCurrent() else { return }
                // This complete validated replacement is the sole accepted
                // edit. No channel mutations or undo group cross the await.
                editor.setSettings(proposed, for: assetID)
                self.levelsSampleDescription = "Probe \(report.windowWidth) × \(report.windowHeight) in \(report.proxyWidth) × \(report.proxyHeight) Pixeln"
                self.endLevelsPicker()
            } catch is CancellationError { }
            catch {
                guard stillCurrent(), let self else { return }
                self.errorMessage = (error as? LocalizedError)?.errorDescription ??
                    "Diese Probe ergibt keine gültige Tonwertkorrektur. Wähle eine andere Bildfläche; die bisherigen Werte bleiben erhalten."
            }
        }
        levelsTask = task
        return task
    }
}
