import Combine
import Foundation
import Testing
@testable import Glowroom

@Suite("Workspace column resize geometry")
@MainActor
struct WorkspaceColumnResizeTests {
    @Test
    func bothColumnsTrackThePointerFromTheirVisibleSize() {
        let panels = WorkspacePanels.libraryDefault
        let left = WorkspaceColumnResize(panels: panels, navigation: false, availableWidth: 1_440, column: .library)
        #expect(left.initial == WorkspaceColumnWidths(library: 218, tools: 320))
        #expect(left.size(for: 74) == WorkspaceColumnWidths(library: 292, tools: 320))
        #expect(left.size(for: 12) == WorkspaceColumnWidths(library: 230, tools: 320))
        let right = WorkspaceColumnResize(panels: panels, navigation: false, availableWidth: 1_440, column: .tools)
        #expect(right.size(for: -74) == WorkspaceColumnWidths(library: 218, tools: 394))
        #expect(right.size(for: 12) == WorkspaceColumnWidths(library: 218, tools: 308))
    }

    @Test(arguments: [WorkspaceColumnResize.Column.library, .tools])
    func constrainedDragStartsAtTheVisibleWidthAndKeepsTheOtherColumnFixed(_ column: WorkspaceColumnResize.Column) {
        var panels = WorkspacePanels.developDefault
        panels.libraryWidth = 360
        panels.toolsWidth = 520
        let drag = WorkspaceColumnResize(panels: panels, navigation: true, availableWidth: 1_000, column: column)
        #expect(abs(drag.initial.library + drag.initial.tools + 14 + 320 - 1_000) < 0.000_001)
        #expect(drag.initial.library < panels.libraryWidth && drag.initial.tools < panels.toolsWidth)
        #expect(drag.size(for: 0) == drag.initial)
        let changed = drag.size(for: column == .library ? -10 : 10)
        if column == .library {
            #expect(abs(changed.library - (drag.initial.library - 10)) < 0.000_001)
            #expect(changed.tools == drag.initial.tools)
        } else {
            #expect(changed.library == drag.initial.library)
            #expect(abs(changed.tools - (drag.initial.tools - 10)) < 0.000_001)
        }
        let expanded = drag.size(for: column == .library ? 1_000 : -1_000)
        #expect(abs(expanded.library + expanded.tools + 14 + 320 - 1_000) < 0.000_001)
    }

    @Test
    func rangesAndReversalDoNotAccumulatePreviousDeltas() {
        let panels = WorkspacePanels.developDefault
        let left = WorkspaceColumnResize(panels: panels, navigation: true, availableWidth: 1_440, column: .library)
        #expect(left.size(for: -1_000).library == 300)
        #expect(left.size(for: 1_000).library == 360)
        #expect(left.size(for: 25).library == 325)
        #expect(left.size(for: 0) == left.initial)
        let right = WorkspaceColumnResize(panels: panels, navigation: true, availableWidth: 1_440, column: .tools)
        #expect(right.size(for: 1_000).tools == 300)
        #expect(right.size(for: -1_000).tools == 520)
        #expect(right.size(for: -25).tools == 345)
        #expect(right.size(for: 0) == right.initial)
    }

    @Test
    func aHiddenPanelUsesNoHandleOrCanvasBudget() {
        var panels = WorkspacePanels.libraryDefault
        panels.showsTools = false
        let left = WorkspaceColumnResize(panels: panels, navigation: false, availableWidth: 600, column: .library)
        #expect(left.initial == WorkspaceColumnWidths(library: 218, tools: 0))
        #expect(left.size(for: 1_000) == WorkspaceColumnWidths(library: 273, tools: 0))
        let hidden = WorkspaceColumnResize(panels: panels, navigation: false, availableWidth: 600, column: .tools)
        #expect(hidden.size(for: -1_000) == hidden.initial)
    }

    @Test(arguments: [Double.nan, Double.infinity, -20, 0, 240, 500])
    func transientWindowSizesStayFiniteAndReserveCanvasSpace(_ width: Double) {
        let panels = WorkspacePanels.developDefault
        for column in [WorkspaceColumnResize.Column.library, .tools] {
            let drag = WorkspaceColumnResize(panels: panels, navigation: true, availableWidth: width, column: column)
            for translation in [Double.nan, Double.infinity, -1_000, 0, 1_000] {
                let size = drag.size(for: translation)
                #expect(size.library.isFinite && size.tools.isFinite)
                #expect(size.library >= 0 && size.tools >= 0)
                if width.isFinite && width >= 334 {
                    #expect(width - size.library - size.tools - 14 >= 320 - 0.000_001)
                }
            }
        }
    }

    @Test
    func passiveGeometryMatchesTheExistingModelBudget() throws {
        let name = "WorkspaceColumnResizeTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = WorkspaceLayoutModel(defaults: defaults)
        model.update(developing: true) { $0.libraryWidth = 360; $0.toolsWidth = 520 }
        for width in [0.0, 500, 1_000, 1_440] {
            let pure = WorkspaceColumnWidths.fitting(panels: model.develop, navigation: true, availableWidth: width)
            let legacy = model.boundedWidths(availableWidth: width - 12, developing: true)
            #expect(pure == WorkspaceColumnWidths(library: legacy.library, tools: legacy.tools))
        }
    }

    @Test
    func unchangedOrClampedPreferencesDoNotPublishAnotherLayout() throws {
        let name = "WorkspaceColumnResizeTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = WorkspaceLayoutModel(defaults: defaults)
        model.update(developing: true) { $0.toolsWidth = 520 }
        let saved = defaults.data(forKey: WorkspaceLayoutModel.preferencesKey)
        var published = 0
        let subscription = model.$develop.dropFirst().sink { _ in published += 1 }
        defer { subscription.cancel() }
        model.update(developing: true) { $0.toolsWidth = 520 }
        model.update(developing: true) { $0.toolsWidth = 5_200 }
        #expect(published == 0)
        #expect(defaults.data(forKey: WorkspaceLayoutModel.preferencesKey) == saved)
    }
}
