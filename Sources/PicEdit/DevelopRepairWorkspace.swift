import AppKit
import PicEditCore

/// Injected services keep native inference out of UI tests. The shared actor
/// owns one bounded source analysis; slider changes never decode another RAW.
struct DevelopRepairServices: Sendable {
    var source: @Sendable (PreviewBitmap, [LocalMaskPoint], Double, LocalMaskRaster?) async throws -> LocalMaskPoint
    var object: @Sendable (PreviewBitmap, LocalMaskPoint, [LocalMaskPoint]) async throws -> DevelopRepairCandidate
    var candidates: @Sendable (PreviewBitmap, DevelopRepairDetectionKind, Double) async throws -> [DevelopRepairCandidate]
    var replacement: @Sendable (PreviewBitmap, LocalMaskRaster, [DevelopRetouchStroke]) async throws -> DevelopRetouchReplacement = {
        try await DevelopRepairAIService.shared.replace($0, mask: $1, priorRepairs: $2)
    }
    var nextSource: @Sendable (PreviewBitmap, [LocalMaskPoint], Double, LocalMaskRaster?, [LocalMaskPoint]) async throws -> LocalMaskPoint = {
        try await DevelopRepairAnalyzer.shared.source(for: $0, path: $1, radius: $2, mask: $3, excluding: $4)
    }

    static let live = Self(
        source: { try await DevelopRepairAnalyzer.shared.source(for: $0, path: $1, radius: $2, mask: $3) },
        object: { try await DevelopRepairAnalyzer.shared.object(in: $0, at: $1, path: $2) },
        candidates: { try await DevelopRepairAnalyzer.shared.candidates(in: $0, kind: $1, sensitivity: $2) })
}

extension DevelopWorkspace {
    func cancelRepairWork(clearCandidates: Bool = true) {
        repairRequest = UUID(); repairTask?.cancel(); repairTask = nil; repairBusy = false
        if clearCandidates {
            repairCandidates = []; repairSelectedCandidateIDs = []
            repairTriedSourceStrokeID = nil; repairTriedSources = []
        }
    }

    func closeRepair() {
        cancelRepairWork(); repairSource = nil; repairStatus = nil; tool = .basic
    }

    func resetRepairs(asset: PhotoAsset, editor: EditingModel) {
        cancelRepairWork(); repairSource = nil; repairStatus = nil
        guard editor.canEdit else { return }
        editor.endEditing(assetID: asset.id)
        var settings = editor.settings(for: asset.id)
        settings.developGeometry.retouchStrokes = []
        editor.setSettings(settings, for: asset.id)
        errorMessage = nil
    }

