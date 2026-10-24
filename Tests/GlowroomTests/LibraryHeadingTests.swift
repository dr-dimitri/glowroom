import AppKit
import Foundation
import GlowroomCore
import SwiftUI
import Testing
@testable import Glowroom

/// AppKit window and accessibility state are shared, so native layouts stay ordered.
@Suite("Library heading native layout", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LibraryHeadingTests {
    @Test(arguments: [320.0, 640.0, 1_180.0], LibrarySearchMode.allCases)
    func searchAndControlsShareOneRowWithoutCollectionHeading(width: Double, mode: LibrarySearchMode) async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        model.searchMode = mode
        await model.waitForProjection()
        let host = LibraryHeadingHost(width: width)
        defer { host.close() }
        try await host.mount(LibraryHeading(model: model, onShowGrid: {}))

        let search = try #require(host.element("library.search"))
        let refresh = try #require(host.element("library.refresh"))
        #expect(host.element("library.title") == nil && host.element("library.photo-count") == nil)
        #expect(host.text(model.title) == nil && host.text("2 Fotos") == nil)
        #expect(search.accessibilityRole() == .textField)
        #expect(search.accessibilityLabel() == (mode == .literal ? "Wörtliche Fotosuche" : "Semantische Bildsuche"))
        let modeControl = try #require(host.element("library.search-mode"))
        // Native macOS menu buttons expose their spoken name through AXTitle;
        // AXLabel is empty even when the visible title is correctly accessible.
        #expect(modeControl.accessibilityTitle() == "Suchmodus: \(mode.label)")
        var controls = [refresh, modeControl]
        if let options = host.element("library.options") {
            controls.append(options)
            #expect(width < 1_180, "Wide canvases should expose the individual controls")
        } else {
            for identifier in ["library.grid", "library.detail", "library.rating", "library.sort"] {
                controls.append(try #require(host.element(identifier)))
            }
            #expect(width > 320, "A narrow canvas should use the compact menu")
        }
        for element in [search] + controls {
            #expect(host.contains(element), "Search and controls must fit inside one header row")
            #expect(abs(element.accessibilityFrame().midY - refresh.accessibilityFrame().midY) <= 2,
                "All controls must share the same row")
        }
        #expect(search.accessibilityFrame().width >= 30, "Even the narrow search must remain editable")
        #expect(host.headerSize.width == width && host.headerSize.height == 42)
        #expect(host.text(model.subtitle) == nil, "The file path must not occupy a header row")
        #expect(host.text("DEINE BIBLIOTHEK") == nil)
        try host.snapshotIfRequested("library-heading-\(mode.rawValue)-\(Int(width))")
        #expect(await model.finishSaving())
    }

    @Test
    func wideToolbarSwitchesBetweenGridAndDetail() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        model.select(try #require(model.visibleAssets.first))
        var gridRequests = 0
        let host = LibraryHeadingHost(width: 1_180)
        defer { host.close() }
        try await host.mount(LibraryHeading(model: model) {
            gridRequests += 1
            model.showsDetail = false
        })

        let detail = try #require(host.element("library.detail"))
        #expect(detail.accessibilityPerformPress())
        try await host.settle { model.showsDetail }
        let grid = try #require(host.element("library.grid"))
        #expect(grid.accessibilityPerformPress())
        try await host.settle { !model.showsDetail && gridRequests == 1 }
        #expect(await model.finishSaving())
    }

    @Test(arguments: LibrarySearchMode.allCases)
    func clearSearchClearsTheVisibleModeAndPreservesTheOtherQuery(mode: LibrarySearchMode) async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        model.search = "first"
        model.semanticQuery = "Sonnenuntergang"
        model.searchMode = mode
        await model.waitForProjection()
        let host = LibraryHeadingHost(width: 320)
        defer { host.close() }
        try await host.mount(LibraryHeading(model: model, onShowGrid: {}))

        let search = try #require(host.element("library.search"))
        #expect(search.accessibilityValue() as? String == (mode == .literal ? "first" : "Sonnenuntergang"))
        let clear = try #require(host.element("library.clear-search"))
        #expect(host.contains(clear))
        #expect(clear.accessibilityPerformPress())
        try await host.settle {
            (mode == .literal ? model.search : model.semanticQuery).isEmpty
                && host.element("library.clear-search") == nil
        }
        #expect(model.search == (mode == .literal ? "" : "first"))
        #expect(model.semanticQuery == (mode == .semantic ? "" : "Sonnenuntergang"))
        #expect(host.element("library.search")?.accessibilityValue() as? String == "")
        #expect(host.headerSize.width == 320 && host.headerSize.height == 42)
        await model.waitForProjection()
        #expect(await model.finishSaving())
    }

    @Test(arguments: [320.0, 640.0])
    func narrowReferenceKeepsModeReferenceAndEndActionReachable(width: Double) async throws {
        let fixture = try await makeFixture(semanticSearchEnabled: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = fixture.model
        let reference = try #require(model.visibleAssets.first)
        model.select(reference)
        model.minimumRating = 4
        model.findSimilarImages()
        await model.waitForProjection()
        let host = LibraryHeadingHost(width: width, height: 220)
        defer { host.close() }
        try await host.mount(VStack(spacing: 0) {
            LibraryHeading(model: model, onShowGrid: {})
            LibrarySearchStatusView(model: model)
        }, requiresSearch: false)
        try await host.settle { host.element("library.end-similarity") != nil }
        let mode = try #require(host.element("library.search-mode"))
        #expect(mode.accessibilityTitle() == "Suchmodus: Ähnliche Bilder")
        for identifier in ["library.search-mode", "library.search-reference", "library.clear-search", "library.search-scope", "library.active-rating", "library.search-results", "library.end-similarity", "library.reset-search"] {
            let element = try #require(host.element(identifier))
            #expect(host.contains(element), "Reference and search actions must fit even on the narrow library canvas: \(identifier)")
        }
        #expect((host.element("library.search-reference")?.accessibilityFrame().width ?? 0) >= 60)
        let end = try #require(host.element("library.end-similarity"))
        #expect(end.accessibilityPerformPress())
        try await host.settle { model.similarityReference == nil && model.searchMode == .literal }
        await model.waitForProjection()
        #expect(await model.finishSaving())
    }

    @Test(arguments: [false, true])
    func filmstripFiltersOnlyAppearInDevelop(developing: Bool) async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.model.isDeveloping = developing
        fixture.model.search = "no matching photos"
        await fixture.model.waitForProjection()
        let host = LibraryHeadingHost(width: 640, height: 160)
        defer { host.close() }
        try await host.mount(PhotoFilmstrip(model: fixture.model, height: 120), requiresSearch: false)
        #expect((host.element("filmstrip.filters") != nil) == developing)
        #expect(await fixture.model.finishSaving())
    }

    @Test
    func semanticStatusShowsScopeRatingAndSetupWithoutInlineManagement() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.model.searchMode = .semantic
        fixture.model.minimumRating = 4
        await fixture.model.waitForProjection()
        let host = LibraryHeadingHost(width: 640)
        defer { host.close() }
        try await host.mount(LibrarySearchStatusView(model: fixture.model), requiresSearch: false)
        #expect(host.element("library.active-rating") != nil)
        #expect(host.element("library.search-scope") != nil)
        #expect(host.element("library.additional-filter") != nil)
        let setup = try #require(host.element("library.search-setup"))
        #expect(setup.accessibilityPerformPress())
        #expect(fixture.model.aiModelsDestination == .search)
        #expect(host.element("ai-models.search.import") == nil)
        #expect(host.element("ai-models.index.prepare") == nil)
        #expect(await fixture.model.finishSaving())
    }

    private func makeFixture(semanticSearchEnabled: Bool = false) async throws -> (directory: URL, model: LibraryModel) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-LibraryHeading-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = LibraryFolder(url: directory.appendingPathComponent("Photos"),
            name: String(repeating: "Ein langer Fotoordner für die Bibliothek ", count: 4))
        let assets = ["first.jpg", "second.jpg"].map {
            PhotoAsset(folderID: folder.id, fileURL: folder.url.appendingPathComponent($0))
        }
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: assets))
        let service: (any SemanticSearchServing)? = semanticSearchEnabled
            ? try SemanticSearchService(directory: directory.appendingPathComponent("Semantic")) : nil
        let model = LibraryModel(repository: repository, semanticSearch: service)
        // This layout fixture has no imports or mutations. Join its actual
        // startup task through the normal drain instead of racing MainActor
        // scheduling against a wall-clock readiness poll. The suite watchdog
        // still bounds a genuinely stuck load; all layout assertions remain.
        await model.drainAcceptedCatalogOperations()
        try Task.checkCancellation()
        try #require(!model.isLoading && model.errorMessage == nil)
        try #require(model.assets.count == assets.count)
        model.selection = .folder(folder.id)
        await model.waitForProjection()
        return (directory, model)
    }
}

