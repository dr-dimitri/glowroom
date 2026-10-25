import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import GlowroomCore

/// Sharing is deliberately session-local. No preference silently reopens it on
/// restart or for another catalog. The app remains the only catalog owner.
@MainActor
final class LocalMCPController: ObservableObject {
    static let shared = LocalMCPController()
    let correction: AIDevelopmentModel
    @Published var showsSettings = false
    @Published private(set) var isEnabled = false
    @Published private(set) var sharesPreviews = false
    @Published private(set) var connectionPath: String?
    @Published private(set) var status: String?
    private var server: MCPLocalServer?
    private weak var library: LibraryModel?
    private weak var editor: EditingModel?
    private weak var workspace: DevelopWorkspace?
    private var directory: URL?
    private var reveal: (() -> Void)?
    private var session = UUID()
    private var workspaceGeneration = UUID()
    private var workspaceSubscriptions: Set<AnyCancellable> = []
    private var photoIDs: [String: String] = [:]
    private var reverseIDs: [String: String] = [:]
    private struct Capture {
        let snapshot: AIEditingSnapshot
        let stamp: ImageAnalysisSourceStamp
        let workspaceGeneration: UUID
    }
    private var captures: [String: Capture] = [:]
    private var captureRetainedBytes = 0
    private struct ProposalRecord {
        let id: String
        let arguments: MCPJSON
        var state: String
    }
    private var proposal: ProposalRecord?
    private var retired = Set<String>()
    private var busy = false
    private var closing: AnyCancellable?

    init(correction: AIDevelopmentModel? = nil) { self.correction = correction ?? AIDevelopmentModel() }

    func bind(library: LibraryModel, editor: EditingModel, workspace: DevelopWorkspace,
              directory: URL, reveal: @escaping () -> Void) {
        if self.directory != directory || self.library !== library || self.workspace !== workspace { revoke() }
        self.library = library; self.editor = editor; self.workspace = workspace
        self.directory = directory; self.reveal = reveal
        closing = library.$isClosing.sink { [weak self] closes in if closes { self?.revoke() } }
        workspaceSubscriptions.removeAll()
        // @Published emits before assignment. Compare against the old value so
        // harmless repeated reveal calls do not revoke the same context, while
        // Develop→Library→Develop and tool ABA always rotate an opaque epoch.
        library.$workspaceMode.dropFirst().sink { [weak self, weak library] mode in
            if mode != library?.workspaceMode { self?.advanceWorkspaceGeneration() }
        }.store(in: &workspaceSubscriptions)
        workspace.$tool.dropFirst().sink { [weak self, weak workspace] tool in
            if tool != workspace?.tool { self?.advanceWorkspaceGeneration() }
        }.store(in: &workspaceSubscriptions)
        library.$comparesOriginal.dropFirst().sink { [weak self, weak library] comparing in
            if comparing != library?.comparesOriginal { self?.advanceWorkspaceGeneration() }
        }.store(in: &workspaceSubscriptions)
        library.$comparesCurrentSourceWithoutSettings.dropFirst().sink { [weak self, weak library] comparing in
            if comparing != library?.comparesCurrentSourceWithoutSettings { self?.advanceWorkspaceGeneration() }
        }.store(in: &workspaceSubscriptions)
    }

    var catalogName: String { directory?.lastPathComponent ?? "Keine Bibliothek" }

    private func advanceWorkspaceGeneration() {
        workspaceGeneration = UUID()
        if let proposal, correction.externalRequestID == proposal.id {
            correction.discard(); self.proposal?.state = "discarded"
        }
    }

    func enable(previews: Bool) {
        revoke()
        guard library?.canModify == true, editor?.canEdit == true else { status = "Die Bibliothek ist gerade nicht verfügbar."; return }
        session = UUID()
        do {
            server = try MCPLocalServer { [weak self] tool, arguments in
                await self?.handle(tool: tool, arguments: arguments) ?? MCPContract.textResult(MCPFailure("access_denied", "Sharing ended.").json, isError: true)
            }
            connectionPath = server?.connectionURL.path
            sharesPreviews = previews; isEnabled = true
            status = "Lokaler Zugang aktiv. Änderungen benötigen weiterhin Übernehmen in Glowroom."
        } catch { status = "Der lokale Zugang konnte nicht gestartet werden." }
    }

    func revoke() {
        isEnabled = false; sharesPreviews = false; session = UUID(); workspaceGeneration = UUID()
        server?.stop(); server = nil; connectionPath = nil
        if let proposal, correction.externalRequestID == proposal.id { correction.discard() }
        proposal = nil; retired = []; captures = [:]; captureRetainedBytes = 0; photoIDs = [:]; reverseIDs = [:]
        status = nil
    }

