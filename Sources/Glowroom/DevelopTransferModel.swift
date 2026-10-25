import AppKit
import Combine
import Foundation
import GlowroomCore

/// A value-only address: selection changes do not retarget a planned write.
struct DevelopTransferTarget: Sendable {
    let assetID: String
    let snapshot: EditingSnapshot
    let revision: Int64
    let sessionID: UUID
    let storeEpoch: UUID
}

struct DevelopTransferReceipt: Equatable, Sendable {
    let assetID: String
    let revision: Int64
    let sessionID: UUID
    let storeEpoch: UUID
}

enum DevelopTransferCommitResult: Sendable {
    case changed(DevelopTransferReceipt)
    case unchanged
    case skipped(String)
    case failed(String)
    case cancelled
}

/// Owns one frozen, finite job per editor. No image service is involved: all
/// preparation is small settings values, and dependent writes stay ordered.
@MainActor
final class DevelopTransferModel: ObservableObject {
    enum Status: Equatable {
        case ready, running, changed, unchanged, skipped(String), failed(String), cancelled
        var title: String {
            switch self {
            case .ready: "Bereit"
            case .running: "Wird gespeichert"
            case .changed: "Übernommen"
            case .unchanged: "Unverändert"
            case .skipped(let reason): "Übersprungen: \(reason)"
            case .failed(let reason): "Fehlgeschlagen: \(reason)"
            case .cancelled: "Abgebrochen"
            }
        }
        var kind: Int {
            switch self {
            case .ready: 0
            case .running: 1
            case .changed: 2
            case .unchanged: 3
            case .skipped: 4
            case .failed: 5
            case .cancelled: 6
            }
        }
    }
    struct Row: Identifiable {
        let id: String
        let name: String
        let changesHistoryFunction: Bool
        var status: Status
        var receipt: DevelopTransferReceipt?
    }
    private struct Plan {
        let asset: PhotoAsset
        let target: DevelopTransferTarget
    }
    private struct CopiedSource {
        let asset: PhotoAsset
        let patch: DevelopSettingsPatch
    }
    static let maximumTargets = 10_000
    @Published var isPresented = false
    @Published var groups = Set(DevelopPresetGroup.allCases)
    @Published private(set) var rows: [Row] = []
    @Published private(set) var sourceName = ""
    @Published private(set) var isRunning = false
    @Published private(set) var isPreparing = false
    @Published private(set) var didFinish = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasCopiedSettings = false
    private weak var editor: EditingModel?
    private var copied: CopiedSource?
    private var patch: DevelopSettingsPatch?
    private var plans: [Plan?] = []
    private var sourceIsCurrent: @MainActor (PhotoAsset) -> Bool = { _ in true }
    private var task: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var preparationID = UUID()
    private var cancellationRequested = false
    private var editorChanges: AnyCancellable?
    private var statusCounts = [Int](repeating: 0, count: 7)

