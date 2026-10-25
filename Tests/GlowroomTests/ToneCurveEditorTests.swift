import AppKit
import Foundation
import GlowroomCore
import SwiftUI
import Testing
@testable import Glowroom

@Suite("Point curve editor native controls", .serialized)
@MainActor
struct ToneCurveEditorTests {
    @Test(arguments: [280.0, 320.0])
    func controlsRemainReachableAtTheMinimumWindowSize(width: Double) async throws {
        let model = ToneCurveEditorTestModel()
        let host = ToneCurveEditorTestHost(width: width)
        defer { host.close() }
        try await host.mount(model)
        for name in ["channel", "point", "x", "y", "add", "delete", "reset"] {
            let control = try #require(host.element(name), "Missing accessible curve control: \(name)")
            let frame = control.accessibilityFrame()
            #expect(frame.width > 0 && frame.height > 0)
            #expect(host.screenFrame.insetBy(dx: -1, dy: -1).contains(frame), "\(name) must remain in the inspector at a 1000×660 window")
        }
        #expect(try #require(host.element("add")).accessibilityPerformPress())
        try await host.settle()
        #expect(model.settings == .neutral, "An ineffective added point stays in the editor instead of creating a noncanonical settings value")
        #expect(try #require(host.element("delete")).isAccessibilityEnabled(), "The local third point must remain selected and editable")
        #expect(try #require(host.element("delete")).accessibilityPerformPress())
        try await host.settle()
        #expect(model.settings.master.points.count == 2)
        model.settings.master = .init(points: [.init(x: 0, y: 0.1), .init(x: 1, y: 0.9)])
        try await host.settle()
        #expect(try #require(host.element("reset")).accessibilityPerformPress())
        try await host.settle()
        #expect(model.settings.master.isNeutral)
    }

    @Test func nativeCoordinateEntryValidatesAndDoesNotOverwriteAnExternalCurveChange() async throws {
        let model = ToneCurveEditorTestModel()
        let host = ToneCurveEditorTestHost(width: 280)
        defer { host.close() }
        try await host.mount(model)
        #expect(try #require(host.element("add")).accessibilityPerformPress())
        try await host.settle()
        let y = try host.field("y")
        try host.type("0.65", into: y)
        try await host.settle()
        host.window.makeFirstResponder(nil)
        try await host.settle()
        #expect(model.settings.master.points[1].y == 0.65)
        let accepted = model.settings
        try host.type("2", into: try host.field("y"))
        host.window.makeFirstResponder(nil)
        try await host.settle()
        #expect(model.settings == accepted)
        try host.type("0.75", into: try host.field("y"))
        try await host.settle()
        model.settings.master.points[1].y = 0.55
        try await host.settle()
        host.window.makeFirstResponder(nil)
        try await host.settle()
        #expect(model.settings.master.points[1].y == 0.55)
    }

    @Test func analysisBudgetChargesCurveAndLevelsProofsIndependently() throws {
        for version in ToneProcessingVersion.allCases {
            let plain = try AutomaticToneEstimator.estimatedAdditionalBytes(sourceBytes: 1_024, width: 64, height: 32,
                version: version, ownsSource: true)
            let curve = try AutomaticToneEstimator.estimatedAdditionalBytes(sourceBytes: 1_024, width: 64, height: 32,
                version: version, ownsSource: true, toneCurvesActive: true)
            let both = try AutomaticToneEstimator.estimatedAdditionalBytes(sourceBytes: 1_024, width: 64, height: 32,
                version: version, ownsSource: true, levelsActive: true, toneCurvesActive: true)
            #expect(curve > plain)
            #expect(both - curve == curve - plain)
        }
    }

    @Test func obsoleteDraggedPointIndicesAreRejectedAndClampedPointsStayValid() throws {
        let shortened = ToneCurve.neutral
        for position in [-1, 2, 8, 15] {
            #expect(throws: ToneCurveValidationError.invalidPoints) {
                try ToneCurvePointEditing.moving(shortened, at: position, x: 0.5, y: 0.5, clamped: true)
            }
        }
        let curve = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.5), .init(x: 1, y: 1)])
        for x in [-1.0, 0, 0.5, 1, 2] {
            for y in [-1.0, 0, 0.5, 1, 2] {
                try ToneCurvePointEditing.moving(curve, at: 1, x: x, y: y, clamped: true).validate()
            }
        }
    }

    @Test func neutralAddFlushThenTwoPointChangesUseTheActualEditorAndDurableReceipts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-CurveDraft-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = EditingModel(directory: directory)
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(editor.canEdit)
        editor.setSettings(.newEditingSettings, for: "A")
        try #require(await editor.flush())
        editor.selectEditingFunction(.crop, assetID: "A"); editor.selectEditingFunction(.adjustments, assetID: "A")
        let baseline = editor.snapshot(for: "A"), revision = editor.localRevision(for: "A")
        let host = ToneCurveEditorTestHost(width: 280)
        defer { host.close() }
        try await host.mount(editor: editor)
        #expect(try #require(host.element("add")).accessibilityPerformPress())
        try await host.settle()
        #expect(editor.snapshot(for: "A") == baseline)
        #expect(editor.localRevision(for: "A") == revision && !editor.canUndo(assetID: "A"))
        try #require(await editor.flush())
        #expect(try #require(host.element("delete")).isAccessibilityEnabled())
        for y in ["0.60", "0.65"] {
            try host.type(y, into: try host.field("y"))
            try await host.settle()
            host.window.makeFirstResponder(nil)
            try await host.settle()
            #expect(editor.settings(for: "A").toneCurves.master.points.count == 3)
            #expect(editor.settings(for: "A").toneCurves.master.points[1].y == Double(y))
            try #require(await editor.flush(), "The next save must accept the preceding canonical receipt")
            #expect(editor.errorMessage == nil && editor.canEdit)
        }
        let accepted = editor.snapshot(for: "A")
        let reopened = EditingModel(directory: directory)
        let reopenedDeadline = ContinuousClock.now + .seconds(10)
        while reopened.isLoading, ContinuousClock.now < reopenedDeadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reopened.snapshot(for: "A") == accepted)
        editor.undo(assetID: "A")
        #expect(editor.settings(for: "A").toneCurves.master.points[1].y == 0.6)
        editor.undo(assetID: "A")
        #expect(editor.snapshot(for: "A") == baseline && !editor.canUndo(assetID: "A"))
        editor.redo(assetID: "A"); editor.redo(assetID: "A")
        #expect(editor.snapshot(for: "A") == accepted)
        try #require(await editor.flush())
    }
}

