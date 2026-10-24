import SwiftUI

/// A function is selected explicitly. Hiding a panel, saving or comparing the
/// original does not start another history. All sliders share adjustments.
enum EditingFunction: Equatable {
    case adjustments, crop, repair, masks, metadata, versions

    init(_ tool: DevelopCanvasTool) {
        switch tool {
        case .basic: self = .adjustments
        case .crop: self = .crop
        // Canvas input differs; all four repair modes share one undo history.
        case .repair, .redEye: self = .repair
        case .masks: self = .masks
        }
    }

    init(_ tool: WorkspaceTool) {
        switch tool {
        case .edit, .color, .details, .aiDevelopment: self = .adjustments
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

/// The full workspace owns the single visible history pair. Standalone mask
/// palettes keep their own controls when they have no workspace history host.
private struct UsesWorkspaceEditingHistoryKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usesWorkspaceEditingHistory: Bool {
        get { self[UsesWorkspaceEditingHistoryKey.self] }
        set { self[UsesWorkspaceEditingHistoryKey.self] = newValue }
    }
}
