import AppKit
import Foundation
import PicEditCore
import SwiftUI
import Testing
@testable import PicEdit

/// These small native layouts stay ordered because AppKit shares window state.
@Suite("Develop photo header native layout", .serialized)
@MainActor
struct DevelopPhotoHeaderTests {
    private let summary = "1/300s, f5,6, ISO 200, 56mm, 12.04.2026"
    private let previewLabel = "Bearbeitete Vorschau"

    @Test(arguments: [320.0, 1_000.0])
    func captureDataFitsAndUsesASecondRowOnlyWhenNeeded(width: Double) async throws {
        let asset = try sampleAsset(fileName: "DSCF0001.RAF")
        let host = PhotoHeaderHost(width: width)
        defer { host.close() }
        try await host.mount(DevelopPhotoHeader(asset: asset, previewLabel: previewLabel))

        let filename = try #require(host.text(asset.fileName))
        let capture = try #require(host.text("Aufnahmedaten: \(summary)"),
            "The complete catalog capture data must remain accessible")
        let source = try #require(host.text(previewLabel))
        for element in [filename, capture, source] {
            #expect(host.contains(element), "Header text must stay visible inside the available width")
        }
        #expect(host.headerSize.width == width && host.headerSize.height <= 70)
        if width == 320 {
            #expect(capture.accessibilityFrame().maxY < filename.accessibilityFrame().minY,
                "A narrow canvas must put capture data below the filename")
        } else {
            #expect(abs(capture.accessibilityFrame().midY - filename.accessibilityFrame().midY) <= 1,
                "A wide canvas should keep filename and capture data on one row")
            #expect(host.headerSize.height <= 31)
        }
        try host.snapshotIfRequested("develop-header-\(Int(width))")
    }

    @Test
    func longFilenameKeepsCompleteCaptureDataInsideANarrowHeader() async throws {
        let asset = try sampleAsset(fileName: String(repeating: "Langer_Dateiname_", count: 10) + ".RAF")
        let host = PhotoHeaderHost(width: 320)
        defer { host.close() }
        try await host.mount(DevelopPhotoHeader(asset: asset, previewLabel: previewLabel))

        let filename = try #require(host.text(asset.fileName), "The full filename must remain accessible after truncation")
        let capture = try #require(host.text("Aufnahmedaten: \(summary)"))
        #expect(host.contains(filename) && host.contains(capture))
        #expect(capture.accessibilityFrame().maxY < filename.accessibilityFrame().minY)
        #expect(host.headerSize.width == 320 && host.headerSize.height <= 70)
        try host.snapshotIfRequested("develop-header-long-filename")
    }

    @Test
    func missingCaptureDataDoesNotRenderAPlaceholderRow() async throws {
        let asset = PhotoAsset(folderID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/no-header-metadata.jpg"))
        let host = PhotoHeaderHost(width: 320)
        defer { host.close() }
        try await host.mount(DevelopPhotoHeader(asset: asset, previewLabel: previewLabel))

        #expect(host.text(asset.fileName) != nil && host.text(previewLabel) != nil)
        #expect(!host.elements.contains { $0.accessibilityLabel()?.hasPrefix("Aufnahmedaten:") == true })
        #expect(host.headerSize.height <= 31)
    }

    private func sampleAsset(fileName: String) throws -> PhotoAsset {
        let calendar = Calendar(identifier: .gregorian)
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 12, hour: 12)))
        return PhotoAsset(folderID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/header-layout.RAF"),
            fileName: fileName, captureDate: date, focalLength: "56 mm", aperture: "ƒ/5.6",
            shutterSpeed: "1/300 s", iso: "200")
    }
}

@MainActor
private final class PhotoHeaderHost {
    private let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private let width: CGFloat
    private(set) var headerSize = CGSize.zero

    init(width: CGFloat) {
        _ = NSApplication.shared
        WorkspaceAccessibilityElement.enableInProcess()
        self.width = width
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 80),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderBack(nil)
    }

    var elements: [WorkspaceAccessibilityElement] { WorkspaceAccessibilityElement.descendants(of: hosting) }

    func text(_ value: String) -> WorkspaceAccessibilityElement? {
        elements.first {
            $0.accessibilityRole() == .staticText &&
                ($0.accessibilityLabel() == value || $0.accessibilityValue() as? String == value)
        }
    }

    func contains(_ element: WorkspaceAccessibilityElement) -> Bool {
        let frame = element.accessibilityFrame()
        let screenFrame = window.convertToScreen(hosting.convert(hosting.bounds, to: nil))
        return frame.width > 0 && frame.height > 0 && screenFrame.insetBy(dx: -1, dy: -1).contains(frame)
    }

    func mount(_ content: some View) async throws {
        hosting.rootView = AnyView(content.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] in self?.headerSize = $0 }
            .frame(maxHeight: .infinity, alignment: .top).preferredColorScheme(.dark))
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    func snapshotIfRequested(_ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["PICEDIT_HEADER_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
    }

    func close() { window.close() }
}
