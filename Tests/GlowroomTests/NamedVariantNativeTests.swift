import AppKit
import Foundation
import Darwin
import GlowroomCore
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Glowroom

/// Opt in separately: real focus/menu tracking is process-global AppKit state.
@Suite("Named variants native acceptance", .serialized, .timeLimit(.minutes(3)))
struct NamedVariantNativeTests: Sendable {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_223_NATIVE"] != nil))
    func realButtonsNameFocusPreviewEscapeRestoreAndMetadata() async throws {
        // Native menu dismissal can stop SwiftPM's outer AppKit loop. A parent
        // process therefore requires all fatal scenario checkpoints and kernel
        // reaping from the bounded child, even if Cocoa stops the SDK reporter.
        guard ProcessInfo.processInfo.environment[namedVariantChildToken] != nil else {
            try await runNamedVariantNativeChild()
            return
        }
        try await runProtectedNativeAcceptanceScenario { try await self.runNativeScenario() }
    }

    @MainActor
    private func runNativeScenario() async throws {
        var stages: [String] = []
        func checkpoint(_ stage: String) {
            stages.append(stage)
            print("NATIVE_223_CHECKPOINT \(stage)")
            fflush(stdout)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-223-native-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Synthetic.png")
        let color = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 1200, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); try #require(CGImageDestinationFinalize(destination))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: url, fileSize: (attributes[.size] as! NSNumber).int64Value,
            pixelWidth: 300, pixelHeight: 200, modifiedAt: attributes[.modificationDate] as! Date)
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(.init(folders: [folder], assets: [asset]))
        let library = LibraryModel(repository: repository), editor = EditingModel(directory: directory.appendingPathComponent("Edits"))
        try await wait { !library.isLoading && !library.isProjecting && !editor.isLoading }
        library.selectedID = asset.id; library.showsDetail = true; library.isDeveloping = true; editor.library = library
        var settings = editor.settings(for: asset.id); settings.exposure = 0.75
        editor.setSettings(settings, for: asset.id); try #require(await editor.flush())
        let suite = "Glowroom-223-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = WorkspaceLayoutModel(defaults: defaults)
        layout.update(developing: true) {
            $0.showsLibrary = true; $0.showsTools = true; $0.showsFilmstrip = false
            $0.libraryWidth = 300; $0.toolsWidth = 330; $0.openGroups = [.versions, .edit, .aiDevelopment]
        }
        let workspace = DevelopWorkspace(scopeDefaults: defaults)
        let metadata = PhotoMetadataModel(store: PhotoMetadataRepository(directory: directory.appendingPathComponent("Metadata")), suggestor: VariantNativeMetadataSuggestor(), library: library, editor: editor)
        let host = VariantNativeHost()
        var didCleanup = false
        defer { if !didCleanup { host.close(); workspace.clear(); library.beginTermination(); editor.beginTermination() } }
        try await host.mount(LibraryView(model: library, dataDirectory: directory, developWorkspace: workspace)
            .environmentObject(editor).environmentObject(layout).environmentObject(metadata)
            .environmentObject(JPEGExportModel(preferences: nil)))
        try await wait { workspace.navigatorImage != nil }
        checkpoint("setup")
        try #require(try host.element("workspace.group.versions").accessibilityLabel() == "Bildstände")
        try await host.press("variants.save")
        try await host.fillName(String(repeating: "x", count: 121))
        try #require(!host.canConfirmName, "A 121-grapheme name must stay unaccepted")
        let longName = String(repeating: "Warme Druckfassung ", count: 6) + "Fertig"
        try #require(longName.count == 120)
        try await host.fillName(longName)
        try await host.confirmName()
        try await wait { !editor.isManagingVariants && editor.variants.count == 1 }
        let variant = try #require(editor.variants.first)
        try #require(variant.name == longName)
        try await host.captureState("named-120")
        checkpoint("named-save")
        settings.exposure = -0.5; editor.setSettings(settings, for: asset.id); try #require(await editor.flush())
        let accepted = editor.snapshot(for: asset.id), revision = editor.localRevision(for: asset.id)
        try await host.press("variants.preview." + variant.id.canonicalString)
        try await wait { editor.isViewingVariant }
        try #require(!editor.canEdit)
        try #require(try host.element("develop.tool.crop").isAccessibilityEnabled() == false)
        if let generate = host.elements.first(where: { $0.accessibilityIdentifier() == "ai-development.generate" }) {
            try #require(!generate.isAccessibilityEnabled())
        }
        let sliders = host.nativeViews.compactMap { $0 as? NSSlider }
        try #require(!sliders.isEmpty && sliders.allSatisfy { !$0.isEnabled })
        try await host.captureState("preview")
        try host.sendKey(characters: "z", keyCode: 6, modifiers: [.command])
        try #require(editor.snapshot(for: asset.id) == accepted && editor.localRevision(for: asset.id) == revision)
        checkpoint("preview-read-only")
        try host.sendKey(characters: "\u{1b}", keyCode: 53)
        try await wait { editor.variantViewingState == nil }
        try #require(library.showsDetail && editor.localRevision(for: asset.id) == revision)
        checkpoint("escape")
        print("NATIVE_223_BEGIN before-menu"); fflush(stdout)
        try await host.menuAction("Als Vorher vergleichen", variant: variant)
        try await wait { editor.variantViewingState?.mode == .before }
        try #require(editor.canEdit && library.previewComparisonLayout == .leftRight)
        try await host.captureState("before")
        checkpoint("before")
        // The visible right side remains the accepted editor. An actual native
        // slider action must still target that side, independently of Before.
        try await wait {
            editor.canEdit && library.selectedID == asset.id && workspace.isFinalPreviewReady
                && workspace.sourceIdentity == (try? editor.resolvedSource(for: asset).identity)
                && editor.localRevision(for: asset.id) == revision
        }
        print("NATIVE_223_BEGIN slider-input"); fflush(stdout)
        try await host.setVisibleExposure(0.5)
        try await wait { abs(editor.settings(for: asset.id).exposure - 0.5) < 0.000_001 }
        try #require(editor.localRevision(for: asset.id) > revision)
        checkpoint("slider")
        let beforeRestore = editor.snapshot(for: asset.id)
        print("NATIVE_223_BEGIN restore-menu"); fflush(stdout)
        try await host.menuAction("Wiederherstellen", variant: variant)
        try await wait { editor.variantViewingState == nil && editor.snapshot(for: asset.id) == variant.snapshot }
        checkpoint("restore")
        print("NATIVE_223_BEGIN undo"); fflush(stdout)
        try host.sendKey(characters: "z", keyCode: 6, modifiers: [.command])
        try #require(editor.snapshot(for: asset.id) == beforeRestore)
        checkpoint("undo")
        print("NATIVE_223_BEGIN redo"); fflush(stdout)
        try host.sendKey(characters: "Z", keyCode: 6, modifiers: [.command, .shift])
        try #require(editor.snapshot(for: asset.id) == variant.snapshot)
        checkpoint("redo")
        print("NATIVE_223_BEGIN rename-menu"); fflush(stdout)
        try await host.menuAction("Umbenennen …", variant: variant)
        try await host.fillName("Prüfstand umbenannt")
        try await host.confirmName()
        try await wait { editor.variants.first?.name == "Prüfstand umbenannt" }
        try await host.captureState("renamed")
        checkpoint("rename")
        let metadataRevision = editor.localRevision(for: asset.id)
        print("NATIVE_223_BEGIN delete-menu"); fflush(stdout)
        try await host.menuAction("Benannten Bildstand entfernen", variant: variant)
        try await wait { editor.variants.isEmpty && !editor.isManagingVariants }
        try #require(editor.localRevision(for: asset.id) == metadataRevision && editor.snapshot(for: asset.id) == variant.snapshot)
        checkpoint("delete")
        print("NATIVE_223_BEGIN cleanup"); fflush(stdout)
        try #require(await editor.finishSaving())
        if let output = ProcessInfo.processInfo.environment["GLOWROOM_223_SNAPSHOT"] { try host.snapshot(URL(fileURLWithPath: output)) }
        host.close(); workspace.clear(); library.beginTermination(); editor.beginTermination()
        try #require(await editor.finishSaving())
        try #require(await library.finishSaving())
        try #require(!host.window.isVisible && host.window.attachedSheet == nil)
        try #require(editor.errorMessage == nil && library.errorMessage == nil)
        didCleanup = true
        checkpoint("cleanup")
        let marker = try #require(ProcessInfo.processInfo.environment[namedVariantChildResult])
        let token = try #require(ProcessInfo.processInfo.environment[namedVariantChildToken])
        try #require(stages == namedVariantRequiredStages)
        let complete = NamedVariantCompletion(token: token, stages: stages, allAssertionsWereFatal: true)
        try JSONEncoder().encode(complete).write(to: URL(fileURLWithPath: marker), options: .atomic)
        print("Named variant native acceptance completed all actions: \(token)")
        fflush(stdout)
    }
    @MainActor
    private func wait(_ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate() { guard ContinuousClock.now < deadline else { throw VariantNativeError.timeout }; try await Task.sleep(for: .milliseconds(20)) }
    }
}

