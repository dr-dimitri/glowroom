import Combine
import Foundation
import PicEditCore
import SwiftUI

/// The sole owner of group-specific small bitmap references. Card views borrow
/// these CGImages directly, without additional NSImage or @State bitmap caches.
/// The existing PhotoPreview remains the sole large active variant display.
@MainActor
final class AILookCardStore: ObservableObject {
    nonisolated static let maximumCardBytes = 8 * 1_024 * 1_024
    nonisolated static let maximumCardCount = 3
    nonisolated static let maximumCardPixelSize = 512

    @Published private(set) var bitmaps: [AILookID: PreviewBitmap] = [:]
    @Published private(set) var errors: [AILookID: String] = [:]
    @Published private(set) var pendingIDs: Set<AILookID> = []
    private(set) var groupID: UUID?
    private(set) var selectedID: AILookID?
    private let imagePipeline: ImagePreviewPipeline
    private let renderPipeline: AdjustedPreviewPipeline
    private let byteLimit: Int
    private let countLimit: Int
    private var request: PreviewRequest?
    private var settings: [AILookID: EditSettings] = [:]
    private var accesses: [AILookID: UInt64] = [:]
    private var sequence: UInt64 = 0
    private var workID = UUID()
    private var renderTask: Task<Void, Never>?
    private var memoryPressure: DispatchSourceMemoryPressure?

    var cardByteCount: Int { bitmaps.values.reduce(0) { $0 + $1.byteCost } }
    var cardCount: Int { bitmaps.count }

