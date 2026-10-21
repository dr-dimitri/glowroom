import AppKit
import Foundation
import GlowroomCore
import SwiftUI
import Testing
@testable import Glowroom

/// Run the production inspector and history routing in the complete workspace.
/// The offscreen host uses native controls without moving the desktop pointer
/// or activating the test process. AppKit events remain ordered on MainActor.
@Suite("Sharpening workspace native interaction", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct DevelopSharpeningWorkspaceTests {
    @Test func detailsCollapseAndReopenWhileSharpeningAndNoiseRemainExpanded() async throws {
        let fixture = try await SharpeningWorkspaceFixture.make()
        fixture.layout.update(developing: true) {
            $0.openGroups = []; $0.openAdjustmentGroups = []; $0.singleGroup = true
        }
        let host = WorkspaceSectionTestHost(size: NSSize(width: 1_200, height: 900))
        defer { host.close(); fixture.removeTemporaryFiles() }
        try await host.mount(LibraryView(model: fixture.library, dataDirectory: fixture.directory)
            .environmentObject(fixture.editor).environmentObject(fixture.layout)
            .environmentObject(fixture.metadata).environmentObject(fixture.exporter)
            .environment(\.displayScale, 2).preferredColorScheme(.dark))
        try await waitForSharpeningWorkspace(operation: "closed saved Details heading") {
            host.accessibilityElements.contains { $0.accessibilityIdentifier() == "workspace.group.details" }
        }
        try await host.settle()
        #expect(host.sliders.isEmpty, "Closed Details must hide its loupe and all six detail sliders")
        var details = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "workspace.group.details" })
        #expect(details.accessibilityRole() == .button)
        #expect((details.accessibilityValue() as? String)?.hasPrefix("Geschlossen") == true)
        #expect(details.accessibilityPerformPress(), "Details must reopen through its production header")
        try await waitForSharpeningWorkspace(operation: "reopened detail sliders") { host.sliders.count == 6 }
        try await host.settle()

        for (identifier, label) in [("develop.adjustment-group.sharpening", "Schärfen"),
                                    ("develop.adjustment-group.noise", "Entrauschen")] {
            let header = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == identifier })
            #expect(header.accessibilityLabel() == label || header.accessibilityValue() as? String == label)
            #expect(header.accessibilityRole() != .button, "The \(label) heading must not offer collapsing")
        }
        let sliderRoot = try #require(host.sliders.first?.window?.contentView)
        for (identifier, label) in [("sharpeningAmount", "Betrag"), ("sharpeningRadius", "Radius"),
                                    ("sharpeningDetail", "Details"), ("sharpeningMasking", "Maskieren"),
                                    ("luminanceNoiseReduction", "Luminanz"), ("colorNoiseReduction", "Farbe")] {
            _ = try sharpeningSlider(identifier: "develop.adjustment.\(identifier)", label: label, root: sliderRoot)
        }

        // Closing the outer group also cancels its active detail picker.
        try await waitForSharpeningWorkspace(operation: "available detail picker") {
            host.accessibilityElements.contains {
                $0.accessibilityIdentifier() == "develop.detail-picker" && $0.isAccessibilityEnabled()
            }
        }
        let picker = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "develop.detail-picker" })
        #expect(picker.accessibilityPerformPress())
        try await waitForSharpeningWorkspace(operation: "active detail picker") {
            host.accessibilityElements.contains {
                $0.accessibilityIdentifier() == "develop.detail-picker" && $0.accessibilityValue() as? String == "Aktiv"
            }
        }
        details = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "workspace.group.details" })
        #expect(details.accessibilityPerformPress())
        try await waitForSharpeningWorkspace(operation: "collapsed detail controls") { host.sliders.isEmpty }
        try await host.settle()
        #expect(!fixture.layout.develop.openGroups.contains(.details))
        let defaults = try #require(UserDefaults(suiteName: fixture.preferenceSuite))
        #expect(!WorkspaceLayoutModel(defaults: defaults).develop.openGroups.contains(.details))

        details = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "workspace.group.details" })
        #expect(details.accessibilityPerformPress())
        try await waitForSharpeningWorkspace(operation: "detail controls reopened after collapse") { host.sliders.count == 6 }
        try await host.settle()
        let reopenedPicker = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "develop.detail-picker" })
        #expect(reopenedPicker.accessibilityValue() as? String == "Inaktiv")

        // The outer Details group participates in the column's solo mode.
        let basics = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "workspace.group.edit" })
        #expect(basics.accessibilityPerformPress())
        try await waitForSharpeningWorkspace(operation: "solo mode hides Details") {
            !fixture.layout.develop.openGroups.contains(.details)
                && !host.sliders.contains { $0.minValue == 0 && $0.maxValue == 150 }
        }
        #expect(fixture.layout.develop.openGroups == [.edit])
        #expect(!host.accessibilityElements.contains { $0.accessibilityIdentifier() == "develop.adjustment-group.noise" })
        #expect(await fixture.library.finishSaving())
        #expect(await fixture.editor.finishSaving())
    }

    @Test func amountSliderEnablesControlsAndRadiusResetParticipatesInWorkspaceHistory() async throws {
        let fixture = try await SharpeningWorkspaceFixture.make()
        let host = WorkspaceSectionTestHost(size: NSSize(width: 1_200, height: 900))
        defer { host.close(); fixture.removeTemporaryFiles() }
        try await host.mount(LibraryView(model: fixture.library, dataDirectory: fixture.directory)
            .environmentObject(fixture.editor).environmentObject(fixture.layout)
            .environmentObject(fixture.metadata).environmentObject(fixture.exporter)
            .environment(\.displayScale, 2).preferredColorScheme(.dark))
        try await waitForSharpeningWorkspace(operation: "mounted amount slider") {
            host.sliders.contains { $0.minValue == 0 && $0.maxValue == 150 }
        }
        try await host.settle()

        let amount = try #require(host.sliders.first { $0.minValue == 0 && $0.maxValue == 150 } as? ResettableNativeSlider)
        var radius = try #require(host.sliders.first { $0.minValue == 0.5 && $0.maxValue == 3 } as? ResettableNativeSlider)
        let detail = try #require(host.sliders.compactMap { $0 as? ResettableNativeSlider }.first { $0.resetNeutralValue == 25 })
        let masking = try sharpeningSlider(identifier: "develop.adjustment.sharpeningMasking",
            label: "Maskieren", root: amount.window?.contentView)
        #expect(amount.isEnabled && amount.doubleValue == 0)
        #expect(!radius.isEnabled && !detail.isEnabled && !masking.isEnabled)
        #expect(radius.doubleValue == 1 && detail.doubleValue == 25 && masking.doubleValue == 0)
        for label in ["Betrag", "Radius", "Details", "Maskieren"] {
            #expect(host.accessibilityElements.contains {
                $0.accessibilityLabel() == label || $0.accessibilityValue() as? String == label
            }, "The real inspector must expose the \(label) control")
        }

        // Route a real native slider action through the production inspector's
        // binding and editing transaction, rather than mutating model settings.
        amount.doubleValue = 40
        #expect(amount.sendAction(amount.action, to: amount.target))
        try await waitForSharpeningWorkspace(operation: "native amount action") {
            fixture.settings.sharpeningAmount == 40
        }
        try await host.settle()
        try await waitForSharpeningWorkspace(operation: "editable radius increments") {
            fixture.editor.canEdit && host.sliders.contains { $0.minValue == 0.5 && $0.maxValue == 3 && $0.isEnabled }
        }
        radius = try sharpeningSlider(identifier: "develop.adjustment.sharpeningRadius", label: "Radius", root: host.sliders.first?.window?.contentView)
        #expect(radius.isEnabled && detail.isEnabled && masking.isEnabled)
        #expect(fixture.settings.exposure == 0.75)

        // Accessibility input starts a new native interaction after the
        // disabled control's pending input was cancelled by SwiftUI.
        for _ in 0..<12 { #expect(radius.accessibilityPerformIncrement()) }
        try await waitForSharpeningWorkspace(operation: "native radius increments") {
            abs(fixture.settings.sharpeningRadius - 2.2) < 0.000_001
        }
        try await host.settle()
        // Accepted edits can briefly disable native controls during automatic
        // backup maintenance. Dispatch the next input only to an enabled,
        // currently mounted control; real clicks obey the same native gate.
        try await waitForSharpeningWorkspace(operation: "editable radius double-click reset") {
            fixture.editor.canEdit && host.sliders.contains { $0.minValue == 0.5 && $0.maxValue == 3 && $0.isEnabled }
        }
        radius = try sharpeningSlider(identifier: "develop.adjustment.sharpeningRadius", label: "Radius", root: host.sliders.first?.window?.contentView)
        let radiusWindow = try #require(radius.window)
        let resetEvent = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: radius.convert(NSPoint(x: radius.bounds.midX, y: radius.bounds.midY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: radiusWindow.windowNumber, context: nil,
            eventNumber: 2, clickCount: 2, pressure: 1))
        radius.mouseDown(with: resetEvent)
        try await waitForSharpeningWorkspace(operation: "radius double-click reset") { fixture.settings.sharpeningRadius == 1 }
        #expect(fixture.settings.sharpeningAmount == 40)
        #expect(host.focus(radius))
        try host.sendHistoryKey()
        #expect(host.focus(nil))
        try await waitForSharpeningWorkspace(operation: "workspace undo radius reset") {
            abs(fixture.settings.sharpeningRadius - 2.2) < 0.000_001
        }
        try await waitForSharpeningWorkspace(operation: "editable radius redo") {
            fixture.editor.canEdit && host.sliders.contains { $0.minValue == 0.5 && $0.maxValue == 3 && $0.isEnabled }
        }
        radius = try sharpeningSlider(identifier: "develop.adjustment.sharpeningRadius", label: "Radius", root: host.sliders.first?.window?.contentView)
        #expect(host.focus(radius))
        try host.sendHistoryKey(redo: true)
        // Keep focus during native shortcut routing, then release it before
        // SwiftUI applies enabled-state changes or forced snapshot layout.
        #expect(host.focus(nil))
        try await waitForSharpeningWorkspace(operation: "workspace redo radius reset") { fixture.settings.sharpeningRadius == 1 }
        try await host.settle()

        // Capture the production inspector, including loupe and neighboring
        // noise controls, for visual QA without WindowServer screenshots.
        try await waitForSharpeningWorkspace(operation: "rendered detail loupe") {
            sharpeningNativeViews(amount.window?.contentView).contains {
                ($0 as? DevelopCropNativeInputView)?.accessibilityIdentifier() == "develop.detail-loupe"
            }
        }
        try await host.settle()
        let inspector = try #require(host.accessibilityElements.first {
            $0.accessibilityIdentifier() == "develop.adjustments"
        })
        #expect(inspector.accessibilityFrame().width >= 280)
        try host.snapshot(to: URL(fileURLWithPath: "/tmp/glowroom-sharpening-inspector.png"))
        #expect(await fixture.library.finishSaving())
        #expect(await fixture.editor.finishSaving())
    }
}