private enum VariantNativeError: Error { case timeout, missingAction }

@MainActor
private final class VariantNativeHost {
    let window: NSWindow
    let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    init() {
        _ = NSApplication.shared; WorkspaceAccessibilityElement.enableInProcess()
        hosting.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1000, height: 660), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true; window.contentView = hosting; window.orderBack(nil)
    }
    var elements: [WorkspaceAccessibilityElement] { WorkspaceAccessibilityElement.descendants(of: hosting) }
    var nativeViews: [NSView] {
        var pending: [NSView] = [hosting], result: [NSView] = []
        while let view = pending.popLast() { result.append(view); pending.append(contentsOf: view.subviews) }; return result
    }
    func element(_ id: String) throws -> WorkspaceAccessibilityElement { try #require(elements.first { $0.accessibilityIdentifier() == id }, "Missing \(id)") }
    func settle() async throws { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded() }
    func mount(_ root: some View) async throws { hosting.rootView = AnyView(root); hosting.frame.size = NSSize(width: 1000, height: 660); try await settle() }
    func press(_ id: String) async throws {
        try await reveal(id)
        let action = try element(id), frame = window.convertFromScreen(action.accessibilityFrame())
        let visible = frame.width > 0 && frame.height > 0 && hosting.bounds.insetBy(dx: -1, dy: -1).contains(frame)
        if !visible { try diagnostics("outside-" + id) }
        try #require(visible, "\(id) must fit1000×660; action=\(frame), host=\(hosting.bounds)")
        try #require(action.isAccessibilityEnabled(), "\(id) disabled at \(frame)")
        try #require(action.accessibilityPerformPress(), "\(id) must support its native press action")
        try await settle()
    }
    func reveal(_ id: String) async throws {
        window.makeFirstResponder(nil)
        for attempt in 0..<12 {
            try await settle()
            let action = try element(id), frame = window.convertFromScreen(action.accessibilityFrame())
            let scrolls = nativeViews.compactMap { $0 as? NSScrollView }.filter { scroll in
                guard let document = scroll.documentView,
                      document.bounds.height > scroll.contentView.bounds.height + 1 else { return false }
                let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
                return frame.midX >= viewport.minX && frame.midX <= viewport.maxX
            }
            // SwiftUI embeds native text editors inside the palette. Use the
            // full column viewport, never the first nested scroll view.
            guard let scroll = scrolls.max(by: { $0.contentView.bounds.width < $1.contentView.bounds.width }),
                  let document = scroll.documentView else { return }
            let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
            if viewport.insetBy(dx: -1, dy: -1).contains(frame), hosting.bounds.insetBy(dx: -1, dy: -1).contains(frame) {
                try await settle()
                let fresh = window.convertFromScreen(try element(id).accessibilityFrame())
                if viewport.insetBy(dx: -1, dy: -1).contains(fresh) { return }
            }
            let minimum = document.bounds.minY
            let maximum = max(minimum, document.bounds.maxY - scroll.contentView.bounds.height)
            let y: CGFloat
            if attempt.isMultiple(of: 2), frame.width > 0, frame.height > 0 {
                let target = document.convert(frame, from: nil)
                y = min(maximum, max(minimum, target.midY - scroll.contentView.bounds.height / 2))
            } else {
                let fraction = CGFloat(attempt / 2) / 5
                y = document.isFlipped ? minimum + (maximum - minimum) * fraction : maximum - (maximum - minimum) * fraction
            }
            scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    private func diagnostics(_ stage: String) throws {
        let safe = stage.replacingOccurrences(of: "/", with: "-")
        let base = URL(fileURLWithPath: "/private/tmp/glowroom-223-" + safe)
        try snapshot(base.appendingPathExtension("png"))
        let frames = elements.filter { ($0.accessibilityIdentifier() ?? "").hasPrefix("variants.") }.map { element in
            ["id": element.accessibilityIdentifier() ?? "", "label": element.accessibilityLabel() ?? "", "enabled": String(element.isAccessibilityEnabled()),
             "frame": NSStringFromRect(window.convertFromScreen(element.accessibilityFrame()))]
        }
        let sliders = nativeViews.compactMap { $0 as? NSSlider }.map { slider in
            ["label": slider.accessibilityLabel() ?? "", "enabled": String(slider.isEnabled), "hidden": String(slider.isHiddenOrHasHiddenAncestor),
             "minimum": String(slider.minValue), "maximum": String(slider.maxValue),
             "frame": NSStringFromRect(slider.convert(slider.bounds, to: nil)), "visible": NSStringFromRect(slider.visibleRect)]
        }
        try JSONSerialization.data(withJSONObject: ["stage": stage, "host": NSStringFromRect(hosting.bounds), "actions": frames, "nativeSliders": sliders], options: [.prettyPrinted, .sortedKeys])
            .write(to: base.appendingPathExtension("json"))
        print("Named variant native diagnostic: \(base.path).png; \(frames)")
    }
    func fillName(_ name: String) async throws {
        try await settle()
        let sheet = try #require(window.attachedSheet), content = try #require(sheet.contentView)
        var pending: [NSView] = [content], field: NSTextField?
        while let view = pending.popLast() { if let input = view as? NSTextField, input.isEditable { field = input; break }; pending.append(contentsOf: view.subviews) }
        let input = try #require(field); try #require(sheet.makeFirstResponder(input))
        let text = try #require(input.currentEditor() as? NSTextView)
        text.selectAll(nil); text.insertText(name, replacementRange: text.selectedRange()); sheet.makeFirstResponder(nil)
        try await settle()
    }
    var canConfirmName: Bool {
        guard let sheet = window.attachedSheet else { return false }
        return WorkspaceAccessibilityElement.descendants(of: sheet.contentView).first { $0.accessibilityIdentifier() == "variants.confirm-name" }?.isAccessibilityEnabled() == true
    }
    func confirmName() async throws {
        let sheet = try #require(window.attachedSheet)
        let action = try #require(WorkspaceAccessibilityElement.descendants(of: sheet.contentView).first { $0.accessibilityIdentifier() == "variants.confirm-name" })
        if !action.isAccessibilityEnabled() { try diagnostics("disabled-confirm-name") }
        try #require(action.isAccessibilityEnabled(), "Valid captured name must enable Sichern")
        try #require(action.accessibilityPerformPress()); try await settle()
    }
    func menuAction(_ title: String, variant: EditingVariant) async throws {
        let id = "variants.actions." + variant.id.canonicalString
        try await reveal(id)
        let action = try element(id), frame = window.convertFromScreen(action.accessibilityFrame())
        try #require(action.isAccessibilityEnabled(), "Native variant menu is disabled")
        try #require(hosting.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Native menu must be visible: \(frame)")
        let probe = NamedVariantMenuProbe(title: title)
        try probe.openAndChoose(action)
        try #require(probe.selectedAction, "Select the real NSMenu item \(title); \(probe.failure ?? "no detail")")
        try #require(!probe.timedOut, "Native menu action must finish within its tracking deadline")
        try await settle()
    }
    func setVisibleExposure(_ value: Double) async throws {
        try await reveal("develop.adjustment.exposure")
        try await settle()
        let candidates = nativeViews.compactMap { $0 as? NSSlider }.filter {
            $0.accessibilityLabel() == "Belichtung" && $0.minValue == -5 && $0.maxValue == 5
                && $0.window === window && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
        }
        guard let slider = candidates.first(where: { $0.isEnabled }) else {
            try diagnostics("missing-visible-exposure")
            throw VariantNativeError.missingAction
        }
        let frame = slider.convert(slider.bounds, to: nil)
        let fullyVisible = frame.width > 0 && frame.height > 0
            && hosting.bounds.insetBy(dx: -1, dy: -1).contains(frame)
            && slider.visibleRect.insetBy(dx: -1, dy: -1).contains(slider.bounds)
            && frame.minX > hosting.bounds.midX
        if !fullyVisible { try diagnostics("outside-exposure") }
        try #require(fullyVisible, "Right Belichtung slider must be visible: frame=\(frame), bounds=\(slider.bounds), visible=\(slider.visibleRect)")
        let point = CGPoint(x: slider.bounds.midX, y: slider.bounds.midY)
        try #require(hosting.hitTest(slider.convert(point, to: hosting.superview)) === slider,
            "The right exposure slider owns its actual native hit area")
        try #require(window.makeFirstResponder(slider) && window.firstResponder === slider)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124))
        // Disabled controls cancel old tracking. A genuine new native input must
        // re-arm this slider before its target/action can represent a new edit.
        slider.keyDown(with: key)
        slider.doubleValue = value
        try #require(slider.sendAction(slider.action, to: slider.target), "The native exposure target/action must run")
        window.makeFirstResponder(nil)
        try await settle()
    }
    func sendKey(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
        window.makeFirstResponder(nil)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: keyCode))
        let input = try #require(nativeViews.compactMap { $0 as? WorkspaceKeyboardInputView }.first)
        try #require(input.process(event) == nil)
    }
    func captureState(_ stage: String) async throws {
        guard let output = ProcessInfo.processInfo.environment["GLOWROOM_223_SNAPSHOT"] else { return }
        try await settle()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while true {
            let decodes = await ImagePreviewPipeline.shared.state()
            let renders = await AdjustedPreviewPipeline.shared.state()
            if decodes.runningCount == 0, decodes.queuedCount == 0,
               renders.runningSelected == 0, renders.runningBackground == 0, renders.queuedCount == 0 { break }
            guard ContinuousClock.now < deadline else { throw VariantNativeError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await settle()
        let base = URL(fileURLWithPath: output).deletingPathExtension()
        let destination = URL(fileURLWithPath: base.path + "-" + stage + ".png")
        try snapshot(destination)
        print("Named variant native state \(stage): \(destination.path)")
    }
    func snapshot(_ url: URL) throws {
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)); hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
    func close() { if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.close() }; hosting.rootView = AnyView(EmptyView()); window.close() }
}

