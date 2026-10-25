import AppKit
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
import GlowroomCore
@testable import Glowroom

@Suite("MCP running catalog access and review", .timeLimit(.minutes(2)))
@MainActor
struct LocalMCPControllerTests {
    @Test func accessStartsOffAndCatalogRebindingRevokesEveryOldIdentifier() async throws {
        let controller = LocalMCPController()
        #expect(!controller.isEnabled && controller.connectionPath == nil)
        #expect(try payload(await controller.handle(tool: "session_inspect", arguments: .object([:] )))["code"].string == "access_denied")
        controller.enable(previews: true)
        #expect(!controller.isEnabled && controller.connectionPath == nil)
        let f = try await MCPControllerFixture.make(); defer { f.remove() }
        f.controller.enable(previews: false)
        let oldPath = try #require(f.controller.connectionPath)
        let photo = try await f.firstPhoto()
        f.controller.bind(library: f.library, editor: f.editor, workspace: f.workspace,
            directory: f.directory.appendingPathComponent("another-catalog"), reveal: {})
        #expect(!f.controller.isEnabled && !FileManager.default.fileExists(atPath: oldPath))
        f.controller.enable(previews: false)
        let response = await f.controller.handle(tool: "snapshot_get", arguments: .object(["photo_id": .string(photo)]))
        #expect(try payload(response)["code"].string == "unknown_photo")
        f.controller.revoke()
        #expect(try payload(await f.controller.handle(tool: "photos_query", arguments: .object([:])))["code"].string == "access_denied")
        #expect(await f.editor.finishSaving())
    }

