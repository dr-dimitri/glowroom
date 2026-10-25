import AppKit
import Darwin
import Foundation
import GlowroomCore
import ImageIO
import SwiftUI
import Testing
@testable import Glowroom

@Suite("Two photo comparison", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct PhotoComparisonTests {
    @Test
    func referenceIsFrozenWhileCandidatesAndSettingsChange() async throws {
        try await withFixture { library, editor, assets in
            var settings = editor.settings(for: assets[0].id)
            settings.exposure = 0.6
            editor.setSettings(settings, for: assets[0].id)
            await library.pinPhotoReference(assets[0], editor: editor)
            let reference = try #require(library.photoComparisonReference)
            #expect(reference.snapshot.settings.exposure == 0.6)
            library.select(assets[1]); library.openPhotoComparison()
            #expect(library.isPhotoComparison)
            library.navigate(1)
            #expect(library.selectedID == assets[2].id)
            library.navigate(-1)
            #expect(library.selectedID == assets[1].id)
            settings.exposure = 1.2
            editor.setSettings(settings, for: assets[0].id)
            #expect(library.photoComparisonReference?.snapshot.settings.exposure == 0.6)
            #expect(library.photoComparisonReference?.identity == reference.identity)
            await library.pinPhotoReference(assets[0], editor: editor)
            #expect(library.photoComparisonReference?.snapshot.settings.exposure == 1.2)
            #expect(library.selectedID == assets[1].id)
            #expect(library.photoComparisonReference?.identity != reference.identity)
        }
    }

    @Test
    func cannotStartWithoutAnExplicitDifferentCandidateAndReferenceCannotBecomeActive() async throws {
        try await withFixture { library, editor, assets in
            library.openPhotoComparison()
            #expect(!library.isPhotoComparison)
            library.select(assets[0])
            await library.pinPhotoReference(assets[0], editor: editor)
            library.openPhotoComparison()
            #expect(!library.isPhotoComparison)
            #expect(library.selectedID == assets[0].id)
            library.select(assets[1]); library.openPhotoComparison()
            library.select(assets[0])
            #expect(library.selectedID == assets[1].id)
            library.selectedID = assets[0].id
            #expect(library.selectedID == assets[1].id)
            library.navigate(-1)
            #expect(library.selectedID == assets[1].id)
            library.selectAll()
            #expect(library.selectedID != assets[0].id)
            library.closePhotoComparison()
            #expect(library.photoComparisonReference?.asset.id == assets[0].id)
            library.select(assets[0])
            #expect(library.selectedID == assets[0].id)
        }
    }

    @Test
    func persistedRatingAdvancesExactlyOnceAndOnlyCandidateChanges() async throws {
        try await withFixture { library, editor, assets in
            await library.pinPhotoReference(assets[0], editor: editor)
            library.select(assets[1]); library.openPhotoComparison()
            #expect(!library.advancesAfterPhotoRating)
            library.advancesAfterPhotoRating = true
            library.setRating(5)
            #expect(library.selectedID == assets[1].id, "No navigation before durable mutation completion")
            #expect(await library.finishSaving())
            try await settle(library, expected: assets[2].id)
            #expect(library.assets.first { $0.id == assets[1].id }?.rating == 5)
            #expect(library.assets.first { $0.id == assets[0].id }?.rating == 4)
            library.toggleFavorite()
            #expect(await library.finishSaving())
            try await settle(library, expected: assets[3].id)
            #expect(library.assets.first { $0.id == assets[2].id }?.isFavorite == true)
            library.setRating(1)
            #expect(await library.finishSaving())
            try await settle(library, expected: assets[3].id)
        }
    }

    @Test
    func ratingWhichRemovesCandidateFromFilterUsesCapturedNextExactlyOnce() async throws {
        try await withFixture { library, editor, assets in
            await library.pinPhotoReference(assets[0], editor: editor)
            library.minimumRating = 4
            await library.waitForProjection()
            library.select(assets[1]); library.openPhotoComparison(); library.advancesAfterPhotoRating = true
            library.setRating(0)
            #expect(await library.finishSaving())
            try await settle(library, expected: assets[2].id)
            #expect(!library.visibleAssets.contains { $0.id == assets[1].id })
        }
    }

    @Test
    func manualCandidateChangeAndABARoundtripPreventLateAdvance() async throws {
        try await withFixture { library, editor, assets in
            await library.pinPhotoReference(assets[0], editor: editor)
            library.select(assets[1]); library.openPhotoComparison(); library.advancesAfterPhotoRating = true
            library.setRating(5)
            library.select(assets[3]); library.select(assets[1])
            #expect(await library.finishSaving())
            try await settle(library, expected: assets[1].id)
            library.setRating(3)
            library.select(assets[3])
            #expect(await library.finishSaving())
            try await settle(library, expected: assets[3].id)
        }
    }

    @Test
    func oldFailedRatingReceiptCannotRollbackANewerEqualValue() async throws {
        try await withFixture { library, editor, assets in
            await library.pinPhotoReference(assets[0], editor: editor)
            library.select(assets[1]); library.openPhotoComparison()
            try #require(library.isPhotoComparison)
            let root = assets[0].fileURL.deletingLastPathComponent().deletingLastPathComponent()
            let catalogURL = root.appendingPathComponent("Catalog/catalog.json")
            let original = try Data(contentsOf: catalogURL)
            // Deliberately invalidate the durable before-reference. All accepted
            // requests fail deterministically without relying on disk capacity.
            try Data("invalid catalog during controlled failure".utf8).write(to: catalogURL, options: .atomic)
            library.setRating(1, for: assets[1].id)
            library.setRating(2, for: assets[1].id)
            library.setRating(1, for: assets[1].id)
            await library.drainAcceptedCatalogOperations()
            #expect(library.errorMessage != nil)
            #expect(library.assets.first { $0.id == assets[1].id }?.rating == 4,
                "All failed optimistic values revert to the confirmed durable rating, never an unsaved predecessor")
            try original.write(to: catalogURL, options: .atomic)
        }
    }

    @Test
    func failedFavoriteABAReturnsToTheConfirmedDurableValue() async throws {
        try await withFixture { library, editor, assets in
            await library.pinPhotoReference(assets[0], editor: editor)
            library.select(assets[1]); library.openPhotoComparison()
            try #require(library.isPhotoComparison)
            let root = assets[0].fileURL.deletingLastPathComponent().deletingLastPathComponent()
            let catalogURL = root.appendingPathComponent("Catalog/catalog.json")
            let original = try Data(contentsOf: catalogURL)
            try Data("controlled catalog mismatch".utf8).write(to: catalogURL, options: .atomic)
            library.toggleFavorite(assets[1].id); library.toggleFavorite(assets[1].id); library.toggleFavorite(assets[1].id)
            await library.drainAcceptedCatalogOperations()
            #expect(library.errorMessage != nil)
            #expect(library.assets.first { $0.id == assets[1].id }?.isFavorite == false)
            try original.write(to: catalogURL, options: .atomic)
        }
    }

    @Test
    func replacingAFilteredOutReferenceNeverLeavesThatSamePhotoEditableOnTheRight() async throws {
        try await withFixture { library, editor, assets in
            await library.pinPhotoReference(assets[0], editor: editor)
            library.setRating(5, for: assets[1].id); library.setRating(5, for: assets[2].id)
            #expect(await library.finishSaving())
            library.minimumRating = 5; await library.waitForProjection()
            library.select(assets[1]); library.openPhotoComparison()
            #expect(library.isPhotoComparison)
            await library.pinPhotoReference(assets[1], editor: editor, startComparison: true)
            #expect(library.photoComparisonReference?.asset.id == assets[1].id)
            #expect(!library.isPhotoComparison, "No automatic fallback candidate and no reference-as-edit-target")
            #expect(library.selectedID == assets[1].id)
            library.select(assets[2]); library.openPhotoComparison()
            #expect(library.isPhotoComparison && library.selectedID != library.photoComparisonReference?.asset.id)
        }
    }

    @Test
    func acceptedRatingAndImmediateFolderRemovalFinishWithoutAMutualWait() async throws {
        try await withFixture { library, editor, assets in
            await library.pinPhotoReference(assets[0], editor: editor)
            library.select(assets[1]); library.openPhotoComparison(); library.advancesAfterPhotoRating = true
            library.setRating(5)
            library.removeFolder(assets[1].folderID)
            #expect(await library.finishSaving())
            await library.waitForProjection()
            #expect(library.assets.isEmpty && !library.isUpdatingCatalog)
        }
    }

    @Test
    func changingSemanticViewLimitDuringRatingPreventsALateNavigation() async throws {
        try await withFixture { library, editor, assets in
            await library.pinPhotoReference(assets[0], editor: editor)
            library.select(assets[1]); library.openPhotoComparison(); library.advancesAfterPhotoRating = true
            library.setRating(5)
            library.semanticTopK = 2
            #expect(await library.finishSaving())
            #expect(library.selectedID == assets[1].id)
        }
    }

    @Test
    func numericFormattingEchoDoesNotHideRealEdits() {
        #expect(AdjustmentSlider.isUnchangedNumericInput(0.7, current: -5 + 114 * 0.05))
        #expect(AdjustmentSlider.isUnchangedNumericInput(0, current: 0))
        #expect(!AdjustmentSlider.isUnchangedNumericInput(0.71, current: 0.7))
        #expect(!AdjustmentSlider.isUnchangedNumericInput(7000.001, current: 7000))
        #expect(!AdjustmentSlider.isUnchangedNumericInput(.nan, current: 0))
    }

    @Test
    func geometryClampsEachAspectRatioAndNeverLabelsProxyAsNativePixels() {
        let position = PhotoComparisonPosition(zoomed: true, center: CGPoint(x: 0.9, y: 0.1))
        let portrait = PhotoComparisonGeometry(viewport: CGSize(width: 400, height: 500), aspectRatio: 0.5, position: position).imageFrame
        let landscape = PhotoComparisonGeometry(viewport: CGSize(width: 400, height: 500), aspectRatio: 2, position: position).imageFrame
        #expect(portrait.width == 500 && portrait.height == 1000)
        #expect(portrait.maxX >= 400 && portrait.maxY >= 500)
        #expect(landscape.width == 800 && landscape.height == 400)
        #expect(landscape.minY == 50)
        #expect(landscape.maxX >= 400)
        let fit = PhotoComparisonGeometry(viewport: CGSize(width: 300, height: 600), aspectRatio: 2,
            position: PhotoComparisonPosition()).imageFrame
        #expect(fit.width == 300 && fit.height == 150)
        #expect(fit.minY == 225)
    }

    @Test(arguments: [NSSize(width: 1000, height: 660), NSSize(width: 1440, height: 900)])
    nonisolated func nativeTwoPhotoCanvasKeepsHitsControlsAndKeyboardOnTheCandidate(size: NSSize) async throws {
        try await runPhotoComparisonNativeChild(size: size)
    }

    @MainActor
    fileprivate func runNativeComparisonScenario(size: NSSize) async throws {
        var stages: [String] = []
        func checkpoint(_ stage: String) {
            stages.append(stage)
            print("NATIVE_222_CHECKPOINT \(Int(size.width))x\(Int(size.height)) \(stage)")
            fflush(stdout)
        }
        try await withFixture { library, editor, assets in
            let directory = assets[0].fileURL.deletingLastPathComponent().deletingLastPathComponent()
            let suite = "Glowroom-PhotoCompare-UI-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let layout = WorkspaceLayoutModel(defaults: defaults)
            layout.update(developing: true) {
                $0.showsLibrary = false; $0.showsFilmstrip = false; $0.showsTools = true
                $0.toolsWidth = 300; $0.openGroups = [.edit]; $0.openAdjustmentGroups = ["tone"]
            }
            let service = ImageAnalysisService(provider: UnavailableImageAnalysisProvider(reason: .sdkUnavailable), budget: AIResourceBudget())
            let metadata = PhotoMetadataModel(store: PhotoMetadataRepository(directory: directory.appendingPathComponent("Metadata")),
                suggestor: LocalPhotoMetadataSuggestor(service: service), library: library, editor: editor)
            let workspace = DevelopWorkspace()
            let host = PhotoComparisonNativeHost(size: size)
            var didCleanup = false
            defer { if !didCleanup { host.close(); workspace.clear() } }
            library.workspaceMode = .develop
            await library.pinPhotoReference(assets[0], editor: editor)
            var candidateSettings = editor.settings(for: assets[1].id)
            candidateSettings.developGeometry.crop = try DevelopCropRect(x: 0.125, y: 0.1, width: 0.75, height: 0.7)
            editor.setSettings(candidateSettings, for: assets[1].id)
            try #require(await editor.finishSaving())
            let candidateOutput = try DevelopGeometryRenderer.outputSize(width: assets[1].pixelWidth,
                height: assets[1].pixelHeight, geometry: candidateSettings.developGeometry)
            try #require(candidateOutput.width < assets[1].pixelWidth && candidateOutput.height < assets[1].pixelHeight)
            try #require(assets[0].pixelWidth > assets[0].pixelHeight && assets[1].pixelWidth < assets[1].pixelHeight)
            library.select(assets[1]); library.openPhotoComparison()
            host.mount(LibraryView(model: library, dataDirectory: directory, developWorkspace: workspace)
                .environmentObject(editor).environmentObject(layout).environmentObject(metadata)
                .environmentObject(JPEGExportModel(preferences: nil)).preferredColorScheme(.dark))
            try await host.wait("two native panes and accepted candidate") {
                host.inputIfPresent("reference") != nil && host.inputIfPresent("candidate") != nil
                    && workspace.isFinalPreviewReady
                    && host.hasVisiblePhoto(width: assets[0].pixelWidth, height: assets[0].pixelHeight)
                    && host.hasVisiblePhoto(width: candidateOutput.width, height: candidateOutput.height)
            }
            try #require(workspace.navigatorImage?.width == candidateOutput.width && workspace.navigatorImage?.height == candidateOutput.height)
            checkpoint("setup")
            let left = try host.input("reference"), right = try host.input("candidate")
            try #require(left.isAccessibilityElement() && right.isAccessibilityElement())
            try #require(left.accessibilityLabel()?.contains("Referenz") == true)
            try #require(right.accessibilityLabel()?.contains("Aktives Foto") == true)
            try host.click(left)
            try await host.wait("linked preview zoom") {
                left.cursor(CGPoint(x: left.bounds.midX, y: left.bounds.midY)) === NSCursor.openHand
                    && right.cursor(CGPoint(x: right.bounds.midX, y: right.bounds.midY)) === NSCursor.openHand
            }
            checkpoint("linked-zoom")
            let coupledLeft = try #require(host.photoFrame(width: assets[0].pixelWidth, height: assets[0].pixelHeight))
            let coupledRight = try #require(host.photoFrame(width: candidateOutput.width, height: candidateOutput.height))
            try host.drag(right)
            try await host.wait("coupled pan moves both rendered photos") {
                guard let leftFrame = host.photoFrame(width: assets[0].pixelWidth, height: assets[0].pixelHeight),
                      let rightFrame = host.photoFrame(width: candidateOutput.width, height: candidateOutput.height) else { return false }
                return leftFrame.origin != coupledLeft.origin && rightFrame.origin != coupledRight.origin
            }
            try #require(library.selectedID == assets[1].id)
            checkpoint("coupled-pan")
            try await host.press("workspace.photo-comparison.link-zoom")
            try #require(!library.photoComparisonZoomLinked)
            try await host.press("workspace.photo-comparison.reference.zoom")
            try await host.wait("independent preview zoom") {
                left.cursor(CGPoint(x: left.bounds.midX, y: left.bounds.midY)) === PhotoCanvasCursors.zoomIn
                    && right.cursor(CGPoint(x: right.bounds.midX, y: right.bounds.midY)) === NSCursor.openHand
            }
            let independentLeft = try #require(host.photoFrame(width: assets[0].pixelWidth, height: assets[0].pixelHeight))
            let independentRight = try #require(host.photoFrame(width: candidateOutput.width, height: candidateOutput.height))
            try host.drag(right)
            try await host.wait("free pan moves only the candidate") {
                guard let frame = host.photoFrame(width: candidateOutput.width, height: candidateOutput.height) else { return false }
                return frame.origin != independentRight.origin
            }
            try #require(host.photoFrame(width: assets[0].pixelWidth, height: assets[0].pixelHeight) == independentLeft)
            checkpoint("free-navigation")
            let exposure = try #require(host.nativeViews.compactMap { $0 as? NSSlider }.first {
                $0.accessibilityLabel() == "Belichtung" && $0.minValue == -5 && $0.maxValue == 5
            })
            try #require(exposure.isEnabled && exposure.target != nil)
            exposure.doubleValue = 0.7
            try #require(exposure.sendAction(exposure.action, to: exposure.target))
            // Native 0.05-step quantization computes -5 + 114 * 0.05,
            // whose floating representation is 0.7000000000000002.
            try await host.wait("right inspector value") {
                abs(editor.settings(for: assets[1].id).exposure - 0.7) < 0.000_001
            }
            try #require(abs(exposure.doubleValue - editor.settings(for: assets[1].id).exposure) < 0.000_001)
            try #require(editor.settings(for: assets[0].id).exposure == 0)
            try #require(library.photoComparisonReference?.snapshot.settings.exposure == 0)
            try #require(await editor.finishSaving())
            try host.requireHealthy("after exposure persistence", library: library, editor: editor, metadata: metadata, workspace: workspace)
            checkpoint("candidate-adjustment")
            host.focus(nil)
            try host.key(code: 124, text: "")
            try await host.wait("candidate navigation") { library.selectedID == assets[2].id }
            try host.requireHealthy("after candidate forward", library: library, editor: editor, metadata: metadata, workspace: workspace)
            try host.key(code: 123, text: "")
            try await host.wait("candidate navigation back") { library.selectedID == assets[1].id }
            try host.requireHealthy("after candidate back", library: library, editor: editor, metadata: metadata, workspace: workspace)
            checkpoint("candidate-roundtrip")
            try host.key(code: 18, text: "1")
            try #require(await library.finishSaving())
            try #require(library.assets.first { $0.id == assets[1].id }?.rating == 1)
            try #require(library.assets.first { $0.id == assets[0].id }?.rating == 4)
            try host.key(code: 3, text: "f")
            try #require(await library.finishSaving())
            try #require(library.assets.first { $0.id == assets[1].id }?.isFavorite == true)
            try host.requireHealthy("after rating and favorite", library: library, editor: editor, metadata: metadata, workspace: workspace)
            checkpoint("rating-favorite")
            let focusSnapshot = editor.snapshot(for: assets[1].id)
            let focusRevision = editor.localRevision(for: assets[1].id)
            let focusGeneration = editor.aiEditGeneration
            let numeric = try host.visibleNumericField(label: "Belichtung Wert")
            do {
                print("PHOTO-COMPARISON-NUMERIC-FOCUS label=\(numeric.accessibilityLabel() ?? "none"), value=\(numeric.stringValue), frame=\(numeric.convert(numeric.bounds, to: nil))")
                let focusedNumeric = try await host.clickAndRequireFieldFocus(label: "Belichtung Wert")
                try #require(focusedNumeric.currentEditor() === host.window.firstResponder,
                    "The mouse-selected Belichtung field must own the current native text editor")
                let before = library.selectedID
                try #require(try host.key(code: 124, text: "", consumed: false) == false,
                    "A focused numeric field retains its arrow key")
                try #require(library.selectedID == before)
                host.focus(nil)
            }
            try await host.settle()
            try #require(editor.snapshot(for: assets[1].id) == focusSnapshot, "Focus and an owned arrow key must not rewrite a formatted numeric value")
            try #require(editor.localRevision(for: assets[1].id) == focusRevision)
            try #require(editor.aiEditGeneration == focusGeneration, "A formatting echo must not open an empty edit transaction")
            try host.requireHealthy("after numeric-field focus", library: library, editor: editor, metadata: metadata, workspace: workspace)
            checkpoint("numeric-mouse-focus")
            try #require(await editor.finishSaving())
            try #require(await library.finishSaving())
            await library.waitForProjection()
            try await host.wait("both accepted comparison photos visible without pending render") {
                guard let display = workspace.levelsDisplay, let revision = display.identity.revision,
                      display.identity.finalSourceReady, workspace.isFinalPreviewReady else { return false }
                return revision.assetID == assets[1].id
                    && revision.selection == DevelopSelectionIdentity(sessionID: library.aiSelectionSessionID,
                        generation: library.aiSelectionGeneration)
                    && display.identity.settings == editor.settings(for: assets[1].id).normalized
                    && host.hasVisiblePhoto(width: assets[0].pixelWidth, height: assets[0].pixelHeight)
                    && host.hasVisiblePhoto(width: candidateOutput.width, height: candidateOutput.height)
            }
            try #require(editor.settings(for: assets[1].id).developGeometry.crop == candidateSettings.developGeometry.crop)
            try host.requireHealthy("before acceptance screenshot", library: library, editor: editor, metadata: metadata, workspace: workspace)
            try #require(!editor.hasPendingChanges && !editor.isSaving)
            if let path = ProcessInfo.processInfo.environment["GLOWROOM_222_SNAPSHOTS"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try host.snapshot(to: directory.appendingPathComponent("photo-comparison-\(Int(size.width)).png"))
            }
            checkpoint("ready-images")
            try host.key(code: 53, text: "\u{1b}")
            try await host.wait("escape closes comparison") { !library.isPhotoComparison }
            try #require(library.selectedID == assets[1].id)
            checkpoint("escape")
            library.openPhotoComparison()
            try await host.wait("comparison reopened") { host.inputIfPresent("reference") != nil }
            try await host.press("workspace.photo-comparison.close")
            try await host.wait("visible close action") { !library.isPhotoComparison }
            try #require(library.photoComparisonReference?.asset.id == assets[0].id)
            checkpoint("close")
            // Selecting a spatial tool ends comparison before its gesture canvas
            // becomes active, rather than leaving a blocked tool over two panes.
            library.openPhotoComparison()
            try await host.wait("comparison ready before spatial tool") { host.inputIfPresent("reference") != nil }
            workspace.tool = .crop
            try await host.wait("crop routes to editable canvas") { !library.isPhotoComparison && workspace.tool == .crop }
            try host.requireHealthy("after crop routing", library: library, editor: editor, metadata: metadata, workspace: workspace)
            checkpoint("crop-routing")
            host.close(); workspace.clear(); library.beginTermination(); editor.beginTermination()
            try #require(await editor.finishSaving())
            try #require(await library.finishSaving())
            try #require(!host.window.isVisible && host.window.attachedSheet == nil)
            try host.requireHealthy("after native cleanup", library: library, editor: editor, metadata: metadata, workspace: workspace)
            didCleanup = true
            checkpoint("cleanup")
        }
        try #require(stages == photoComparisonRequiredStages)
        let path = try #require(ProcessInfo.processInfo.environment[photoComparisonChildResult])
        let token = try #require(ProcessInfo.processInfo.environment[photoComparisonChildToken])
        let completion = PhotoComparisonNativeCompletion(token: token, width: Int(size.width), height: Int(size.height),
            stages: stages, allAssertionsWereFatal: true)
        try JSONEncoder().encode(completion).write(to: URL(fileURLWithPath: path), options: .atomic)
        print("Photo comparison native acceptance completed every action: \(token)")
        fflush(stdout)
    }

    private func settle(_ library: LibraryModel, expected id: String) async throws {
        await library.waitForProjection()
        // finishSaving includes the exact mutation's projection/navigation.
        #expect(library.selectedID == id)
    }

    private func withFixture(_ body: (LibraryModel, EditingModel, [PhotoAsset]) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-PhotoCompare-\(UUID())")
        let photosURL = root.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photosURL, withIntermediateDirectories: true)
        let folder = LibraryFolder(url: photosURL)
        let assets: [PhotoAsset] = try (0..<4).map { index in
            let url = photosURL.appendingPathComponent("photo-\(index).png")
            let dimensions = [(144, 96), (96, 160), (160, 80), (96, 96)]
            let (width, height) = dimensions[index]
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: CGFloat(index) / 4, green: 0.4, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // An asymmetric grid, corner markers and a round center marker make
            // crop, orientation, panning and accidental stretching inspectable.
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.35)); context.setLineWidth(1)
            for x in stride(from: 0, through: width, by: 12) {
                context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: height))
            }
            for y in stride(from: 0, through: height, by: 12) {
                context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: width, y: y))
            }
            context.strokePath()
            context.setFillColor(CGColor(red: 0.95, green: 0.2, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 3, y: 3, width: 13, height: 13))
            context.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: width - 19, y: height - 19, width: 16, height: 16))
            let diameter = CGFloat(min(width, height)) * 0.35
            context.setFillColor(CGColor(red: 0.95, green: 0.6, blue: 0.1, alpha: 1))
            context.fillEllipse(in: CGRect(x: CGFloat(width) * 0.35 - diameter / 2,
                y: CGFloat(height) * 0.6 - diameter / 2, width: diameter, height: diameter))
            let image = try #require(context.makeImage())
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            try #require(CGImageDestinationFinalize(destination))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return PhotoAsset(folderID: folder.id, fileURL: url, fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                pixelWidth: width, pixelHeight: height, modifiedAt: attributes[.modificationDate] as? Date ?? Date(), rating: 4)
        }
        let repository = CatalogRepository(directory: root.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: assets))
        let library = LibraryModel(repository: repository)
        let editor = EditingModel(directory: root.appendingPathComponent("Editing"))
        do {
            async let loadedLibrary = library.finishSaving()
            async let loadedEditor = editor.finishSaving()
            let loaded = await (loadedLibrary, loadedEditor)
            try #require(loaded.0 && loaded.1)
            await library.waitForProjection()
            library.sort = .name; await library.waitForProjection()
            library.selectedID = assets[0].id; editor.library = library
            try await body(library, editor, assets)
            library.beginTermination(); editor.beginTermination()
            _ = await library.finishSaving(); _ = await editor.finishSaving()
            try FileManager.default.removeItem(at: root)
        } catch {
            library.beginTermination(); editor.beginTermination()
            _ = await library.finishSaving(); _ = await editor.finishSaving()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}

