import AppKit
import PicEditCore
import SwiftUI
import Testing
@testable import PicEdit

/// Native layout measurements are opt-in, because they render many windows.
/// No personal catalog, model download or cloud request is involved.
@Suite("Native workspace geometry", .serialized)
@MainActor
struct WorkspaceGeometryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PICEDIT_WORKSPACE_MEASUREMENTS"] != nil))
    func measureFittedLandscapeAndPortrait() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PICEDIT_WORKSPACE_MEASUREMENTS"]!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Geometry-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "PicEdit-Geometry-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = WorkspaceLayoutModel(defaults: defaults)
        let folder = LibraryFolder(url: directory)
        let assets = try [(1_200, 800), (800, 1_200)].map { width, height in
            let url = directory.appendingPathComponent("\(width)x\(height).png")
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor(srgbRed: 1, green: 0.2, blue: 0.4, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))).fill()
            NSGraphicsContext.restoreGraphicsState()
            let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path)
            return PhotoAsset(folderID: folder.id, fileURL: url, fileSize: Int64(bytes.count),
                pixelWidth: width, pixelHeight: height,
                createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 1))
        }
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: assets))
        let library = LibraryModel(repository: repository)
        let editor = EditingModel(directory: directory.appendingPathComponent("Editing"))
        let provider = LocalAIEditingProvider(runtime: UnavailableLocalAIModelRuntime(reason: .sdkUnavailable))
        let assistant = AIAssistantModel(provider: provider,
            coordinator: AIRequestCoordinator(provider: provider, budget: AIResourceBudget()), editor: editor, library: library)
        let analysisService = ImageAnalysisService(provider: UnavailableImageAnalysisProvider(reason: .sdkUnavailable), budget: AIResourceBudget())
        let analysis = ImageAnalysisModel(service: analysisService, editor: editor, library: library)
        let metadata = PhotoMetadataModel(store: PhotoMetadataRepository(directory: directory.appendingPathComponent("Metadata")),
            suggestor: LocalPhotoMetadataSuggestor(service: analysisService), library: library, editor: editor)
        let exporter = JPEGExportModel(preferences: nil)
        try await eventually { !library.isLoading && !library.isProjecting && !editor.isLoading }
        library.isDeveloping = true
        library.showsDetail = true
        var records: [Measurement] = []
        // SwiftUI window state is shared on MainActor. These measurements must
        // stay ordered; decoding and rendering use the normal background caches.
        for size in [NSSize(width: 1_000, height: 660), NSSize(width: 1_440, height: 900), NSSize(width: 1_920, height: 1_080)] {
            let host = GeometryHost(size: size)
            defer { host.window.close() }
            #if PICEDIT_WORKSPACE_BASELINE
            let root = HistoricalLibraryView(model: library, dataDirectory: directory)
            let states = ["baseline"]
            #else
            let root = LibraryView(model: library, dataDirectory: directory)
            let states = ["classic-open", "classic-closed", "focus-open", "focus-closed"]
            #endif
            host.mount(root
                .environmentObject(editor).environmentObject(exporter).environmentObject(layout)
                .environmentObject(assistant).environmentObject(analysis).environmentObject(metadata)
                .environment(\.workspaceCanvasMeasurement, { [weak host] size in host?.canvasSize = size })
                .preferredColorScheme(.dark))
            for asset in assets {
                library.select(asset)
                for state in states {
                    #if !PICEDIT_WORKSPACE_BASELINE
                    if state.hasPrefix("focus"), !layout.isFocused { WorkspaceActions.toggleFocus(layout, library: library) }
                    if state.hasPrefix("classic"), layout.isFocused { WorkspaceActions.toggleFocus(layout, library: library) }
                    layout.update(developing: true) {
                        $0.showsLibrary = state == "classic-open"
                        $0.showsTools = state.hasSuffix("open")
                        $0.showsFilmstrip = state == "classic-open"
                    }
                    #endif
                    host.layout()
                    #if !PICEDIT_WORKSPACE_BASELINE
                    #expect(host.contentSize == size)
                    #endif
                    try await eventually { host.elements.contains { $0.accessibilityRole() == .image && $0.accessibilityLabel() == asset.fileName } }
                    // Let deferred SwiftUI layout and cached image publication settle.
                    try await Task.sleep(for: .milliseconds(80))
                    host.layout()
                    // Accessibility groups use the union of their children, not
                    // the empty canvas margins. NSImageView also fills its layout
                    // box while proportionally drawing inside it. Measure the
                    // synthetic pink pixels in its native snapshot separately.
                    let viewport = host.canvasSize
                    #if PICEDIT_WORKSPACE_BASELINE
                    let rendered = try #require(host.elements.filter { $0.accessibilityRole() == .image && $0.accessibilityLabel() == asset.fileName }
                        .max { $0.accessibilityFrame().width * $0.accessibilityFrame().height < $1.accessibilityFrame().width * $1.accessibilityFrame().height }).accessibilityFrame().size
                    #else
                    let rendered = try host.renderedImageSize()
                    #endif
                    #expect(viewport.width > 0 && viewport.height > 0)
                    #expect(abs(rendered.width / rendered.height - Double(asset.pixelWidth) / Double(asset.pixelHeight)) < 0.01)
                    #expect(rendered.width <= viewport.width + 1 && rendered.height <= viewport.height + 1)
                    records.append(Measurement(requestedWindowWidth: size.width, requestedWindowHeight: size.height,
                        windowWidth: host.contentSize.width, windowHeight: host.contentSize.height, state: state,
                        image: asset.fileName, viewportWidth: viewport.width, viewportHeight: viewport.height,
                        imageWidth: rendered.width, imageHeight: rendered.height))
                    try host.snapshot(to: output.appendingPathComponent("\(state)-\(Int(size.width))-\(asset.fileName)"))
                }
                #if !PICEDIT_WORKSPACE_BASELINE
                if size.width == 1_440 {
                    let zoom = try #require(host.elements.first { $0.accessibilityIdentifier() == "workspace.zoom" })
                    #expect(zoom.accessibilityPerformPress())
                    try await eventually { host.elements.contains { $0.accessibilityRole() == .image && $0.accessibilityLabel() == asset.fileName } }
                    try await Task.sleep(for: .milliseconds(80)); host.layout()
                    func imageSize() throws -> NSSize {
                        try host.renderedImageSize()
                    }
                    let magnified = try imageSize()
                    layout.update(developing: true) { $0.showsTools = true; $0.showsFilmstrip = true }
                    try await eventually { host.elements.contains { $0.accessibilityRole() == .image && $0.accessibilityLabel() == asset.fileName } }
                    try await Task.sleep(for: .milliseconds(80)); host.layout()
                    #expect(try imageSize() == magnified)
                    #expect(try #require(host.elements.first { $0.accessibilityIdentifier() == "workspace.zoom" }).accessibilityPerformPress())
                }
                #endif
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: output.appendingPathComponent("native-layout-measurements.json"))
        #expect(await editor.flush())
        #expect(await metadata.finishSaving())
        #expect(await library.finishSaving())
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw MeasurementError.timeout }
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    private struct Measurement: Codable {
        let requestedWindowWidth, requestedWindowHeight: Double
        let windowWidth, windowHeight: Double
        let state, image: String
        let viewportWidth, viewportHeight, imageWidth, imageHeight: Double
    }
    private enum MeasurementError: Error { case timeout }
}

