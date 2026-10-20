import Testing
@testable import Glowroom

@Suite("Workspace focus return")
struct WorkspaceFocusRoutingTests {
    @Test(arguments: [false, true])
    func closingNavigationOrFilmstripKeepsTheirReopenControlReachable(focused: Bool) {
        let visible = visibility(focused: focused)
        #expect(target(from: visible, to: visibility(focused: focused, library: false)) == (focused ? .tool(.metadata) : .library))
        #expect(target(from: visible, to: visibility(focused: focused, filmstrip: false)) == .filmstrip)
    }

    @Test
    func closingClassicToolsReturnsToToolsRatherThanChangingWorkspace() {
        #expect(target(from: visibility(), to: visibility(tools: false), tool: .metadata) == .tools)
        #expect(target(from: visibility(), to: visibility(tools: false), hasSelection: false) == .tools)
    }

    @Test(arguments: WorkspaceTool.allCases)
    func closingFocusAdjustmentsReturnsToTheirOwningTool(_ tool: WorkspaceTool) {
        #expect(target(from: visibility(focused: true),
                       to: visibility(focused: true, tools: false), tool: tool) == .tool(.edit))
    }

    @Test(arguments: WorkspaceTool.allCases)
    func closingFocusNavigationReturnsToItsLastGroupOrTheFirstNavigationTool(_ tool: WorkspaceTool) {
        #expect(target(from: visibility(focused: true),
                       to: visibility(focused: true, library: false), tool: tool)
                == .tool(tool.isNavigationTool ? tool : .metadata))
    }

    @Test
    func focusToolsHaveAnEnabledFallbackWithoutASelectedPhoto() {
        let visible = visibility(focused: true)
        let closed = visibility(focused: true, tools: false)
        #expect(target(from: visible, to: closed) == .tool(.edit))
        #expect(target(from: visible, to: closed, tool: .metadata, hasSelection: false) == .focus)
        #expect(target(from: visible, to: visibility(focused: true, library: false),
                       tool: .metadata, hasSelection: false) == .focus)
    }

    @Test
    func focusTransitionsUseTheReturnButtonEvenWhenSeveralPanelsDisappear() {
        let focused = visibility(focused: true, library: false, tools: false, filmstrip: false)
        #expect(target(from: visibility(), to: focused) == .focus)
        #expect(target(from: visibility(focused: true),
                       to: visibility(library: false, tools: false, filmstrip: false)) == .focus)
    }

    @Test
    func leavingFocusWithoutSelectionAvoidsTheDisabledFocusButton() {
        #expect(target(from: visibility(focused: true), to: visibility(), hasSelection: false) == .library)
    }

    @Test(arguments: [false, true])
    func showingPanelsOrKeepingTheirVisibilityDoesNotTakeFocus(focused: Bool) {
        let closed = visibility(focused: focused, library: false, tools: false, filmstrip: false)
        #expect(target(from: closed, to: closed) == nil)
        #expect(target(from: closed, to: visibility(focused: focused)) == nil)
    }

    private func visibility(focused: Bool = false, library: Bool = true, tools: Bool = true,
                            filmstrip: Bool = true) -> WorkspacePanelVisibility {
        WorkspacePanelVisibility(isFocused: focused, showsLibrary: library,
                                 showsTools: tools, showsFilmstrip: filmstrip)
    }

    private func target(from previous: WorkspacePanelVisibility, to current: WorkspacePanelVisibility,
                        tool: WorkspaceTool? = nil, hasSelection: Bool = true) -> WorkspaceControlFocus? {
        WorkspaceFocusRouting.target(previous: previous, current: current,
                                     revealedTool: tool, hasSelection: hasSelection)
    }
}
