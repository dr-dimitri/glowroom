import AppKit
import Foundation
import PicEditCore
import SwiftUI
import Testing
@testable import PicEdit

/// Native controls have their own intrinsic sizes. Measure the rendered
/// palette, rather than assuming SwiftUI spacing constants keep it compact.
@Suite("Compact mask palettes", .serialized)
@MainActor
struct CompactMaskLayoutTests {
    @Test func newMaskCreatorFitsAndExposesItsToolsBeforeTheFirstMask() async throws {
        let fixture = try await CompactMaskFixture.make()
        let host = CompactMaskHost(width: 300, height: 460)
        defer { host.close(); fixture.close() }
        try await host.mount(InlineMaskInspector(workspace: fixture.workspace).padding(.horizontal, 12))

        #expect(fixture.model.settings.localAdjustments.isEmpty)
        #expect(host.fittingHeight <= 460, "The complete mask creator must fit below the histogram and toolbar")
        _ = try host.element("local-mask.creator")
        let choices = [
            ("subject", "Motiv auswählen"), ("sky", "Himmel auswählen"), ("background", "Hintergrund auswählen"),
            ("brush", "Pinsel"), ("linear", "Linearer Verlauf"), ("radial", "Radialverlauf")
        ]
        for (kind, title) in choices {
            let button = try host.element("local-mask.create.\(kind)")
            #expect(button.accessibilityRole() == .button)
            #expect(button.accessibilityLabel() == title)
            #expect(button.isAccessibilityEnabled(), "\(title) must be usable before creating a mask")
            let frame = button.accessibilityFrame()
            #expect(frame.width > 0 && frame.height > 0)
            #expect(host.screenFrame.insetBy(dx: -1, dy: -1).contains(frame), "\(title) must be visible without scrolling")
        }
        for kind in ["landscape", "object"] {
            let unavailable = try host.element("local-mask.unavailable.\(kind)")
            #expect(!unavailable.isAccessibilityEnabled(), "Unimplemented selections must not promise an action")
        }
        let skySetup = try host.element("local-mask.sky-setup")
        #expect(skySetup.isAccessibilityEnabled(), "Sky model setup must remain reachable without an existing mask")
        #expect(!host.elements.contains { $0.accessibilityLabel() == "Bereich" })
        #expect(!host.elements.contains { $0.accessibilityIdentifier() == "local-mask.show-creator" })
        try host.snapshotIfRequested("mask-creator-empty")
        #expect(await fixture.library.finishSaving())
    }

