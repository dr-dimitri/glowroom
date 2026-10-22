import AppKit
import Darwin
import Foundation
import GlowroomCore
import QuartzCore
import SwiftUI
import Testing
@testable import Glowroom

/// SwiftUI gesture tracking owns native process state. Run the held-pointer
/// sequence in an isolated child so other AppKit suites cannot alter delivery.
@Suite("Inline mask canvas native cursor", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct InlineMaskCanvasInputTests {
    @Test func brushCursorFollowsHeldDragWithoutHoverAndTheStrokeRemainsUndoable() async throws {
        try await runInlineMaskCursorChild()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment[inlineMaskCursorResult] != nil))
    func inlineMaskCursorChildOnly() async throws {
        let environment = ProcessInfo.processInfo.environment
        let result = try #require(environment[inlineMaskCursorResult])
        let token = try #require(environment[inlineMaskCursorToken])
        let fixture = try await InlineMaskCursorFixture.make()
        let host = InlineMaskCursorHost()
        defer { host.close(); fixture.close() }
        try await host.mount(fixture.workspace)

        // No hover events are delivered. The real held drag must update both
        // the stroke and the visible cursor, even though the red mask is clear.
        let first = CGPoint(x: 120, y: 100), second = CGPoint(x: 280, y: 100)
        try host.send(.leftMouseDown, at: CGPoint(x: 80, y: 100))
        try host.send(.leftMouseDragged, at: first)
        try await inlineMaskCursorWait("first native brush point") {
            fixture.workspace.brush.previewDocument?.strokes.last?.points.last?.x == Double(first.x)
        }
        try await host.requireCursor(at: first, absentAt: second)
        try #require(fixture.workspace.brush.document?.strokes.isEmpty == true,
                     "The pointer remains held: no stroke may be committed yet")

        try host.send(.leftMouseDragged, at: second)
        try await inlineMaskCursorWait("second native brush point") {
            fixture.workspace.brush.previewDocument?.strokes.last?.points.last?.x == Double(second.x)
        }
        try await host.requireCursor(at: second, absentAt: first)
        try #require(fixture.workspace.brush.document?.strokes.isEmpty == true,
                     "The moved ring must be visible before mouse-up commits the stroke")

        try host.send(.leftMouseUp, at: second)
        try await inlineMaskCursorWait("accepted native brush stroke") {
            fixture.workspace.brush.document?.strokes.count == 1
        }
        let document = try #require(fixture.workspace.brush.document)
        try #require(document.strokes[0].points.last?.x == Double(second.x))
        fixture.workspace.undo()
        try #require(fixture.workspace.brush.document?.strokes.isEmpty == true,
                     "Both held-drag updates must share one undo boundary")
        try #require(await fixture.editor.flush())
        try #require(await fixture.library.finishSaving())
        // A native AppKit loop can exit its test host early with status zero.
        // This marker proves every input, rendered-pixel and undo check ran.
        try token.write(to: URL(fileURLWithPath: result), atomically: true, encoding: .utf8)
    }
}

@MainActor
private struct InlineMaskCursorFixture {
    let directory: URL
    let library: LibraryModel
    let editor: EditingModel
    let workspace: InlineMaskWorkspace