    /// A painted gesture is stored once, after source selection/segmentation.
    /// Source/session/revision guards protect Undo, restore and A→B→A changes.
    func applyRepair(path: [LocalMaskPoint], selection: LocalMaskRaster? = nil, asset: PhotoAsset, editor: EditingModel,
                     expectedRevision: Int64, expectedSession: UUID) {
        guard !path.isEmpty, editor.canEdit, isOriginalCanvasReady, tool == .repair,
              editor.localRevision(for: asset.id) == expectedRevision,
              editor.aiEditSessionID == expectedSession,
              let bitmap = originalBitmap, let sourceIdentity else { return }
        cancelRepairWork(clearCandidates: false)
        repairTriedSourceStrokeID = nil; repairTriedSources = []
        let request = repairRequest, services = repairServices
        let baseline = editor.settings(for: asset.id)
        let mode = repairMode, radius = repairRadius, feather = repairFeather
        let usesAI = repairUsesAI && mode == .remove
        if usesAI && baseline.developColor.hdrEnabled {
            errorMessage = "Das lokale Reparaturmodell verarbeitet SDR-Farben. Deaktiviere HDR, bevor du eine KI-Reparatur erstellst."
            return
        }
        let sourceSize = self.sourceSize ?? CGSize(width: bitmap.image.width, height: bitmap.image.height)
        let detectsObject = selection == nil && repairObjectDetection && mode == .remove
        let manualSource = usesAI ? nil : repairSource
        if mode == .clone && manualSource == nil {
            errorMessage = "Wähle zuerst mit ⌥-Klick einen sauberen Quellbereich für den Kopierstempel."
            return
        }
        repairBusy = true; errorMessage = nil; repairStatus = nil
        repairTask = Task { [weak self, weak editor] in
            defer { if let self, self.repairRequest == request { self.repairBusy = false; self.repairTask = nil } }
            do {
                var mask = selection
                var target = path[0]
                var savedPath = path
                var status: String?
                if detectsObject {
                    do {
                        let object = try await services.object(bitmap, target, path)
                        mask = object.mask; target = object.center; savedPath = [target]
                        status = "Objektauswahl erkannt."
                    } catch DevelopRepairAnalysisError.noObject {
                        status = "Kein Objekt erkannt; der gemalte Pinselbereich wurde verwendet."
                    }
                }
                try Task.checkCancellation()
                var replacement: DevelopRetouchReplacement?
                if usesAI {
                    if mask == nil {
                        let frozenPath = savedPath
                        mask = try await Task.detached {
                            try DevelopRepairAIService.brushMask(path: frozenPath, radius: radius, sourceSize: sourceSize)
                        }.value
                    }
                    if let mask { replacement = try await services.replacement(bitmap, mask, baseline.developGeometry.retouchStrokes) }
                }
                let source: LocalMaskPoint
                if usesAI { source = target }
                else if let manualSource { source = manualSource }
                else { source = try await services.source(bitmap, savedPath, radius, mask) }
                try Task.checkCancellation()
                let stroke = try DevelopRetouchStroke(mode: mode.retouchMode, source: source, target: target,
                    radius: radius, feather: feather, path: savedPath, mask: mask, replacement: replacement)
                try await Self.validateRepairs([stroke], baseline: baseline)
                try Task.checkCancellation()
                guard let self, let editor, self.repairRequest == request, self.sourceIdentity == sourceIdentity,
                      self.tool == .repair, editor.canEdit,
                      editor.localRevision(for: asset.id) == expectedRevision,
                      editor.aiEditSessionID == expectedSession else { return }
                try self.appendRepairs([stroke], asset: asset, editor: editor)
                self.repairTriedSourceStrokeID = usesAI ? nil : stroke.id
                self.repairTriedSources = usesAI ? [] : [source]
                self.repairCandidates = []; self.repairSelectedCandidateIDs = []
                self.repairStatus = (status.map { $0 + " " } ?? "")
                    + (usesAI ? "Lokale KI-Reparatur aktiv. Mit ⌘Z rückgängig machen."
                       : "Reparatur aktiv. Mit ⌘Z rückgängig machen.")
            } catch is CancellationError { }
            catch {
                if let self, self.repairRequest == request { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func detectRepairCandidates(_ kind: DevelopRepairDetectionKind) async {
        guard tool == .repair, isOriginalCanvasReady, let bitmap = originalBitmap, let sourceIdentity else { return }
        cancelRepairWork()
        let request = repairRequest, sensitivity = repairSpotThreshold
        repairBusy = true; errorMessage = nil; repairStatus = nil
        let task = Task { [repairServices] in try await repairServices.candidates(bitmap, kind, sensitivity) }
        // Keep a cancellation handle independent of the inspector Task lifetime.
        repairTask = Task { await withTaskCancellationHandler { _ = try? await task.value } onCancel: { task.cancel() } }
        defer { if repairRequest == request { repairBusy = false; repairTask = nil } }
        do {
            let candidates = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard repairRequest == request, self.sourceIdentity == sourceIdentity, tool == .repair else { return }
            repairCandidates = candidates; repairSelectedCandidateIDs = Set(candidates.map(\.id))
            repairStatus = "\(candidates.count) Vorschläge. Prüfe die markierten Bereiche vor dem Entfernen."
        } catch is CancellationError { }
        catch { if repairRequest == request { errorMessage = error.localizedDescription } }
    }

    func removeSelectedRepairCandidates(asset: PhotoAsset, editor: EditingModel) async {
        let candidates = repairCandidates.filter { repairSelectedCandidateIDs.contains($0.id) }
        guard !candidates.isEmpty, !repairBusy, tool == .repair, editor.canEdit,
              let bitmap = originalBitmap, let sourceIdentity else { return }
        if repairUsesAI, let first = candidates.first {
            let revision = editor.localRevision(for: asset.id), session = editor.aiEditSessionID
            let request = repairRequest
            do {
                let mask = try await Task.detached { try DevelopRepairMaskUnion.combine(candidates.map(\.mask)) }.value
                try Task.checkCancellation()
                guard repairRequest == request, self.sourceIdentity == sourceIdentity, tool == .repair, editor.canEdit,
                      editor.localRevision(for: asset.id) == revision, editor.aiEditSessionID == session else { return }
                applyRepair(path: [first.center], selection: mask, asset: asset, editor: editor,
                    expectedRevision: revision, expectedSession: session)
            } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
            return
        }
        cancelRepairWork(clearCandidates: false)
        let request = repairRequest, revision = editor.localRevision(for: asset.id), session = editor.aiEditSessionID
        let baseline = editor.settings(for: asset.id)
        repairBusy = true; errorMessage = nil
        let services = repairServices, feather = repairFeather
        let task = Task { () throws -> [DevelopRetouchStroke] in
            var strokes: [DevelopRetouchStroke] = []
            // One cached source actor already bounds CPU work. Serial source
            // searches avoid competing queues and preserve candidate order.
            for candidate in candidates {
                try Task.checkCancellation()
                let source = try await services.source(bitmap, [candidate.center], candidate.radius, candidate.mask)
                strokes.append(try DevelopRetouchStroke(mode: .heal, source: source, target: candidate.center,
                    radius: candidate.radius, feather: feather, path: [candidate.center], mask: candidate.mask))
            }
            try await Self.validateRepairs(strokes, baseline: baseline)
            return strokes
        }
        repairTask = Task { await withTaskCancellationHandler { _ = try? await task.value } onCancel: { task.cancel() } }
        defer { if repairRequest == request { repairBusy = false; repairTask = nil } }
        do {
            let strokes = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard repairRequest == request, self.sourceIdentity == sourceIdentity, tool == .repair,
                  editor.canEdit, editor.localRevision(for: asset.id) == revision, editor.aiEditSessionID == session else { return }
            try appendRepairs(strokes, asset: asset, editor: editor)
            repairCandidates.removeAll { repairSelectedCandidateIDs.contains($0.id) }
            repairSelectedCandidateIDs = []; repairStatus = "\(strokes.count) Bereiche lokal entfernt."
        } catch is CancellationError { }
        catch { if repairRequest == request { errorMessage = error.localizedDescription } }
    }

    private func appendRepairs(_ strokes: [DevelopRetouchStroke], asset: PhotoAsset, editor: EditingModel) throws {
        var settings = editor.settings(for: asset.id)
        settings.developGeometry.retouchStrokes.append(contentsOf: strokes)
        settings = settings.normalized
        _ = try EditingSnapshot(settings: settings)
        editor.endEditing(assetID: asset.id)
        editor.setSettings(settings, for: asset.id)
        guard editor.settings(for: asset.id) == settings else { throw ArtifactContractError.staleSnapshot }
        errorMessage = nil
    }

    nonisolated private static func validateRepairs(_ strokes: [DevelopRetouchStroke], baseline: EditSettings) async throws {
        // Encoding a frozen RGB patch can approach the snapshot's 4 MiB limit.
        // Check the exact durable payload off MainActor before accepting the edit.
        try await Task.detached {
            try Task.checkCancellation()
            var settings = baseline
            settings.developGeometry.retouchStrokes.append(contentsOf: strokes)
            _ = try ArtifactJSONCodec.encode(EditingSnapshot(settings: settings.normalized))
        }.value
    }

    func canTryAnotherRepairSource(asset: PhotoAsset, editor: EditingModel) -> Bool {
        tool == .repair && isOriginalCanvasReady && editor.canEdit && !repairBusy
            && editor.settings(for: asset.id).developGeometry.retouchStrokes.last.map {
                $0.mode == .heal && $0.replacement == nil
            } == true
    }

    /// Replace the last accepted repair in place. Each source choice is its own
    /// undo step; the frozen selection and decoded source stay unchanged.
    func tryAnotherRepairSource(asset: PhotoAsset, editor: EditingModel) {
        guard canTryAnotherRepairSource(asset: asset, editor: editor),
              let stroke = editor.settings(for: asset.id).developGeometry.retouchStrokes.last,
              let bitmap = originalBitmap, let sourceIdentity else { return }
        let excluded = repairTriedSourceStrokeID == stroke.id ? repairTriedSources : [stroke.source]
        guard excluded.count < 16 else {
            errorMessage = "Bereits 16 Quellen geprüft. Wähle mit ⌥-Klick eine eigene Quelle für eine neue Reparatur."
            return
        }
        cancelRepairWork(clearCandidates: false)
        let request = repairRequest, revision = editor.localRevision(for: asset.id), session = editor.aiEditSessionID
        let services = repairServices
        var baseline = editor.settings(for: asset.id)
        baseline.developGeometry.retouchStrokes.removeLast()
        let path = stroke.path.isEmpty ? [stroke.target] : stroke.path
        repairBusy = true; errorMessage = nil
        repairTask = Task { [weak self, weak editor] in
            defer { if let self, self.repairRequest == request { self.repairBusy = false; self.repairTask = nil } }
            do {
                let source = try await services.nextSource(bitmap, path, stroke.radius, stroke.mask, excluded)
                try Task.checkCancellation()
                let next = try DevelopRetouchStroke(id: stroke.id, mode: stroke.mode, source: source,
                    target: stroke.target, radius: stroke.radius, feather: stroke.feather, opacity: stroke.opacity,
                    path: stroke.path, mask: stroke.mask)
                try await Self.validateRepairs([next], baseline: baseline)
                try Task.checkCancellation()
                guard let self, let editor, self.repairRequest == request, self.sourceIdentity == sourceIdentity,
                      self.tool == .repair, editor.canEdit,
                      editor.settings(for: asset.id).developGeometry.retouchStrokes.last == stroke,
                      editor.localRevision(for: asset.id) == revision, editor.aiEditSessionID == session else { return }
                var settings = baseline
                settings.developGeometry.retouchStrokes.append(next)
                editor.endEditing(assetID: asset.id)
                editor.setSettings(settings, for: asset.id)
                guard editor.settings(for: asset.id) == settings else { return }
                self.repairTriedSourceStrokeID = stroke.id
                self.repairTriedSources = excluded + [source]
                self.repairStatus = "Andere Quelle aktiv. Mit ⌘Z zur vorherigen Quelle zurückkehren."
            } catch is CancellationError { }
            catch { if let self, self.repairRequest == request { self.errorMessage = error.localizedDescription } }
        }
    }

    func refreshRepairAIAvailability() async {
        do {
            let installation = try await repairAIStore.installedModel()
            try Task.checkCancellation()
            repairAIReady = installation != nil; repairAIModelName = installation?.displayName
            if installation == nil { repairUsesAI = false }
        } catch is CancellationError { }
        catch { repairAIReady = false; repairUsesAI = false; errorMessage = error.localizedDescription }
    }

    func importRepairAIModel(from url: URL) async {
        guard !repairBusy else { return }
        cancelRepairWork(); repairBusy = true; errorMessage = nil
        let request = repairRequest
        defer { if repairRequest == request { repairBusy = false } }
        do {
            let installation = try await repairAIStore.importModel(from: url)
            try Task.checkCancellation()
            guard repairRequest == request, tool == .repair else { return }
            repairAIReady = true; repairAIModelName = installation.displayName; repairUsesAI = true
            repairStatus = "Lokales Modell eingerichtet. Markiere einen kleinen Bereich für eine KI-Reparatur."
        } catch is CancellationError { }
        catch { if repairRequest == request { errorMessage = error.localizedDescription } }
    }

    func refreshRepairVisualization() {
        repairSpotTask?.cancel(); repairSpotTask = nil
        guard tool == .repair, repairVisualizesSpots, let bitmap = repairDisplayBitmap else {
            repairSpotImage = nil; return
        }
        let imageID = ObjectIdentifier(bitmap.image), threshold = repairSpotThreshold, source = sourceIdentity
        repairSpotTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(40))
                let image = try await DevelopRepairSpotVisualizer.shared.image(bitmap, sensitivity: threshold)
                try Task.checkCancellation()
                guard let self, self.tool == .repair, self.repairVisualizesSpots,
                      self.sourceIdentity == source, self.repairSpotThreshold == threshold,
                      self.repairDisplayBitmap.map({ ObjectIdentifier($0.image) }) == imageID else { return }
                self.repairSpotImage = image
            } catch { }
        }
    }
}