    func revokePreviews() {
        sharesPreviews = false
        if let proposal, correction.externalRequestID == proposal.id { correction.discard(); self.proposal?.state = "discarded" }
    }

    private func opaqueID(_ assetID: String) throws -> String {
        if let existing = reverseIDs[assetID] { return existing }
        guard photoIDs.count < 4_096 else { throw MCPFailure("limit", "Session photo limit reached. End sharing and start a new session.") }
        let id = UUID().uuidString
        photoIDs[id] = assetID; reverseIDs[assetID] = id
        return id
    }

    private func asset(_ id: String, library: LibraryModel) throws -> PhotoAsset {
        guard let assetID = photoIDs[id], let asset = library.assets.first(where: { $0.id == assetID }) else { throw MCPFailure("unknown_photo", "Photo is not shared in this session.") }
        return asset
    }

    private func currentSnapshot(_ asset: PhotoAsset, library: LibraryModel, editor: EditingModel) throws -> AIEditingSnapshot {
        guard editor.canRetainLocalEditingAnchor, library.canModify else { throw MCPFailure("unavailable", "Catalog is unavailable.") }
        let source = try editor.resolvedSource(for: asset)
        return AIEditingSnapshot(assetID: asset.id, source: source.identity, settings: source.settings,
            token: AIEditingToken(editSessionID: editor.aiEditSessionID, editGeneration: editor.aiEditGeneration,
                selectionSessionID: library.aiSelectionSessionID, selectionGeneration: library.aiSelectionGeneration),
            persistedVersion: editor.persistedState(for: asset.id))
    }

    private func matching(_ capture: Capture, asset: PhotoAsset, library: LibraryModel, editor: EditingModel) throws {
        let current = try currentSnapshot(asset, library: library, editor: editor)
        guard current == capture.snapshot, workspaceGeneration == capture.workspaceGeneration else {
            throw MCPFailure("conflict", "Source, selection, workspace or editing snapshot changed.")
        }
    }

    private func sourceStamp(_ snapshot: AIEditingSnapshot) async throws -> ImageAnalysisSourceStamp {
        try await Task.detached(priority: .userInitiated) {
            try await ImageAnalysisPreparer().sourceStamp(for: .init(snapshot: snapshot, inputKind: .editedPreview, lifecycleID: UUID()))
        }.value
    }

