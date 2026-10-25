import AppKit
import SwiftUI
import GlowroomCore

/// Viewing uses the existing bounded decode/render lanes. No accepted editor
/// snapshot, preview sink, history or export state is changed by these views.
struct FrozenVariantPreview: View {
    let state: VariantViewingState
    var body: some View {
        VariantSnapshotImage(source: state.source, expectedStamp: state.sourceStamp,
            identity: state.variant.id.canonicalString, pixelSize: 2400, priority: .selected)
            .accessibilityLabel("Bildstand \(state.variant.displayName)")
    }
}

struct VariantThumbnail: View {
    let variant: EditingVariant
    let asset: PhotoAsset
    @ObservedObject var editor: EditingModel
    private struct LoadIdentity: Hashable {
        let variantID: EditingVariantID
        let url: URL
        let modifiedAt: Date
        let fileSize: Int64
        let storeGeneration: UUID
    }
    @ViewState private var source: ResolvedEditingSource?
    @ViewState private var stamp: ImageAnalysisSourceStamp?
    @ViewState private var lease: ArtifactLease?
    @ViewState private var failed = false
    var body: some View {
        Group {
            if let source, let stamp {
                VariantSnapshotImage(source: source, expectedStamp: stamp,
                    identity: variant.id.canonicalString, pixelSize: 256, priority: .thumbnail)
            } else if failed { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            else { ProgressView().controlSize(.small) }
        }.frame(width: 64, height: 48).background(Color.black.opacity(0.25)).clipped()
            .task(id: LoadIdentity(variantID: variant.id, url: asset.fileURL, modifiedAt: asset.modifiedAt,
                fileSize: asset.fileSize, storeGeneration: editor.variantsReloadID)) {
                source = nil; stamp = nil; lease = nil; failed = false
                do {
                    let retained = try await editor.retainViewingSource(for: asset, snapshot: variant.snapshot)
                    let captured = try await PreviewSourceStamp.capture(for: .init(source: retained.0.identity, pixelSize: 256))
                    try Task.checkCancellation()
                    source = retained.0; stamp = captured; lease = retained.1; failed = false
                } catch { if !Task.isCancelled { failed = true } }
            }
            .onDisappear { source = nil; stamp = nil; lease = nil }
    }
}

struct VariantSnapshotImage: View {
    let source: ResolvedEditingSource
    let expectedStamp: ImageAnalysisSourceStamp
    let identity: String
    let pixelSize: Int
    let priority: PreviewPriority
    var validationGeneration: UInt64 = 0
    private struct RenderIdentity: Hashable {
        let request: PreviewRequest
        let identity: String
        let settings: EditSettings
    }
    private struct LoadIdentity: Hashable { let render: RenderIdentity; let validationGeneration: UInt64 }
    @ViewState private var displayedIdentity: RenderIdentity?
    @ViewState private var image: NSImage?
    // NSImage retains the pixels, but not the resource reservation attached to
    // PreviewBitmap. Keep both until the visible frame is actually replaced.
    @ViewState private var retainedBitmap: PreviewBitmap?
    @ViewState private var failure: String?
    private var request: PreviewRequest {
        PreviewRequest(source: source.identity, pixelSize: pixelSize, allowsEmbeddedPreview: false,
            sourceRevision: expectedStamp.cacheRevision, allowsHDR: source.settings.developColor.hdrEnabled)
    }
    private var renderIdentity: RenderIdentity { .init(request: request, identity: identity, settings: source.settings) }
    var body: some View {
        Group {
            if displayedIdentity == renderIdentity, let image { DevelopImageView(image: image, hdr: source.settings.developColor.hdrEnabled) }
            else if let failure {
                VStack { Image(systemName: "exclamationmark.triangle"); Text(failure) }
                    .font(.system(size: 13)).foregroundStyle(.orange)
            } else { ProgressView() }
        }.task(id: LoadIdentity(render: renderIdentity, validationGeneration: validationGeneration)) {
            let rendering = renderIdentity
            // Candidate navigation only asks us to revalidate the same frozen
            // source. Keep its accepted pixels steady while that check runs.
            if displayedIdentity != rendering { image = nil; retainedBitmap = nil; displayedIdentity = nil }
            failure = nil
            do {
                guard try await PreviewSourceStamp.capture(for: request) == expectedStamp else { throw ArtifactContractError.sourceChanged }
                let input = try await ImagePreviewPipeline.shared.image(for: request, priority: priority)
                let output = try await AdjustedPreviewPipeline.shared.image(input, request: request, settings: source.settings, priority: priority, maximumOutputPixelSize: pixelSize)
                guard try await PreviewSourceStamp.capture(for: request) == expectedStamp else { throw ArtifactContractError.sourceChanged }
                try Task.checkCancellation()
                retainedBitmap = output
                image = NSImage(cgImage: output.image, size: NSSize(width: output.image.width, height: output.image.height))
                displayedIdentity = rendering
            } catch {
                if !Task.isCancelled {
                    image = nil; retainedBitmap = nil; displayedIdentity = nil
                    failure = "Bildstand nicht verfügbar"
                }
            }
        }.onDisappear { image = nil; retainedBitmap = nil; displayedIdentity = nil }
    }
}
