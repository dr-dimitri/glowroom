import AppKit
import Foundation
import GlowroomCore
import Testing
import SwiftUI
@testable import Glowroom

@Suite("AI development review transactions", .timeLimit(.minutes(2)))
@MainActor
struct AIDevelopmentModelTests {
    @Test func externalNumericProposalUsesVisibleAcceptanceAndOneUndo() async throws {
        let f = try await AIDevelopmentFixture.make()
        defer { f.remove() }
        let stamp = ImageAnalysisSourceStamp(device: 1, inode: 1, byteCount: 1, modifiedSeconds: 1,
            modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0)
        let bitmap = try #require(f.workspace.originalBitmap)
        f.workspace.receive(bitmap, sourceBitmap: bitmap, sourceStamp: stamp)
        let snapshot = try #require(f.editor.aiSnapshot(in: f.library))
        try await f.model.prepareExternal(snapshot: snapshot, patch: .init([.init(.exposure, 1)]), requestID: "external-1",
            library: f.library, editor: f.editor, workspace: f.workspace)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        #expect(!f.editor.canUndo(assetID: f.assetID))
        #expect(f.model.canApplyProposal && f.model.proposal?.settings.exposure == 1)
        let host = WorkspaceSectionTestHost(size: NSSize(width: 420, height: 1_100))
        defer { host.close() }
        try await host.mount(AIDevelopmentView(library: f.library, model: f.model)
            .environmentObject(f.editor).environmentObject(f.workspace).frame(width: 380))
        let apply = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "ai-development.apply" })
        try #require(apply.accessibilityPerformPress())
        try await waitForTestState("external proposal accepted", state: { @MainActor in f.model.proposal == nil && !f.model.isRunning }, until: { $0 })
        #expect(f.editor.settings(for: f.assetID).exposure == 1)
        #expect(f.model.externalOutcome == "accepted")
        await (try #require(f.start())).value
        #expect(f.model.proposal != nil && f.model.externalRequestID == nil)
        #expect(f.model.lastExternalResult?.id == "external-1" && f.model.lastExternalResult?.state == "accepted")
        f.model.discard()
        f.editor.undo(assetID: f.assetID)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        #expect(!f.editor.canUndo(assetID: f.assetID))
        #expect(await f.editor.flush())
        try await host.unmount()
    }

    @Test func externalProposalCannotSurviveSelectionRoundTripOrChangeUnsupportedValues() async throws {
        let f = try await AIDevelopmentFixture.make()
        defer { f.remove() }
        let bitmap = try #require(f.workspace.originalBitmap)
        f.workspace.receive(bitmap, sourceBitmap: bitmap, sourceStamp: .init(device: 1, inode: 1, byteCount: 1,
            modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0))
        let snapshot = try #require(f.editor.aiSnapshot(in: f.library))
        f.library.selectedID = nil; f.library.selectedID = f.assetID
        await #expect(throws: MCPFailure.self) {
            try await f.model.prepareExternal(snapshot: snapshot, patch: .init([.init(.exposure, 1)]),
                library: f.library, editor: f.editor, workspace: f.workspace)
        }
        #expect(f.model.proposal == nil && !f.editor.canUndo(assetID: f.assetID))
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        #expect(await f.editor.flush())
    }

    @Test func presetPreviewRevokesAIProposalAcceptanceIncludingDelayedValidation() async throws {
        let entered = TestAsyncLatch(), release = TestAsyncLatch()
        let f = try await AIDevelopmentFixture.make(validateSource: { _, _ in
            entered.releaseAll(); await release.wait()
        })
        defer { release.releaseAll(); f.remove() }
        await (try #require(f.start())).value
        let ai = try #require(f.workspace.aiCorrectionPreview)
        f.workspace.presetPreview = ai
        #expect(!f.model.canApplyProposal)
        #expect(f.model.apply(library: f.library, editor: f.editor) == nil)
        await (try #require(f.start())).value
        let work = try #require(f.model.apply(library: f.library, editor: f.editor))
        await entered.wait()
        f.workspace.presetPreview = ai
        release.releaseAll(); await work.value
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        #expect(f.workspace.presetPreview != nil && f.workspace.aiCorrectionPreview == nil)
        #expect(!f.model.canApplyProposal && !f.model.isRunning)
        #expect(await f.editor.finishSaving())
    }

    @Test func lateAIResultCannotReplaceNewerPersonalPreviewRequest() async throws {
        let entered = TestAsyncLatch(), release = TestAsyncLatch()
        let f = try await AIDevelopmentFixture.make(renderCorrection: { bitmap, _, _, _ in
            entered.releaseAll(); await release.wait(); return bitmap
        })
        defer { release.releaseAll(); f.remove() }
        let work = try #require(f.start()); await entered.wait()
        _ = f.workspace.beginCorrectionPreview()
        let personal = AICorrectionPreview(snapshot: try #require(f.editor.aiSnapshot(in: f.library)),
            settings: EditSettings(exposure: -1), bitmap: try #require(f.workspace.originalBitmap))
        f.workspace.presetPreview = personal
        release.releaseAll(); await work.value
        #expect(f.model.proposal == nil && !f.model.canApplyProposal)
        #expect(f.workspace.aiCorrectionPreview == nil && f.workspace.presetPreview?.settings == personal.settings)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        #expect(await f.editor.finishSaving())
    }

    @Test func slidersAndProposalDoNotWriteUntilExplicitAcceptance() async throws {
        let f = try await AIDevelopmentFixture.make()
        defer { f.remove() }
        f.model.intent.brightness = 0.8
        #expect(await f.probe.calls == 0)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        let task = try #require(f.start())
        await task.value
        #expect(f.model.proposal?.settings.exposure == 0.5)
        let preview = try #require(f.workspace.aiCorrectionPreview)
        #expect(preview.snapshot.settings == .neutral && preview.settings.exposure == 0.5)
        #expect(f.workspace.showsAICorrectionProposal)
        #expect(try ImageAnalysisPreparer.describeRaster(preview.bitmap).digest
            != ImageAnalysisPreparer.describeRaster(try #require(f.workspace.originalBitmap)).digest)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        #expect(!f.editor.canUndo(assetID: f.assetID))
        let revision = f.editor.localRevision(for: f.assetID)
        f.workspace.showsAICorrectionProposal = false
        f.workspace.showsAICorrectionProposal = true
        #expect(f.editor.localRevision(for: f.assetID) == revision)
        await (try #require(f.model.apply(library: f.library, editor: f.editor))).value
        #expect(f.workspace.aiCorrectionPreview == nil)
        #expect(f.editor.settings(for: f.assetID).exposure == 0.5)
        #expect(f.editor.canUndo(assetID: f.assetID))
        f.editor.undo(assetID: f.assetID)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        #expect(!f.editor.canUndo(assetID: f.assetID))
        f.editor.redo(assetID: f.assetID)
        #expect(f.editor.settings(for: f.assetID).exposure == 0.5)
        #expect(await f.probe.calls == 1)
        #expect(await f.editor.flush())
        #expect(await f.store.loadAll()[f.assetID]?.exposure == 0.5)
    }

    @Test(arguments: ["empty", "unchangedTargets", "zeroStrength"])
    func unchangedProposalCannotBeAcceptedOrReportedAsApplied(kind: String) async throws {
        let adjustments: AIDevelopmentAdjustments = kind == "empty" ? .init()
            : kind == "unchangedTargets" ? .init(settings: .neutral) : .init(exposure: 1)
        let f = try await AIDevelopmentFixture.make(adjustments: adjustments)
        defer { f.remove() }
        if kind == "zeroStrength" { f.model.intent.strength = 0 }
        await (try #require(f.start())).value
        let status = try #require(f.model.status)
        #expect(!f.model.canApplyProposal)
        #expect(f.workspace.aiCorrectionPreview == nil)
        #expect(f.model.apply(library: f.library, editor: f.editor) == nil)
        #expect(f.model.status == status)
        #expect(!f.model.isRunning)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        #expect(f.editor.localRevision(for: f.assetID) == 0)
        #expect(!f.editor.canUndo(assetID: f.assetID))
        #expect(await f.editor.flush())
        #expect(await f.store.loadAll()[f.assetID] == .neutral)
    }

    @Test func discardingRenderedProposalKeepsAcceptedPreviewHistoryAndSettings() async throws {
        let f = try await AIDevelopmentFixture.make()
        defer { f.remove() }
        let acceptedImage = try #require(f.workspace.navigatorImage)
        let acceptedSource = try #require(f.workspace.originalBitmap).rangeSourceIdentity
        await (try #require(f.start())).value
        #expect(f.workspace.aiCorrectionPreview != nil)
        #expect(f.workspace.navigatorImage === acceptedImage)
        #expect(f.workspace.originalBitmap?.rangeSourceIdentity == acceptedSource)
        #expect(await f.editor.flush())
        #expect(await f.store.loadAll()[f.assetID] == .neutral)
        f.model.discard()
        #expect(f.workspace.aiCorrectionPreview == nil)
        #expect(f.workspace.navigatorImage === acceptedImage)
        #expect(!f.editor.canUndo(assetID: f.assetID))
        #expect(await f.probe.calls == 1)
    }

    @Test(arguments: ["cancel", "selection", "editUndo", "scope", "source"])
    func staleCorrectionRenderNeverPublishes(change: String) async throws {
        let entered = TestAsyncLatch(), release = TestAsyncLatch()
        let f = try await AIDevelopmentFixture.make(renderCorrection: { bitmap, snapshot, settings, _ in
            #expect(snapshot.settings == .neutral && settings.exposure == 0.5)
            entered.releaseAll(); await release.wait() // Native rendering can finish after cancellation.
            return bitmap
        })
        defer { release.releaseAll(); f.remove() }
        let work = try #require(f.start()); await entered.wait()
        #expect(f.model.proposal == nil && f.workspace.aiCorrectionPreview == nil)
        switch change {
        case "cancel": f.model.cancel()
        case "selection": f.library.selectedID = nil
        case "editUndo":
            f.editor.setSettings(EditSettings(exposure: 2), for: f.assetID)
            f.editor.undo(assetID: f.assetID)
        case "scope": f.model.intent.targetMaskID = UUID()
        default: f.workspace.clear()
        }
        f.model.invalidateIfNeeded(library: f.library, editor: f.editor)
        #expect(f.start() == nil, "An in-flight render retains admission until completion")
        release.releaseAll(); await work.value
        #expect(f.model.proposal == nil && f.workspace.aiCorrectionPreview == nil)
        #expect(!f.model.canApplyProposal && !f.model.isRunning)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        #expect(!f.editor.canUndo(assetID: f.assetID))
    }

    @Test func correctionRenderFailureOffersNoUnreviewedAcceptance() async throws {
        let f = try await AIDevelopmentFixture.make(renderCorrection: { _, _, _, _ in throw PreviewFailure.unavailable })
        defer { f.remove() }
        await (try #require(f.start())).value
        #expect(f.model.proposal == nil && f.workspace.aiCorrectionPreview == nil)
        #expect(f.model.status == "Die Vorschau des Vorschlags konnte nicht erstellt werden. Erstelle den Vorschlag erneut.")
        #expect(!f.model.canApplyProposal && !f.model.isRunning)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
    }

    @Test func externallyReplacedSourceCannotRenderAProposalOnOlderCanvasPixels() async throws {
        let renders = AICorrectionRenderProbe()
        let f = try await AIDevelopmentFixture.make(renderCorrection: { bitmap, _, _, _ in
            await renders.record(bitmap.rangeSourceIdentity)
            return bitmap
        })
        defer { f.remove() }
        let bitmap = try #require(f.workspace.originalBitmap)
        // The catalog identity remains unchanged. Only the native inode/ctime
        // distinguishes these canvas pixels from the later inference source.
        let oldStamp = ImageAnalysisSourceStamp(device: 1, inode: 2, byteCount: 1,
            modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 0, changedNanoseconds: 0)
        f.workspace.receive(bitmap, sourceBitmap: bitmap, sourceStamp: oldStamp)
        await (try #require(f.start())).value
        #expect(f.model.status == AIDevelopmentError.staleContext.localizedDescription)
        #expect(f.model.proposal == nil && f.workspace.aiCorrectionPreview == nil)
        #expect(await renders.sources.isEmpty)
        #expect(!f.model.canApplyProposal && !f.editor.canUndo(assetID: f.assetID))
        #expect(f.editor.settings(for: f.assetID) == .neutral)
    }

    @Test func progressivePreviewWaitsForFinalSourceBeforeStartingInference() async throws {
        let f = try await AIDevelopmentFixture.make()
        defer { f.remove() }
        let bitmap = try #require(f.workspace.originalBitmap)
        f.workspace.receive(bitmap, sourceBitmap: bitmap, finalSourceReady: false)
        #expect(f.start() == nil)
        #expect(f.model.status == AIDevelopmentError.missingPreview.localizedDescription)
        #expect(await f.probe.calls == 0)
        f.workspace.receive(bitmap, sourceBitmap: bitmap, finalSourceReady: true)
        await (try #require(f.start())).value
        #expect(f.model.canApplyProposal)
        #expect(await f.probe.calls == 1)
    }

    @Test func renderedProposalCanBeAcceptedAfterModelWeightsBecomeUnavailable() async throws {
        let f = try await AIDevelopmentFixture.make()
        defer { f.remove() }
        await (try #require(f.start())).value
        #expect(f.model.canApplyProposal && f.workspace.aiCorrectionPreview != nil)
        let host = WorkspaceSectionTestHost(size: NSSize(width: 420, height: 1_100))
        defer { host.close() }
        try await host.mount(AIDevelopmentView(library: f.library, model: f.model, checkModel: { false })
            .environmentObject(f.editor).environmentObject(f.workspace).frame(width: 380))
        try await waitForTestState("weights unavailable after a rendered proposal", state: { @MainActor in
            host.accessibilityElements.contains { $0.accessibilityIdentifier() == "ai-development.model-required" }
        }, until: { $0 })
        try await host.settle()
        let generate = try #require(host.accessibilityElements.first {
            $0.accessibilityIdentifier() == "ai-development.generate"
        })
        let apply = try #require(host.accessibilityElements.first {
            $0.accessibilityIdentifier() == "ai-development.apply"
        })
        #expect(!generate.isAccessibilityEnabled(), "Another inference still requires model weights")
        try #require(apply.isAccessibilityEnabled(), "A reviewed proposal needs no further inference")
        try #require(apply.accessibilityPerformPress())
        try await waitForTestState("rendered proposal accepted without installed weights", state: { @MainActor in
            !f.model.isRunning && f.model.proposal == nil && f.editor.settings(for: f.assetID).exposure == 0.5
        }, until: { $0 })
        #expect(f.workspace.aiCorrectionPreview == nil)
        #expect(await f.probe.calls == 1)
        #expect(await f.editor.flush())
        #expect(await f.store.loadAll()[f.assetID]?.exposure == 0.5)
        try await host.unmount()
    }

    @Test func coldAndWarmProposalsRenderFromTheSameDecodedSourceWithoutNewInferenceOnDisplayChanges() async throws {
        let probe = AICorrectionRenderProbe()
        let f = try await AIDevelopmentFixture.make(renderCorrection: { bitmap, snapshot, settings, _ in
            await probe.record(bitmap.rangeSourceIdentity)
            return try await AdjustedPreviewPipeline.shared.image(bitmap,
                request: PreviewRequest(source: snapshot.source, pixelSize: 128), settings: settings, priority: .selected)
        })
        defer { f.remove() }
        let original = try #require(f.workspace.originalBitmap)
        await (try #require(f.start())).value
        let first = try #require(f.workspace.aiCorrectionPreview).bitmap
        f.workspace.showsAICorrectionProposal = false
        f.workspace.showsAICorrectionProposal = true
        #expect(await f.probe.calls == 1)
        f.model.discard()
        await (try #require(f.start())).value
        let second = try #require(f.workspace.aiCorrectionPreview).bitmap
        #expect(await probe.sources == [original.rangeSourceIdentity, original.rangeSourceIdentity])
        #expect(first.image === second.image, "The warm proposal reuses the shared adjusted render cache")
        #expect(f.workspace.originalBitmap?.rangeSourceIdentity == original.rangeSourceIdentity)
        #expect(f.editor.localRevision(for: f.assetID) == 0)
    }

    @Test(arguments: ["inference", "ready", "sourceValidation"])
    func persistenceCompletionPreservesProposalForUnchangedVisibleEdit(phase: String) async throws {
        let inference = TestAsyncLatch(open: phase != "inference")
        let save = TestAsyncLatch(), saveEntered = TestAsyncLatch()
        let validation = TestAsyncLatch(open: phase != "sourceValidation"), validationEntered = TestAsyncLatch()
        let f = try await AIDevelopmentFixture.make(latch: inference, saveLatch: save, saveEntered: saveEntered,
            validateSource: { _, _ in validationEntered.releaseAll(); await validation.wait() })
        defer { inference.releaseAll(); save.releaseAll(); validation.releaseAll(); f.remove() }
        f.editor.setSettings(EditSettings(exposure: 0.2), for: f.assetID)
        let saving = Task { await f.editor.flush() }
        await saveEntered.wait()
        let captured = try #require(f.editor.aiSnapshot(in: f.library))
        let generating = try #require(f.start())
        var applying: Task<Void, Never>?
        if phase == "inference" {
            try await waitForTestState("Qwen fake entered before persistence completes", state: { await f.probe.calls }, until: { $0 == 1 })
        } else {
            await generating.value
            #expect(f.model.canApplyProposal)
            if phase == "sourceValidation" {
                let application = try #require(f.model.apply(library: f.library, editor: f.editor))
                applying = application
                await validationEntered.wait()
            }
        }

        save.releaseAll()
        #expect(await saving.value)
        let persisted = try #require(f.editor.aiSnapshot(in: f.library))
        #expect(captured.persistedVersion != persisted.persistedVersion)
        #expect(captured.settings == persisted.settings && captured.token == persisted.token)
        // SwiftUI and the Combine observer both revalidate after publication.
        // Exercise that boundary explicitly without depending on their scheduling.
        f.model.invalidateIfNeeded(library: f.library, editor: f.editor)
        inference.releaseAll(); await generating.value
        if let applying {
            validation.releaseAll(); await applying.value
        } else {
            #expect(f.model.canApplyProposal)
            await (try #require(f.model.apply(library: f.library, editor: f.editor))).value
        }
        #expect(abs(f.editor.settings(for: f.assetID).exposure - 0.6) < 0.000_001)
        #expect(f.model.status == "Vorschlag übernommen.")
        #expect(await f.editor.flush())
        #expect(abs((await f.store.loadAll()[f.assetID]?.exposure ?? 0) - 0.6) < 0.000_001)
        f.editor.undo(assetID: f.assetID)
        #expect(f.editor.settings(for: f.assetID).exposure == 0.2)
        #expect(await f.editor.flush())
    }

    @Test(arguments: ["inference", "ready", "sourceValidation"])
    func automaticBackupFencesPreserveProposalAndDeferAcceptance(phase: String) async throws {
        let backup = AIDevelopmentBackupSchedule()
        let inference = TestAsyncLatch(open: phase != "inference")
        let validation = TestAsyncLatch(open: phase != "sourceValidation"), validationEntered = TestAsyncLatch()
        let f = try await AIDevelopmentFixture.make(latch: inference, backup: backup,
            validateSource: { _, _ in validationEntered.releaseAll(); await validation.wait() })
        defer { backup.releaseAll(); inference.releaseAll(); validation.releaseAll(); f.remove() }
        var generating: Task<Void, Never>?, applying: Task<Void, Never>?
        do {
            f.editor.setSettings(EditSettings(exposure: 0.2), for: f.assetID)
            #expect(await f.editor.flush())
            let generation = try #require(f.start())
            generating = generation
            if phase == "inference" {
                try await waitForTestState("Qwen fake entered before automatic backup", state: { await f.probe.calls }, until: { $0 == 1 })
            } else {
                await generating?.value
                if phase == "sourceValidation" {
                    let application = try #require(f.model.apply(library: f.library, editor: f.editor))
                    applying = application
                    await validationEntered.wait()
                }
            }

            backup.start.releaseAll(); await backup.snapshotEntered.wait()
            #expect(f.editor.isAutomaticBackupMaintenance && !f.editor.canEdit)
            #expect(f.editor.aiSnapshot(in: f.library) == nil)
            f.model.invalidateIfNeeded(library: f.library, editor: f.editor)
            // Native work may finish while write admission is briefly closed.
            // Its result must stay reviewable, with acceptance deferred.
            inference.releaseAll(); await generating?.value
            validation.releaseAll(); await applying?.value
            #expect(f.model.canApplyProposal && !f.model.isRunning)
            let proposal = try #require(f.model.proposal)
            #expect(f.model.apply(library: f.library, editor: f.editor) == nil)
            #expect(f.model.proposal == proposal)
            #expect(f.editor.settings(for: f.assetID).exposure == 0.2)

            backup.snapshotRelease.releaseAll(); await backup.copyEntered.wait()
            #expect(!f.editor.isAutomaticBackupMaintenance && f.editor.canEdit)
            f.model.invalidateIfNeeded(library: f.library, editor: f.editor)
            #expect(f.model.proposal == proposal)
            backup.copyRelease.releaseAll(); await backup.pruneEntered.wait()
            #expect(f.editor.isAutomaticBackupMaintenance && !f.editor.canEdit)
            f.model.invalidateIfNeeded(library: f.library, editor: f.editor)
            #expect(f.model.apply(library: f.library, editor: f.editor) == nil)
            #expect(f.model.proposal == proposal && f.model.canApplyProposal)
            #expect(f.editor.settings(for: f.assetID).exposure == 0.2)

            backup.pruneRelease.releaseAll(); await backup.finished.wait()
            #expect(f.editor.canEdit)
            await (try #require(f.model.apply(library: f.library, editor: f.editor))).value
            #expect(abs(f.editor.settings(for: f.assetID).exposure - 0.6) < 0.000_001)
            #expect(f.model.status == "Vorschlag übernommen.")
            #expect(await f.editor.flush())
            f.editor.undo(assetID: f.assetID)
            #expect(f.editor.settings(for: f.assetID).exposure == 0.2)
            #expect(await f.editor.finishSaving())
        } catch {
            backup.releaseAll(); inference.releaseAll(); validation.releaseAll()
            await generating?.value; await applying?.value
            _ = await f.editor.finishSaving()
            throw error
        }
    }

    @Test(arguments: ["editUndo", "selection", "workspace", "workspaceRoundTrip", "toolRoundTrip", "comparisonRoundTrip", "sourceComparisonRoundTrip", "intent", "cancel", "bitmap"])
    func staleOrCancelledInferenceNeverPublishes(change: String) async throws {
        let latch = TestAsyncLatch()
        let f = try await AIDevelopmentFixture.make(latch: latch)
        defer { latch.releaseAll(); f.remove() }
        let task = try #require(f.start())
        try await waitForTestState("Qwen fake entered", state: { await f.probe.calls }, until: { $0 == 1 })
        switch change {
        case "editUndo":
            f.editor.setSettings(EditSettings(exposure: 2), for: f.assetID)
            f.editor.undo(assetID: f.assetID)
        case "selection":
            let id = f.library.selectedID; f.library.selectedID = nil; f.library.selectedID = id
        case "workspace": f.library.workspaceMode = .library
        case "workspaceRoundTrip":
            f.library.workspaceMode = .library; f.library.workspaceMode = .develop
        case "toolRoundTrip":
            f.workspace.tool = .crop; f.workspace.tool = .basic
        case "comparisonRoundTrip":
            f.library.comparesOriginal = true; f.library.comparesOriginal = false
        case "sourceComparisonRoundTrip":
            f.library.comparesCurrentSourceWithoutSettings = true; f.library.comparesCurrentSourceWithoutSettings = false
        case "intent": f.model.intent.warmth = 0.3
        case "cancel": f.model.cancel()
        default: f.workspace.clear()
        }
        #expect(f.start() == nil, "A cancelled native call keeps admission until it actually returns")
        latch.releaseAll(); await task.value
        #expect(f.model.proposal == nil && !f.model.isRunning)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        #expect(await f.editor.flush())
    }

    @Test(arguments: ["library", "crop", "original", "source"])
    func requestAdmissionUsesTheSharedDevelopContext(context: String) async throws {
        let f = try await AIDevelopmentFixture.make()
        defer { f.remove() }
        switch context {
        case "library": f.library.workspaceMode = .library
        case "crop": f.workspace.tool = .crop
        case "original": f.library.comparesOriginal = true
        default: f.library.comparesCurrentSourceWithoutSettings = true
        }
        #expect(f.start() == nil)
        #expect(await f.probe.calls == 0)
        #expect(!f.model.isRunning && f.model.proposal == nil)
        #expect(await f.editor.flush())
    }

    @Test(arguments: ["inference", "ready"])
    func displayChangesPreserveTheSharedProposalWithoutStartingInference(phase: String) async throws {
        let release = TestAsyncLatch(open: phase != "inference")
        let f = try await AIDevelopmentFixture.make(latch: release)
        defer { release.releaseAll(); f.remove() }
        #expect(f.library.workspaceMode == .develop)
        let generation = try #require(f.start())
        try await waitForTestState("shared development request entered", state: { await f.probe.calls }, until: { $0 == 1 })
        if phase == "ready" { await generation.value }
        let settings = f.editor.settings(for: f.assetID)
        let token = f.editor.localRevision(for: f.assetID)
        f.workspace.showsHighlights.toggle()
        f.workspace.photoViewport.toggleZoom(at: CGPoint(x: 0.3, y: 0.4))
        f.model.invalidateIfNeeded(library: f.library, editor: f.editor)
        release.releaseAll(); await generation.value
        #expect(f.model.canApplyProposal)
        #expect(f.editor.settings(for: f.assetID) == settings)
        #expect(f.editor.localRevision(for: f.assetID) == token)
        #expect(f.workspace.photoViewport.isZoomed)
        #expect(await f.probe.calls == 1)
        await (try #require(f.model.apply(library: f.library, editor: f.editor))).value
        #expect(f.editor.settings(for: f.assetID).exposure == 0.5)
        #expect(await f.editor.flush())
    }

    @Test func leavingDevelopAfterAcceptanceKeepsTheQueuedWriteAndUndo() async throws {
        let save = TestAsyncLatch(), entered = TestAsyncLatch()
        let f = try await AIDevelopmentFixture.make(saveLatch: save, saveEntered: entered)
        defer { save.releaseAll(); f.remove() }
        await (try #require(f.start())).value
        await (try #require(f.model.apply(library: f.library, editor: f.editor))).value
        let saving = Task { await f.editor.flush() }
        await entered.wait()
        f.library.workspaceMode = .library
        f.model.cancel()
        #expect(f.editor.settings(for: f.assetID).exposure == 0.5)
        save.releaseAll()
        #expect(await saving.value)
        #expect(await f.store.loadAll()[f.assetID]?.exposure == 0.5)
        f.library.workspaceMode = .develop
        f.editor.undo(assetID: f.assetID)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        #expect(await f.editor.flush())
    }

    @Test func readyProposalCannotOverwriteLaterManualEditAndSupportsRetry() async throws {
        let f = try await AIDevelopmentFixture.make()
        defer { f.remove() }
        await (try #require(f.start())).value
        f.editor.setSettings(EditSettings(shadows: 30), for: f.assetID)
        f.model.apply(library: f.library, editor: f.editor)
        #expect(f.editor.settings(for: f.assetID) == EditSettings(shadows: 30))
        await (try #require(f.start())).value
        #expect(f.model.proposal != nil)
        f.model.discard()
        #expect(f.model.proposal == nil && f.model.status == nil)
        #expect(await f.editor.flush())
    }

    @Test func changedNativeSourceRejectsReadyProposal() async throws {
        let f = try await AIDevelopmentFixture.make(validateSource: { _, _ in throw AIDevelopmentError.staleContext })
        defer { f.remove() }
        await (try #require(f.start())).value
        await (try #require(f.model.apply(library: f.library, editor: f.editor))).value
        #expect(f.editor.settings(for: f.assetID) == .neutral && f.model.proposal == nil)
        #expect(f.model.status == AIDevelopmentError.staleContext.localizedDescription)
        #expect(!f.editor.canUndo(assetID: f.assetID))
    }

    @Test func manualEditAndUndoDuringSourceValidationRejectsApply() async throws {
        let latch = TestAsyncLatch(), entered = TestAsyncLatch()
        let f = try await AIDevelopmentFixture.make(validateSource: { _, _ in
            entered.releaseAll(); await latch.wait()
        })
        defer { latch.releaseAll(); f.remove() }
        await (try #require(f.start())).value
        let task = try #require(f.model.apply(library: f.library, editor: f.editor))
        await entered.wait()
        f.editor.setSettings(EditSettings(exposure: 3), for: f.assetID)
        f.editor.undo(assetID: f.assetID)
        latch.releaseAll(); await task.value
        #expect(f.editor.settings(for: f.assetID) == .neutral && f.model.proposal == nil)
        #expect(await f.editor.flush())
    }

    @Test func nativeObjectMaskAcceptanceSharesLayerAndHistoryAcrossTools() async throws {
        let response = try Self.maskResponse()
        let f = try await AIDevelopmentFixture.make(proposeMask: { _, instruction in
            #expect(instruction == "Maskiere den Blumenstrauß")
            return response
        })
        defer { f.remove() }
        f.model.createsMask = true
        f.model.intent.instruction = "Maskiere den Blumenstrauß"
        let host = WorkspaceSectionTestHost(size: NSSize(width: 420, height: 1_100))
        defer { host.close() }
        try await host.mount(AIDevelopmentView(library: f.library, model: f.model)
            .environmentObject(f.editor).environmentObject(f.workspace).frame(width: 380))
        let generate = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "ai-development.generate" })
        try #require(generate.accessibilityPerformPress())
        try await waitForTestState("object mask proposed", state: { @MainActor in f.model.proposal != nil && !f.model.isRunning }, until: { $0 })
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        #expect(f.model.proposal?.createdMaskID == response.layer.id)
        #expect(f.model.maskPreview != nil)
        try await host.settle()
        let apply = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "ai-development.apply" })
        try #require(apply.accessibilityPerformPress())
        try await waitForTestState("object mask accepted", state: { @MainActor in f.model.proposal == nil && !f.model.isRunning }, until: { $0 })
        let accepted = f.editor.settings(for: f.assetID)
        #expect(accepted.localAdjustments == [response.layer])
        #expect(accepted.exposure == 0 && response.layer.settings == .neutral)
        #expect(await f.probe.calls == 0, "Mask creation never invokes the global development route")
        let inline = InlineMaskWorkspace()
        let asset = try #require(f.library.selectedAsset)
        let source = try f.editor.resolvedSource(for: asset).identity
        #expect(inline.open(asset: asset, source: source, settings: accepted, editor: f.editor, library: f.library))
        #expect(inline.model?.settings.localAdjustments == [response.layer])
        inline.close()
        f.editor.undo(assetID: f.assetID)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        f.editor.redo(assetID: f.assetID)
        #expect(f.editor.settings(for: f.assetID) == accepted)
        #expect(await f.editor.flush())
        #expect(await f.store.loadAll()[f.assetID] == accepted)
        try await host.unmount()
    }

    @Test(arguments: ["cancel", "selection", "editUndo", "mode", "scope"])
    func staleObjectMaskNeverPublishesOrWrites(change: String) async throws {
        let response = try Self.maskResponse()
        let entered = TestAsyncLatch(), release = TestAsyncLatch()
        let f = try await AIDevelopmentFixture.make(proposeMask: { _, _ in
            entered.releaseAll(); await release.wait(); return response
        })
        defer { release.releaseAll(); f.remove() }
        f.model.createsMask = true; f.model.intent.instruction = "Maskiere den Blumenstrauß"
        let work = try #require(f.start()); await entered.wait()
        switch change {
        case "cancel": f.model.cancel()
        case "selection": f.library.selectedID = nil
        case "editUndo":
            f.editor.setSettings(EditSettings(exposure: 2), for: f.assetID)
            f.editor.undo(assetID: f.assetID)
        case "mode": f.model.createsMask = false
        default: f.model.intent.targetMaskID = UUID()
        }
        release.releaseAll(); await work.value
        #expect(f.model.proposal == nil && f.model.maskPreview == nil)
        #expect(f.editor.settings(for: f.assetID).localAdjustments.isEmpty)
        #expect(await f.editor.flush())
    }

    @Test func removingTargetMaskRejectsProposalWithoutGlobalFallback() async throws {
        let layer = try Self.maskResponse().layer
        let f = try await AIDevelopmentFixture.make()
        defer { f.remove() }
        f.editor.setSettings(EditSettings(localAdjustments: [layer]), for: f.assetID)
        f.model.intent.targetMaskID = layer.id
        await (try #require(f.start())).value
        #expect(f.model.proposal?.settings.exposure == 0)
        #expect(f.model.proposal?.settings.localAdjustments[0].settings.exposure == 0.5)
        f.editor.setSettings(.neutral, for: f.assetID)
        #expect(f.model.apply(library: f.library, editor: f.editor) == nil)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        #expect(f.start() == nil)
        #expect(f.model.status == AIDevelopmentError.unavailableMask.localizedDescription)
        #expect(await f.editor.flush())
    }

    private static func maskResponse() throws -> AIObjectMaskResponse {
        let layer = try LocalAdjustment(name: "Blumenstrauß", mask: LocalAdjustmentMask(shape: .subject(
            LocalMaskRaster(width: 2, height: 2, bytes: Data([255, 0, 0, 0]))), feather: 0))
        return AIObjectMaskResponse(layer: layer,
            sourceStamp: .init(device: 1, inode: 1, byteCount: 1, modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0),
            summary: "Ungefähre Kontur des Blumenstraußes.", preview: PreviewBitmap(image: try aiDevelopmentTestImage()))
    }

}

@MainActor private struct AIDevelopmentFixture {
    let directory: URL
    let library: LibraryModel
    let editor: EditingModel
    let workspace: DevelopWorkspace
    let store: AIDevelopmentTestStore
    let probe: AIDevelopmentTestProbe
    let model: AIDevelopmentModel
    var assetID: String { library.assets[0].id }
    func start() -> Task<Void, Never>? { model.start(library: library, editor: editor, workspace: workspace) }
    func remove() { model.discard(); workspace.clear(); try? FileManager.default.removeItem(at: directory) }

    static func make(latch: TestAsyncLatch = TestAsyncLatch(open: true),
                     adjustments: AIDevelopmentAdjustments = .init(exposure: 1),
                     proposeMask: AIDevelopmentModel.ProposeMask? = nil,
                     saveLatch: TestAsyncLatch = TestAsyncLatch(open: true),
                     saveEntered: TestAsyncLatch = TestAsyncLatch(),
                     backup: AIDevelopmentBackupSchedule? = nil,
                     validateSource: @escaping AIDevelopmentModel.ValidateSource = { _, _ in },
                     renderCorrection: @escaping AIDevelopmentModel.RenderCorrection = { bitmap, snapshot, settings, _ in
                         try await AdjustedPreviewPipeline.shared.image(bitmap,
                             request: PreviewRequest(source: snapshot.source, pixelSize: 128),
                             settings: settings, priority: .selected)
                     }) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-AIDevelopment-\(UUID())")
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: directory.appendingPathComponent("photo.png"))
        let repository = CatalogRepository(directory: directory.appendingPathComponent("catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: [asset]))
        let library = LibraryModel(repository: repository)
        let store = AIDevelopmentTestStore(assetID: asset.id, saveLatch: saveLatch, saveEntered: saveEntered)
        let adapter = LegacySnapshotTestAdapter(store)
        let database: any EditingPersistence = if let backup { AIDevelopmentBackupStore(base: adapter, schedule: backup) } else { adapter }
        let editor = EditingModel(database: database)
        try await waitForTestState("AI development fixture", state: { @MainActor in
            !library.isLoading && !library.isProjecting && !editor.isLoading
        }, until: { $0 })
        library.selectedID = asset.id; library.workspaceMode = .develop
        let workspace = DevelopWorkspace(analyze: { _ in
            DevelopPreviewAnalysis(width: 1, height: 1, pixels: [128, 128, 128, 255],
                channels: [[Int]](repeating: [Int](repeating: 0, count: 128), count: 3), shadows: 0, highlights: 0)
        })
        let snapshot = try #require(editor.aiSnapshot(in: library))
        workspace.bind(source: snapshot.source)
        let bitmap = PreviewBitmap(image: try aiDevelopmentTestImage())
        workspace.receive(bitmap, sourceBitmap: bitmap)
        let probe = AIDevelopmentTestProbe(latch: latch, adjustments: adjustments)
        let model = AIDevelopmentModel(propose: { snapshot, _, intent in try await probe.propose(snapshot, intent) },
                                     proposeMask: proposeMask ?? { snapshot, instruction in
                                         try await AIObjectMaskService().propose(snapshot: snapshot, instruction: instruction)
                                     }, validateSource: validateSource, renderCorrection: renderCorrection)
        return Self(directory: directory, library: library, editor: editor, workspace: workspace, store: store, probe: probe, model: model)
    }
}

private actor AICorrectionRenderProbe {
    private(set) var sources: [UUID] = []
    func record(_ source: UUID) { sources.append(source) }
}

private actor AIDevelopmentTestProbe {
    private(set) var calls = 0
    let latch: TestAsyncLatch
    let adjustments: AIDevelopmentAdjustments
    init(latch: TestAsyncLatch, adjustments: AIDevelopmentAdjustments) {
        self.latch = latch; self.adjustments = adjustments
    }
    func propose(_ snapshot: AIEditingSnapshot, _ intent: AIDevelopmentIntent) async throws -> AIDevelopmentResponse {
        calls += 1
        await latch.wait() // Deliberately ignores cancellation like native GPU work.
        return AIDevelopmentResponse(proposal: AIDevelopmentProposal(summary: "Das Bild behutsam aufhellen.", adjustments: adjustments),
            sourceStamp: .init(device: 1, inode: 1, byteCount: 1, modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0))
    }
}

private actor AIDevelopmentTestStore: LegacySnapshotTestStore {
    private var values: [String: EditSettings]
    private var versions: [String: Int64] = [:]
    let saveLatch: TestAsyncLatch
    let saveEntered: TestAsyncLatch
    init(assetID: String, saveLatch: TestAsyncLatch, saveEntered: TestAsyncLatch) {
        values = [assetID: .neutral]; self.saveLatch = saveLatch; self.saveEntered = saveEntered
    }
    func loadAll() -> [String: EditSettings] { values }
    func revisions() -> [String: Int64] { versions }
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) async {
        saveEntered.releaseAll(); await saveLatch.wait()
        values[assetID] = settings; versions[assetID] = revision
    }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/unused-ai-test-backup") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { values }
}

private struct AIDevelopmentBackupSchedule: Sendable {
    let start = TestAsyncLatch()
    let snapshotEntered = TestAsyncLatch(), snapshotRelease = TestAsyncLatch()
    let copyEntered = TestAsyncLatch(), copyRelease = TestAsyncLatch()
    let pruneEntered = TestAsyncLatch(), pruneRelease = TestAsyncLatch()
    let finished = TestAsyncLatch()
    func releaseAll() { start.releaseAll(); snapshotRelease.releaseAll(); copyRelease.releaseAll(); pruneRelease.releaseAll() }
}

/// The regular fixture keeps its existing persistence semantics. Only these
/// tests add the real editor callback boundary for snapshot and pruning.
private actor AIDevelopmentBackupStore: EditingPersistence {
    let base: LegacySnapshotTestAdapter
    let schedule: AIDevelopmentBackupSchedule
    init(base: LegacySnapshotTestAdapter, schedule: AIDevelopmentBackupSchedule) {
        self.base = base; self.schedule = schedule
    }
    func loadState() async throws -> EditingStoreState { try await base.loadState() }
    func saveSnapshot(_ snapshot: EditingSnapshot, for assetID: String, expected: EditingExpectedState, revision: Int64) async throws -> StoredEditingState {
        try await base.saveSnapshot(snapshot, for: assetID, expected: expected, revision: revision)
    }
    func createAutomaticBackup(maintenance: @escaping @Sendable (Bool) async throws -> Void) async throws -> URL {
        defer { schedule.finished.releaseAll() }
        await schedule.start.wait()
        do {
            try await maintenance(true)
            schedule.snapshotEntered.releaseAll(); await schedule.snapshotRelease.wait()
            try await maintenance(false)
            schedule.copyEntered.releaseAll(); await schedule.copyRelease.wait()
            try await maintenance(true)
            schedule.pruneEntered.releaseAll(); await schedule.pruneRelease.wait()
            try await maintenance(false)
            return try await base.createBackup(automatic: true)
        } catch { try? await maintenance(false); throw error }
    }
    func createBackup(automatic: Bool) async throws -> URL { try await base.createBackup(automatic: automatic) }
    func restoreBackup(from url: URL) async throws -> EditingStoreState { try await base.restoreBackup(from: url) }
    func commitGenerated(_ request: GenerationCommitRequest) async throws -> ArtifactCommitReceipt { try await base.commitGenerated(request) }
    func committed(_ id: EditingCommitID) async throws -> ArtifactCommitReceipt? { try await base.committed(id) }
    func variants(for assetID: String) async throws -> [EditingVariant] { try await base.variants(for: assetID) }
    func prepareAssetRemap(_ plan: VerifiedAssetRemap, preparingBy: CatalogParticipantPreparation) async throws -> PreparedAssetRemap {
        try await base.prepareAssetRemap(plan, preparingBy: preparingBy)
    }
    func inspectAssetRemap(_ id: EditingRemapID, expectedRequestSHA256: ArtifactDigest) async throws -> AssetRemapInspection? {
        try await base.inspectAssetRemap(id, expectedRequestSHA256: expectedRequestSHA256)
    }
    func remapAssets(_ prepared: PreparedAssetRemap, armedBy: ArmedCatalogCoordination) async throws -> AssetRemapReceipt {
        try await base.remapAssets(prepared, armedBy: armedBy)
    }
    func confirmCatalogRemap(_ prepared: PreparedAssetRemap, publication: CatalogPublicationEvidence) async throws {
        try await base.confirmCatalogRemap(prepared, publication: publication)
    }
    func completeAssetRemap(_ prepared: PreparedAssetRemap, publication: CatalogPublicationEvidence) async throws -> AssetRemapReceipt {
        try await base.completeAssetRemap(prepared, publication: publication)
    }
    func cancelPreparedAssetRemap(_ prepared: PreparedAssetRemap, abortedBy: CatalogCoordinationAbort) async throws {
        try await base.cancelPreparedAssetRemap(prepared, abortedBy: abortedBy)
    }
}

func aiDevelopmentTestImage() throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: 128, height: 96, bitsPerComponent: 8, bytesPerRow: 128 * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
    context.setFillColor(CGColor(red: 0.7, green: 0.2, blue: 0.1, alpha: 1)); context.fillEllipse(in: CGRect(x: 32, y: 24, width: 64, height: 48))
    return try #require(context.makeImage())
}

@Suite("Qwen native product route")
struct QwenNativeModelTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_QWEN_MODEL_PATH"] != nil), .timeLimit(.minutes(3)))
    func installedLocalModelProducesValidatedDevelopmentJSON() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["GLOWROOM_QWEN_MODEL_PATH"])
        var intent = AIDevelopmentIntent(); intent.brightness = 0.6; intent.instruction = "Helle das Bild behutsam auf."
        let budget = AIResourceBudget.shared
        let lease = try await budget.acquireLocalInference(residentBytes: 5 * 1_024 * 1_024 * 1_024)
        let data: Data
        do {
            data = try await QwenDevelopmentBackend().propose(modelDirectory: URL(fileURLWithPath: path),
                image: aiDevelopmentTestImage(), prompt: intent.prompt(settings: .neutral), schema: AIDevelopmentProposal.schema)
            await budget.release(lease)
        } catch { await budget.release(lease); throw error }
        let response = try AIDevelopmentProposal.decode(data)
        #expect(!response.summary.isEmpty)
        print("Qwen product smoke: \(String(decoding: data, as: UTF8.self))")
    }
}