    func handle(tool: String, arguments: MCPJSON) async -> MCPJSON {
        do {
            let args = try MCPContract.validate(tool: tool, arguments: arguments)
            guard isEnabled, let library, let editor, let workspace, !library.isClosing else { throw MCPFailure("access_denied", "Activate sharing in Glowroom first.") }
            let generation = session
            func checkSession() throws {
                guard isEnabled, session == generation, !library.isClosing else { throw MCPFailure("access_denied", "Session access was revoked.") }
            }
            if tool == "session_inspect" {
                let selected = try library.selectedID.map { try opaqueID($0) }
                return MCPContract.textResult(.object(["session_id": .string(session.uuidString), "catalog": .string(catalogName),
                    "photo_count": .number(Double(library.assets.count)), "selected_photo_id": selected.map(MCPJSON.string) ?? .null,
                    "workspace": .string(library.isDeveloping ? "develop" : "library"), "workspace_token": .string(workspaceGeneration.uuidString), "image_access": .bool(sharesPreviews)]))
            }
            if tool == "controls_list" { return MCPContract.textResult(try .encoded(EditParameter.allCases.map(DevelopControlDescriptor.init))) }
            if tool == "photos_query" {
                let offset = Int(args["offset"]?.number ?? 0), limit = Int(args["limit"]?.number ?? 100)
                let assets = library.assets
                let rows = try assets.dropFirst(min(offset, assets.count)).prefix(limit).map { asset in
                    MCPJSON.object(["photo_id": .string(try opaqueID(asset.id)), "name": .string(asset.fileName), "rating": .number(Double(asset.rating)), "favorite": .bool(asset.isFavorite)])
                }
                return MCPContract.textResult(.object(["photos": .array(rows), "next_offset": offset + rows.count < assets.count ? .number(Double(offset + rows.count)) : .null]))
            }
            if tool == "proposal_get" || tool == "proposal_discard" {
                let id = args["request_id"]!.string!
                guard var record = proposal, record.id == id else { throw MCPFailure("outcome_unknown", "Request is unknown. Do not retry it as a new write.") }
                if record.state == "ready", correction.proposal == nil || correction.externalRequestID != id {
                    record.state = correction.lastExternalResult?.id == id ? (correction.lastExternalResult?.state ?? "outcome_unknown") : "outcome_unknown"; proposal = record
                }
                if tool == "proposal_discard", record.state == "ready" || record.state == "preparing" {
                    if correction.externalRequestID == id { correction.discard() }
                    record.state = "discarded"; proposal = record
                }
                return MCPContract.textResult(.object(["request_id": .string(id), "state": .string(record.state), "requires_user_acceptance": .bool(true)]))
            }
            guard !busy else { throw MCPFailure("busy", "A preview is already being prepared.") }
            busy = true; defer { busy = false }
            let asset = try asset(args["photo_id"]!.string!, library: library)
            if tool == "snapshot_get" {
                let snapshot = try currentSnapshot(asset, library: library, editor: editor)
                let capturedWorkspace = workspaceGeneration
                let stamp = try await sourceStamp(snapshot)
                try checkSession()
                let capture = Capture(snapshot: snapshot, stamp: stamp, workspaceGeneration: capturedWorkspace)
                try matching(capture, asset: asset, library: library, editor: editor)
                let id: String
                if let existing = captures.first(where: { $0.value.snapshot == snapshot && $0.value.stamp == stamp && $0.value.workspaceGeneration == capturedWorkspace }) { id = existing.key }
                else {
                    let retainedBytes = DevelopCommandDispatcher.retentionCost(snapshot.settings)
                        + (snapshot.persistedVersion?.snapshot.map { DevelopCommandDispatcher.retentionCost($0.settings) } ?? 0)
                    guard captures.count < 128, retainedBytes <= 64 * 1_024 * 1_024 - captureRetainedBytes else {
                        throw MCPFailure("limit", "Snapshot count or memory budget reached; start a new sharing session.")
                    }
                    id = UUID().uuidString; captures[id] = capture; captureRetainedBytes += retainedBytes
                }
                let controls = Dictionary(uniqueKeysWithValues: EditParameter.allCases.map { ($0.rawValue, MCPJSON.number($0.value(in: snapshot.settings))) })
                return MCPContract.textResult(.object(["snapshot_id": .string(id), "photo_id": args["photo_id"]!, "controls": .object(controls), "source": .string({ if case .original = snapshot.source { "original" } else { "artifact" } }())]))
            }
            guard let capture = captures[args["snapshot_id"]!.string!] else { throw MCPFailure("conflict", "Unknown snapshot for this session.") }
            guard capture.snapshot.assetID == asset.id else { throw MCPFailure("conflict", "Snapshot belongs to another photo.") }
            try matching(capture, asset: asset, library: library, editor: editor)
            if tool == "proposal_create" {
                guard library.isDeveloping, library.selectedID == asset.id else { throw MCPFailure("inactive_target", "Only the active Develop photo can receive a proposal.") }
                let id = args["request_id"]!.string!
                if let record = proposal, record.id == id {
                    guard record.arguments == arguments else { throw MCPFailure("request_conflict", "Request ID already belongs to a different proposal.") }
                    return MCPContract.textResult(.object(["request_id": .string(id), "state": .string(record.state)]))
                }
                guard !retired.contains(id) else { throw MCPFailure("outcome_unknown", "Retired request. It will not run again.") }
                guard try await sourceStamp(capture.snapshot) == capture.stamp else { throw MCPFailure("conflict", "Native source changed since the captured snapshot.") }
                try checkSession(); try matching(capture, asset: asset, library: library, editor: editor)
                guard retired.count < 256 else { throw MCPFailure("limit", "Request limit reached; start a new sharing session.") }
                if let existing = proposal {
                    guard existing.state != "preparing", existing.state != "ready" || correction.proposal == nil else { throw MCPFailure("busy", "Review or discard the active proposal first.") }
                    retired.insert(existing.id)
                }
                proposal = ProposalRecord(id: id, arguments: arguments, state: "preparing")
                do {
                    reveal?()
                    try await correction.prepareExternal(snapshot: capture.snapshot, patch: MCPContract.patch(args["values"]!), requestID: id, library: library, editor: editor, workspace: workspace)
                    try checkSession()
                    guard proposal?.id == id, proposal?.state == "preparing",
                          correction.externalRequestID == id, correction.canApplyProposal else {
                        if correction.externalRequestID == id { correction.discard() }
                        throw MCPFailure("cancelled", "Proposal was discarded.")
                    }
                    proposal?.state = "ready"
                    return MCPContract.textResult(.object(["request_id": .string(id), "state": .string("ready"), "requires_user_acceptance": .bool(true)]))
                } catch { if proposal?.id == id { proposal?.state = "failed" }; throw error }
            }
            guard tool == "preview_render", sharesPreviews else { throw MCPFailure("image_access_denied", "Grant image preview access in Glowroom separately.") }
            let size = Int(args["maximum_size"]?.number ?? 2048)
            let stamp = try await sourceStamp(capture.snapshot)
            guard stamp == capture.stamp else { throw MCPFailure("conflict", "Native source changed.") }
            let snapshot = capture.snapshot
            let renderSettings: EditSettings
            if let requestID = args["request_id"]?.string {
                guard proposal?.id == requestID, proposal?.state == "ready",
                      correction.externalRequestID == requestID, let review = correction.proposal,
                      correction.canApplyProposal else { throw MCPFailure("conflict", "The proposal is no longer available.") }
                renderSettings = review.settings
            } else { renderSettings = snapshot.settings }
            let request = PreviewRequest(source: snapshot.source, pixelSize: size, allowsEmbeddedPreview: false, sourceRevision: stamp.cacheRevision, allowsHDR: snapshot.settings.developColor.hdrEnabled)
            let rendered: PreviewBitmap
            if library.selectedID == asset.id, workspace.sourceIdentity == snapshot.source,
               workspace.originalSourceStamp == stamp, let bitmap = workspace.originalBitmap {
                rendered = try await AdjustedPreviewPipeline.shared.image(bitmap, request: request, settings: renderSettings, priority: .selected, maximumOutputPixelSize: size)
            } else {
                let bitmap = try await ImagePreviewPipeline.shared.image(for: request, priority: .selected)
                rendered = try await AdjustedPreviewPipeline.shared.image(bitmap, request: request, settings: renderSettings, priority: .selected, maximumOutputPixelSize: size)
            }
            let png = try await Task.detached(priority: .userInitiated) { try Self.png(rendered) }.value
            guard try await sourceStamp(snapshot) == stamp else { throw MCPFailure("conflict", "Native source changed during rendering.") }
            try checkSession(); try matching(capture, asset: asset, library: library, editor: editor)
            guard sharesPreviews else { throw MCPFailure("image_access_denied", "Image access was revoked.") }
            return .object(["content": .array([.object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(png.base64EncodedString())])]), "isError": .bool(false)])
        } catch {
            let failure = error as? MCPFailure ?? MCPFailure("conflict", "The image or editing context is unavailable or changed. Capture a new snapshot.")
            return MCPContract.textResult(failure.json, isError: true)
        }
    }

    nonisolated private static func png(_ bitmap: PreviewBitmap) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw PreviewFailure.unavailable }
        // ImageIO writes the CGImage's color profile. No source EXIF/GPS is copied.
        CGImageDestinationAddImage(destination, bitmap.image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length < 11 * 1_024 * 1_024 else { throw MCPFailure("message_too_large", "Preview exceeds the response limit; request a smaller size.") }
        return data as Data
    }
}