    @Test func selectedMaskCanToggleTheCreatorAndAddingAMaskRestoresCorrections() async throws {
        let fixture = try await CompactMaskFixture.make()
        let host = CompactMaskHost(width: 300, height: 900)
        defer { host.close(); fixture.close() }
        fixture.model.add(.linear)
        let selectedID = try #require(fixture.model.selectedID)
        try await host.mount(InlineMaskInspector(workspace: fixture.workspace).padding(.horizontal, 12))

        #expect(!host.elements.contains { $0.accessibilityIdentifier() == "local-mask.creator" })
        let showCreator = try host.element("local-mask.show-creator")
        #expect(showCreator.accessibilityPerformPress())
        try await host.settle()
        _ = try host.element("local-mask.creator")
        _ = try host.element("local-mask.create.linear")
        #expect(fixture.model.selectedID == selectedID)
        #expect(fixture.model.settings.localAdjustments.count == 1)
        try host.snapshotIfRequested("mask-creator-expanded")

        #expect(try host.element("local-mask.show-creator").accessibilityPerformPress())
        try await host.settle()
        #expect(!host.elements.contains { $0.accessibilityIdentifier() == "local-mask.creator" })
        _ = try host.element("local-mask.correction.dehaze")
        #expect(fixture.model.selectedID == selectedID)

        #expect(try host.element("local-mask.show-creator").accessibilityPerformPress())
        try await host.settle()
        #expect(try host.element("local-mask.create.radial").accessibilityPerformPress())
        try await host.settle()
        #expect(fixture.model.settings.localAdjustments.count == 2)
        let created = try #require(fixture.model.selected)
        #expect(created.id != selectedID)
        switch created.mask.shape {
        case .radial: break
        default: Issue.record("The radial creator action must select the new radial mask")
        }
        #expect(!host.elements.contains { $0.accessibilityIdentifier() == "local-mask.creator" },
            "Creating a new selected mask must close the creator and expose its corrections")
        _ = try host.element("local-mask.correction.dehaze")
        #expect(await fixture.library.finishSaving())
    }

    @Test func nativeInversionAndEraserControlsUpdateTheBrushModeWithoutChangingItsDocument() async throws {
        let fixture = try await CompactMaskFixture.make()
        let host = CompactMaskHost(width: 300, height: 460)
        defer { host.close(); fixture.close() }
        fixture.model.add(.brush)
        try await host.mount(InlineMaskInspector(workspace: fixture.workspace).padding(.horizontal, 12))
        let document = try #require(fixture.workspace.brush.document)

        #expect(try host.element("local-mask.invert").accessibilityPerformPress())
        try await host.settle()
        #expect(fixture.model.selected?.mask.isInverted == true)
        #expect(!fixture.workspace.erases)
        #expect(fixture.workspace.brush.mode == .erase, "Painting an inverted mask must expand its visible selection")

        #expect(try host.element("local-mask.erase").accessibilityPerformPress())
        try await host.settle()
        #expect(fixture.workspace.erases)
        #expect(fixture.workspace.brush.mode == .brush, "Erasing an inverted mask must reduce its visible selection")

        #expect(try host.element("local-mask.invert").accessibilityPerformPress())
        try await host.settle()
        #expect(fixture.model.selected?.mask.isInverted == false)
        #expect(fixture.workspace.erases)
        #expect(fixture.workspace.brush.mode == .erase)
        #expect(fixture.workspace.brush.document == document, "Changing tool semantics must preserve the accepted mask strokes")
        for identifier in ["local-mask.invert", "local-mask.erase", "local-mask.correction.dehaze"] {
            let control = try host.element(identifier)
            #expect(control.isAccessibilityEnabled())
            let frame = control.accessibilityFrame()
            #expect(frame.width > 0 && frame.height > 0)
            #expect(host.screenFrame.insetBy(dx: -1, dy: -1).contains(frame))
        }
        #expect(await fixture.library.finishSaving())
    }

    @Test func floatingMaskListAppearsForCreationAndDisappearsAfterDeletingTheLastMask() async throws {
        let fixture = try await CompactMaskFixture.make()
        let inspector = CompactMaskHost(width: 300, height: 460)
        let list = CompactMaskHost(width: 250, height: 260)
        defer { inspector.close(); list.close(); fixture.close() }
        try await inspector.mount(InlineMaskInspector(workspace: fixture.workspace).padding(.horizontal, 12))
        try await list.mount(InlineMaskList(workspace: fixture.workspace))

        #expect(!fixture.workspace.showsMaskList)
        #expect(!list.elements.contains { $0.accessibilityIdentifier() == "local-mask.list" })
        #expect(try inspector.element("local-mask.create.linear").accessibilityPerformPress())
        try await inspector.settle()
        try await list.settle()

        #expect(fixture.model.settings.localAdjustments.count == 1)
        #expect(fixture.workspace.showsMaskList)
        _ = try list.element("local-mask.list")
        let selected = try #require(fixture.model.selected)
        fixture.workspace.comparesBefore = true
        #expect(try list.element("local-mask.delete.\(selected.id.uuidString)").accessibilityPerformPress())
        try await inspector.settle()
        try await list.settle()

        #expect(fixture.model.settings.localAdjustments.isEmpty)
        #expect(!fixture.workspace.comparesBefore, "Hiding the list must not strand the canvas in its before state")
        #expect(!fixture.workspace.showsMaskList)
        #expect(!list.elements.contains { $0.accessibilityIdentifier() == "local-mask.list" })
        _ = try inspector.element("local-mask.creator")

        let emptyUndo = try inspector.element("local-mask.undo")
        #expect(emptyUndo.isAccessibilityEnabled(), "Deleting the final mask must leave an accessible undo action")
        #expect(emptyUndo.accessibilityPerformPress())
        try await inspector.settle()
        try await list.settle()
        #expect(fixture.model.selectedID == selected.id)
        #expect(fixture.workspace.showsMaskList)
        _ = try list.element("local-mask.select.\(selected.id.uuidString)")

        // Undo creation as well, then restore it through the inspector's redo
        // action while the empty floating list remains hidden.
        fixture.workspace.comparesBefore = true
        #expect(try list.element("local-mask.undo").accessibilityPerformPress())
        try await inspector.settle()
        try await list.settle()
        #expect(!fixture.workspace.showsMaskList)
        #expect(!fixture.workspace.comparesBefore)
        #expect(!list.elements.contains { $0.accessibilityIdentifier() == "local-mask.list" })
        let emptyRedo = try inspector.element("local-mask.redo")
        #expect(emptyRedo.isAccessibilityEnabled())
        #expect(emptyRedo.accessibilityPerformPress())
        try await inspector.settle()
        try await list.settle()
        #expect(fixture.model.selectedID == selected.id)
        #expect(fixture.workspace.showsMaskList)
        _ = try list.element("local-mask.select.\(selected.id.uuidString)")
        #expect(await fixture.library.finishSaving())
    }

    @Test(arguments: [LocalMaskCreation.brush, .linear, .radial])
    func localCorrectionsFitBelowTheHistogramInANarrowInspector(_ kind: LocalMaskCreation) async throws {
        let fixture = try await CompactMaskFixture.make()
        let host = CompactMaskHost(width: 300, height: 460)
        defer { host.close(); fixture.close() }
        fixture.model.add(kind)
        try await host.mount(InlineMaskInspector(workspace: fixture.workspace).padding(.horizontal, 12))

        #expect(host.fittingHeight <= 460, "The complete local palette must fit in the space below the histogram and toolbar")
        let lastCorrection = try #require(host.elements.first {
            $0.accessibilityRole() == .slider && $0.accessibilityIdentifier() == "local-mask.correction.dehaze"
        })
        let frame = lastCorrection.accessibilityFrame()
        #expect(frame.width >= 70 && frame.height > 0, "Compaction must preserve a usable native slider")
        #expect(host.screenFrame.insetBy(dx: -1, dy: -1).contains(frame), "The final correction must be visible without scrolling")
        try host.snapshotIfRequested("mask-inspector-\(kind.rawValue)")
        #expect(await fixture.library.finishSaving())
    }

    @Test func floatingMaskListKeepsItsHeightWhenTheLayerLimitIsReached() async throws {
        let fixture = try await CompactMaskFixture.make()
        let host = CompactMaskHost(width: 250, height: 260)
        defer { host.close(); fixture.close() }
        fixture.model.add(.linear)
        try await host.mount(InlineMaskList(workspace: fixture.workspace))
        let oneLayerHeight = host.fittingHeight
        for _ in 1..<16 { fixture.model.add(.linear) }
        try await host.settle()

        #expect(fixture.model.settings.localAdjustments.count == 16)
        #expect(host.fittingHeight <= 260, "A long list must scroll within its own palette, preserving the image and correction controls")
        #expect(host.fittingHeight <= oneLayerHeight + 120, "Only the first four rows may increase the palette height")
        let selected = try #require(fixture.model.selected)
        let selectedRow = try #require(host.elements.first { $0.accessibilityIdentifier() == "local-mask.select.\(selected.id.uuidString)" })
        #expect(host.screenFrame.insetBy(dx: -1, dy: -1).contains(selectedRow.accessibilityFrame()),
            "A newly created mask must remain visible after the list starts scrolling")
        try host.snapshotIfRequested("mask-list-sixteen")
        let delete = try #require(host.elements.first { $0.accessibilityIdentifier() == "local-mask.delete.\(selected.id.uuidString)" })
        #expect(delete.accessibilityPerformPress())
        #expect(fixture.model.settings.localAdjustments.count == 15)
        #expect(!fixture.model.settings.localAdjustments.contains { $0.id == selected.id })
        try await host.settle()
        let neighbor = try #require(fixture.model.selected)
        let neighborRow = try #require(host.elements.first { $0.accessibilityIdentifier() == "local-mask.select.\(neighbor.id.uuidString)" })
        #expect(host.screenFrame.insetBy(dx: -1, dy: -1).contains(neighborRow.accessibilityFrame()),
            "Deleting a row must keep its newly selected neighbor visible")
        #expect(await fixture.library.finishSaving())
    }
}