@MainActor
private final class ToneCurveEditorTestModel: ObservableObject {
    @Published var settings = ToneCurveSettings.neutral
}

@MainActor
private struct ToneCurveEditorTestHarness: View {
    @ObservedObject var model: ToneCurveEditorTestModel
    let width: CGFloat
    var body: some View {
        HStack {
            Spacer(minLength: 0)
            ScrollView {
                ToneCurveEditor(settings: $model.settings).padding(8)
            }.frame(width: width, height: 410)
        }.frame(width: 1000, height: 660, alignment: .topTrailing)
    }
}

@MainActor
private final class ToneCurveEditorTestHost {
    let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private let width: CGFloat
    init(width: CGFloat) {
        _ = NSApplication.shared
        WorkspaceAccessibilityElement.enableInProcess()
        self.width = width
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1000, height: 660),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        window.contentView = hosting; window.orderBack(nil)
    }
    var screenFrame: NSRect { window.convertToScreen(hosting.convert(hosting.bounds, to: nil)) }
    private var elements: [WorkspaceAccessibilityElement] { WorkspaceAccessibilityElement.descendants(of: hosting) }
    func element(_ name: String) -> WorkspaceAccessibilityElement? {
        elements.first { $0.accessibilityIdentifier() == "develop.curves." + name }
    }
    func field(_ name: String) throws -> NSTextField {
        let frame = try #require(element(name), "Missing accessible coordinate field: \(name)").accessibilityFrame()
        var pending: [NSView] = [hosting], fields: [(NSTextField, NSRect)] = []
        while let view = pending.popLast() {
            if let field = view as? NSTextField, field.isEditable {
                if field.accessibilityIdentifier() == "develop.curves." + name { return field }
                fields.append((field, window.convertToScreen(field.convert(field.bounds, to: nil))))
            }
            pending.append(contentsOf: view.subviews)
        }
        // SwiftUI attaches the public identifier to its virtual AX wrapper,
        // while AppKit owns the actual native text editor below that wrapper.
        // Match its observed screen frame; do not depend on private class names.
        let matching = fields.filter { $0.1.intersects(frame) }.min {
            hypot($0.1.midX - frame.midX, $0.1.midY - frame.midY)
                < hypot($1.1.midX - frame.midX, $1.1.midY - frame.midY)
        }
        return try #require(matching?.0, "No native editable field overlaps \(name) AX frame \(frame); candidates: \(fields.map { $0.1 })")
    }
    func type(_ text: String, into field: NSTextField) throws {
        try #require(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange())
    }
    func mount(_ model: ToneCurveEditorTestModel) async throws {
        hosting.rootView = AnyView(ToneCurveEditorTestHarness(model: model, width: width))
        try await settle()
    }
    func mount(editor: EditingModel) async throws {
        hosting.rootView = AnyView(ToneCurveActualEditorHarness(editor: editor, width: width))
        try await settle()
    }
    func settle() async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
    }
    func close() { window.close() }
}

@MainActor
private struct ToneCurveActualEditorHarness: View {
    @ObservedObject var editor: EditingModel
    let width: CGFloat
    var body: some View {
        HStack {
            Spacer(minLength: 0)
            ScrollView {
                ToneCurveEditor(settings: Binding(get: { editor.settings(for: "A").toneCurves }, set: { value in
                    var settings = editor.settings(for: "A"); settings.toneCurves = value
                    editor.setSettings(settings, for: "A")
                }), onEditingChanged: { editing in
                    if editing { editor.beginEditing(assetID: "A") } else { editor.endEditing(assetID: "A") }
                }).padding(8)
            }.frame(width: width, height: 410)
        }.frame(width: 1000, height: 660, alignment: .topTrailing)
    }
}
