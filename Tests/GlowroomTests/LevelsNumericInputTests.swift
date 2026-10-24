import AppKit
import Foundation
import GlowroomCore
import SwiftUI
import Testing
@testable import Glowroom

@Suite("Levels synchronous numeric drafts")
@MainActor
struct LevelsNumericInputTests {
    @Test func unchangedDisplayNeverRoundsOrPublishesTheExactStoredValue() {
        let input = LevelsNumericInput(), id = UUID()
        var value = 1.234_567_89, changes = [Bool](), published = [Double](), invalid = 0
        input.begin(id: id, value: value, display: "1.235", readValue: { value },
            publish: { published.append($0); value = $0 }, editingChanged: { changes.append($0) }, invalid: { invalid += 1 })
        #expect(!input.hasPendingChanges)
        input.commit(id: id)
        #expect(value == 1.234_567_89)
        #expect(published.isEmpty && changes.isEmpty && invalid == 0 && !input.hasPendingChanges)
    }

    @Test func aConsumedDraftCannotReplayAfterChannelOrResetMutation() {
        let input = LevelsNumericInput(), old = UUID(), next = UUID()
        var red = 1.0, green = 1.0, changes = [Bool]()
        input.begin(id: old, value: red, display: "1.000", readValue: { red },
            publish: { red = $0 }, editingChanged: { changes.append($0) }, invalid: {})
        input.change(id: old, text: "1,75")
        #expect(input.hasPendingChanges)
        input.commit()
        #expect(red == 1.75 && changes == [true, false] && !input.hasPendingChanges)
        red = 1 // The following reset must remain newer than native callbacks.
        input.begin(id: next, value: green, display: "1.000", readValue: { green },
            publish: { green = $0 }, editingChanged: { changes.append($0) }, invalid: {})
        input.change(id: next, text: "2.25")
        input.commit(id: old)
        #expect(input.isActive(next) && red == 1 && green == 1 && input.hasPendingChanges)
        input.commit(id: next)
        #expect(green == 2.25 && changes == [true, false, true, false] && !input.hasPendingChanges)
    }

    @Test func revertingTheDraftTextRestoresNeutralResetAvailability() {
        let input = LevelsNumericInput(), id = UUID()
        input.begin(id: id, value: 1, display: "1.000", readValue: { 1 },
            publish: { _ in }, editingChanged: { _ in }, invalid: {})
        input.change(id: id, text: "1.5")
        #expect(input.hasPendingChanges)
        input.change(id: id, text: "1.000")
        #expect(!input.hasPendingChanges)
        input.commit()
        #expect(!input.hasPendingChanges)
    }

    @Test func invalidOrSupersededTextClosesItsGroupWithoutPublishing() {
        let input = LevelsNumericInput()
        var value = 1.0, invalid = 0, changes = [Bool]()
        for text in ["not a number", "inf", "nan"] {
            let id = UUID()
            input.begin(id: id, value: value, display: "1.000", readValue: { value },
                publish: { value = $0 }, editingChanged: { changes.append($0) }, invalid: { invalid += 1 })
            input.change(id: id, text: text); input.commit()
        }
        #expect(value == 1 && invalid == 3 && changes.count == 6)
        let id = UUID()
        input.begin(id: id, value: value, display: "1.000", readValue: { value },
            publish: { value = $0 }, editingChanged: { changes.append($0) }, invalid: { invalid += 1 })
        input.change(id: id, text: "2")
        value = 3
        input.commit()
        #expect(value == 3 && invalid == 3 && changes.count == 8)
    }
}

