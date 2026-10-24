import AppKit
import GlowroomCore

/// A native independent mouseDown confirms the preceding point click. Only
/// the latest undecided click belongs to a possible double click. Commands
/// run serially because every accepted repair changes the next baseline.
@MainActor
final class DevelopRepairInputQueue {
    static let maximumCommands = 32
    private struct Command {
        let path: [LocalMaskPoint]
        let selectsSource: Bool
        let brush: DevelopRepairBrush
    }
    private var commands: [Command] = []
    private var pending: Command?
    private var timer: Task<Void, Never>?
    private var runner: Task<Void, Never>?
    private var generation = UUID()
    private weak var workspace: DevelopWorkspace?
    private weak var editor: EditingModel?
    private var asset: PhotoAsset?
    private var source: AISourceIdentity?
    private var session: UUID?
    private var request: UUID?
    private var revision: Int64?

    var isProcessing: Bool { runner != nil }
    var hasScheduledSource: Bool { pending?.selectsSource == true || commands.contains { $0.selectsSource } }

    func isCurrent(asset: PhotoAsset, workspace: DevelopWorkspace, editor: EditingModel) -> Bool {
        self.asset?.id == asset.id && source == workspace.sourceIdentity && session == editor.aiEditSessionID
            && request == workspace.repairRequest && revision == editor.localRevision(for: asset.id)
            && workspace.tool == .repair && workspace.isOriginalCanvasReady && editor.canEdit
    }

    func begin(asset: PhotoAsset, workspace: DevelopWorkspace, editor: EditingModel) -> Bool {
        if runner == nil && commands.isEmpty && pending == nil {
            self.asset = asset; self.workspace = workspace; self.editor = editor
            source = workspace.sourceIdentity; session = editor.aiEditSessionID
            revision = editor.localRevision(for: asset.id); request = workspace.repairRequest
        }
        guard isCurrent(asset: asset, workspace: workspace, editor: editor) else { cancel(); return false }
        confirmPending()
        return true
    }

    func submit(path: [LocalMaskPoint], selectsSource: Bool, brush: DevelopRepairBrush, pointClick: Bool) {
        guard let workspace, let editor, let asset,
              isCurrent(asset: asset, workspace: workspace, editor: editor) else { cancel(); return }
        guard commands.count + (runner == nil ? 0 : 1) + (pending == nil ? 0 : 1) < Self.maximumCommands else {
            workspace.errorMessage = "Die Reparaturwarteschlange ist voll. Warte auf die laufenden Reparaturen und wiederhole diesen Pinselzug."
            return
        }
        let command = Command(path: path, selectsSource: selectsSource, brush: brush)
        if pointClick {
            pending = command
            timer = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                    try Task.checkCancellation()
                    self?.confirmPending()
                } catch { }
            }
        } else {
            commands.append(command); startNext()
        }
    }

    func cancelPending() {
        timer?.cancel(); timer = nil; pending = nil
    }

    func cancel(cancelWorker: Bool = true) {
        generation = UUID(); cancelPending(); commands.removeAll()
        if cancelWorker, runner != nil, let workspace, request == workspace.repairRequest {
            workspace.cancelRepairWork(clearCandidates: false, preservingInputQueue: true)
        }
        runner?.cancel(); runner = nil
        asset = nil; revision = nil; request = nil
    }

    private func confirmPending() {
        timer?.cancel(); timer = nil
        if let pending { commands.append(pending); self.pending = nil }
        startNext()
    }

    private func startNext() {
        guard runner == nil else { return }
        guard let workspace, let editor, let asset, let session,
              isCurrent(asset: asset, workspace: workspace, editor: editor) else { cancel(); return }
        while !commands.isEmpty {
            let command = commands.removeFirst()
            if command.selectsSource {
                workspace.repairSource = command.path.first; workspace.errorMessage = nil
                workspace.repairChoosesSource = false
                continue
            }
            let token = generation
            var accepted = false
            workspace.applyRepair(path: command.path, asset: asset, editor: editor,
                expectedRevision: editor.localRevision(for: asset.id), expectedSession: session,
                brush: command.brush, preservingInputQueue: true, onAccepted: { [weak self, weak editor] in
                    guard let self, self.generation == token, let editor else { return }
                    // Only this command may advance the queue's revision. An
                    // Undo or unrelated edit must never rebase later commands.
                    self.revision = editor.localRevision(for: asset.id); accepted = true
                })
            request = workspace.repairRequest
            guard let operation = workspace.repairTask else { cancel(); return }
            runner = Task { [weak self] in
                await operation.value
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.runner = nil
                guard accepted, self.isCurrent(asset: asset, workspace: workspace, editor: editor) else {
                    self.cancel(); return
                }
                self.startNext()
            }
            return
        }
    }
}
