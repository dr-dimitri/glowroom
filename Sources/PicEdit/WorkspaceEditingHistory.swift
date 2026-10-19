import SwiftUI

/// A function is selected explicitly. Hiding a panel, saving or comparing the
/// original does not start another history. All sliders share adjustments.
enum EditingFunction: Equatable {
    case adjustments, crop, repair, redEye, masks, assistant, analysis, metadata, versions

    init(_ tool: DevelopCanvasTool) {
        switch tool {
        case .basic: self = .adjustments
        case .crop: self = .crop
        case .repair: self = .repair
        case .redEye: self = .redEye
        case .masks: self = .masks
        }
    }

    init(_ tool: WorkspaceTool) {
        switch tool {
        case .edit: self = .adjustments
        case .assistant: self = .assistant
        case .analysis: self = .analysis
        case .metadata: self = .metadata
        case .versions: self = .versions
        }
    }
}

/// Menus and keyboard input use the same active history, including local masks.
struct WorkspaceEditingHistory {
    let canUndo: Bool
    let canRedo: Bool
    let undo: () -> Void
    let redo: () -> Void
    let canReset: Bool
    let reset: () -> Void
    let allowsComparison: Bool
}

private struct WorkspaceEditingHistoryKey: FocusedValueKey {
    typealias Value = WorkspaceEditingHistory
}

extension FocusedValues {
    var editingHistory: WorkspaceEditingHistory? {
        get { self[WorkspaceEditingHistoryKey.self] }
        set { self[WorkspaceEditingHistoryKey.self] = newValue }
    }
}
