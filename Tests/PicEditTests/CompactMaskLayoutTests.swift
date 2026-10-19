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