private enum LibraryHeadingTestError: Error { case timeout }

@MainActor
private final class LibraryHeadingHost {
    private let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private let width: CGFloat
    private(set) var headerSize = CGSize.zero

    init(width: CGFloat, height: CGFloat = 60) {
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

    private var elements: [WorkspaceAccessibilityElement] { WorkspaceAccessibilityElement.descendants(of: hosting) }

    func element(_ identifier: String) -> WorkspaceAccessibilityElement? {
        elements.first { $0.accessibilityIdentifier() == identifier }
    }

    func text(_ value: String) -> WorkspaceAccessibilityElement? {
        elements.first {
            $0.accessibilityRole() == .staticText
                && ($0.accessibilityLabel() == value || $0.accessibilityValue() as? String == value)
        }
    }

    func contains(_ element: WorkspaceAccessibilityElement) -> Bool {
        let frame = element.accessibilityFrame()
        let screenFrame = window.convertToScreen(hosting.convert(hosting.bounds, to: nil))
        return frame.width > 0 && frame.height > 0 && screenFrame.insetBy(dx: -1, dy: -1).contains(frame)
    }

    func mount(_ content: some View, requiresSearch: Bool = true) async throws {
        hosting.rootView = AnyView(content.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] in self?.headerSize = $0 }
            .frame(maxHeight: .infinity, alignment: .top).preferredColorScheme(.dark))
        try await settle { self.headerSize.height > 0 && (!requiresSearch || self.element("library.search") != nil) }
    }

    func settle(until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            if predicate() { return }
            guard ContinuousClock.now < deadline else { throw LibraryHeadingTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        } while true
    }

    func snapshotIfRequested(_ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["GLOWROOM_HEADER_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
    }

    func close() { window.close() }
}
