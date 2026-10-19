import AppKit
import SwiftUI

enum WorkspaceControlFocus: Hashable {
    case focus, library, tools, filmstrip
    case tool(WorkspaceTool)
    case group(WorkspaceTool)
    case adjustmentGroup(String)
}

struct WorkspacePanelVisibility: Equatable {
    let isFocused: Bool
    let showsLibrary: Bool
    let showsTools: Bool
    let showsFilmstrip: Bool
}

enum WorkspaceFocusRouting {
    static func target(previous: WorkspacePanelVisibility, current: WorkspacePanelVisibility,
                       revealedTool: WorkspaceTool?, hasSelection: Bool) -> WorkspaceControlFocus? {
        if previous.isFocused != current.isFocused {
            return current.isFocused || hasSelection ? .focus : .library
        }
        if previous.showsLibrary && !current.showsLibrary {
            if !current.isFocused { return .library }
            guard hasSelection else { return .focus }
            let navigationTool = revealedTool.flatMap { $0.isNavigationTool ? $0 : nil } ?? .assistant
            return .tool(navigationTool)
        }
        if previous.showsTools && !current.showsTools {
            return current.isFocused ? (hasSelection ? .tool(.edit) : .focus) : .tools
        }
        if previous.showsFilmstrip && !current.showsFilmstrip { return .filmstrip }
        return nil
    }
}

extension View {
    /// Return targets must accept programmatic focus even when macOS Keyboard
    /// Navigation is off. Give their explicit focus item normal button activation.
    func workspaceFocusTarget(_ binding: FocusState<WorkspaceControlFocus?>.Binding,
                              equals target: WorkspaceControlFocus,
                              action: @escaping () -> Void) -> some View {
        focusable(interactions: [.edit, .activate])
            .focused(binding, equals: target)
            .onKeyPress(keys: [.space, .return], phases: .down) { key in
                guard key.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                action()
                return .handled
            }
    }
}

/// Presentation commands never create edits, cancel proposals or start analysis.
@MainActor
enum WorkspaceActions {
    static func toggleFocus(_ layout: WorkspaceLayoutModel, library: LibraryModel) {
        finishField()
        if layout.isFocused {
            let origin = layout.leaveFocus()
            library.isDeveloping = origin.developing
            library.showsDetail = origin.showsDetail && library.selectedAsset != nil
        } else {
            guard library.selectedAsset != nil else { return }
            layout.enterFocus(developing: library.isDeveloping, showsDetail: library.showsDetail)
            library.isDeveloping = true
            library.showsDetail = true
        }
    }

    static func reveal(_ tool: WorkspaceTool, layout: WorkspaceLayoutModel, library: LibraryModel) {
        finishField()
        guard library.selectedAsset != nil else { return }
        library.isDeveloping = true
        library.showsDetail = true
        layout.reveal(tool, developing: true)
    }

    static func toggleLibrary(_ layout: WorkspaceLayoutModel, library: LibraryModel) {
        finishField()
        layout.update(developing: library.isDeveloping) { $0.showsLibrary.toggle() }
    }

    static func toggleTools(_ layout: WorkspaceLayoutModel, library: LibraryModel) {
        finishField()
        layout.update(developing: library.isDeveloping) { $0.showsTools.toggle() }
    }

    static func toggleFilmstrip(_ layout: WorkspaceLayoutModel, library: LibraryModel) {
        finishField()
        layout.update(developing: library.isDeveloping) { $0.showsFilmstrip.toggle() }
    }

    static func showGrid(_ layout: WorkspaceLayoutModel, library: LibraryModel) {
        finishField()
        if layout.isFocused { layout.leaveFocus() }
        library.isDeveloping = false
        library.showsDetail = false
    }

    static func finishField() { NSApp?.keyWindow?.makeFirstResponder(nil) }
}

struct WorkspaceViewCommands: View {
    @ObservedObject var layout: WorkspaceLayoutModel
    @ObservedObject var library: LibraryModel
    var shortcuts = false