@MainActor
private struct CompactMaskFixture {
    let directory: URL
    let library: LibraryModel
    let editor: EditingModel
    let model: LocalAdjustmentEditorModel
    let workspace: InlineMaskWorkspace

    static func make() async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-CompactMasks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: directory.appendingPathComponent("synthetic.jpg"))
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: [asset]))
        let library = LibraryModel(repository: repository)
        let editor = EditingModel(database: LegacySnapshotTestAdapter(CompactMaskSnapshotStore()))
        try await compactMaskWait { !library.isLoading && !library.isProjecting && !editor.isLoading }
        library.selectedID = asset.id
        let data = Data(repeating: 100, count: 40 * 20 * 4)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: 40, height: 20, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 160,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bitmap = PreviewBitmap(image: image)
        let model = LocalAdjustmentEditorModel(settings: .neutral, loader: { _ in bitmap })
        let workspace = InlineMaskWorkspace()
        #expect(workspace.open(asset: asset, source: try editor.resolvedSource(for: asset).identity,
            settings: .neutral, editor: editor, library: library, model: model))
        try await compactMaskWait { workspace.canvasSize != nil }
        return Self(directory: directory, library: library, editor: editor, model: model, workspace: workspace)
    }

    func close() { workspace.cancel(); try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private final class CompactMaskHost {
    private let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private let width: CGFloat

    init(width: CGFloat, height: CGFloat) {
        _ = NSApplication.shared
        WorkspaceAccessibilityElement.enableInProcess()
        self.width = width
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderBack(nil)
    }

    var fittingHeight: CGFloat { hosting.fittingSize.height }
    var elements: [WorkspaceAccessibilityElement] { WorkspaceAccessibilityElement.descendants(of: hosting) }
    var screenFrame: NSRect { window.convertToScreen(hosting.convert(hosting.bounds, to: nil)) }

    func element(_ identifier: String) throws -> WorkspaceAccessibilityElement {
        try #require(elements.first { $0.accessibilityIdentifier() == identifier }, "Missing native control: \(identifier)")
    }

    func mount(_ content: some View) async throws {
        hosting.rootView = AnyView(content.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top).preferredColorScheme(.dark))
        try await settle()
    }

    func settle() async throws {
        // Native windows share AppKit state on MainActor. Layout is ordered;
        // the synthetic bitmap loader still uses its normal asynchronous path.
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    func snapshotIfRequested(_ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["PICEDIT_COMPACT_MASK_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }

    func close() { window.close() }
}

@MainActor
private func compactMaskWait(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw TestSchedulingTimeout(operation: "compact mask fixture", lastState: "not ready") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private actor CompactMaskSnapshotStore: LegacySnapshotTestStore {
    func loadAll() -> [String: EditSettings] { [:] }
    func revisions() -> [String: Int64] { [:] }
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) {}
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/compact-mask-test-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { [:] }
}
