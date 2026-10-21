import Foundation
import GlowroomCore

/// Accepted changes of original references are fenced before their first await.
/// The final export holds this lock only for its destination check and rename;
/// catalog reads, native-lock waits and image processing stay outside it.
final class JPEGExportCatalogProtection: @unchecked Sendable {
    let repository: CatalogRepository
    private let lock = NSLock()
    private var generation = UUID()
    private var changes = Set<UUID>()
    private var unavailable = false
    private var protectedSourceURLs: [URL] = []

    struct Snapshot: Sendable { let generation: UUID; let protectedSourceURLs: [URL] }

    init(repository: CatalogRepository) { self.repository = repository }

    final class Admission: @unchecked Sendable {
        private let owner: JPEGExportCatalogProtection
        private let id: UUID
        fileprivate init(owner: JPEGExportCatalogProtection, id: UUID) { self.owner = owner; self.id = id }
        deinit { owner.finishChange(id) }
    }

    func acceptCatalogChange() -> Admission {
        lock.withLock {
            let id = UUID()
            changes.insert(id); generation = UUID()
            return Admission(owner: self, id: id)
        }
    }

    private func finishChange(_ id: UUID) {
        lock.withLock { changes.remove(id); generation = UUID() }
    }

    func updateProtectedSources(_ urls: [URL]) {
        lock.withLock {
            guard protectedSourceURLs != urls else { return }
            protectedSourceURLs = urls; generation = UUID()
        }
    }

    func setUnavailable(_ value: Bool) {
        lock.withLock {
            guard unavailable != value else { return }
            unavailable = value; generation = UUID()
        }
    }

    func snapshot() throws -> Snapshot {
        try lock.withLock {
            guard changes.isEmpty else { throw JPEGExportError.catalogBusy }
            guard !unavailable else { throw JPEGExportError.catalogUnavailable }
            return Snapshot(generation: generation, protectedSourceURLs: protectedSourceURLs)
        }
    }

    func withPublication<Result>(generation expected: UUID, _ operation: () throws -> Result) throws -> Result {
        try lock.withLock {
            guard changes.isEmpty else { throw JPEGExportError.catalogBusy }
            guard !unavailable else { throw JPEGExportError.catalogUnavailable }
            guard generation == expected else { throw JPEGExportError.catalogChanged }
            return try operation()
        }
    }
}
