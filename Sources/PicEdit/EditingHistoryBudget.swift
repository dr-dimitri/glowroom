import Foundation
import PicEditCore

/// Bounds extra undo ownership, independently of the current edit and durable
/// snapshots. Metadata is conservative; shared immutable raster allocations
/// are charged once. No pixel data is copied, compared or hashed on MainActor.
enum EditingHistoryLimits {
    static let maximumBytes = 64 * 1_024 * 1_024
    static let maximumStates = 256
}

struct EditingHistoryFootprint {
    struct Storage: Hashable {
        let address: UInt
        let bytes: Int
    }
    var metadataBytes = 1_024
    var storage: [Storage] = []

    private mutating func include(_ data: Data) {
        // Small Data can be inline, whose temporary access address is not a
        // stable storage identity. Charge it per state instead. Large Data is
        // immutable and its owner stays retained by the corresponding entry;
        // a freed address cannot be reused while that entry still exists.
        guard data.count > 256 else { metadataBytes += data.count; return }
        data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                storage.append(Storage(address: UInt(bitPattern: base), bytes: bytes.count))
            }
        }
    }

    private mutating func include(_ document: MaskDocument) {
        metadataBytes += 128 + document.strokes.count * 128
        // Read array counts only, not their point payloads.
        for stroke in document.strokes { metadataBytes += stroke.points.count * MemoryLayout<MaskPoint>.stride }
    }

    static func layers(_ layers: [LocalAdjustment]) -> Self {
        var result = Self()
        for layer in layers {
            result.metadataBytes += 512 + layer.name.utf8.count
            switch layer.mask.shape {
            case .subject(let raster), .sky(let raster): result.include(raster.bytes)
            case .brush(let document): result.include(document)
            case .linear, .radial: break
            }
            if let refinement = layer.mask.refinement { result.include(refinement) }
        }
        return result
    }

    static func snapshot(_ snapshot: EditingSnapshot) -> Self {
        var result = layers(snapshot.settings.localAdjustments)
        let geometry = snapshot.settings.developGeometry
        result.metadataBytes += 512 + geometry.redEyeCorrections.count * 128
        for stroke in geometry.retouchStrokes {
            result.metadataBytes += 256 + stroke.path.count * MemoryLayout<LocalMaskPoint>.stride
            if let mask = stroke.mask { result.include(mask.bytes) }
            if let replacement = stroke.replacement { result.include(replacement.rgba) }
        }
        return result
    }
}

/// All stacks owned by one editor share a budget, including active group
/// starts. Eviction removes the oldest retained state; current settings and
/// accepted saves are owned separately and are never evicted here.
struct BoundedEditingHistory<Value> {
    private enum Stack: Equatable { case undo, redo, group }
    private struct Lane {
        var undo: [UUID] = []
        var redo: [UUID] = []
        var group: UUID?
        var isEmpty: Bool { undo.isEmpty && redo.isEmpty && group == nil }
    }
    private struct Entry {
        let value: Value
        let key: String
        let stack: Stack
        let footprint: EditingHistoryFootprint
    }
    private let footprint: (Value) -> EditingHistoryFootprint
    private let maximumBytes: Int
    private let maximumStates: Int
    private var lanes: [String: Lane] = [:]
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var references: [EditingHistoryFootprint.Storage: Int] = [:]
    private(set) var byteCount = 0
    var count: Int { entries.count }

    init(maximumBytes: Int = EditingHistoryLimits.maximumBytes,
         maximumStates: Int = EditingHistoryLimits.maximumStates,
         footprint: @escaping (Value) -> EditingHistoryFootprint) {
        self.maximumBytes = maximumBytes; self.maximumStates = maximumStates
        self.footprint = footprint
    }

    func canUndo(_ key: String = "") -> Bool { lanes[key]?.undo.isEmpty == false }
    func canRedo(_ key: String = "") -> Bool { lanes[key]?.redo.isEmpty == false }
    func group(_ key: String = "") -> Value? { lanes[key]?.group.flatMap { entries[$0]?.value } }
    func lastUndo(_ key: String = "") -> Value? { lanes[key]?.undo.last.flatMap { entries[$0]?.value } }
    func lastRedo(_ key: String = "") -> Value? { lanes[key]?.redo.last.flatMap { entries[$0]?.value } }
    mutating func appendUndo(_ value: Value, for key: String = "") { append(value, key: key, stack: .undo) }
    mutating func appendRedo(_ value: Value, for key: String = "") { append(value, key: key, stack: .redo) }
    mutating func beginGroup(_ value: Value, for key: String = "") {
        guard lanes[key]?.group == nil else { return }
        append(value, key: key, stack: .group)
    }
    @discardableResult mutating func popUndo(_ key: String = "") -> Value? {
        guard let id = lanes[key]?.undo.last else { return nil }; return remove(id)
    }
    @discardableResult mutating func popRedo(_ key: String = "") -> Value? {
        guard let id = lanes[key]?.redo.last else { return nil }; return remove(id)
    }
    @discardableResult mutating func endGroup(_ key: String = "") -> Value? {
        guard let id = lanes[key]?.group else { return nil }; return remove(id)
    }

    mutating func clearRedo(_ key: String = "") {
        for id in lanes[key]?.redo ?? [] { remove(id) }
    }
    mutating func clear(_ key: String) {
        guard let lane = lanes[key] else { return }
        for id in lane.undo + lane.redo + (lane.group.map { [$0] } ?? []) { remove(id) }
    }
    mutating func removeAll() {
        lanes.removeAll(); entries.removeAll(); order.removeAll(); references.removeAll(); byteCount = 0
    }

    private mutating func append(_ value: Value, key: String, stack: Stack) {
        let id = UUID()
        var cost = footprint(value)
        cost.metadataBytes += key.utf8.count
        entries[id] = Entry(value: value, key: key, stack: stack, footprint: cost)
        order.append(id)
        switch stack {
        case .undo: lanes[key, default: Lane()].undo.append(id)
        case .redo: lanes[key, default: Lane()].redo.append(id)
        case .group: lanes[key, default: Lane()].group = id
        }
        byteCount += cost.metadataBytes
        for storage in cost.storage {
            if references[storage] == nil { byteCount += storage.bytes }
            references[storage, default: 0] += 1
        }
        while count > maximumStates || byteCount > maximumBytes {
            // Preserve an active slider/brush group's starting value while
            // ordinary history can be retired. Even groups alone remain bounded.
            guard let oldest = order.first(where: { entries[$0]?.stack != .group }) ?? order.first else { break }
            remove(oldest)
        }
    }

    @discardableResult private mutating func remove(_ id: UUID) -> Value? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        order.removeAll { $0 == id }
        switch entry.stack {
        case .undo: lanes[entry.key]?.undo.removeAll { $0 == id }
        case .redo: lanes[entry.key]?.redo.removeAll { $0 == id }
        case .group: lanes[entry.key]?.group = nil
        }
        if lanes[entry.key]?.isEmpty == true { lanes.removeValue(forKey: entry.key) }
        byteCount -= entry.footprint.metadataBytes
        for storage in entry.footprint.storage {
            if let count = references[storage], count > 1 { references[storage] = count - 1 }
            else { references.removeValue(forKey: storage); byteCount -= storage.bytes }
        }
        return entry.value
    }
}