    init(editor: EditingModel) {
        self.editor = editor
        editorChanges = editor.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    var readyCount: Int { statusCounts[0] }
    var changedCount: Int { statusCounts[2] }
    var unchangedCount: Int { statusCounts[3] }
    var skippedCount: Int { statusCounts[4] }
    var failedCount: Int { statusCounts[5] }
    var cancelledCount: Int { statusCounts[6] }
    var canStart: Bool { !isPreparing && !isRunning && !didFinish && readyCount > 0 && !groups.isEmpty && editor?.canEdit == true }

    /// Ends native entry before copying. The portable patch contains only the
    /// four groups; the source label is retained separately for the dialog.
    func copy(library: LibraryModel) {
        guard !isRunning, let editor, editor.developCommands.availability(in: library, permitsActiveInput: true).isAvailable,
              let source = library.selectedAsset else { return }
        NSApp?.keyWindow?.makeFirstResponder(nil)
        ResettableNativeSlider.cancelInputs(in: NSApp?.keyWindow?.contentView)
        editor.endEditing(assetID: source.id)
        do {
            copied = CopiedSource(asset: source, patch: try .init(settings: editor.settings(for: source.id), groups: Set(DevelopPresetGroup.allCases)))
            hasCopiedSettings = true
            editor.notice = "Einstellungen von „\(source.fileName)“ kopiert."
        } catch { editor.errorMessage = error.localizedDescription }
    }

    func present(library: LibraryModel) {
        guard !isRunning, !isPresented, let editor,
              editor.developCommands.availability(in: library, permitsActiveInput: true).isAvailable else { return }
        NSApp?.keyWindow?.makeFirstResponder(nil)
        ResettableNativeSlider.cancelInputs(in: NSApp?.keyWindow?.contentView)
        if let id = library.selectedID { editor.endEditing(assetID: id) }
        let source: PhotoAsset
        let value: DevelopSettingsPatch
        do {
            if let copied { source = copied.asset; value = copied.patch }
            else {
                guard let active = library.selectedAsset else { return }
                source = active
                value = try .init(settings: editor.settings(for: source.id), groups: Set(DevelopPresetGroup.allCases))
            }
        } catch { editor.errorMessage = error.localizedDescription; return }
        // Membership/source identity comes from the existing indexed catalog
        // lookup. Ratings and selection changes are irrelevant to this check.
        let validator: @MainActor (PhotoAsset) -> Bool = { [weak library] asset in
            guard let context = library?.photoMetadataSelectionContext(for: asset.id), context.canModify else { return false }
            return context.source == AIOriginalSourceFingerprint(fileURL: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize)
        }
        prepare(source: source, patch: value, targets: library.selectedAssets, sourceIsCurrent: validator)
    }

    /// Also used by deterministic tests with synthetic catalog entries.
    func prepare(source: PhotoAsset, patch: DevelopSettingsPatch, targets: [PhotoAsset],
                 sourceIsCurrent: @escaping @MainActor (PhotoAsset) -> Bool = { _ in true }) {
        guard !isRunning, let editor else { return }
        let targets = targets.filter { $0.id != source.id }
        guard targets.count <= Self.maximumTargets else {
            editor.errorMessage = "Bitte höchstens \(Self.maximumTargets) Zielfotos auf einmal auswählen."; return
        }
        self.patch = patch; self.sourceIsCurrent = sourceIsCurrent
        sourceName = source.fileName; groups = patch.groups
        preparationTask?.cancel()
        let preparationID = UUID(); self.preparationID = preparationID
        rows = []; plans = []; didFinish = false; cancellationRequested = false; errorMessage = nil
        statusCounts = [Int](repeating: 0, count: 7)
        isPreparing = true
        var seen: Set<String> = []
        // One synchronous pass captures immutable references and revision IDs
        // before any yield, so all target identities describe the same moment.
        // It does no file access, settings encoding, raster copy or rendering.
        for asset in targets where seen.insert(asset.id).inserted {
            let token = editor.transferTarget(assetID: asset.id)
            rows.append(Row(id: asset.id, name: asset.fileName,
                changesHistoryFunction: editor.editingFunction(assetID: asset.id) != .adjustments,
                status: token == nil ? .skipped("Bearbeitung gesperrt") : .ready))
            statusCounts[rows[rows.count - 1].status.kind] += 1
            plans.append(token.map { Plan(asset: asset, target: $0) })
        }
        isPresented = true
        preparationTask = Task { [self] in
            defer {
                if self.preparationID == preparationID { isPreparing = false; preparationTask = nil }
            }
            for index in rows.indices {
                guard !Task.isCancelled, self.preparationID == preparationID else { return }
                if let plan = plans[index] {
                    let reason: String?
                    if !sourceIsCurrent(plan.asset) { reason = "Bildquelle oder Katalog gesperrt" }
                    else if plan.target.snapshot.settings.toneProcessingVersion != patch.toneProcessingVersion { reason = "Andere Prozessversion" }
                    else { reason = nil }
                    if let reason { setStatus(.skipped(reason), at: index); plans[index] = nil }
                }
                if index.isMultiple(of: 32) { await Task.yield() }
            }
        }
    }

    func start() {
        guard canStart, let editor, let patch else { return }
        let selected: DevelopSettingsPatch
        do { selected = try patch.selecting(groups) }
        catch { errorMessage = error.localizedDescription; return }
        let jobID = UUID()
        guard editor.beginTransferJob(id: jobID) else {
            errorMessage = "Es läuft bereits eine Übertragung für diese Mediathek."; return
        }
        isRunning = true; cancellationRequested = false
        // The job is owned here, not by the sheet's .task or the caller. Dismiss
        // and cancellation stop future admissions; accepted writes finish.
        task = Task { [self, editor] in
            defer {
                isRunning = false; didFinish = true; task = nil; plans.removeAll()
                editor.finishTransferJob(id: jobID, didSave: changedCount > 0)
            }
            for index in rows.indices {
                guard rows[index].status == .ready, let plan = plans[index] else { continue }
                if cancellationRequested {
                    setStatus(.cancelled, at: index); plans[index] = nil; continue
                }
                if !sourceIsCurrent(plan.asset) {
                    setStatus(.skipped("Bildquelle oder Katalog geändert"), at: index); plans[index] = nil; continue
                }
                setStatus(.running, at: index)
                let result = await editor.commitTransfer(selected, target: plan.target) { [weak self] in
                    guard let self, !cancellationRequested else { return .cancelled }
                    return sourceIsCurrent(plan.asset) ? nil : .skipped("Bildquelle oder Katalog geändert")
                }
                switch result {
                case .changed(let receipt): setStatus(.changed, at: index); rows[index].receipt = receipt
                case .unchanged: setStatus(.unchanged, at: index)
                case .skipped(let reason): setStatus(.skipped(reason), at: index)
                case .failed(let reason): setStatus(.failed(reason), at: index)
                case .cancelled: setStatus(.cancelled, at: index)
                }
                // Release the old snapshot immediately. Results retain only a
                // tiny receipt, so they cannot bypass the shared history budget.
                plans[index] = nil
                // Independent rendering/UI work can proceed between ordered
                // commits. No unbounded worker pool or per-photo decoder tasks.
                await Task.yield()
            }
        }
    }
    func cancel() { cancellationRequested = true }
    func createBackup() {
        guard !isRunning, let editor, editor.canBackUp else { return }
        Task { _ = await editor.createBackup() }
    }
    func waitUntilFinished() async { await task?.value }
    func waitUntilPrepared() async { await preparationTask?.value }
    func dismiss() {
        guard !isRunning else { return }
        preparationTask?.cancel(); preparationTask = nil; preparationID = UUID(); isPreparing = false
        isPresented = false; plans.removeAll(); patch = nil
    }
    func presentationDidClose() {
        if isRunning { cancel(); isPresented = false }
        else { dismiss() }
    }
    func canUndo(_ row: Row) -> Bool {
        guard row.status == .changed, let receipt = row.receipt else { return false }
        return editor?.canUndoTransfer(receipt) == true
    }
    func undo(_ row: Row) {
        guard canUndo(row), let editor else { return }
        editor.undo(assetID: row.id)
        objectWillChange.send()
    }
    private func setStatus(_ status: Status, at index: Int) {
        statusCounts[rows[index].status.kind] -= 1
        rows[index].status = status
        statusCounts[status.kind] += 1
    }
}
