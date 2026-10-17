import AppKit
import SwiftUI

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
        Button(layout.panels(developing: library.isDeveloping).showsLibrary ? "Bibliothek ausblenden" : "Bibliothek einblenden") {
            WorkspaceActions.toggleLibrary(layout, library: library)
        }.keyboardShortcut(shortcuts ? KeyboardShortcut("l", modifiers: [.command, .option]) : nil)
        Button(layout.panels(developing: library.isDeveloping).showsTools ? "Werkzeuge ausblenden" : "Werkzeuge einblenden") {
            WorkspaceActions.toggleTools(layout, library: library)
        }.keyboardShortcut(shortcuts ? KeyboardShortcut("i", modifiers: .command) : nil)
        Button(layout.panels(developing: library.isDeveloping).showsFilmstrip ? "Filmstreifen ausblenden" : "Filmstreifen einblenden") {
            WorkspaceActions.toggleFilmstrip(layout, library: library)
        }.keyboardShortcut(shortcuts ? KeyboardShortcut("s", modifiers: [.command, .option]) : nil)
        Divider()
        ForEach(WorkspaceTool.allCases) { tool in
            Button(tool.title) { WorkspaceActions.reveal(tool, layout: layout, library: library) }
                .disabled(library.selectedAsset == nil)
        }
        Divider()
        Button("Darstellung merken") { layout.remember() }
        Button("Standardansicht wiederherstellen") {
            WorkspaceActions.finishField()
            layout.reset(developing: library.isDeveloping)
        }
    }
}

struct WorkspaceDock: View {
    @ObservedObject var layout: WorkspaceLayoutModel
    @ObservedObject var library: LibraryModel
    @FocusState private var focusedPanel: String?
    private var panels: WorkspacePanels { layout.panels(developing: library.isDeveloping) }

    var body: some View {
        HStack(spacing: 6) {
            dockButton("Bibliothek", symbol: "sidebar.left", active: panels.showsLibrary) {
                WorkspaceActions.toggleLibrary(layout, library: library)
            }.focused($focusedPanel, equals: "library")
            dockButton("Filmstreifen", symbol: "film", active: panels.showsFilmstrip) {
                WorkspaceActions.toggleFilmstrip(layout, library: library)
            }.focused($focusedPanel, equals: "film")
            Divider().frame(height: 22)
            ForEach(WorkspaceTool.allCases) { tool in
                dockButton(tool.dockTitle, symbol: tool.symbol,
                           active: panels.showsTools && panels.openGroups.contains(tool)) {
                    WorkspaceActions.reveal(tool, layout: layout, library: library)
                }.disabled(library.selectedAsset == nil)
                    .focused($focusedPanel, equals: tool.rawValue)
            }
            Spacer(minLength: 0)
            if panels.showsTools {
                Button { WorkspaceActions.toggleTools(layout, library: library) } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 32)
                }.help("Werkzeuge schließen").accessibilityLabel("Werkzeuge schließen")
            }
        }.font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
            .padding(.horizontal, 16).frame(height: 50)
            .background(Theme.sidebar)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            .onChange(of: panels.showsTools) { old, visible in
                if old && !visible { focusedPanel = layout.revealedTool?.rawValue ?? WorkspaceTool.edit.rawValue }
            }
            .onChange(of: panels.showsLibrary) { old, visible in if old && !visible { focusedPanel = "library" } }
    }

    private func dockButton(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).padding(.horizontal, 6).frame(minHeight: 32) }
            .foregroundStyle(active ? Theme.accent : Theme.muted)
            .background(active ? Theme.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .help(title).accessibilityLabel(title)
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