@MainActor
private final class GeometryHost {
    let window: NSWindow
    var canvasSize = CGSize.zero
    var contentSize: NSSize { hosting.bounds.size }
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    init(size: NSSize) {
        _ = NSApplication.shared
        WorkspaceAccessibilityElement.enableInProcess()
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderBack(nil)
    }
    func mount(_ view: some View) { hosting.rootView = AnyView(view); layout() }
    func layout() { hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded() }
    var elements: [WorkspaceAccessibilityElement] { WorkspaceAccessibilityElement.descendants(of: hosting) }
    func renderedImageSize() throws -> NSSize {
        var pending: [NSView] = [hosting]
        var images: [NSImageView] = []
        while let view = pending.popLast() {
            pending.append(contentsOf: view.subviews)
            if let image = view as? NSImageView, image.image != nil { images.append(image) }
        }
        let mainImage = try #require(images.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        let snapshot = try #require(mainImage.bitmapImageRepForCachingDisplay(in: mainImage.bounds))
        mainImage.cacheDisplay(in: mainImage.bounds, to: snapshot)
        let image = try #require(snapshot.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var minX = width, minY = height, maxX = -1, maxY = -1
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let rgba = bytes.bindMemory(to: UInt8.self)
            func isPink(x: Int, y: Int) -> Bool {
                let index = (y * width + x) * 4
                return rgba[index] > 220 && rgba[index + 1] < 100
                    && rgba[index + 2] > 65 && rgba[index + 2] < 160
            }
            // The solid fixture is centered. Scan its two central axes rather
            // than every pixel; independent view snapshots remain ordered.
            for x in 0..<width where isPink(x: x, y: height / 2) {
                minX = min(minX, x); maxX = max(maxX, x)
            }
            for y in 0..<height where isPink(x: width / 2, y: y) {
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        try #require(maxX >= minX && maxY >= minY, "The native snapshot contains the synthetic pink photo")
        return NSSize(width: Double(maxX - minX + 1) * mainImage.bounds.width / Double(width),
                      height: Double(maxY - minY + 1) * mainImage.bounds.height / Double(height))
    }
    func snapshot(to url: URL) throws {
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