private struct VariantNativeMetadataSuggestor: PhotoMetadataSuggesting {
    func availability() async -> ImageAnalysisAvailability { .unavailable(.modelUnavailable) }
    func suggest(_ request: PhotoMetadataSuggestionRequest) async throws -> PhotoMetadataSuggestionResult { throw ImageAnalysisError.unavailable(.modelUnavailable) }
}


private let namedVariantChildToken = "GLOWROOM_TEST_NAMED_VARIANT_CHILD_TOKEN"
private let namedVariantChildResult = "GLOWROOM_TEST_NAMED_VARIANT_CHILD_RESULT"

private func runNamedVariantNativeChild() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do { try launchNamedVariantNativeChild(); continuation.resume() }
            catch { continuation.resume(throwing: error) }
        }
    }
}

private func launchNamedVariantNativeChild() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-223-child-" + UUID().uuidString)
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
    child.arguments = arguments + ["--testing-library", "swift-testing", "--filter", "realButtonsNameFocusPreviewEscapeRestoreAndMetadata"]
    var environment = ProcessInfo.processInfo.environment
    environment[namedVariantChildToken] = token; environment[namedVariantChildResult] = result.path
    child.environment = environment
    child.standardOutput = output; child.standardError = output
    child.terminationHandler = { _ in ended.signal() }
    try child.run()
    guard ended.wait(timeout: .now() + 120) == .success else {
        if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
        let reaped = ended.wait(timeout: .now() + 2) == .success
        throw NamedVariantChildFailure(detail: "Timed out; SIGKILL reaped=\(reaped)", log: try namedVariantChildLog(log))
    }
    let transcript = try namedVariantChildLog(log)
    let marker = (try? Data(contentsOf: result)).flatMap { try? JSONDecoder().decode(NamedVariantCompletion.self, from: $0) }
    let complete = marker?.token == token && marker?.stages == namedVariantRequiredStages && marker?.allAssertionsWereFatal == true
    let passed = transcript.range(of: #"✔\s+Test run with 1 test(?: in 1 suite)? passed after"#, options: .regularExpression) != nil
    let reportedIssue = transcript.contains("✘") || transcript.localizedCaseInsensitiveContains("recorded an issue")
    guard child.terminationReason == .exit, child.terminationStatus == 0, complete, !reportedIssue else {
        throw NamedVariantChildFailure(detail: "Status=\(child.terminationStatus), reason=\(child.terminationReason), all fatal checkpoints=\(complete), SDK summary=\(passed), reported issue=\(reportedIssue)", log: transcript)
    }
    print(transcript)
    print("Named variant native child was reaped after ALL fatal assertions and checkpoints; SDK completion record=\(passed).")
}