/// Real field-editor notifications exercise the synchronous production path.
/// Offscreen windows avoid changing the user's active window or desktop pointer.
@Suite("Levels native field and channel boundaries", .serialized)
@MainActor
struct LevelsNumericNativeTests {
    @Test func focusAndBlurPreserveHighPrecisionValuesWithoutUndo() async throws {
        let fixture = try await LevelsNumericFixture.make()
        let host = LevelsNumericHost()
        defer { host.close(); fixture.remove() }
        try await host.mount(fixture)
        let baseline = fixture.settings, revision = fixture.editor.localRevision(for: fixture.asset.id)
        let field = try host.field(.gamma)
        #expect(field.stringValue == "1.235")
        try host.focus(field)
        #expect(host.window.makeFirstResponder(nil))
        try await host.settle()
        #expect(fixture.settings == baseline)
        #expect(fixture.editor.localRevision(for: fixture.asset.id) == revision)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test func typingThenSwitchingChannelCommitsToTheOldChannelAsOneUndoStep() async throws {
        let fixture = try await LevelsNumericFixture.make()
        let host = LevelsNumericHost()
        defer { host.close(); fixture.remove() }
        try await host.mount(fixture)
        let baseline = fixture.settings
        try host.type("1.75", into: host.field(.gamma))
        try #require(fixture.settings == baseline, "Text remains a draft until the input boundary")
        try host.selectRedChannel()
        try #require(fixture.settings.levels.master.gamma == 1.75, "Commit must precede the channel mutation")
        try #require(fixture.settings.levels.red == baseline.levels.red)
        try await host.settle()
        try host.type("2.25", into: host.field(.gamma))
        try #require(host.window.makeFirstResponder(nil))
        try await host.settle()
        try #require(fixture.settings.levels.red.gamma == 2.25)
        fixture.editor.undo(assetID: fixture.asset.id)
        try #require(fixture.settings.levels.red == baseline.levels.red && fixture.settings.levels.master.gamma == 1.75)
        fixture.editor.undo(assetID: fixture.asset.id)
        try #require(fixture.settings == baseline && !fixture.editor.canUndo(assetID: fixture.asset.id))
        try #require(await fixture.editor.flush())
    }