@MainActor
private final class PhotoComparisonNativeHost {
    let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    init(size: NSSize) {
        _ = NSApplication.shared
        WorkspaceAccessibilityElement.enableInProcess()
        window = PhotoComparisonTestWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        window.contentView = hosting; window.orderBack(nil)
    }
    func mount(_ view: some View) { hosting.rootView = AnyView(view) }
    func unmount() { hosting.rootView = AnyView(EmptyView()); hosting.layoutSubtreeIfNeeded() }
    func close() { unmount(); window.close() }
    var nativeViews: [NSView] {
        var pending: [NSView] = [hosting], result: [NSView] = []
        while let view = pending.popLast() { result.append(view); pending.append(contentsOf: view.subviews) }
        return result
    }
    func inputIfPresent(_ side: String) -> DevelopCropNativeInputView? {
        nativeViews.compactMap { $0 as? DevelopCropNativeInputView }.first {
            $0.accessibilityIdentifier() == "workspace.photo-comparison." + side
        }
    }
    func input(_ side: String) throws -> DevelopCropNativeInputView { try #require(inputIfPresent(side)) }
    func settle() async throws {
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(40)); hosting.layoutSubtreeIfNeeded()
    }
    func wait(_ label: String, _ condition: @escaping @MainActor () -> Bool) async throws {
        try await waitForTestState(label, timeout: .seconds(15), state: { @MainActor in condition() }, until: { $0 })
        try await settle()
    }
    func press(_ identifier: String) async throws {
        try await settle()
        let element = try #require(WorkspaceAccessibilityElement.descendants(of: hosting).first {
            $0.accessibilityIdentifier() == identifier
        }, "Missing native action \(identifier); available: \(WorkspaceAccessibilityElement.descendants(of: hosting).compactMap { $0.accessibilityIdentifier() ?? $0.accessibilityLabel() })")
        try #require(element.isAccessibilityEnabled())
        try #require(element.accessibilityPerformPress())
        try await settle()
    }
    func click(_ input: DevelopCropNativeInputView) throws {
        let point = CGPoint(x: input.bounds.midX, y: input.bounds.midY)
        try requireHit(input, at: point)
        let windowPoint = input.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] { window.sendEvent(try event(type, at: windowPoint)) }
    }
    func drag(_ input: DevelopCropNativeInputView) throws {
        let point = CGPoint(x: input.bounds.midX, y: input.bounds.midY)
        try requireHit(input, at: point)
        let start = input.convert(point, to: nil), end = CGPoint(x: start.x + 20, y: start.y + 12)
        window.sendEvent(try event(.leftMouseDown, at: start))
        window.sendEvent(try event(.leftMouseDragged, at: end))
        window.sendEvent(try event(.leftMouseUp, at: end))
    }
    private func requireHit(_ input: NSView, at point: CGPoint) throws {
        try #require(hosting.hitTest(input.convert(point, to: hosting.superview)) === input,
            "Each pane owns its visible native hit area")
    }
    private func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }
    @discardableResult func focus(_ responder: NSResponder?) -> Bool { window.makeFirstResponder(responder) }
    @discardableResult func key(code: UInt16, text: String, consumed: Bool = true) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        let handler = try #require(nativeViews.compactMap { $0 as? WorkspaceKeyboardInputView }.first)
        let result = handler.process(event) == nil
        try #require(result == consumed)
        return result
    }
    func visibleNumericField(label: String) throws -> NSTextField {
        try #require(nativeViews.compactMap { $0 as? NSTextField }.first { field in
            guard field.accessibilityLabel() == label, field.isEditable, field.isEnabled,
                  !field.isHiddenOrHasHiddenAncestor else { return false }
            return hosting.bounds.contains(field.convert(field.bounds, to: hosting))
        }, "A fully visible candidate field named \(label) must be reachable")
    }
    func clickAndRequireFieldFocus(label: String) async throws -> NSTextField {
        // Probe several meaningful interior text positions, rather than bezel
        // edges. The repeated center also verifies a fresh independent click.
        let fractions = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.35, y: 0.5),
                         CGPoint(x: 0.65, y: 0.5), CGPoint(x: 0.5, y: 0.35), CGPoint(x: 0.5, y: 0.65)]
        var mostRecentField: NSTextField?
        for fraction in fractions {
            try #require(window.makeFirstResponder(nil), "The previous native editor must finish before the next independent click")
            // SwiftUI removes/rebinds its field-editor bridge on the next native
            // update. Never send a click to the previous editor's stale view.
            try await settle()
            let field = try visibleNumericField(label: label)
            let textRect = field.cell?.titleRect(forBounds: field.bounds) ?? field.bounds
            let drawingRect = field.cell?.drawingRect(forBounds: field.bounds) ?? field.bounds
            var interactive = field.bounds.intersection(textRect)
            var parent = field.superview
            while let current = parent {
                interactive = interactive.intersection(field.convert(current.bounds, from: current))
                parent = current.superview
            }
            try #require(interactive.width > 2 && interactive.height > 2,
                "The visible Belichtung field must have a complete native event region")
            let inset = interactive.insetBy(dx: 1, dy: 1)
            let point = CGPoint(x: inset.minX + fraction.x * inset.width,
                                y: inset.minY + fraction.y * inset.height)
            let hostPoint = field.convert(point, to: hosting.superview)
            let windowPoint = field.convert(point, to: nil)
            let hit = hosting.hitTest(hostPoint)
            var chain: [String] = []
            var ancestor: NSView? = field
            while let current = ancestor {
                chain.append("\(type(of: current)) frame=\(current.convert(current.bounds, to: nil)) clips=\(current.clipsToBounds)")
                ancestor = current.superview
            }
            print("PHOTO-COMPARISON-FIELD-HIT titleRect=\(textRect), drawingRect=\(drawingRect), interactive=\(interactive), point=\(point), hostPoint=\(hostPoint), windowPoint=\(windowPoint), hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil"), hitFrame=\(hit.map { $0.convert($0.bounds, to: nil) } ?? .zero), chain=\(chain)")
            try #require(hosting.bounds.contains(field.convert(field.bounds, to: hosting)),
                "The complete numeric field stays inside the visible window")
            let down = try event(.leftMouseDown, at: windowPoint)
            let up = try event(.leftMouseUp, at: windowPoint)
            // AppKit text selection can consume mouseUp in an inner tracking
            // loop. Queue that event before delivering the real window mouseDown.
            // No direct focus call or control mouseDown bypass selects the field.
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
            // NSTextView may consume the queued release inside tracking before
            // NSWindow sees it. Finish the synthetic window pointer sequence as
            // well, so a subsequent independent click has no stale receiver.
            if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                    inMode: .eventTracking, dequeue: false),
               queued.windowNumber == up.windowNumber, queued.timestamp == up.timestamp {
                _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: true)
            }
            window.sendEvent(up)
            try await settle()
            let focused = try visibleNumericField(label: label)
            let editor = try #require(focused.currentEditor() as? NSTextView,
                "A real window click at \(point) must activate the Belichtung text editor")
            try #require(window.firstResponder === editor,
                "Exactly the clicked Belichtung field must own native keyboard focus")
            mostRecentField = focused
        }
        return try #require(mostRecentField)
    }
    func photoFrame(width: Int, height: Int) -> CGRect? {
        guard let view = nativeViews.compactMap({ $0 as? NSImageView }).first(where: { view in
            guard !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty,
                  let image = view.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
            return image.width == width && image.height == height
                && hosting.bounds.intersects(view.convert(view.bounds, to: hosting))
        }) else { return nil }
        return view.convert(view.bounds, to: hosting)
    }
    func hasVisiblePhoto(width: Int, height: Int) -> Bool { photoFrame(width: width, height: height) != nil }
    func requireHealthy(_ stage: String, library: LibraryModel, editor: EditingModel,
                        metadata: PhotoMetadataModel, workspace: DevelopWorkspace) throws {
        let diagnostics = "\(stage): library=\(library.errorMessage ?? "none"), editor=\(editor.errorMessage ?? "none"), metadata=\(metadata.errorMessage ?? "none"), workspace=\(workspace.errorMessage ?? "none"), selected=\(library.selectedID ?? "none")"
        if library.errorMessage != nil || editor.errorMessage != nil || metadata.errorMessage != nil || workspace.errorMessage != nil {
            print("PHOTO-COMPARISON-ACCEPTANCE ERROR: " + diagnostics)
        }
        try #require(library.errorMessage == nil && editor.errorMessage == nil
            && metadata.errorMessage == nil && workspace.errorMessage == nil, Comment(rawValue: diagnostics))
    }
    func snapshot(to url: URL) throws {
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

@MainActor
private final class PhotoComparisonTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// Keep the actual child entry outside any MainActor-isolated suite. Its
/// CF-perform block, rather than Swift Testing's main-dispatch callback, owns
/// the entire native scenario and continues pumping after AppKit tracking.
@Suite("Protected photo comparison native child")
struct PhotoComparisonNativeChildTests: Sendable {
    @Test(.enabled(if: ProcessInfo.processInfo.environment[photoComparisonChildToken] != nil))
    func protectedPhotoComparisonNativeChildScenario() async throws {
        let key = try #require(ProcessInfo.processInfo.environment[photoComparisonChildSize])
        let size = try #require(photoComparisonNativeSizes[key])
        try await runProtectedNativeAcceptanceScenario {
            try await PhotoComparisonTests().runNativeComparisonScenario(size: size)
        }
    }
}

private let photoComparisonChildToken = "GLOWROOM_TEST_PHOTO_COMPARISON_CHILD_TOKEN"
private let photoComparisonChildResult = "GLOWROOM_TEST_PHOTO_COMPARISON_CHILD_RESULT"
private let photoComparisonChildSize = "GLOWROOM_TEST_PHOTO_COMPARISON_CHILD_SIZE"
private let photoComparisonNativeSizes = ["1000x660": NSSize(width: 1000, height: 660), "1440x900": NSSize(width: 1440, height: 900)]
private let photoComparisonRequiredStages = ["setup", "linked-zoom", "coupled-pan", "free-navigation",
    "candidate-adjustment", "candidate-roundtrip", "rating-favorite", "numeric-mouse-focus", "ready-images", "escape", "close", "crop-routing", "cleanup"]
private struct PhotoComparisonNativeCompletion: Codable {
    let token: String
    let width: Int
    let height: Int
    let stages: [String]
    let allAssertionsWereFatal: Bool
}

private func runPhotoComparisonNativeChild(size: NSSize) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do { try launchPhotoComparisonNativeChild(size: size); continuation.resume() }
            catch { continuation.resume(throwing: error) }
        }
    }
}