    static func make() async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-MaskCursor-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: directory.appendingPathComponent("synthetic.jpg"))
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: [asset]))
        let library = LibraryModel(repository: repository)
        let editor = EditingModel(directory: directory.appendingPathComponent("Edits"))
        try await inlineMaskCursorWait("mask cursor fixture") {
            !library.isLoading && !library.isProjecting && !editor.isLoading
        }
        library.selectedID = asset.id
        let context = try #require(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8,
            bytesPerRow: 400 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bitmap = PreviewBitmap(image: try #require(context.makeImage()))
        let model = LocalAdjustmentEditorModel(settings: .neutral, loader: { _ in bitmap })
        let workspace = InlineMaskWorkspace()
        let source = try editor.resolvedSource(for: asset).identity
        try #require(workspace.open(asset: asset, source: source,
            settings: .neutral, editor: editor, library: library, model: model))
        try await inlineMaskCursorWait("mask cursor canvas") { workspace.canvasSize != nil }
        model.add(.brush)
        // Zero coverage keeps snapshots independent of asynchronous mask
        // rasterization. The white ring is still the production brush cursor.
        model.updateSelected { $0.mask.opacity = 0 }
        workspace.brush.radius = 12
        workspace.brush.hardness = 0.8
        return Self(directory: directory, library: library, editor: editor, workspace: workspace)
    }

    func close() { workspace.cancel(); try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private final class InlineMaskCursorHost {
    private let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var lastPoint = CGPoint.zero
    private var pointerIsHeld = false
    private var eventNumber = 0

    init() {
        _ = NSApplication.shared
        window = InlineMaskCursorWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 200),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderBack(nil)
    }

    func mount(_ workspace: InlineMaskWorkspace) async throws {
        hosting.rootView = AnyView(Color.black.overlay { InlineMaskCanvas(workspace: workspace) }
            .frame(width: 400, height: 200).preferredColorScheme(.dark))
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
        try #require(hosting.bounds.size == CGSize(width: 400, height: 200))
    }

    func send(_ type: NSEvent.EventType, at point: CGPoint) throws {
        lastPoint = point
        if type == .leftMouseDown { pointerIsHeld = true }
        if type == .leftMouseUp { pointerIsHeld = false }
        eventNumber += 1
        let event = try #require(NSEvent.mouseEvent(with: type, location: hosting.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        window.sendEvent(event)
    }

    func requireCursor(at point: CGPoint, absentAt previous: CGPoint) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        var currentCount = 0, previousCount = 0
        repeat {
            hosting.layoutSubtreeIfNeeded()
            hosting.needsDisplay = true
            hosting.displayIfNeeded(); CATransaction.flush()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            currentCount = brightPixelCount(bitmap, around: point)
            previousCount = brightPixelCount(bitmap, around: previous)
            if currentCount >= 20 && previousCount == 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        try #require(currentCount >= 20 && previousCount == 0,
            "Held-drag cursor pixels must move to \(point); current=\(currentCount), previous=\(previousCount)")
    }

    private func brightPixelCount(_ bitmap: NSBitmapImageRep, around point: CGPoint) -> Int {
        let sx = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        let sy = CGFloat(bitmap.pixelsHigh) / hosting.bounds.height
        // Both checkpoints use the vertical center, independent of bitmap row
        // direction. A generous box includes the full antialiased 12-point ring.
        let x0 = max(0, Int((point.x - 16) * sx)), x1 = min(bitmap.pixelsWide - 1, Int((point.x + 16) * sx))
        let y0 = max(0, Int((point.y - 16) * sy)), y1 = min(bitmap.pixelsHigh - 1, Int((point.y + 16) * sy))
        var count = 0
        for y in y0...y1 {
            for x in x0...x1 {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.redComponent > 0.7, color.greenComponent > 0.7, color.blueComponent > 0.7 { count += 1 }
            }
        }
        return count
    }

    func close() {
        if pointerIsHeld { try? send(.leftMouseUp, at: lastPoint) }
        hosting.rootView = AnyView(EmptyView())
        window.close()
    }
}

@MainActor
private final class InlineMaskCursorWindow: NSWindow {
    // Exercise production event dispatch without activating the test process
    // or changing the user's actual key window.
    override var isKeyWindow: Bool { true }
}

@MainActor
private func inlineMaskCursorWait(_ operation: String, until predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
        guard ContinuousClock.now < deadline else {
            throw TestSchedulingTimeout(operation: operation, lastState: "native canvas state did not arrive")
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private let inlineMaskCursorResult = "GLOWROOM_TEST_MASK_CURSOR_RESULT"
private let inlineMaskCursorToken = "GLOWROOM_TEST_MASK_CURSOR_TOKEN"

private func runInlineMaskCursorChild() async throws {
    // Process launch/reaping block; keep them off MainActor and the cooperative
    // executor. The suite admits just this one native child at a time.
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do { try launchInlineMaskCursorChild(); continuation.resume() }
            catch { continuation.resume(throwing: error) }
        }
    }
}

private func launchInlineMaskCursorChild() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-MaskCursorChild-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = directory.appendingPathComponent("complete.txt"), log = directory.appendingPathComponent("child.log")
    try Data().write(to: log)
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let token = UUID().uuidString, invocation = CommandLine.arguments
    let child = Process(), ended = DispatchSemaphore(value: 0)
    child.executableURL = URL(fileURLWithPath: invocation[0])
    var arguments: [String] = []
    if let index = invocation.firstIndex(of: "--test-bundle-path"), index + 1 < invocation.count {
        arguments = ["--test-bundle-path", invocation[index + 1]]
    }
    child.arguments = arguments + ["--testing-library", "swift-testing", "--filter", "inlineMaskCursorChildOnly"]
    var environment = ProcessInfo.processInfo.environment
    environment[inlineMaskCursorResult] = result.path; environment[inlineMaskCursorToken] = token
    child.environment = environment
    child.standardOutput = output; child.standardError = output
    child.terminationHandler = { _ in ended.signal() }
    try child.run()
    let completed = ended.wait(timeout: .now() + 25) == .success
    if !completed {
        if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
        _ = ended.wait(timeout: .now() + 2)
    }
    let marker = try? String(contentsOf: result, encoding: .utf8)
    guard completed, child.terminationReason == .exit, child.terminationStatus == 0, marker == token else {
        let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? "No child log"
        throw InlineMaskCursorChildFailure(description:
            "Native mask cursor child: completed=\(completed), completion marker=\(marker == token)\n\(logText.suffix(65_536))")
    }
}

private struct InlineMaskCursorChildFailure: Error, CustomStringConvertible {
    let description: String
}