    @Test func returnThenTypingAgainInTheSameFieldCreatesTwoUndoSteps() async throws {
        let fixture = try await LevelsNumericFixture.make()
        let host = LevelsNumericHost()
        defer { host.close(); fixture.remove() }
        try await host.mount(fixture)
        let baseline = fixture.settings
        let field = try host.field(.gamma)
        try host.type("1.75", into: field)
        let firstEditor = try #require(field.currentEditor() as? NSTextView)
        firstEditor.insertNewline(nil)
        try await host.settle()
        #expect(fixture.settings.levels.master.gamma == 1.75)
        // Return can leave this same field editor active. The next actual
        // keystroke must open a new draft without accepting stale callbacks.
        try host.type("2.25", into: field)
        let secondEditor = try #require(field.currentEditor() as? NSTextView)
        secondEditor.insertNewline(nil)
        try await host.settle()
        #expect(fixture.settings.levels.master.gamma == 2.25)
        #expect(host.window.makeFirstResponder(nil))
        try await host.settle()
        #expect(fixture.settings.levels.master.gamma == 2.25)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.settings.levels.master.gamma == 1.75)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.settings == baseline && !fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test func resetConsumesPendingNativeTextBeforeApplyingItsOwnUndoStep() async throws {
        let fixture = try await LevelsNumericFixture.make()
        let host = LevelsNumericHost()
        defer { host.close(); fixture.remove() }
        try await host.mount(fixture)
        let baseline = fixture.settings
        let field = try host.field(.gamma)
        try host.type("1.75", into: field)
        let oldDelegate = try #require(field.delegate)
        let oldSubmit = try #require(field.action)
        let reset = try host.element("develop.levels.reset-all")
        #expect(reset.accessibilityPerformPress())
        #expect(fixture.settings.levels.isNeutral)
        // Old notifications cannot reopen a consumed draft, even if this
        // offscreen window still owns its field editor after the reset action.
        oldDelegate.controlTextDidBeginEditing?(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        oldDelegate.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        oldDelegate.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(NSApp.sendAction(oldSubmit, to: oldDelegate, from: field))
        #expect(host.window.makeFirstResponder(nil))
        try await host.settle()
        #expect(fixture.settings.levels.isNeutral && fixture.settings.exposure == baseline.exposure)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.settings.levels.master.gamma == 1.75)
        #expect(fixture.settings.levels.red == baseline.levels.red)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.settings == baseline)
        #expect(await fixture.editor.flush())
    }

    @Test(arguments: [false, true])
    func theFirstResetClickAcceptsAndResetsADirtyInitiallyNeutralCurve(resetsAll: Bool) async throws {
        let fixture = try await LevelsNumericFixture.make(levels: .neutral)
        let host = LevelsNumericHost()
        defer { host.close(); fixture.remove() }
        try await host.mount(fixture)
        let baseline = fixture.settings
        #expect(baseline.levels.isNeutral && !fixture.editor.canUndo(assetID: fixture.asset.id))
        let field = try host.field(.gamma)
        try host.type("1.5", into: field)
        let oldDelegate = try #require(field.delegate)
        let oldSubmit = try #require(field.action)
        // Give the observable native draft a normal UI update before the click.
        try await host.settle()
        #expect(fixture.settings == baseline, "The typed value must still be an uncommitted native draft")
        let identifier = resetsAll ? "develop.levels.reset-all" : "develop.levels.reset-channel"
        let reset = try host.element(identifier)
        #expect(reset.accessibilityPerformPress(), "A dirty draft must enable the first reset click")
        try await host.settle()
        #expect(fixture.settings == baseline)
        let revision = fixture.editor.localRevision(for: fixture.asset.id)
        field.stringValue = "9.5"
        oldDelegate.controlTextDidBeginEditing?(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        oldDelegate.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        oldDelegate.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(NSApp.sendAction(oldSubmit, to: oldDelegate, from: field))
        #expect(host.window.makeFirstResponder(nil))
        try await host.settle()
        #expect(fixture.settings == baseline && fixture.editor.localRevision(for: fixture.asset.id) == revision,
            "Delayed callbacks must not recreate the consumed draft")
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.settings.levels.master.gamma == 1.5)
        #expect(fixture.settings.exposure == baseline.exposure)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.settings == baseline && !fixture.editor.canUndo(assetID: fixture.asset.id),
            "Accepting the draft and resetting it must create exactly two undo steps")
        #expect(await fixture.editor.flush())
    }

    @Test(arguments: [false, true])
    func lateBeginChangeAndEndCannotReopenAnOldFieldOrFlushANewerDraft(switchesChannel: Bool) async throws {
        let fixture = try await LevelsNumericFixture.make()
        let host = LevelsNumericHost()
        defer { host.close(); fixture.remove() }
        try await host.mount(fixture)
        let oldField = try host.field(.gamma)
        try host.type("1.75", into: oldField)
        // Retain the old coordinator deliberately: real queued notifications
        // may outlive removal of its channel row or a reset's focus transition.
        let oldDelegate = try #require(oldField.delegate)
        let oldSubmit = try #require(oldField.action)
        if switchesChannel {
            try host.selectRedChannel()
        } else {
            let reset = try host.element("develop.levels.reset-all")
            try #require(reset.accessibilityPerformPress())
        }
        try await host.settle()
        let boundary = fixture.settings
        let parameter: LevelsUIParameter = switchesChannel ? .gamma : .inputBlack
        let newField = try host.field(parameter)
        try host.type(switchesChannel ? "2.25" : "0.2", into: newField)
        let revision = fixture.editor.localRevision(for: fixture.asset.id)
        try #require(fixture.settings == boundary)
        oldField.stringValue = "9.5"
        for name in [NSControl.textDidBeginEditingNotification, NSControl.textDidChangeNotification,
                     NSControl.textDidEndEditingNotification] {
            let notification = Notification(name: name, object: oldField)
            if name == NSControl.textDidBeginEditingNotification { oldDelegate.controlTextDidBeginEditing?(notification) }
            else if name == NSControl.textDidChangeNotification { oldDelegate.controlTextDidChange?(notification) }
            else { oldDelegate.controlTextDidEndEditing?(notification) }
            try #require(fixture.settings == boundary, "An obsolete notification must not commit either draft")
            try #require(fixture.editor.localRevision(for: fixture.asset.id) == revision)
        }
        try #require(NSApp.sendAction(oldSubmit, to: oldDelegate, from: oldField))
        try #require(fixture.settings == boundary, "An obsolete submit must not commit or reopen a draft")
        try #require(fixture.editor.localRevision(for: fixture.asset.id) == revision)
        try #require(host.window.makeFirstResponder(nil))
        try await host.settle()
        if switchesChannel {
            try #require(fixture.settings.levels.red.gamma == 2.25)
            try #require(fixture.settings.levels.master == boundary.levels.master)
        } else {
            try #require(fixture.settings.levels.master.inputBlack == 0.2)
            try #require(fixture.settings.levels.master.gamma == 1)
        }
        fixture.editor.undo(assetID: fixture.asset.id)
        try #require(fixture.settings == boundary, "The new field must retain its own undo boundary")
        try #require(await fixture.editor.flush())
    }
}