    var body: some View {
        Button(layout.isFocused ? "Zur vorherigen Ansicht" : "Bildfokus") {
            WorkspaceActions.toggleFocus(layout, library: library)
        }.keyboardShortcut(shortcuts ? KeyboardShortcut("f", modifiers: [.command, .shift]) : nil)
            .disabled(!layout.isFocused && library.selectedAsset == nil)
        Divider()
        Button(leftPanelTitle + (layout.panels(developing: library.isDeveloping).showsLibrary ? " ausblenden" : " einblenden")) {
            WorkspaceActions.toggleLibrary(layout, library: library)
        }.keyboardShortcut(shortcuts ? KeyboardShortcut("l", modifiers: [.command, .option]) : nil)
        Button(layout.panels(developing: library.isDeveloping).showsTools ? "Werkzeuge ausblenden" : "Werkzeuge einblenden") {
            WorkspaceActions.toggleTools(layout, library: library)
        }.keyboardShortcut(shortcuts ? KeyboardShortcut("i", modifiers: .command) : nil)
        Button(layout.panels(developing: library.isDeveloping).showsFilmstrip ? "Filmstreifen ausblenden" : "Filmstreifen einblenden") {
            WorkspaceActions.toggleFilmstrip(layout, library: library)
        }.keyboardShortcut(shortcuts ? KeyboardShortcut("s", modifiers: [.command, .option]) : nil)
        if shortcuts {
            Divider()
            ForEach(WorkspaceTool.allCases) { tool in
                Button(tool.title) { WorkspaceActions.reveal(tool, layout: layout, library: library) }
                    .disabled(library.selectedAsset == nil)
            }
        }
        Divider()
        Button("Darstellung merken") { layout.remember() }
        Button("Standardansicht wiederherstellen") {
            WorkspaceActions.finishField()
            layout.reset(developing: library.isDeveloping)
        }
    }

    private var leftPanelTitle: String { library.isDeveloping ? "Navigation" : "Bibliothek" }
}

struct WorkspaceDock: View {
    @ObservedObject var layout: WorkspaceLayoutModel
    @ObservedObject var library: LibraryModel
    var focusedControl: FocusState<WorkspaceControlFocus?>.Binding
    private var panels: WorkspacePanels { layout.panels(developing: library.isDeveloping) }

    var body: some View {
        HStack(spacing: 6) {
            dockButton("Navigation", symbol: "sidebar.left", active: panels.showsLibrary) {
                WorkspaceActions.toggleLibrary(layout, library: library)
            }.workspaceFocusTarget(focusedControl, equals: .library) {
                WorkspaceActions.toggleLibrary(layout, library: library)
            }
            dockButton("Filmstreifen", symbol: "film", active: panels.showsFilmstrip) {
                WorkspaceActions.toggleFilmstrip(layout, library: library)
            }.workspaceFocusTarget(focusedControl, equals: .filmstrip) {
                WorkspaceActions.toggleFilmstrip(layout, library: library)
            }
            if !hiddenTools.isEmpty { Divider().frame(height: 22) }
            ForEach(hiddenTools) { tool in
                dockButton(tool.dockTitle, symbol: tool.symbol, active: false) {
                    WorkspaceActions.reveal(tool, layout: layout, library: library)
                }.workspaceFocusTarget(focusedControl, equals: .tool(tool)) {
                    WorkspaceActions.reveal(tool, layout: layout, library: library)
                }
                    .disabled(library.selectedAsset == nil)
            }
            Spacer(minLength: 0)
            if panels.showsTools {
                Button { WorkspaceActions.toggleTools(layout, library: library) } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 32)
                }.help("Werkzeuge schließen").accessibilityLabel("Werkzeuge schließen")
            }
        }.font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
            .padding(.horizontal, 16).frame(height: 50)
            .background(Theme.chrome)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var hiddenTools: [WorkspaceTool] {
        WorkspaceTool.allCases.filter { $0.isNavigationTool ? !panels.showsLibrary : !panels.showsTools }
    }

    private func dockButton(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).padding(.horizontal, 6).frame(minHeight: 32) }
            .foregroundStyle(active ? Theme.accent : Theme.muted)
            .background(active ? Theme.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .help(title).accessibilityLabel(title)
            .accessibilityValue(active ? "Geöffnet" : "Geschlossen")
    }
}

/// Dragging is a short MainActor preference update. Image decoding/rendering stays in its existing pipeline.
struct WorkspaceResizeHandle: View {
    let horizontal: Bool
    let label: String
    let value: Double
    let step: Double
    let change: (Double) -> Void
    @ViewState private var dragStart: Double?

    var body: some View {
        Rectangle().fill(Theme.line)
            .frame(width: horizontal ? 7 : nil, height: horizontal ? nil : 7)
            .overlay {
                Capsule().fill(Theme.muted.opacity(0.65))
                    .frame(width: horizontal ? 2 : 32, height: horizontal ? 32 : 2)
            }.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { event in
                if dragStart == nil { dragStart = value }
                change((dragStart ?? value) + (horizontal ? event.translation.width : -event.translation.height) * step)
            }.onEnded { _ in dragStart = nil })
            .accessibilityElement().accessibilityLabel(label)
            .accessibilityValue("\(Int(value)) Punkte")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: change(value + 10)
                case .decrement: change(value - 10)
                @unknown default: break
                }
            }
    }
}

private extension WorkspaceTool {
    var dockTitle: String {
        switch self {
        case .edit: return "Bearbeiten"
        case .assistant: return "Assistent & Looks"
        case .analysis: return "Analyse"
        case .metadata: return "Informationen"
        case .versions: return "Bildstände"
        }
    }
}
