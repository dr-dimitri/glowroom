import AppKit
import Foundation
import GlowroomCore
import SwiftUI
import Testing
@testable import Glowroom

/// Sample actual native compositing: an opaque gray image can pass a mask
/// factory test while SwiftUI still tints every pixel outside the selection.
@Suite("Repair mask overlay native pixels", .serialized)
@MainActor
struct DevelopRepairOverlayTests {
    @Test(arguments: ["candidate", "saved"])
    func onlyMaskedPixelsChangeAndSelectionChangesTheirTint(kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-RepairOverlay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = PhotoAsset(folderID: UUID(), fileURL: directory.appendingPathComponent("Photo.png"),
            pixelWidth: 200, pixelHeight: 150)
        let editor = EditingModel(directory: directory.appendingPathComponent("Editing"))
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isLoading {
            guard ContinuousClock.now < deadline else {
                throw TestSchedulingTimeout(operation: "repair overlay fixture", lastState: "editor is loading")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let workspace = DevelopWorkspace()
        defer { workspace.clear() }
        let source = AISourceIdentity.original(.init(fileURL: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize))
        workspace.bind(source: source); workspace.markDisplayed(source: source, settings: .newEditingSettings)
        workspace.tool = .repair
        var bytes = Data(repeating: 0, count: 32 * 24)
        for y in 9..<15 { for x in 12..<20 { bytes[y * 32 + x] = 255 } }
        let mask = try LocalMaskRaster(width: 32, height: 24, bytes: bytes)
        let center = try LocalMaskPoint(x: 0.5, y: 0.5)
        let id: UUID
        if kind == "candidate" {
            let candidate = DevelopRepairCandidate(id: UUID(), label: "Staub 1", mask: mask, center: center, radius: 0.1)
            workspace.repairCandidates = [candidate]
            id = candidate.id
        } else {
            // A stored AI patch has a target pin but no source connector. Keep
            // the sampled mask interior clear of that intentional pin.
            let replacement = try DevelopRetouchReplacement(bounds: DevelopCropRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                width: 2, height: 2, rgba: Data(repeating: 120, count: 16))
            let stroke = try DevelopRetouchStroke(source: center, target: center, radius: 0.1,
                mask: mask, replacement: replacement)
            var settings = EditSettings.newEditingSettings
            settings.developGeometry.retouchStrokes = [stroke]
            editor.setSettings(settings, for: asset.id)
            id = stroke.id
        }
        workspace.repairOverlay = .never
        let host = RepairOverlayPixelHost()
        defer { host.close() }
        try await host.mount(ZStack {
            Color(.sRGB, red: 0.2, green: 0.3, blue: 0.4, opacity: 1)
            DevelopRepairCanvas(asset: asset, workspace: workspace)
        }.environmentObject(editor))
        let baseline = try host.snapshot()
        workspace.repairOverlay = .always
        if kind == "candidate" { workspace.repairSelectedCandidateIDs = [id] }
        else { workspace.repairSelectedStrokeID = id }
        try await host.settle()
        let selected = try host.snapshot()
        workspace.repairSelectedCandidateIDs = []; workspace.repairSelectedStrokeID = nil
        try await host.settle()
        let unselected = try host.snapshot()

        for point in [CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.85, y: 0.15),
                      CGPoint(x: 0.15, y: 0.85), CGPoint(x: 0.85, y: 0.85)] {
            let reference = try pixel(baseline, at: point)
            #expect(try distance(reference, pixel(selected, at: point)) < 0.01,
                    "Selected \(kind) mask must leave pixels outside its region unchanged")
            #expect(try distance(reference, pixel(unselected, at: point)) < 0.01,
                    "Unselected \(kind) mask must leave pixels outside its region unchanged")
        }
        let interior = CGPoint(x: 0.44, y: 0.56)
        let originalColor = try pixel(baseline, at: interior)
        let selectedColor = try pixel(selected, at: interior)
        let unselectedColor = try pixel(unselected, at: interior)
        #expect(distance(originalColor, selectedColor) > 0.03, "Selected mask must visibly mark its interior")
        #expect(distance(originalColor, unselectedColor) > 0.01, "Unselected mask must retain its review outline/tint")
        #expect(distance(selectedColor, unselectedColor) > 0.03, "Selection must be distinguishable in the image")
        #expect(await editor.finishSaving())
    }

    private func pixel(_ image: NSBitmapImageRep, at point: CGPoint) throws -> [Double] {
        let color = try #require(image.colorAt(x: Int(point.x * Double(image.pixelsWide)),
            y: Int(point.y * Double(image.pixelsHigh)))?.usingColorSpace(.sRGB))
        return [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
    }
    private func distance(_ first: [Double], _ second: [Double]) -> Double {
        zip(first, second).map { abs($0 - $1) }.max() ?? 0
    }
}

@MainActor
private final class RepairOverlayPixelHost {
    private let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 150),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        window.contentView = hosting; window.orderBack(nil)
    }
    func mount(_ content: some View) async throws {
        hosting.rootView = AnyView(content.frame(width: 200, height: 150).preferredColorScheme(.dark))
        try await settle()
    }
    func settle() async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
    }
    func snapshot() throws -> NSBitmapImageRep {
        let image = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        return image
    }
    func close() { hosting.rootView = AnyView(EmptyView()); window.close() }
}
