import AppKit
import SwiftUI
import PicEditCore

// Some CLT SDKs also export a State macro without its compiler plugin.
private typealias PhotoState<Value> = SwiftUI.State<Value>

@MainActor
struct AssetThumbnail: View {
    let url: URL
    let modifiedAt: Date
    var size: CGFloat = 320
    var fileSize: Int64 = 0
    var priority: PreviewPriority = .thumbnail
    var settings: EditSettings = .neutral
    var source: AISourceIdentity? = nil
    @Environment(\.displayScale) private var displayScale

    private var pixelSize: Int {
        let points = size.isFinite ? min(max(size, 1), 768) : 320
        let scale = displayScale.isFinite ? min(max(displayScale, 1), 3) : 2
        let pixels = min(Int(ceil(points * scale)), 1_536)
        return [256, 512, 1_024, 1_536].first { $0 >= pixels } ?? 1_536
    }

    var body: some View {
        AsyncPhotoView(
            request: PreviewRequest(source: source ?? .original(.init(fileURL: url, modifiedAt: modifiedAt, fileSize: fileSize)), pixelSize: pixelSize,
                                    allowsEmbeddedPreview: settings.isNeutral),
            priority: priority, settings: settings, showsFailureDescription: false
        )
    }
}

@MainActor
struct PhotoPreview: View {
    let url: URL
    let modifiedAt: Date
    var fileSize: Int64 = 0
    var settings: EditSettings = .neutral
    var source: AISourceIdentity? = nil
    var developing = false

    var body: some View {
        AsyncPhotoView(
            request: PreviewRequest(source: source ?? .original(.init(fileURL: url, modifiedAt: modifiedAt, fileSize: fileSize)), pixelSize: 2_400,
                                    allowsEmbeddedPreview: !developing && settings.isNeutral),
            priority: .selected, settings: settings, showsFailureDescription: true, progressive: true
        )
    }
}

@MainActor
private struct AsyncPhotoView: View {
    let request: PreviewRequest
    let priority: PreviewPriority
    let settings: EditSettings
    let showsFailureDescription: Bool
    var progressive = false

    private struct RenderIdentity: Hashable {
        let request: PreviewRequest
        let settings: EditSettings
        let sourceToken: UUID?
    }
    private struct Displayed {
        let identity: RenderIdentity
        let image: NSImage
    }

    private struct SourceLoadIdentity: Hashable { let request: PreviewRequest; let retry: UUID }
    @PhotoState private var retry = UUID()
    @PhotoState private var loadedRequest: PreviewRequest?
    @PhotoState private var sourceBitmap: PreviewBitmap?
    @PhotoState private var sourceToken: UUID?
    @PhotoState private var displayed: Displayed?
    @PhotoState private var loadingSource = true
    @PhotoState private var sourceError: String?
    @PhotoState private var renderError: String?

    private var renderIdentity: RenderIdentity {
        RenderIdentity(request: request, settings: settings.normalized, sourceToken: sourceToken)
    }
    private var sameDisplayedPhoto: Bool {
        guard let displayed else { return false }
        let previous = displayed.identity.request
        return previous.source == request.source && previous.sourceRevision == request.sourceRevision
    }
    private var busy: Bool {
        (loadingSource || displayed?.identity != renderIdentity) && sourceError == nil && renderError == nil
    }

    var body: some View {
        ZStack {
            if sameDisplayedPhoto, let displayed {
                Image(nsImage: displayed.image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .accessibilityLabel(request.displayName)
            } else if let error = sourceError ?? renderError {
                failure(error)
            } else {
                loadingIndicator
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if sameDisplayedPhoto {
                if let error = sourceError ?? renderError {
                    Button { retry = UUID() } label: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(10)
                    }.buttonStyle(.plain).help("Vorschau erneut laden: " + error)
                        .accessibilityLabel("Vorschau erneut laden: " + error)
                } else if busy {
                    loadingIndicator.padding(12).help("Vorschau wird aktualisiert")
                }
            }
        }
        // Decoding is keyed only by the original, independently of the slider
        // values. Moving a slider never repeatedly cancels a slow RAW decode.
        .task(id: SourceLoadIdentity(request: request, retry: retry), priority: priority == .selected ? .userInitiated : .utility) {
            guard !Task.isCancelled else { return }
            loadedRequest = request
            sourceBitmap = nil
            sourceToken = nil
            loadingSource = true
            sourceError = nil
            renderError = nil
            if !sameDisplayedPhoto { displayed = nil }
            if progressive {
                let small = request.resized(to: 512)
                if let first = try? await ImagePreviewPipeline.shared.image(for: small, priority: priority),
                   !Task.isCancelled, loadedRequest == request {
                    sourceBitmap = first
                    sourceToken = UUID()
                }
            }
            do {
                let bitmap = try await ImagePreviewPipeline.shared.image(for: request, priority: priority)
                try Task.checkCancellation()
                guard loadedRequest == request else { return }
                sourceBitmap = bitmap
                sourceToken = UUID()
                loadingSource = false
            } catch is CancellationError {
                // The next photo's task owns the state.
            } catch {
                guard !Task.isCancelled, loadedRequest == request else { return }
                loadingSource = false
                sourceError = error.localizedDescription
            }
        }
        .task(id: renderIdentity, priority: priority == .selected ? .userInitiated : .utility) {
            let identity = renderIdentity
            guard loadedRequest == request, let sourceBitmap, !Task.isCancelled else { return }
            renderError = nil
            do {
                // Coalesce continuous slider events while retaining the previous
                // display; only the current settings may replace it.
                if !settings.isNeutral { try await Task.sleep(for: .milliseconds(45)) }
                // A cached source can exceed request.pixelSize. Enforce the
                // actual output limit even for neutral/original comparisons.
                let bitmap = try await AdjustedPreviewPipeline.shared.image(sourceBitmap, request: request,
                    settings: identity.settings, priority: priority, maximumOutputPixelSize: request.pixelSize)
                try Task.checkCancellation()
                guard renderIdentity == identity else { return }
                displayed = Displayed(identity: identity, image: NSImage(cgImage: bitmap.image,
                                      size: NSSize(width: bitmap.image.width, height: bitmap.image.height)))
            } catch is CancellationError {
                // A newer parameter value, photo or source resolution supersedes this result.
            } catch {
                guard !Task.isCancelled, renderIdentity == identity else { return }
                renderError = error.localizedDescription
            }
        }
        .onDisappear {
            loadedRequest = nil
            sourceBitmap = nil
            sourceToken = nil
            displayed = nil
            loadingSource = true
            sourceError = nil
            renderError = nil
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "photo").font(showsFailureDescription ? .largeTitle : .title2).foregroundStyle(.secondary)
            if showsFailureDescription {
                Text("Vorschau nicht verfügbar").font(.callout).foregroundStyle(.secondary)
                Text(message).font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
                Button("Erneut versuchen") { retry = UUID() }.buttonStyle(.plain)
            }
        }.padding(showsFailureDescription ? 24 : 8).help(message)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Vorschau nicht verfügbar: \(request.displayName). \(message)")
    }

    private var loadingIndicator: some View {
        ProgressView().controlSize(.small).accessibilityLabel("Bildvorschau wird aktualisiert")
    }
}