@MainActor
private struct LevelsNumericFixture {
    let directory: URL
    let library: LibraryModel
    let editor: EditingModel
    let asset: PhotoAsset
    var settings: EditSettings { editor.settings(for: asset.id) }
    static func make(levels: LevelsSettings = .init(master: .init(gamma: 1.234_567_89), red: .init(gamma: 1.4))) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("levels-numeric-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("synthetic.png")
        try Data([1, 2, 3, 4]).write(to: source)
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: source, fileSize: 4, pixelWidth: 2, pixelHeight: 2)
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(.init(folders: [folder], assets: [asset]))
        let library = LibraryModel(repository: repository)
        let editor = EditingModel(database: LegacySnapshotTestAdapter(LevelsNumericStore()))
        let deadline = ContinuousClock.now + .seconds(10)
        while library.isLoading || library.isProjecting || editor.isLoading {
            try #require(ContinuousClock.now < deadline, "Levels numeric fixture must load")
            try await Task.sleep(for: .milliseconds(5))
        }
        library.select(asset); library.isDeveloping = true
        editor.setSettings(.init(exposure: 0.7, levels: levels), for: asset.id)
        try #require(await editor.finishSaving())
        editor.selectEditingFunction(.crop, assetID: asset.id)
        editor.selectEditingFunction(.adjustments, assetID: asset.id)
        return Self(directory: directory, library: library, editor: editor, asset: asset)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private final class LevelsNumericHost {
    let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    init() {
        _ = NSApplication.shared
        WorkspaceAccessibilityElement.enableInProcess()
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 380, height: 420),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        window.contentView = hosting; window.orderBack(nil)
    }
    var nativeViews: [NSView] {
        var pending: [NSView] = [hosting], result: [NSView] = []
        while let view = pending.popLast() { result.append(view); pending.append(contentsOf: view.subviews) }
        return result
    }
    var elements: [WorkspaceAccessibilityElement] { WorkspaceAccessibilityElement.descendants(of: hosting) }
    private var accessibleDescription: String {
        elements.map {
            "\($0.accessibilityRole()?.rawValue ?? "?") id=\($0.accessibilityIdentifier() ?? "-") label=\($0.accessibilityLabel() ?? "-")"
        }.joined(separator: "\n")
    }
    func mount(_ fixture: LevelsNumericFixture) async throws {
        hosting.rootView = AnyView(LevelsInspector(assetID: fixture.asset.id, library: fixture.library, workspace: DevelopWorkspace())
            .environmentObject(fixture.editor).frame(width: 360).fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top))
        try await settle()
    }
    func element(_ identifier: String) throws -> WorkspaceAccessibilityElement {
        try #require(elements.first { $0.accessibilityIdentifier() == identifier },
            "Missing Levels control \(identifier). Native accessibility tree:\n\(accessibleDescription)")
    }
    func selectRedChannel() throws {
        let picker = try #require(nativeViews.compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityIdentifier() == "develop.levels.channel"
        })
        try #require(picker.isEnabled)
        picker.selectItem(at: try #require(LevelsChannel.allCases.firstIndex(of: .red)))
        try #require(picker.sendAction(picker.action, to: picker.target),
            "Use the production channel menu's native target/action")
    }
    func field(_ parameter: LevelsUIParameter) throws -> NSTextField {
        try #require(nativeViews.compactMap { $0 as? NSTextField }.first {
            $0.isEditable && $0.accessibilityIdentifier() == "develop.levels.\(parameter.rawValue).value"
        })
    }
    func focus(_ field: NSTextField) throws {
        try #require(window.makeFirstResponder(field))
        _ = try #require(field.currentEditor())
    }
    func type(_ text: String, into field: NSTextField) throws {
        try focus(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }
    func settle() async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
        // SwiftUI's virtual controls become AX children during display; native
        // NSTextFields alone already exist after layout. Match the other native
        // inspector hosts before inspecting or pressing the virtual controls.
        hosting.displayIfNeeded()
    }
    func close() { window.close() }
}

private actor LevelsNumericStore: LegacySnapshotTestStore {
    private var values: [String: EditSettings] = [:], savedRevisions: [String: Int64] = [:]
    func loadAll() -> [String: EditSettings] { values }
    func revisions() -> [String: Int64] { savedRevisions }
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) { values[assetID] = settings; savedRevisions[assetID] = revision }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/levels-numeric-fake-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { values }
}
