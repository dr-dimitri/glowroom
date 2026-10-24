import SwiftUI

/// A drag invalidates only the column frames, rather than every observer of the
/// saved workspace. Child views and accepted preview pixels keep their identity.
struct WorkspaceColumns<Navigation: View, Content: View, Tools: View>: View {
    let panels: WorkspacePanels
    let navigation: Bool
    let focused: Bool
    let libraryLabel: String
    let commit: (WorkspaceColumnWidths) -> Void
    private let library: Navigation
    private let content: Content
    private let tools: Tools
    @ViewState private var resize: WorkspaceColumnResize?
    @ViewState private var preview: WorkspaceColumnWidths?

    init(panels: WorkspacePanels, navigation: Bool, focused: Bool = false, libraryLabel: String,
         commit: @escaping (WorkspaceColumnWidths) -> Void,
         @ViewBuilder library: () -> Navigation, @ViewBuilder content: () -> Content,
         @ViewBuilder tools: () -> Tools) {
        self.panels = panels
        self.navigation = navigation
        self.focused = focused
        self.libraryLabel = libraryLabel
        self.commit = commit
        self.library = library()
        self.content = content()
        self.tools = tools()
    }

    var body: some View {
        GeometryReader { geometry in
            let widths = preview ?? WorkspaceColumnWidths.fitting(panels: panels, navigation: navigation,
                                                                  availableWidth: geometry.size.width)
            HStack(spacing: 0) {
                if panels.showsLibrary {
                    library.frame(width: widths.library)
                    handle(.library, value: widths.library, width: geometry.size.width)
                }
                content.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                if panels.showsTools {
                    handle(.tools, value: widths.tools, width: geometry.size.width)
                    tools.frame(width: widths.tools)
                }
            }
            .transaction { transaction in
                if resize != nil { transaction.animation = nil; transaction.disablesAnimations = true }
            }
            .onChange(of: geometry.size.width) { _, _ in cancel() }
        }
        .onChange(of: panels) { _, _ in cancel() }
        .onChange(of: navigation) { _, _ in cancel() }
        .onChange(of: focused) { _, _ in cancel() }
        .onDisappear { cancel() }
    }

    private func handle(_ column: WorkspaceColumnResize.Column, value: Double, width: Double) -> some View {
        WorkspaceResizeHandle(horizontal: true, label: column == .library ? libraryLabel : "Breite der Werkzeuge",
                              value: value, step: column == .library ? 1 : -1, begin: {
            let session = WorkspaceColumnResize(panels: panels, navigation: navigation,
                                                availableWidth: width, column: column)
            resize = session
            preview = session.initial
        }, end: { completed in
            if completed, let resize, let preview, preview != resize.initial { commit(preview) }
            cancel()
        }, adjust: { value in
            // Accessibility adjustments use the same bounds, as a discrete edit.
            let session = WorkspaceColumnResize(panels: panels, navigation: navigation,
                                                availableWidth: width, column: column)
            let delta = column == .library ? value - session.initial.library : session.initial.tools - value
            commit(session.size(for: delta))
        }) { value in
            guard let resize else { return }
            let delta = column == .library ? value - resize.initial.library : resize.initial.tools - value
            let next = resize.size(for: delta)
            if preview != next { preview = next }
        }
    }

    private func cancel() {
        resize = nil
        preview = nil
    }
}