private func namedVariantChildLog(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    let end = try handle.seekToEnd(); try handle.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
    return String(decoding: try handle.read(upToCount: 65_536) ?? Data(), as: UTF8.self)
}

private struct NamedVariantChildFailure: Error, CustomStringConvertible {
    let detail: String
    let log: String
    var description: String { "Named variant native child: \(detail)\n\(log)" }
}

/// Keep AppKit tracking inside a bounded nested default/eventTracking loop,
/// matching the existing native zoom-popup harness. Every action goes through
/// the production NSMenuItem target; no model/controller shortcut is involved.
@MainActor
private final class NamedVariantMenuProbe {
    let title: String
    private var menus: [ObjectIdentifier: NSMenu] = [:]
    private var observers: [NSObjectProtocol] = []
    private var timers: [Timer] = []
    private var started = false
    private(set) var selectedAction = false
    private(set) var timedOut = false
    private(set) var failure: String?
    init(title: String) { self.title = title }
    func openAndChoose(_ control: WorkspaceAccessibilityElement) throws {
        defer { stop() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu else { return }
                self?.begin(menu)
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu else { return }
                _ = self?.menus.removeValue(forKey: ObjectIdentifier(menu))
            }
        })
        try #require(control.accessibilityPerformPress(), "Open the production variant menu")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !started || !menus.isEmpty {
            try #require(ContinuousClock.now < deadline, "Native variant menu must finish tracking")
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
    private func begin(_ menu: NSMenu) {
        started = true
        let id = ObjectIdentifier(menu); menus[id] = menu
        let timeout = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let menu = self.menus[id] else { return }
                self.timedOut = true; menu.cancelTrackingWithoutAnimation()
            }
        }
        let choose = Timer(timeInterval: 0.02, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let menu = self.menus[id] else { return }
                guard let index = menu.items.firstIndex(where: { $0.title == self.title }), menu.items[index].isEnabled else {
                    self.failure = "Missing/disabled item in \(menu.items.map(\.title))"
                    menu.cancelTrackingWithoutAnimation(); return
                }
                menu.performActionForItem(at: index)
                self.selectedAction = true
                menu.cancelTrackingWithoutAnimation()
            }
        }
        timers.append(contentsOf: [timeout, choose])
        RunLoop.main.add(timeout, forMode: .eventTracking)
        RunLoop.main.add(choose, forMode: .eventTracking)
    }
    private func stop() {
        timers.forEach { $0.invalidate() }; timers.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        for menu in Array(menus.values) { menu.cancelTrackingWithoutAnimation() }
        menus.removeAll()
    }
}


private let namedVariantRequiredStages = ["setup", "named-save", "preview-read-only", "escape", "before", "slider", "restore", "undo", "redo", "rename", "delete", "cleanup"]
private struct NamedVariantCompletion: Codable {
    let token: String
    let stages: [String]
    let allAssertionsWereFatal: Bool
}