    init(imagePipeline: ImagePreviewPipeline = .shared,
         renderPipeline: AdjustedPreviewPipeline = .shared,
         maximumBytes: Int = AILookCardStore.maximumCardBytes,
         maximumCards: Int = AILookCardStore.maximumCardCount,
         observesMemoryPressure: Bool = true) {
        self.imagePipeline = imagePipeline
        self.renderPipeline = renderPipeline
        byteLimit = min(Self.maximumCardBytes, max(0, maximumBytes))
        countLimit = min(Self.maximumCardCount, max(0, maximumCards))
        if observesMemoryPressure {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.handleMemoryPressure() }
            }
            source.resume()
            memoryPressure = source
        }
    }

    deinit {
        renderTask?.cancel()
        memoryPressure?.cancel()
    }

    func bitmap(for id: AILookID) -> PreviewBitmap? { bitmaps[id] }
    func failure(for id: AILookID) -> String? { errors[id] }

    func begin(group: AILookGroupResult, selectedID: AILookID?) {
        clear()
        guard group.validation.variants.count == Self.maximumCardCount,
              Set(group.validation.variants.map { $0.proposal.id }) == Set(AILookID.allCases)
        else { return }
        groupID = group.request.id
        request = PreviewRequest(source: group.request.snapshot.source, pixelSize: 2_400, allowsEmbeddedPreview: false)
        for variant in group.validation.variants { settings[variant.proposal.id] = variant.target }
        self.selectedID = selectedID
        startRendering(AILookID.allCases)
    }

    /// Selection changes only retention/lazy rendering, never model inference.
    /// All card work stays in the background lane; PhotoPreview owns .selected.
    func select(id: AILookID) {
        guard settings[id] != nil else { return }
        selectedID = id
        touch(id)
        if bitmaps[id] == nil { errors.removeValue(forKey: id) }
        ensureSelectedCard()
    }

    func clear() {
        cancelRendering()
        groupID = nil
        selectedID = nil
        request = nil
        settings.removeAll()
        bitmaps.removeAll()
        errors.removeAll()
        accesses.removeAll()
    }

    /// Keep recipes and the main display, release all expendable UI references
    /// and pending group work. A later explicit selection lazily requests a card.
    func handleMemoryPressure() {
        cancelRendering()
        bitmaps.removeAll()
        errors.removeAll()
        accesses.removeAll()
    }

    private func cancelRendering() {
        workID = UUID()
        renderTask?.cancel()
        renderTask = nil
        pendingIDs.removeAll()
    }

    private func startRendering(_ ids: [AILookID]) {
        guard renderTask == nil, let request, let groupID, !ids.isEmpty else { return }
        let workID = UUID()
        self.workID = workID
        let targets = ids.compactMap { id in settings[id].map { (id, $0) } }
        pendingIDs = Set(targets.map { $0.0 })
        let imagePipeline = imagePipeline
        let renderPipeline = renderPipeline
        renderTask = Task { [weak self] in
            do {
                // Same request/base as Develop. The shared pipeline coalesces
                // cached or in-flight decoding; no decoder is created per look.
                let source = try await imagePipeline.image(for: request, priority: .thumbnail)
                try Task.checkCancellation()
                await withTaskGroup(of: (AILookID, CardResult).self) { group in
                    // Exactly three bounded waiters, not another worker pool.
                    // Actual downsampling and filtering use existing render slots.
                    for (id, target) in targets {
                        group.addTask {
                            do {
                                let bitmap = try await renderPipeline.image(source, request: request, settings: target,
                                    priority: .thumbnail, maximumOutputPixelSize: Self.maximumCardPixelSize)
                                try Task.checkCancellation()
                                return (id, .bitmap(bitmap))
                            } catch is CancellationError { return (id, .cancelled) }
                            catch { return (id, .failed) }
                        }
                    }
                    for await (id, result) in group {
                        guard let self, self.groupID == groupID, self.workID == workID, !Task.isCancelled else { continue }
                        self.pendingIDs.remove(id)
                        switch result {
                        case .bitmap(let bitmap): self.install(bitmap, for: id)
                        case .failed: self.errors[id] = "Die kleine Lookvorschau konnte nicht gerendert werden."
                        case .cancelled: break
                        }
                    }
                }
            } catch is CancellationError {
                // Invalidation already removed all of this group's references.
            } catch {
                guard let self, self.groupID == groupID, self.workID == workID, !Task.isCancelled else { return }
                for id in ids { self.errors[id] = "Die Bildbasis für die Lookvorschau ist nicht verfügbar." }
            }
            guard let self, self.groupID == groupID, self.workID == workID else { return }
            self.pendingIDs.removeAll()
            self.renderTask = nil
            self.ensureSelectedCard()
        }
    }

    private func ensureSelectedCard() {
        guard renderTask == nil, let id = selectedID, bitmaps[id] == nil, errors[id] == nil else { return }
        startRendering([id])
    }

    private func install(_ bitmap: PreviewBitmap, for id: AILookID) {
        guard bitmap.image.width <= Self.maximumCardPixelSize, bitmap.image.height <= Self.maximumCardPixelSize,
              bitmap.byteCost <= byteLimit, countLimit > 0 else {
            errors[id] = "Die kleine Lookvorschau überschreitet das Raster- oder Speicherlimit."
            return
        }
        bitmaps.removeValue(forKey: id)
        while cardCount >= countLimit || cardByteCount > byteLimit - bitmap.byteCost {
            // Prefer retaining the selected card while background cards arrive.
            let candidates = bitmaps.keys.filter { $0 != selectedID }
            guard let oldest = candidates.min(by: { accesses[$0, default: 0] < accesses[$1, default: 0] }) else { return }
            bitmaps.removeValue(forKey: oldest)
            accesses.removeValue(forKey: oldest)
        }
        bitmaps[id] = bitmap
        errors.removeValue(forKey: id)
        touch(id)
    }

    private func touch(_ id: AILookID) {
        sequence &+= 1
        accesses[id] = sequence
    }
}

private enum CardResult: Sendable {
    case bitmap(PreviewBitmap)
    case failed
    case cancelled
}

/// Deliberately stateless bitmap display: the store's byte budget includes the
/// very same immutable CGImage retained by this view, with no NSImage copy/cache.
struct AILookCardImage: View {
    @ObservedObject var store: AILookCardStore
    let id: AILookID

    var body: some View {
        ZStack {
            if let bitmap = store.bitmap(for: id) {
                Image(decorative: bitmap.image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else if let failure = store.failure(for: id) {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption).multilineTextAlignment(.center).padding(8)
            } else if store.pendingIDs.contains(id) {
                ProgressView().controlSize(.small).accessibilityLabel("Kleine Lookvorschau wird gerendert")
            } else {
                Label("Vorschau bei Auswahl", systemImage: "photo").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Kleine Lookvorschau")
    }
}