private func launchPhotoComparisonNativeChild(size: NSSize) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-222-child-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = directory.appendingPathComponent("complete.json"), log = directory.appendingPathComponent("child.log")
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
    child.arguments = arguments + ["--testing-library", "swift-testing", "--filter", "protectedPhotoComparisonNativeChildScenario"]
    var environment = ProcessInfo.processInfo.environment
    environment[photoComparisonChildToken] = token
    environment[photoComparisonChildResult] = result.path
    environment[photoComparisonChildSize] = "\(Int(size.width))x\(Int(size.height))"
    child.environment = environment
    child.standardOutput = output; child.standardError = output
    child.terminationHandler = { _ in ended.signal() }
    try child.run()
    guard ended.wait(timeout: .now() + 120) == .success else {
        if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
        let reaped = ended.wait(timeout: .now() + 2) == .success
        throw PhotoComparisonNativeChildFailure(detail: "Timed out; SIGKILL reaped=\(reaped)", log: try photoComparisonChildLog(log))
    }
    let transcript = try photoComparisonChildLog(log)
    let marker = (try? Data(contentsOf: result)).flatMap { try? JSONDecoder().decode(PhotoComparisonNativeCompletion.self, from: $0) }
    let complete = marker?.token == token && marker?.width == Int(size.width) && marker?.height == Int(size.height)
        && marker?.stages == photoComparisonRequiredStages && marker?.allAssertionsWereFatal == true
    let passed = transcript.range(of: #"✔\s+Test run with 1 test(?: in 1 suite)? passed after"#, options: .regularExpression) != nil
    let reportedIssue = transcript.contains("✘") || transcript.localizedCaseInsensitiveContains("recorded an issue")
    guard child.terminationReason == .exit, child.terminationStatus == 0, complete, passed, !reportedIssue else {
        throw PhotoComparisonNativeChildFailure(detail: "Status=\(child.terminationStatus), reason=\(child.terminationReason), all fatal checkpoints=\(complete), SDK completion=\(passed), reported issue=\(reportedIssue)", log: transcript)
    }
    print(transcript)
    print("Photo comparison \(Int(size.width))x\(Int(size.height)): all fatal native checkpoints, matching completion token, SDK success and child exit confirmed.")
}

private func photoComparisonChildLog(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let end = try handle.seekToEnd()
    try handle.seek(toOffset: end > 65536 ? end - 65536 : 0)
    return String(decoding: try handle.read(upToCount: 65536) ?? Data(), as: UTF8.self)
}
private struct PhotoComparisonNativeChildFailure: Error, CustomStringConvertible {
    let detail: String
    let log: String
    var description: String { "Photo comparison native child: \(detail)\n\(log)" }
}