    @Test func readsPreserveSelectionAndHistoryAndImageConsentIsSeparate() async throws {
        let f = try await MCPControllerFixture.make(); defer { f.remove() }
        let baseline = f.editor.snapshot(for: f.assets[0].id), selected = f.library.selectedID
        f.controller.enable(previews: false)
        let photo = try await f.firstPhoto(), snapshot = try await f.capture(photo)
        let values = try payload(await f.controller.handle(tool: "controls_list", arguments: .object([:])))
        guard case .array(let controls) = values else { Issue.record("Missing controls"); return }
        #expect(controls.count == EditParameter.allCases.count)
        let denied = await f.controller.handle(tool: "preview_render", arguments: .object(["photo_id": .string(photo), "snapshot_id": .string(snapshot)]))
        #expect(try payload(denied)["code"].string == "image_access_denied")
        #expect(f.library.selectedID == selected && f.editor.snapshot(for: f.assets[0].id) == baseline)
        #expect(f.editor.localRevision(for: f.assets[0].id) == 0 && !f.editor.canUndo(assetID: f.assets[0].id))
        f.controller.enable(previews: true)
        let sharedPhoto = try await f.firstPhoto(), sharedSnapshot = try await f.capture(sharedPhoto)
        let result = await f.controller.handle(tool: "preview_render", arguments: .object(["photo_id": .string(sharedPhoto), "snapshot_id": .string(sharedSnapshot), "maximum_size": .number(64)]))
        #expect(result["isError"] == .bool(false))
        guard case .array(let content) = result["content"] else { Issue.record("Missing image"); return }
        let data = try #require(content.first?["data"].string.flatMap { Data(base64Encoded: $0) })
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) <= 64 && image.colorSpace != nil)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let original = try #require(CGImageSourceCreateWithURL(f.assets[0].fileURL as CFURL, nil))
        let originalProperties = CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any]
        let originalExif = originalProperties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(originalExif?[kCGImagePropertyExifUserComment] as? String == "private-source-exif-sentinel")
        #expect((originalProperties?[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSLatitude] as? Double == 48.125)
        // ImageIO synthesizes ColorSpace and pixel dimensions when encoding PNG.
        // These describe the output raster; camera/location/source fields must
        // not survive even when deliberately present in the synthetic original.
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let allowed: Set<CFString> = [kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension]
        #expect(Set(exif.keys).isSubset(of: allowed))
        #expect((properties?[kCGImagePropertyGPSDictionary] as? [CFString: Any])?.isEmpty != false)
        #expect(!String(describing: properties).contains("private-source-exif-sentinel"))
        f.controller.revokePreviews()
        #expect(f.controller.isEnabled && !f.controller.sharesPreviews)
        #expect(f.library.selectedID == selected && f.editor.snapshot(for: f.assets[0].id) == baseline)
        #expect(await f.editor.finishSaving())
    }

    @Test func inactiveStaleAndUnknownRequestsCannotCreateAProposal() async throws {
        let f = try await MCPControllerFixture.make(); defer { f.remove() }
        f.controller.enable(previews: false)
        let photos = try await f.photos(), inactive = try #require(photos.last?["photo_id"].string)
        let inactiveSnapshot = try await f.capture(inactive)
        let inactiveResult = await f.controller.handle(tool: "proposal_create", arguments: f.proposalArguments(photo: inactive, snapshot: inactiveSnapshot))
        #expect(try payload(inactiveResult)["code"].string == "inactive_target")
        let photo = try #require(photos.first?["photo_id"].string), snapshot = try await f.capture(photo)
        f.library.selectedID = f.assets[1].id; f.library.selectedID = f.assets[0].id
        let stale = await f.controller.handle(tool: "proposal_create", arguments: f.proposalArguments(photo: photo, snapshot: snapshot))
        #expect(try payload(stale)["code"].string == "conflict")
        let fresh = try await f.capture(photo)
        var invalid = f.proposalArguments(photo: photo, snapshot: fresh).object!
        invalid["values"] = .object(["temperature": .number(6500)])
        #expect(try payload(await f.controller.handle(tool: "proposal_create", arguments: .object(invalid)))["code"].string == "invalid_arguments")
        #expect(try payload(await f.controller.handle(tool: "snapshot_get", arguments: .object(["photo_id": .string("foreign")])))["code"].string == "unknown_photo")
        #expect(f.controller.correction.proposal == nil && !f.editor.canUndo(assetID: f.assets[0].id))
        #expect(await f.editor.finishSaving())
    }

    @Test func externalProposalStaysTransientThenAcceptsExactlyOnceAndReportsItsOutcome() async throws {
        let f = try await MCPControllerFixture.make(); defer { f.remove() }
        f.controller.enable(previews: false)
        let photo = try await f.firstPhoto(), snapshot = try await f.capture(photo)
        let args = f.proposalArguments(photo: photo, snapshot: snapshot)
        let baseline = f.editor.snapshot(for: f.assets[0].id)
        let created = try payload(await f.controller.handle(tool: "proposal_create", arguments: args))
        #expect(created["state"].string == "ready" && f.controller.correction.canApplyProposal)
        #expect(f.editor.snapshot(for: f.assets[0].id) == baseline && f.editor.localRevision(for: f.assets[0].id) == 0)
        let preview = try #require(f.workspace.aiCorrectionPreview)
        #expect(try payload(await f.controller.handle(tool: "proposal_create", arguments: args))["state"].string == "ready")
        #expect(f.workspace.aiCorrectionPreview?.bitmap.rangeSourceIdentity == preview.bitmap.rangeSourceIdentity)
        await (try #require(f.controller.correction.apply(library: f.library, editor: f.editor))).value
        #expect(f.editor.settings(for: f.assets[0].id).exposure == 1)
        #expect(try payload(await f.controller.handle(tool: "proposal_get", arguments: .object(["request_id": .string("request-1")])))["state"].string == "accepted")
        #expect(f.editor.localRevision(for: f.assets[0].id) == 1)
        f.editor.undo(assetID: f.assets[0].id)
        #expect(f.editor.snapshot(for: f.assets[0].id) == baseline && !f.editor.canUndo(assetID: f.assets[0].id))
        #expect(await f.editor.finishSaving())
    }

    @Test func rejectedNativeSourceDuringVisibleAcceptanceReportsFailedWithoutAnEdit() async throws {
        let validation = MCPSourceValidationGate()
        let f = try await MCPControllerFixture.make(validateSource: { _, _ in try await validation.check() })
        defer { f.remove() }
        f.controller.enable(previews: false)
        let photo = try await f.firstPhoto(), snapshot = try await f.capture(photo)
        #expect(try payload(await f.controller.handle(tool: "proposal_create", arguments: f.proposalArguments(photo: photo, snapshot: snapshot)))["state"].string == "ready")
        let baseline = f.editor.snapshot(for: f.assets[0].id), revision = f.editor.localRevision(for: f.assets[0].id)
        let host = WorkspaceSectionTestHost(size: NSSize(width: 420, height: 1100))
        defer { host.close() }
        try await host.mount(AIDevelopmentView(library: f.library, model: f.controller.correction)
            .environmentObject(f.editor).environmentObject(f.workspace).frame(width: 380))
        await validation.rejectFurtherChecks()
        let apply = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "ai-development.apply" })
        try #require(apply.isAccessibilityEnabled() && apply.accessibilityPerformPress())
        try await waitForTestState("external source validation rejected", state: { @MainActor in
            f.controller.correction.proposal == nil && !f.controller.correction.isRunning
        }, until: { $0 })
        let outcome = try payload(await f.controller.handle(tool: "proposal_get", arguments: .object(["request_id": .string("request-1")])))
        #expect(outcome["state"].string == "failed")
        #expect(f.controller.correction.lastExternalResult?.state == "failed" && !f.controller.correction.canApplyProposal)
        #expect(f.editor.snapshot(for: f.assets[0].id) == baseline && f.editor.localRevision(for: f.assets[0].id) == revision)
        #expect(!f.editor.canUndo(assetID: f.assets[0].id) && !f.editor.hasPendingChanges)
        #expect(await f.editor.finishSaving())
        try await host.unmount()
    }

    @Test(arguments: ["workspace", "tool", "comparison"])
    func workspaceAndToolRoundTripsInvalidateCapturedAndPreparedProposals(change: String) async throws {
        let f = try await MCPControllerFixture.make(); defer { f.remove() }
        f.controller.enable(previews: false)
        let photo = try await f.firstPhoto(), old = try await f.capture(photo)
        func roundTrip() {
            switch change {
            case "workspace": f.library.workspaceMode = .library; f.library.workspaceMode = .develop
            case "tool": f.workspace.tool = .crop; f.workspace.tool = .basic
            default: f.library.comparesOriginal = true; f.library.comparesOriginal = false
            }
        }
        roundTrip()
        #expect(try payload(await f.controller.handle(tool: "proposal_create", arguments: f.proposalArguments(photo: photo, snapshot: old)))["code"].string == "conflict")
        let fresh = try await f.capture(photo)
        #expect(try payload(await f.controller.handle(tool: "proposal_create", arguments: f.proposalArguments(photo: photo, snapshot: fresh)))["state"].string == "ready")
        roundTrip()
        #expect(f.controller.correction.proposal == nil && !f.controller.correction.canApplyProposal)
        #expect(try payload(await f.controller.handle(tool: "proposal_get", arguments: .object(["request_id": .string("request-1")])))["state"].string == "discarded")
        #expect(f.editor.localRevision(for: f.assets[0].id) == 0 && !f.editor.canUndo(assetID: f.assets[0].id))
        #expect(await f.editor.finishSaving())
    }

    @Test func remoteDiscardAndRevocationNeverCancelASubsequentLocalDraft() async throws {
        let f = try await MCPControllerFixture.make(); defer { f.remove() }
        f.controller.enable(previews: false)
        let photo = try await f.firstPhoto(), snapshot = try await f.capture(photo)
        #expect(try payload(await f.controller.handle(tool: "proposal_create", arguments: f.proposalArguments(photo: photo, snapshot: snapshot)))["state"].string == "ready")
        await (try #require(f.controller.correction.apply(library: f.library, editor: f.editor))).value
        #expect(await f.editor.finishSaving())
        await (try #require(f.controller.correction.start(library: f.library, editor: f.editor, workspace: f.workspace))).value
        let localDraft = try #require(f.controller.correction.proposal)
        #expect(f.controller.correction.externalRequestID == nil)
        let result = try payload(await f.controller.handle(tool: "proposal_discard", arguments: .object(["request_id": .string("request-1")])))
        #expect(result["state"].string == "accepted" && f.controller.correction.proposal == localDraft)
        f.controller.revokePreviews()
        #expect(f.controller.correction.proposal == localDraft)
        f.controller.revoke()
        #expect(f.controller.correction.proposal == localDraft)
        f.controller.correction.discard()
        #expect(await f.editor.finishSaving())
    }

    private func payload(_ response: MCPJSON) throws -> MCPJSON { try mcpPayload(response) }
}

private func mcpPayload(_ response: MCPJSON) throws -> MCPJSON {
    guard case .array(let content) = response["content"], let text = content.first?["text"].string else { throw MCPFailure("test", "Expected text tool result.") }
    return try MCPContract.decodeMessage(Data(text.utf8))
}

@MainActor private struct MCPControllerFixture {
    let directory: URL
    let library: LibraryModel
    let editor: EditingModel
    let workspace: DevelopWorkspace
    let masks: InlineMaskWorkspace
    let controller: LocalMCPController
    let assets: [PhotoAsset]
    func remove() {
        controller.revoke(); controller.correction.discard(); workspace.clear()
        try? FileManager.default.removeItem(at: directory)
    }
    func photos() async throws -> [MCPJSON] {
        let response = await controller.handle(tool: "photos_query", arguments: .object([:]))
        let text = try mcpPayload(response)
        guard case .array(let photos) = text["photos"] else { throw MCPFailure("test", "No photos: \(text)") }
        #expect(!String(data: try JSONEncoder().encode(text), encoding: .utf8)!.contains(directory.path))
        return photos
    }
    func firstPhoto() async throws -> String {
        let values = try await photos()
        return try #require(values.first?["photo_id"].string)
    }
    func capture(_ photo: String) async throws -> String {
        let result = try mcpPayload(await controller.handle(tool: "snapshot_get", arguments: .object(["photo_id": .string(photo)])))
        return try #require(result["snapshot_id"].string, "Snapshot capture failed: \(result)")
    }
    func proposalArguments(photo: String, snapshot: String) -> MCPJSON {
        .object(["photo_id": .string(photo), "snapshot_id": .string(snapshot), "request_id": .string("request-1"), "values": .object(["exposure": .number(1)])])
    }
    static func make(validateSource: AIDevelopmentModel.ValidateSource? = nil) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-MCP-Controller-\(UUID())")
        let images = directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let folder = LibraryFolder(url: images)
        let assets = try ["A", "B"].map { name -> PhotoAsset in
            let url = images.appendingPathComponent(name + ".png")
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(colorSpace: space, components: [0.3, 0.45, 0.6, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            let metadata: [CFString: Any] = [
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private-source-exif-sentinel"],
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.125, kCGImagePropertyGPSLatitudeRef: "N",
                    kCGImagePropertyGPSLongitude: 16.375, kCGImagePropertyGPSLongitudeRef: "E"]
            ]
            CGImageDestinationAddImage(destination, context.makeImage()!, metadata as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw PreviewFailure.unavailable }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return PhotoAsset(folderID: folder.id, fileURL: url, fileSize: (attributes[.size] as! NSNumber).int64Value,
                pixelWidth: 64, pixelHeight: 48, modifiedAt: attributes[.modificationDate] as! Date)
        }
        let repository = CatalogRepository(directory: directory.appendingPathComponent("catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: assets))
        let library = LibraryModel(repository: repository), editor = EditingModel(directory: directory.appendingPathComponent("edits"))
        editor.library = library
        try await waitForTestState("MCP controller fixture", state: { @MainActor in !library.isLoading && !library.isProjecting && !editor.isLoading }, until: { $0 })
        library.selectedID = assets[0].id; library.workspaceMode = .develop
        let workspace = DevelopWorkspace(), masks = InlineMaskWorkspace()
        editor.developCommands.bind(workspace: workspace, masks: masks)
        let snapshot = try #require(editor.aiSnapshot(in: library))
        let request = PreviewRequest(source: snapshot.source, pixelSize: 128, allowsEmbeddedPreview: false)
        let bitmap = try await ImagePreviewPipeline.shared.image(for: request, priority: .selected)
        let stamp = try await PreviewSourceStamp.capture(for: request)
        workspace.bind(source: snapshot.source); workspace.receive(bitmap, sourceBitmap: bitmap, sourceStamp: stamp)
        let propose: AIDevelopmentModel.Propose = { snapshot, _, _ in
            let stamp = try await ImageAnalysisPreparer().sourceStamp(for: .init(snapshot: snapshot, inputKind: .editedPreview, lifecycleID: UUID()))
            return AIDevelopmentResponse(proposal: .init(summary: "Lokale Testkorrektur", adjustments: .init(exposure: 0.5)), sourceStamp: stamp)
        }
        let correction: AIDevelopmentModel
        if let validateSource { correction = AIDevelopmentModel(propose: propose, validateSource: validateSource) }
        else { correction = AIDevelopmentModel(propose: propose) }
        let controller = LocalMCPController(correction: correction)
        controller.bind(library: library, editor: editor, workspace: workspace, directory: repository.directory, reveal: {})
        return Self(directory: directory, library: library, editor: editor, workspace: workspace, masks: masks, controller: controller, assets: assets)
    }
}

private actor MCPSourceValidationGate {
    private var rejectsChecks = false
    func rejectFurtherChecks() { rejectsChecks = true }
    func check() throws {
        if rejectsChecks { throw AIDevelopmentError.staleContext }
    }
}
