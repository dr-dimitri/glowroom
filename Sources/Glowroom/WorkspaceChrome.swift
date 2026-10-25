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
            let navigationTool = revealedTool.flatMap { $0.isNavigationTool ? $0 : nil } ?? .metadata
            return .tool(navigationTool)
        }
        if previous.showsTools && !current.showsTools {
            guard current.isFocused else { return .tools }
            let adjustmentTool = revealedTool.flatMap { $0.isNavigationTool ? nil : $0 } ?? .edit
            return hasSelection || adjustmentTool == .aiDevelopment ? .tool(adjustmentTool) : .focus
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

/// Presentation commands never start analysis. Hidden correction views cancel
/// unaccepted proposals; accepted edits remain owned by the shared editor.
@MainActor
enum WorkspaceActions {
    static func toggleFocus(_ layout: WorkspaceLayoutModel, library: LibraryModel) {
        finishField()
        if layout.isFocused {
            let origin = layout.leaveFocus()
            library.workspaceMode = origin.developing ? .develop : .library
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
        guard library.selectedAsset != nil || tool == .edit || tool == .aiDevelopment else { return }
        if tool == .metadata, !library.isDeveloping, !layout.isFocused {
            layout.reveal(tool, developing: false)
            return
        }
        library.workspaceMode = .develop
        library.showsDetail = library.selectedAsset != nil
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
                    .disabled(library.selectedAsset == nil && tool != .edit && tool != .aiDevelopment)
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
                    .disabled(library.selectedAsset == nil && tool != .edit && tool != .aiDevelopment)
            }
            Spacer(minLength: 0)
            if panels.showsTools {
                Button { WorkspaceActions.toggleTools(layout, library: library) } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 32)
                }.help("Werkzeuge schließen").accessibilityLabel("Werkzeuge schließen")
            }
        }.font(.system(size: 13, weight: .medium)).buttonStyle(.plain)
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

/// Window coordinates stay fixed when the handle moves under the pointer.
struct WorkspaceResizeHandle: View {
    let horizontal: Bool
    let label: String
    let value: Double
    let step: Double
    var begin: () -> Void = {}
    var end: (Bool) -> Void = { _ in }
    var adjust: ((Double) -> Void)? = nil
    let change: (Double) -> Void

    var body: some View {
        Rectangle().fill(Theme.line)
            .frame(width: horizontal ? 7 : nil, height: horizontal ? nil : 7)
            .overlay {
                Capsule().fill(Theme.muted.opacity(0.65))
                    .frame(width: horizontal ? 2 : 32, height: horizontal ? 32 : 2)
            }.overlay {
                WorkspaceResizeInput(horizontal: horizontal, value: value, step: step,
                                     begin: begin, change: change, end: end)
            }
            .accessibilityElement().accessibilityLabel(label)
            .accessibilityValue("\(Int(value)) Punkte")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: (adjust ?? change)(value + 10)
                case .decrement: (adjust ?? change)(value - 10)
                @unknown default: break
                }
            }
    }
}

private struct WorkspaceResizeInput: NSViewRepresentable {
    let horizontal: Bool
    let value: Double
    let step: Double
    let begin: () -> Void
    let change: (Double) -> Void
    let end: (Bool) -> Void

    func makeNSView(context: Context) -> WorkspaceResizeInputView { WorkspaceResizeInputView() }

    func updateNSView(_ view: WorkspaceResizeInputView, context: Context) {
        view.horizontal = horizontal
        view.value = value
        view.step = step
        view.begin = begin
        view.change = change
        view.end = end
    }
}

/// Native event delivery avoids a gesture's moving local coordinate system.
/// Only tiny geometry updates run here; image work retains its background lanes.
final class WorkspaceResizeInputView: NSView {
    var horizontal = true
    var value = 0.0
    var step = 1.0
    var begin: () -> Void = {}
    var change: (Double) -> Void = { _ in }
    var end: (Bool) -> Void = { _ in }

    private struct Drag {
        let origin: NSPoint
        let value: Double
        let horizontal: Bool
        let step: Double
        let change: (Double) -> Void
        let end: (Bool) -> Void
    }
    private var drag: Drag?
    private let menus = WorkspaceMenuTracking()

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard drag == nil else { return }
        window?.makeFirstResponder(self)
        drag = Drag(origin: event.locationInWindow, value: value, horizontal: horizontal,
                    step: step, change: change, end: end)
        begin()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let translation = drag.horizontal ? event.locationInWindow.x - drag.origin.x
            : event.locationInWindow.y - drag.origin.y
        drag.change(drag.value + translation * drag.step)
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        mouseDragged(with: event)
        self.drag = nil
        drag.end(true)
    }

    override func cancelOperation(_ sender: Any?) {
        let previous = drag
        drag = nil
        previous?.end(false)
    }

    func processKeyEvent(_ event: NSEvent) -> Bool {
        guard drag != nil, event.type == .keyDown, event.keyCode == 53, !menus.isTracking,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        cancelOperation(nil)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !processKeyEvent(event) { super.keyDown(with: event) }
    }

    @objc private func windowResigned(_ notification: Notification) { cancelOperation(nil) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Removing the handle cancels its local preview. Never call a stale
        // commit closure while SwiftUI is replacing the workspace hierarchy.
        if newWindow !== window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
            drag = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned(_:)),
                name: NSWindow.didResignKeyNotification, object: window)
        }
    }
}

private extension WorkspaceTool {
    var dockTitle: String {
        switch self {
        case .edit: return "Licht"
        case .color: return "Farbe"
        case .details: return "Details"
        case .aiDevelopment: return "KI-Korrektur"
        case .metadata: return "Bildinformationen"
        case .versions: return "Bildstände"
        }
    }
}
