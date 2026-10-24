import Combine
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Workspace layout preferences")
@MainActor
struct WorkspaceLayoutTests {
    @Test
    func developDefaultsOpenOnlyBasicAdjustmentsAndPreserveExplicitDetailsChoice() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(layout.develop.openGroups == [.edit])
        #expect(layout.focus.openGroups == [.edit])
        #expect(layout.develop.openAdjustmentGroups.contains("sharpening"))

        layout.toggleGroup(.details, developing: true)
        let restored = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(restored.develop.openGroups == [.edit, .details])
    }

    @Test(arguments: [false, true])
    func detailsCanStayClosedAcrossRestartAndReopenInEachWorkspace(_ focused: Bool) throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        if focused { layout.enterFocus() }
        layout.update(developing: true) {
            $0.singleGroup = true
            $0.openGroups = [.details, .metadata]
        }
        layout.toggleGroup(.details, developing: true)

        let restored = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(restored.panels(developing: true).openGroups == [.metadata])
        #expect(restored.panels(developing: true).openAdjustmentGroups.contains("noise"),
            "An open inner group must not reopen deliberately closed Details during decoding")
        restored.toggleGroup(.details, developing: true)
        #expect(restored.panels(developing: true).openGroups == [.details, .metadata])
        #expect(WorkspaceLayoutModel(defaults: fixture.defaults).panels(developing: true) == restored.panels(developing: true))
        restored.toggleGroup(.edit, developing: true)
        #expect(restored.panels(developing: true).openGroups == [.edit, .metadata])
    }

    @Test
    func sharpeningGroupCanBeOpenedClosedAndRestored() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        layout.update(developing: true) { $0.openAdjustmentGroups = ["sharpening", "unknown"] }
        #expect(layout.develop.openAdjustmentGroups == ["sharpening"])
        #expect(WorkspaceLayoutModel(defaults: fixture.defaults).develop.openAdjustmentGroups == ["sharpening"])
        layout.update(developing: true) { $0.openAdjustmentGroups.remove("sharpening") }
        #expect(!WorkspaceLayoutModel(defaults: fixture.defaults).develop.openAdjustmentGroups.contains("sharpening"))
    }

    @Test
    func preferenceUpdatePublishesTheNormalizedLayoutOnce() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        var emitted: [WorkspacePanels] = []
        let subscription = layout.$develop.dropFirst().sink { emitted.append($0) }
        defer { subscription.cancel() }
        layout.update(developing: true) {
            $0.toolsWidth = 430
            $0.singleGroup = true
            $0.openGroups = [.metadata, .versions]
        }
        #expect(emitted.count == 1, "Normalization must not send a second unchanged @Published value")
        #expect(emitted.first?.toolsWidth == 430)
        #expect(emitted.first?.openGroups == [.metadata])
        #expect(WorkspaceLayoutModel(defaults: fixture.defaults).develop == layout.develop)
    }

    @Test
    func restartRestoresEachWorkspaceAndFocusReturnDestination() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        layout.update(developing: false) {
            $0.showsLibrary = false
            $0.libraryWidth = 260
            $0.openGroups = [.metadata, .versions]
        }
        layout.update(developing: true) {
            $0.toolsWidth = 430
            $0.filmstripHeight = 150
            $0.openGroups = [.edit, .metadata]
            $0.openAdjustmentGroups = ["tone", "presence"]
        }
        let library = layout.library, develop = layout.develop
        layout.enterFocus(developing: false, showsDetail: false)
        layout.reveal(.versions, developing: true)
        layout.update(developing: true) { $0.showsFilmstrip = true; $0.toolsWidth = 380 }
        let focus = layout.focus

        let restored = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(restored.isFocused)
        #expect(restored.panels(developing: false) == focus)
        #expect(restored.panels(developing: true) == focus)
        #expect(restored.leaveFocus() == WorkspaceFocusOrigin(developing: false, showsDetail: false))
        #expect(restored.panels(developing: false) == library)
        #expect(restored.panels(developing: true) == develop)
        #expect(!WorkspaceLayoutModel(defaults: fixture.defaults).isFocused)
    }

    @Test
    func repeatedFocusEntryDoesNotReplaceOriginOrNormalPanelPreferences() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        layout.update(developing: true) {
            $0.showsTools = false
            $0.libraryWidth = 310
            $0.filmstripHeight = 190
            $0.openGroups = [.versions, .metadata]
        }
        let library = layout.library, develop = layout.develop
        layout.enterFocus(developing: false, showsDetail: false)
        #expect(!layout.focus.showsLibrary && !layout.focus.showsTools && !layout.focus.showsFilmstrip)
        layout.enterFocus(developing: true, showsDetail: true)
        layout.update(developing: true) {
            $0.showsLibrary = true
            $0.libraryWidth = 240
            $0.openGroups = [.metadata]
        }
        #expect(layout.leaveFocus() == WorkspaceFocusOrigin(developing: false, showsDetail: false))
        #expect(layout.library == library && layout.develop == develop)
        layout.enterFocus()
        #expect(layout.focus.showsLibrary && layout.focus.libraryWidth == 300)
        #expect(layout.focus.openGroups == [.metadata])
    }

    @Test
    func smallWindowReservesImageWidthAndLaterRestoresRequestedPanelWidths() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        layout.update(developing: true) { $0.libraryWidth = 360; $0.toolsWidth = 520 }
        let narrow = layout.boundedWidths(availableWidth: 1_000, developing: true)
        #expect(narrow.library >= 180 && narrow.tools >= 300)
        #expect(abs(1_000 - narrow.library - narrow.tools - 2 - 320) < 0.000_001)
        #expect(layout.develop.libraryWidth == 360 && layout.develop.toolsWidth == 520)

        let wide = layout.boundedWidths(availableWidth: 1_440, developing: true)
        #expect(wide.library == 360 && wide.tools == 520)
        let restored = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(restored.develop.libraryWidth == 360 && restored.develop.toolsWidth == 520)
        restored.update(developing: true) { $0.showsLibrary = false }
        let onePanel = restored.boundedWidths(availableWidth: 1_000, developing: true)
        #expect(onePanel.library == 0 && onePanel.tools == 520)
        restored.update(developing: true) { $0.showsTools = false }
        let noPanels = restored.boundedWidths(availableWidth: 1_000, developing: true)
        #expect(noPanels.library == 0 && noPanels.tools == 0)
    }

    @Test(arguments: [Double.nan, Double.infinity, -20, 0, 240, 500])
    func transientWindowGeometryProducesFiniteNonnegativeSizes(_ width: Double) throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        let bounded = layout.boundedWidths(availableWidth: width, developing: true)
        let filmstrip = layout.boundedFilmstripHeight(availableHeight: width, developing: true)
        #expect(bounded.library.isFinite && bounded.tools.isFinite && filmstrip.isFinite)
        #expect(bounded.library >= 0 && bounded.tools >= 0 && filmstrip >= 0)
        if width.isFinite && width >= 322 {
            #expect(width - bounded.library - bounded.tools - 2 >= 320 - 0.000_001)
        }
    }

    @Test
    func filmstripClampingDoesNotOverwritePreferredHeightOrHiddenState() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        layout.update(developing: true) { $0.filmstripHeight = 220 }
        #expect(layout.boundedFilmstripHeight(availableHeight: 350, developing: true) == 109)
        #expect(layout.boundedFilmstripHeight(availableHeight: 800, developing: true) == 220)
        #expect(layout.develop.filmstripHeight == 220)
        layout.update(developing: true) { $0.showsFilmstrip = false }
        #expect(layout.boundedFilmstripHeight(availableHeight: 800, developing: true) == 0)
        let restored = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(!restored.develop.showsFilmstrip && restored.develop.filmstripHeight == 220)
    }

    @Test
    func accordionAndDirectRevealOperateWithinCurrentWorkspace() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        let library = layout.library
        layout.toggleGroup(.metadata, developing: true)
        #expect(layout.develop.openGroups == [.edit, .metadata])
        layout.update(developing: true) { $0.singleGroup = true }
        #expect(layout.develop.openGroups == [.edit, .metadata], "Each column keeps its own open group")
        layout.toggleGroup(.versions, developing: true)
        #expect(layout.develop.openGroups == [.edit, .versions])
        layout.toggleGroup(.versions, developing: true)
        #expect(layout.develop.openGroups == [.edit])
        layout.update(developing: true) { $0.showsLibrary = false; $0.showsTools = false }
        let before = layout.revealRequest
        layout.reveal(.metadata, developing: true)
        #expect(layout.develop.showsLibrary && !layout.develop.showsTools)
        #expect(layout.develop.openGroups == [.edit, .metadata])
        #expect(layout.revealedTool == .metadata && layout.revealRequest != before)
        let firstReveal = layout.revealRequest
        layout.reveal(.metadata, developing: true)
        #expect(layout.revealRequest != firstReveal, "The same group can be scrolled into view repeatedly")
        layout.reveal(.edit, developing: true)
        #expect(layout.develop.showsTools && layout.develop.openGroups == [.edit, .metadata])
        layout.toggleGroup(.edit, developing: true)
        #expect(layout.develop.openGroups == [.metadata])
        #expect(layout.library == library)
    }

    @Test
    func detailsShareAdjustmentHistoryAndRevealTheRightColumn() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(EditingFunction(WorkspaceTool.details) == .adjustments)
        #expect(!WorkspaceTool.details.isNavigationTool)
        layout.update(developing: true) {
            $0.showsLibrary = false
            $0.showsTools = false
            $0.singleGroup = true
            $0.openGroups = [.edit, .metadata]
        }
        layout.reveal(.details, developing: true)
        #expect(!layout.develop.showsLibrary && layout.develop.showsTools)
        #expect(layout.develop.openGroups == [.details, .metadata])
        layout.toggleGroup(.edit, developing: true)
        #expect(layout.develop.openGroups == [.edit, .metadata])
        #expect(WorkspaceLayoutModel(defaults: fixture.defaults).develop == layout.develop)
    }

    @Test(arguments: [WorkspaceTool.edit, .aiDevelopment])
    func openingDevelopmentWithoutSelectionShowsTheCommonTools(_ tool: WorkspaceTool) async throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-EmptyWorkspace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryModel(repository: CatalogRepository(directory: directory))
        #expect(await library.finishSaving())
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        layout.update(developing: true) { $0.showsTools = false }
        WorkspaceActions.reveal(tool, layout: layout, library: library)
        #expect(library.workspaceMode == .develop && library.selectedAsset == nil && !library.showsDetail)
        #expect(layout.develop.showsTools && layout.develop.openGroups.contains(tool))
        #expect(layout.revealedTool == tool)
        #expect(await library.finishSaving())
    }

    @Test
    func oldAIEntryPersistsOnlyTheSharedDevelopmentOrigin() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        layout.enterFocus(developing: false, showsDetail: true, aiDeveloping: true)
        let restored = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(restored.focusOrigin.aiDeveloping == nil)
        #expect(restored.leaveFocus() == WorkspaceFocusOrigin(developing: true, showsDetail: true))
        #expect(EditingFunction(WorkspaceTool.aiDevelopment) == .adjustments)
        #expect(EditingFunction(WorkspaceTool.color) == .adjustments)
        #expect(!WorkspaceTool.aiDevelopment.isNavigationTool && !WorkspaceTool.color.isNavigationTool)
    }

    @Test(arguments: [false, true])
    func savedAIFocusMigratesItsTaskAndPreservesPanelPreferences(_ singleGroup: Bool) throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let json = """
        {"isFocused":true,"focusOrigin":{"developing":false,"showsDetail":true,"aiDeveloping":true},
        "develop":{"toolsWidth":480,"openGroups":["color","metadata"],"singleGroup":\(singleGroup)},
        "focus":{"showsTools":true,"showsLibrary":true,"libraryWidth":340,"toolsWidth":460,
        "filmstripHeight":140,"openGroups":["edit","versions"],"singleGroup":\(singleGroup)}}
        """
        fixture.defaults.set(Data(json.utf8), forKey: WorkspaceLayoutModel.preferencesKey)
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(layout.isFocused && layout.focusOrigin == WorkspaceFocusOrigin(developing: true, showsDetail: true))
        #expect(layout.focus.showsTools && layout.focus.showsLibrary)
        #expect(layout.focus.libraryWidth == 340 && layout.focus.toolsWidth == 460 && layout.focus.filmstripHeight == 140)
        #expect(layout.focus.openGroups.contains(.aiDevelopment) && layout.focus.openGroups.contains(.versions))
        #expect(layout.focus.openGroups.contains(.edit) == !singleGroup)
        #expect(layout.develop.toolsWidth == 480)
        #expect(layout.develop.openGroups.contains(.aiDevelopment) && layout.develop.openGroups.contains(.metadata))
        #expect(layout.develop.openGroups.contains(.color) == !singleGroup)
        let restored = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(restored.focus == layout.focus && restored.develop == layout.develop)
        #expect(restored.leaveFocus() == WorkspaceFocusOrigin(developing: true, showsDetail: true))
        let returnedPanels = restored.panels(developing: true)
        #expect(returnedPanels.openGroups.contains(.aiDevelopment) && returnedPanels.toolsWidth == 480)
        #expect(returnedPanels.openGroups.contains(.metadata))
        let stored = try #require(fixture.defaults.data(forKey: WorkspaceLayoutModel.preferencesKey))
        #expect(!String(decoding: stored, as: UTF8.self).contains("aiDeveloping"))
    }

    @Test
    func partiallyDamagedAIFocusOriginKeepsItsValidTaskAndWindowState() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let json = #"{"isFocused":true,"focusOrigin":{"developing":"damaged","aiDeveloping":true},"focus":{"toolsWidth":420,"showsTools":true}}"#
        fixture.defaults.set(Data(json.utf8), forKey: WorkspaceLayoutModel.preferencesKey)
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(layout.isFocused && layout.focus.toolsWidth == 420 && layout.focus.showsTools)
        #expect(layout.focus.openGroups.contains(.aiDevelopment))
        #expect(layout.leaveFocus() == WorkspaceFocusOrigin(developing: true, showsDetail: true))
    }

    @Test
    func savedClassicFocusOriginRemainsClassicDuringMigration() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let json = #"{"isFocused":true,"focusOrigin":{"developing":false,"showsDetail":true}}"#
        fixture.defaults.set(Data(json.utf8), forKey: WorkspaceLayoutModel.preferencesKey)
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(layout.leaveFocus() == WorkspaceFocusOrigin(developing: false, showsDetail: true))
        #expect(layout.focus.openGroups == [.edit])
    }

    @Test(arguments: [false, true])
    func olderOpenNoiseGroupMovesToDetailsAndSubsequentClosingPersists(_ singleGroup: Bool) throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let json = """
        {"develop":{"openGroups":["edit","metadata"],"singleGroup":\(singleGroup),
        "openAdjustmentGroups":["tone","noise"]}}
        """
        fixture.defaults.set(Data(json.utf8), forKey: WorkspaceLayoutModel.preferencesKey)
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(layout.develop.openGroups.contains(.details))
        #expect(layout.develop.openGroups.contains(.metadata))
        #expect(layout.develop.openGroups.contains(.edit) == !singleGroup)
        #expect(layout.develop.openAdjustmentGroups.contains("noise"))
        layout.toggleGroup(.details, developing: true)
        let restored = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(!restored.develop.openGroups.contains(.details))
        #expect(restored.develop == layout.develop)
    }

    @Test
    func olderClosedNoiseGroupDoesNotForceDetailsOpen() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let json = #"{"develop":{"openGroups":["edit"],"openAdjustmentGroups":["tone"]}}"#
        fixture.defaults.set(Data(json.utf8), forKey: WorkspaceLayoutModel.preferencesKey)
        #expect(WorkspaceLayoutModel(defaults: fixture.defaults).develop.openGroups == [.edit])
    }

    @Test
    func partialOlderPreferencesKeepValidFieldsAndScopeDefaults() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let json = """
        {"library":"damaged", "develop":{"toolsWidth":450,"openGroups":["assistant","analysis","newerTool"],
        "openAdjustmentGroups":["presence","unknown"]}, "focus":{"toolsWidth":"NaN"},"isFocused":true}
        """
        fixture.defaults.set(Data(json.utf8), forKey: WorkspaceLayoutModel.preferencesKey)
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(layout.library == .libraryDefault)
        #expect(layout.develop.toolsWidth == 450 && layout.develop.openGroups.isEmpty)
        #expect(layout.develop.openAdjustmentGroups == ["presence"])
        #expect(layout.focus == .focusDefault)
        #expect(layout.isFocused)
    }

    @Test
    func removedAssistantAndAnalysisGroupsKeepSavedMetadataAndPanelDimensions() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let json = #"{"develop":{"libraryWidth":340,"toolsWidth":430,"openGroups":["analysis","assistant","metadata"]}}"#
        fixture.defaults.set(Data(json.utf8), forKey: WorkspaceLayoutModel.preferencesKey)

        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(layout.develop.libraryWidth == 340 && layout.develop.toolsWidth == 430)
        #expect(layout.develop.openGroups == [.metadata])
        layout.remember()
        #expect(WorkspaceLayoutModel(defaults: fixture.defaults).develop == layout.develop)
    }

    @Test
    func olderNarrowSidebarsKeepLibraryWidthAndReserveRoomForDevelopContent() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let json = #"{"library":{"libraryWidth":218},"develop":{"libraryWidth":218},"focus":{"libraryWidth":218},"isFocused":true}"#
        fixture.defaults.set(Data(json.utf8), forKey: WorkspaceLayoutModel.preferencesKey)
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(layout.library.libraryWidth == 218)
        #expect(layout.develop.libraryWidth == 300 && layout.focus.libraryWidth == 300)
        #expect(layout.boundedWidths(availableWidth: 1_000, developing: false).library == 0)
        layout.update(developing: false) { $0.showsLibrary = true; $0.libraryWidth = 218 }
        #expect(layout.focus.libraryWidth == 300, "Focus uses the develop navigation column even for a library origin")
    }

    @Test(arguments: ["not-json", "{\"version\":999,\"isFocused\":true}", "null", "[]"])
    func unusableOrFuturePreferencesFallBackToSafeDefaults(_ json: String) throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        fixture.defaults.set(Data(json.utf8), forKey: WorkspaceLayoutModel.preferencesKey)
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        #expect(layout.library == .libraryDefault && layout.develop == .developDefault)
        #expect(layout.focus == .focusDefault && !layout.isFocused)
    }

    @Test
    func invalidDirectAssignmentsCannotPoisonGeometryOrSubsequentPersistence() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        layout.develop.libraryWidth = .nan
        layout.develop.toolsWidth = .infinity
        layout.develop.filmstripHeight = -1
        layout.develop.singleGroup = true
        layout.develop.openGroups = [.versions, .metadata]
        #expect(layout.develop.libraryWidth == 300 && layout.develop.toolsWidth == 320)
        #expect(layout.develop.filmstripHeight == 80)
        #expect(layout.develop.openGroups == [.metadata])
        #expect(WorkspaceLayoutModel(defaults: fixture.defaults).develop == layout.develop)
    }

    @Test
    func resetOnlyChangesTheActiveLayoutAndPreservesFocusReturn() throws {
        let fixture = try Preferences()
        defer { fixture.remove() }
        let layout = WorkspaceLayoutModel(defaults: fixture.defaults)
        layout.update(developing: false) { $0.libraryWidth = 300 }
        layout.update(developing: true) { $0.toolsWidth = 440; $0.openGroups = [.edit, .details] }
        let library = layout.library, develop = layout.develop
        layout.enterFocus(developing: false, showsDetail: true)
        layout.reveal(.versions, developing: true)
        layout.reveal(.details, developing: true)
        layout.reset(developing: true)
        #expect(layout.focus == .focusDefault && layout.isFocused)
        #expect(layout.focus.openGroups == [.edit])
        #expect(layout.library == library && layout.develop == develop)
        #expect(layout.leaveFocus() == WorkspaceFocusOrigin(developing: false, showsDetail: true))
        layout.reset(developing: true)
        #expect(layout.develop == .developDefault && layout.library == library)
        #expect(layout.develop.openGroups == [.edit])
        #expect(WorkspaceLayoutModel(defaults: fixture.defaults).develop.openGroups == [.edit])
    }

    private struct Preferences {
        let suite: String
        let defaults: UserDefaults

        init() throws {
            suite = "Glowroom-WorkspaceLayout-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
        }

        func remove() { defaults.removePersistentDomain(forName: suite) }
    }
}