struct LocalMCPSettingsView: View {
    @ObservedObject var model: LocalMCPController
    @ViewState private var previews = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lokaler MCP-Zugang").font(.title2)
            Text("Bibliothek: \(model.catalogName)").font(.headline)
            Text("Verbundene Clients können Fotos, Auswahl und Regler abfragen und Korrekturen zur sichtbaren Prüfung vorbereiten. Übernehmen erfolgt in Glowroom.")
            Text("Ein externer Client kann empfangene Daten und freigegebene Bildvorschauen an seinen Anbieter senden.")
            if model.isEnabled {
                Text(model.sharesPreviews ? "Bildvorschauen freigegeben" : "Bildvorschauen gesperrt")
                if model.sharesPreviews { Button("Bildfreigabe widerrufen") { model.revokePreviews() } }
                if let path = model.connectionPath {
                    Button("Verbindungspfad kopieren") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
                }
                Button("Zugang beenden") { model.revoke() }
            } else {
                Toggle("Auch Bildvorschauen freigeben", isOn: $previews)
                Button("Zugang für diese Sitzung aktivieren") { model.enable(previews: previews) }.buttonStyle(.borderedProminent)
            }
            if let status = model.status { Text(status).textSelection(.enabled) }
            HStack { Spacer(); Button("Schließen") { model.showsSettings = false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 540).fixedSize(horizontal: false, vertical: true)
    }
}