@MainActor
private struct SharpeningWorkspaceFixture {
    let directory: URL
    let preferenceSuite: String
    let asset: PhotoAsset
    let library: LibraryModel
    let editor: EditingModel
    let layout: WorkspaceLayoutModel
    let metadata: PhotoMetadataModel
    let exporter: JPEGExportModel

    var settings: EditSettings { editor.settings(for: asset.id) }

    static func make() async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-SharpeningWorkspace-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preferenceSuite = "Glowroom-SharpeningWorkspace-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: preferenceSuite))
        let layout = WorkspaceLayoutModel(defaults: defaults)
        layout.update(developing: true) {
            $0.showsLibrary = false; $0.showsFilmstrip = false; $0.showsTools = true
            $0.openGroups = [.details]; $0.openAdjustmentGroups = ["sharpening", "noise"]
        }
        let width = 600, height = 400
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.16, green: 0.23, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for index in 0..<12 {
            context.setFillColor(CGColor(red: CGFloat(index) / 14 + 0.1, green: 0.3, blue: 0.12, alpha: 1))
            context.fillEllipse(in: CGRect(x: 20 + index * 45, y: 60 + (index % 3) * 75, width: 70, height: 70))
        }
        let image = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let imageURL = directory.appendingPathComponent("synthetic-sharpening.png")
        try png.write(to: imageURL)
        let modifiedAt = try #require(FileManager.default.attributesOfItem(atPath: imageURL.path)[.modificationDate] as? Date)
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: imageURL, fileSize: Int64(png.count),
            pixelWidth: width, pixelHeight: height, createdAt: modifiedAt, modifiedAt: modifiedAt)
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: [asset]))
        let library = LibraryModel(repository: repository)
        let editor = EditingModel(directory: directory.appendingPathComponent("Editing"))
        let analysis = ImageAnalysisService(provider: UnavailableImageAnalysisProvider(reason: .sdkUnavailable), budget: AIResourceBudget())
        let metadata = PhotoMetadataModel(store: PhotoMetadataRepository(directory: directory.appendingPathComponent("Metadata")),
            suggestor: LocalPhotoMetadataSuggestor(service: analysis), library: library, editor: editor)
        try await waitForSharpeningWorkspace(operation: "fixture library/editor initial load") {
            !library.isLoading && !library.isProjecting && !editor.isLoading
        }
        library.select(asset); library.isDeveloping = true; library.showsDetail = true
        editor.setSettings(.init(exposure: 0.75), for: asset.id)
        // Complete the fixture's first save and daily automatic backup before
        // mounting native controls. flush() alone does not drain that backup's
        // intentional temporary editing fence.
        try #require(await editor.finishSaving())
        return Self(directory: directory, preferenceSuite: preferenceSuite, asset: asset,
            library: library, editor: editor, layout: layout, metadata: metadata,
            exporter: JPEGExportModel(preferences: nil))
    }

    func removeTemporaryFiles() {
        UserDefaults(suiteName: preferenceSuite)?.removePersistentDomain(forName: preferenceSuite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private func sharpeningSlider(identifier: String, label: String, root: NSView?) throws -> ResettableNativeSlider {
    let sliders = sharpeningNativeViews(root).compactMap { $0 as? ResettableNativeSlider }
    let elements = WorkspaceAccessibilityElement.descendants(of: root)
    let frames = elements.filter { $0.accessibilityIdentifier() == identifier }
        .map { $0.accessibilityFrame() }
    for frame in frames where frame.width > 0 && frame.height > 0 {
        if let slider = sliders.first(where: { sharpeningScreenFrame($0).intersects(frame) }) { return slider }
    }
    // Some SwiftUI versions expose the row identifier on its text node only.
    // Its vertical center still identifies exactly one native slider row.
    let labelFrames = elements.filter {
        $0.accessibilityLabel() == label || $0.accessibilityValue() as? String == label
    }.map { $0.accessibilityFrame() }
    for frame in labelFrames where frame.width > 0 && frame.height > 0 {
        if let slider = sliders.first(where: {
            let track = sharpeningScreenFrame($0)
            return track.minY <= frame.midY && track.maxY >= frame.midY
        }) { return slider }
    }
    return try #require(nil as ResettableNativeSlider?, "Missing native slider for \(identifier)")
}

@MainActor
private func sharpeningScreenFrame(_ view: NSView) -> NSRect {
    view.window?.convertToScreen(view.convert(view.bounds, to: nil)) ?? .zero
}

@MainActor
private func sharpeningNativeViews(_ root: NSView?) -> [NSView] {
    var pending = root.map { [$0] } ?? [], result: [NSView] = []
    while let view = pending.popLast() {
        result.append(view); pending.append(contentsOf: view.subviews)
    }
    return result
}

@MainActor
private func waitForSharpeningWorkspace(operation: String, _ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw TestSchedulingTimeout(operation: "sharpening workspace: \(operation)", lastState: "waiting for bound inspector state")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
