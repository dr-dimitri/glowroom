import CryptoKit
import Darwin
import Foundation

/// The journal and retained catalog use positively owned, pinned directories.
/// Native locks cover only synchronous file CAS; never participant actor awaits.
internal final class CatalogCoordinationFiles: @unchecked Sendable {
    static let folderName = "CatalogCoordination"
    static let rootStagePrefix = ".catalog-coordination-root-"
    private static let maximumOperations = 4_096
    let directory: URL
    init(directory: URL) { self.directory = directory }

    private struct RootMarker: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let rootOwnerID: UUID
    }
    private final class FD: @unchecked Sendable {
        let value: Int32
        private let editingOwnership: EditingNativeFileReservation?
        init(_ value: Int32, editingOwnership: EditingNativeFileReservation? = nil) {
            self.value = value; self.editingOwnership = editingOwnership
        }
        deinit { if let editingOwnership { editingOwnership.close() } else { close(value) } }
    }
    private struct Root: Sendable {
        let catalog: FD
        let coordination: FD
        let marker: RootMarker
    }
    private struct Operation: Sendable {
        let root: Root
        let directory: FD
        let name: String
        let descriptor: DurableCatalogStageDescriptor
    }
    private struct Stamp: Codable, Equatable, Sendable {
        let device: Int64; let inode: UInt64; let size: Int64
        let modifiedSeconds: Int64; let modifiedNanos: Int64
        let changedSeconds: Int64; let changedNanos: Int64
        init(_ s: stat) {
            device = Int64(s.st_dev); inode = UInt64(s.st_ino); size = s.st_size
            modifiedSeconds = Int64(s.st_mtimespec.tv_sec); modifiedNanos = Int64(s.st_mtimespec.tv_nsec)
            changedSeconds = Int64(s.st_ctimespec.tv_sec); changedNanos = Int64(s.st_ctimespec.tv_nsec)
        }
    }
    private struct PayloadIdentity: Codable {
        let rootOwnerID: UUID
        let operationID: UUID
        let stamp: Stamp
    }
    private struct OpenFile: Sendable {
        let handle: FD
        let descriptor: ArtifactFileDescriptor
        let stamp: Stamp
        let data: Data?
    }

    func recoveryInventory() throws -> CatalogRecoveryInventory {
        let root = try openRoot()
        return try locked(root) {
            let hash = try terminalInventoryDigest(root)
            return try CatalogFileIO.withPublicationLock(directory: directory) { catalog in
                CatalogRecoveryInventory(rootOwnerID: root.marker.rootOwnerID, catalog: catalog, journalSHA256: hash)
            }
        }
    }
    func withRecoveryBoundary<Result>(_ expected: CatalogRecoveryInventory,
                                      operation: () throws -> Result) throws -> Result {
        let root = try openRoot()
        return try locked(root) {
            guard root.marker.rootOwnerID == expected.rootOwnerID,
                  try terminalInventoryDigest(root) == expected.journalSHA256 else {
                throw CatalogCoordinationError.recoveryRequired
            }
            return try CatalogFileIO.withPublicationLock(directory: directory) { catalog in
                guard catalog == expected.catalog else { throw CatalogCoordinationError.externallyModifiedCatalog }
                try requireCurrentRoot(root)
                try requireDatabaseFamilyIsNotImportedSource(catalog)
                return try operation()
            }
        }
    }
    private func requireDatabaseFamilyIsNotImportedSource(_ expected: MetadataCatalogFileReference) throws {
        let contents = try CatalogFileIO.readCatalog(directory: directory)
        guard contents.reference == expected else { throw CatalogCoordinationError.externallyModifiedCatalog }
        guard let bytes = contents.data else { return }
        let catalog = try JSONDecoder().decode(LibraryCatalog.self, from: bytes)
        try CatalogRepository(directory: directory).validate(catalog)
        let checks = try ["", "-wal", "-shm", "-journal", "-recovery.json"].map {
            try PhotoMetadataFiles.DestinationCheck(directory.appendingPathComponent("edits.sqlite" + $0))
        }
        // Reuse the established native/case-aware protection primitive. It has
        // no metadata database dependency and streams existing catalog storage.
        for asset in catalog.assets {
            try autoreleasepool { for check in checks { try check.checkFile(asset.fileURL) } }
        }
    }
    private func terminalInventoryDigest(_ root: Root) throws -> ArtifactDigest {
        var hasher = SHA256()
        for name in try names(root.coordination.value, maximum: Self.maximumOperations + 2) {
            if name == "owner.json" || name == "coordination-write.lock" { continue }
            guard let id = UUID(uuidString: name), name == id.uuidString.lowercased() else { throw CatalogCoordinationError.unknownJournal }
            let value = try readJournal(openOperation(root, id: id))
            guard value.phase == .completed, value.disposition == .completed || value.disposition == .aborted else {
                throw CatalogCoordinationError.recoveryRequired
            }
            hasher.update(data: Data(name.utf8))
            hasher.update(data: try EditingContractJSON.encoder().encode(value))
        }
        return try ArtifactDigest(sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
    func rootIdentity() throws -> UUID { try openRoot().marker.rootOwnerID }

    func pendingValues() throws -> [CatalogCoordinationJournalValue] {
        let root = try openRoot()
        return try locked(root) {
            var values: [CatalogCoordinationJournalValue] = []
            for name in try names(root.coordination.value, maximum: Self.maximumOperations + 2) {
                if name == "owner.json" || name == "coordination-write.lock" { continue }
                guard let id = UUID(uuidString: name), name == id.uuidString.lowercased() else {
                    throw CatalogCoordinationError.unknownJournal
                }
                let operation = try openOperation(root, id: id)
                let journal = try readJournal(operation)
                if journal.disposition == .active || (journal.disposition == .aborted && journal.phase == .prepared) { values.append(journal) }
            }
            guard values.count <= 1 else { throw CatalogCoordinationError.recoveryRequired }
            return values
        }
    }

    func value(id: UUID) throws -> CatalogCoordinationJournalValue {
        let root = try openRoot()
        return try locked(root) { try readJournal(openOperation(root, id: id)) }
    }

    /// Exact original command bytes are retained before the prepared journal.
    /// A crash before the journal is visible leaves a preserved ambiguous stage.
    func create(_ value: CatalogCoordinationJournalValue, prepared: PreparedLibraryCatalog,
                editing: Data?, metadata: Data?) throws -> DurableCatalogStage {
        let root = try openRoot()
        guard value.body.catalog.rootOwnerID == root.marker.rootOwnerID,
              value.body.catalog.after == prepared.reference else { throw CatalogCoordinationError.invalidCapability }
        try validate(value)
        let descriptor = DurableCatalogStageDescriptor(payload: value.body.catalog,
                                                       coordinatorRequestSHA256: value.requestSHA256)
        return try locked(root) {
            let existing = try names(root.coordination.value, maximum: Self.maximumOperations + 2)
            for name in existing where name != "owner.json" && name != "coordination-write.lock" {
                guard let id = UUID(uuidString: name), name == id.uuidString.lowercased() else {
                    throw CatalogCoordinationError.unknownJournal
                }
                let prior = try readJournal(openOperation(root, id: id))
                guard prior.phase == .completed else { throw CatalogCoordinationError.maintenanceAlreadyPending }
            }
            guard existing.count < Self.maximumOperations + 2 else { throw ArtifactContractError.limitExceeded }
            let name = value.body.operationID.uuidString.lowercased()
            guard mkdirat(root.coordination.value, name, 0o700) == 0 else { throw CatalogCoordinationError.invalidCapability }
            let fd = openat(root.coordination.value, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw posix("Katalogjournal-Verzeichnis öffnen") }
            let operation = Operation(root: root, directory: FD(fd), name: name, descriptor: descriptor)
            try writeNew(try EditingContractJSON.encoder().encode(descriptor), name: "descriptor.json", in: operation.directory.value)
            try writeNew(prepared.bytes, name: "catalog.json", in: operation.directory.value)
            let originalPayload = try readFile(operation.directory.value, name: "catalog.json", maximum: CatalogFileIO.maximumBytes, capture: false)
            let payloadIdentity = PayloadIdentity(rootOwnerID: root.marker.rootOwnerID, operationID: value.body.operationID, stamp: originalPayload.stamp)
            try writeNew(try EditingContractJSON.encoder().encode(payloadIdentity), name: "payload-identity.json", in: operation.directory.value)
            if let editing { try writeNew(editing, name: "editing-command.json", in: operation.directory.value) }
            if let metadata { try writeNew(metadata, name: "metadata-command.json", in: operation.directory.value) }
            try writeNew(try EditingContractJSON.encoder().encode(value), name: "journal.json", in: operation.directory.value)
            guard fsync(root.coordination.value) == 0, fsync(root.catalog.value) == 0 else { throw posix("Katalogjournal sichern") }
            return try stage(operation)
        }
    }

    func command(_ journal: ValidatedCatalogCoordinatorJournal, kind: CatalogParticipantKind) throws -> Data {
        let operation = try checkedOperation(journal)
        let name = kind == .editing ? "editing-command.json" : "metadata-command.json"
        let maximum = kind == .editing ? EditSettings.maximumEncodedBytes : 67_108_864
        guard let expected = journal.value.body.requiredParticipants.first(where: { $0.store.kind == kind }) else {
            throw CatalogCoordinationError.requiredParticipantMissing(kind)
        }
        let file = try readFile(operation.directory.value, name: name, maximum: maximum, capture: true)
        guard file.descriptor.bytes == expected.canonicalByteCount, let data = file.data else {
            throw CatalogCoordinationError.originalRequestMismatch(kind)
        }
        return data
    }

    func advance(_ journal: ValidatedCatalogCoordinatorJournal, phase: CatalogCoordinationPhase,
                 disposition: CatalogCoordinationDisposition = .active) throws -> CatalogCoordinationJournalValue {
        let root = try openRoot()
        return try locked(root) {
            let operation = try checkedOperation(journal, root: root)
            let previous = try readJournal(operation)
            guard previous.revision == journal.value.revision, previous.phase == journal.value.phase,
                  previous.disposition == journal.value.disposition, previous.revision < Int64.max else {
                throw CatalogCoordinationError.invalidPhase
            }
            let legal = (previous.phase == .prepared && phase == .armed && disposition == .active) ||
                (previous.phase == .prepared && phase == .prepared && disposition == .aborted) ||
                (previous.phase == .armed && phase == .editingCommitted && disposition == .active) ||
                (previous.phase == .editingCommitted && phase == .catalogPublished && disposition == .active) ||
                (previous.phase == .catalogPublished && phase == .completed && disposition == .completed)
            let finishedAbort = previous.disposition == .aborted && previous.phase == .prepared && phase == .completed && disposition == .aborted
            guard (previous.disposition == .active && legal) || finishedAbort else { throw CatalogCoordinationError.invalidPhase }
            let next = CatalogCoordinationJournalValue(body: previous.body, requestSHA256: previous.requestSHA256,
                revision: previous.revision + 1, phase: phase, disposition: disposition)
            try validate(next)
            try replace(try EditingContractJSON.encoder().encode(next), name: "journal.json", in: operation.directory.value,
                        expected: try EditingContractJSON.encoder().encode(previous))
            return next
        }
    }

    func inspect(_ journal: ValidatedCatalogCoordinatorJournal) throws -> CatalogRecoveryEvidence {
        let operation = try checkedOperation(journal)
        let actual = try CatalogFileIO.readCatalog(directory: directory).reference
        if actual == journal.value.body.catalog.after {
            return .exactAfter(CatalogPublicationEvidence(journal: journal, published: actual, nonce: UUID()))
        }
        if actual == journal.value.body.catalog.before { return .exactBefore(stage: try stage(operation)) }
        return .conflict(actual: actual)
    }

    func publish(_ durable: DurableCatalogStage, armed: ArmedCatalogCoordination) throws -> CatalogPublicationEvidence {
        let operation = try checkedOperation(armed.journal)
        guard durable.descriptor == operation.descriptor,
              armed.journal.value.disposition == .active,
              armed.journal.value.phase == .armed || armed.journal.value.phase == .editingCommitted else {
            throw CatalogCoordinationError.invalidCapability
        }
        guard let publicationPayload = durable.publicationPayload else { throw CatalogCoordinationError.invalidCapability }
        let native = try publicationPayload()
        guard native.prepared.reference == operation.descriptor.payload.after else { throw CatalogCoordinationError.invalidCapability }
        try CatalogFileIO.publish(native, directory: directory, expected: operation.descriptor.payload.before)
        return CatalogPublicationEvidence(journal: armed.journal, published: native.prepared.reference, nonce: UUID())
    }

    func cleanup(_ journal: ValidatedCatalogCoordinatorJournal, abort: Bool) throws {
        let root = try openRoot()
        try locked(root) {
            let operation = try checkedOperation(journal, root: root)
            let actual = try readJournal(operation)
            guard actual.phase == .completed, abort ? actual.disposition == .aborted : actual.disposition == .completed else {
                throw CatalogCoordinationError.invalidPhase
            }
            let ownership = try EditingDatabaseAccess.reserveNativeFile()
            let fd = openat(operation.directory.value, "catalog.json", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            if fd < 0 && errno == ENOENT { return }
            guard fd >= 0 else { throw CatalogCoordinationError.missingPreparedPayload }
            let file = FD(fd, editingOwnership: ownership.own(fd))
            let owned = try readFile(operation.directory.value, name: "catalog.json", maximum: CatalogFileIO.maximumBytes, capture: false)
            let identityFile = try readFile(operation.directory.value, name: "payload-identity.json", maximum: 4_096, capture: true)
            let identity: PayloadIdentity = try canonicalDecode(identityFile.data!)
            guard identity.rootOwnerID == operation.root.marker.rootOwnerID,
                  identity.operationID == operation.descriptor.payload.operationID, identity.stamp == owned.stamp,
                  reference(owned.descriptor) == operation.descriptor.payload.after,
                  sameFile(file.value, owned.handle.value) else { throw CatalogCoordinationError.invalidCapability }
            try requireNamed(file.value, parent: operation.directory.value, name: "catalog.json")
            guard unlinkat(operation.directory.value, "catalog.json", 0) == 0 else { throw posix("Abgeschlossenes Katalog-Staging entfernen") }
            guard fsync(operation.directory.value) == 0 else { throw posix("Katalog-Staging sichern") }
        }
    }

    private func stage(_ operation: Operation) throws -> DurableCatalogStage {
        let file = try readFile(operation.directory.value, name: "catalog.json", maximum: CatalogFileIO.maximumBytes, capture: false)
        let identityFile = try readFile(operation.directory.value, name: "payload-identity.json", maximum: 4_096, capture: true)
        let identity: PayloadIdentity = try canonicalDecode(identityFile.data!)
        guard reference(file.descriptor) == operation.descriptor.payload.after,
              identity.rootOwnerID == operation.root.marker.rootOwnerID,
              identity.operationID == operation.descriptor.payload.operationID,
              identity.stamp == file.stamp else { throw CatalogCoordinationError.missingPreparedPayload }
        return DurableCatalogStage(descriptor: operation.descriptor, publicationPayload: {
            try self.requireOperation(operation)
            try self.requireNamed(file.handle.value, parent: operation.directory.value, name: "catalog.json")
            let prepared = try self.preparedCatalog(operation)
            let payloadOwnership = try EditingDatabaseAccess.reserveNativeFile()
            let payloadFD = try self.duplicate(file.handle.value)
            let payload = CatalogDirectoryHandle(payloadFD, editingOwnership: payloadOwnership.own(payloadFD))
            return StagedLibraryCatalog(id: operation.descriptor.payload.operationID, prepared: prepared,
                root: CatalogDirectoryHandle(try self.duplicate(operation.root.catalog.value)),
                stage: CatalogDirectoryHandle(try self.duplicate(operation.directory.value)), name: "catalog.json",
                payload: payload,
                validateAdditionalBoundary: { try self.requireOperation(operation) })
        }, openOriginalBytes: {
            try self.requireOperation(operation)
            try self.requireNamed(file.handle.value, parent: operation.directory.value, name: "catalog.json")
            return ArtifactFileReadHandle(bytes: file.descriptor.bytes, sha256: file.descriptor.sha256, ownership: nil) { offset, maximum in
                try Self.readPinned(file, offset: offset, maximum: maximum)
            }
        })
    }
    private func preparedCatalog(_ operation: Operation) throws -> PreparedLibraryCatalog {
        let file = try readFile(operation.directory.value, name: "catalog.json", maximum: CatalogFileIO.maximumBytes, capture: true)
        guard reference(file.descriptor) == operation.descriptor.payload.after, let bytes = file.data else {
            throw CatalogCoordinationError.missingPreparedPayload
        }
        let catalog = try JSONDecoder().decode(LibraryCatalog.self, from: bytes)
        try CatalogRepository(directory: directory).validate(catalog)
        return PreparedLibraryCatalog(catalog: catalog, bytes: bytes)
    }
    private func checkedOperation(_ journal: ValidatedCatalogCoordinatorJournal, root: Root? = nil) throws -> Operation {
        let root = try root ?? openRoot()
        guard journal.ownerID == root.marker.rootOwnerID else { throw CatalogCoordinationError.invalidCapability }
        let operation = try openOperation(root, id: journal.value.body.operationID)
        let actual = try readJournal(operation)
        guard actual.body == journal.value.body, actual.requestSHA256 == journal.value.requestSHA256 else {
            throw CatalogCoordinationError.invalidCapability
        }
        return operation
    }
    private func openOperation(_ root: Root, id: UUID) throws -> Operation {
        try requireCurrentRoot(root)
        let name = id.uuidString.lowercased()
        let fd = openat(root.coordination.value, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw CatalogCoordinationError.missingPreparedPayload }
        let directory = FD(fd)
        try requireNamed(fd, parent: root.coordination.value, name: name, directory: true)
        let file = try readFile(fd, name: "descriptor.json", maximum: 65_536, capture: true)
        let descriptor: DurableCatalogStageDescriptor = try canonicalDecode(file.data!)
        guard descriptor.payload.schemaVersion == 1, descriptor.payload.operationID == id,
              descriptor.payload.rootOwnerID == root.marker.rootOwnerID else { throw CatalogCoordinationError.unknownJournal }
        let permitted = Set(["descriptor.json", "catalog.json", "editing-command.json", "metadata-command.json", "journal.json", "payload-identity.json"])
        guard try names(fd, maximum: permitted.count).allSatisfy({ permitted.contains($0) }) else {
            throw CatalogCoordinationError.unknownJournal
        }
        return Operation(root: root, directory: directory, name: name, descriptor: descriptor)
    }
    private func readJournal(_ operation: Operation) throws -> CatalogCoordinationJournalValue {
        let file = try readFile(operation.directory.value, name: "journal.json", maximum: 65_536, capture: true)
        let value: CatalogCoordinationJournalValue = try canonicalDecode(file.data!)
        try validate(value)
        guard value.body.catalog == operation.descriptor.payload,
              value.requestSHA256 == operation.descriptor.coordinatorRequestSHA256 else { throw CatalogCoordinationError.unknownJournal }
        return value
    }
    private func validate(_ value: CatalogCoordinationJournalValue) throws {
        let body = value.body, participants = body.requiredParticipants
        guard body.schemaVersion == 1, body.catalog.schemaVersion == 1,
              body.operationID == body.catalog.operationID, value.revision > 0,
              participants.count <= 2, !participants.isEmpty,
              Set(participants.map { $0.store.kind }).count == participants.count,
              participants.map({ $0.store.kind.rawValue }) == participants.map({ $0.store.kind.rawValue }).sorted(),
              participants.allSatisfy({ $0.operationID == body.operationID && $0.requestSchemaVersion == 1 &&
                  $0.canonicalByteCount > 0 && $0.canonicalByteCount <= Int64($0.store.kind == .editing ? EditSettings.maximumEncodedBytes : 67_108_864) }),
              CatalogFileIO.digest(try EditingContractJSON.encoder().encode(body)) == value.requestSHA256.sha256,
              value.disposition != .aborted || value.phase == .prepared || value.phase == .completed,
              value.disposition != .completed || value.phase == .completed,
              value.phase != .completed || value.disposition == .completed || value.disposition == .aborted else { throw CatalogCoordinationError.unknownJournal }
        try validReference(body.catalog.before)
        try validReference(body.catalog.after)
        guard case .present = body.catalog.after, body.catalog.before != body.catalog.after else { throw CatalogCoordinationError.unknownJournal }
    }
    private func validReference(_ ref: MetadataCatalogFileReference) throws {
        switch ref {
        case .absent: break
        case .present(let hash, let count):
            guard count > 0, count <= CatalogFileIO.maximumBytes else { throw CatalogCoordinationError.unknownJournal }
            _ = try ArtifactDigest(sha256: hash)
        }
    }

    private func openRoot() throws -> Root {
        guard directory.isFileURL else { throw CatalogCoordinationError.invalidCapability }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let catalogFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard catalogFD >= 0 else { throw posix("Katalogverzeichnis öffnen") }
        let catalog = FD(catalogFD)
        var existing = stat()
        if fstatat(catalogFD, Self.folderName, &existing, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw posix("Koordinationsverzeichnis prüfen") }
            try publishNewRoot(in: catalogFD)
        }
        let coordinationFD = openat(catalogFD, Self.folderName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard coordinationFD >= 0 else { throw CatalogCoordinationError.unknownJournal }
        let coordination = FD(coordinationFD)
        let markerFile = try readFile(coordinationFD, name: "owner.json", maximum: 1_024, capture: true)
        let marker: RootMarker = try canonicalDecode(markerFile.data!)
        guard marker.schemaVersion == 1 else { throw CatalogCoordinationError.unknownJournal }
        return Root(catalog: catalog, coordination: coordination, marker: marker)
    }
    private func publishNewRoot(in catalog: Int32) throws {
        // Publish the owner and directory as one namespace operation. Independent
        // processes may prepare concurrently; RENAME_EXCL chooses one complete
        // root without ever adopting an existing unowned or damaged directory.
        try Task.checkCancellation()
        let stageName = Self.rootStagePrefix + UUID().uuidString.lowercased() + ".stage"
        guard mkdirat(catalog, stageName, 0o700) == 0 else { throw posix("Koordinationswurzel vorbereiten") }
        var created = stat()
        guard fstatat(catalog, stageName, &created, AT_SYMLINK_NOFOLLOW) == 0,
              created.st_mode & S_IFMT == S_IFDIR else { throw CatalogCoordinationError.invalidCapability }
        let stageFD = openat(catalog, stageName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard stageFD >= 0 else { throw posix("Koordinationsstage öffnen") }
        let stage = FD(stageFD)
        var opened = stat()
        guard fstat(stage.value, &opened) == 0, created.st_dev == opened.st_dev, created.st_ino == opened.st_ino else {
            throw CatalogCoordinationError.invalidCapability
        }
        var owner: FD?, published = false
        defer {
            // Cleanup has only creation-time authority over our own file and
            // empty directory. Replacements/unknown entries are never removed.
            if !published, (try? requireNamed(stage.value, parent: catalog, name: stageName, directory: true)) != nil {
                if let owner, (try? requireNamed(owner.value, parent: stage.value, name: "owner.json")) != nil {
                    _ = unlinkat(stage.value, "owner.json", 0)
                }
                _ = unlinkat(catalog, stageName, AT_REMOVEDIR)
            }
        }
        try requireNamed(stage.value, parent: catalog, name: stageName, directory: true)
        let reservation = try EditingDatabaseAccess.reserveNativeFile()
        let ownerFD = openat(stage.value, "owner.json", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard ownerFD >= 0 else { throw posix("Koordinationsowner anlegen") }
        owner = FD(ownerFD, editingOwnership: reservation.own(ownerFD))
        let marker = RootMarker(schemaVersion: 1, rootOwnerID: UUID())
        try write(EditingContractJSON.encoder().encode(marker), to: ownerFD)
        guard fsync(ownerFD) == 0, fsync(stage.value) == 0 else { throw posix("Koordinationsowner sichern") }
        try requireNamed(stage.value, parent: catalog, name: stageName, directory: true)
        try requireNamed(ownerFD, parent: stage.value, name: "owner.json")
        try Task.checkCancellation()
        if renameatx_np(catalog, stageName, catalog, Self.folderName, UInt32(RENAME_EXCL)) == 0 {
            published = true
            guard fsync(catalog) == 0 else { throw posix("Koordinationsverzeichnis sichern") }
        } else if errno != EEXIST {
            throw posix("Koordinationswurzel veröffentlichen")
        }
        // A concurrent winner is reopened and validated by openRoot. A crash
        // before the rename leaves only an inert sibling stage, never a half root.
    }
    private func requireCurrentRoot(_ root: Root) throws {
        let current = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw CatalogCoordinationError.invalidCapability }
        defer { close(current) }
        guard sameFile(current, root.catalog.value) else { throw CatalogCoordinationError.invalidCapability }
        try requireNamed(root.coordination.value, parent: root.catalog.value, name: Self.folderName, directory: true)
        let file = try readFile(root.coordination.value, name: "owner.json", maximum: 1_024, capture: true)
        let marker: RootMarker = try canonicalDecode(file.data!)
        guard marker == root.marker else { throw CatalogCoordinationError.invalidCapability }
    }
    private func requireOperation(_ operation: Operation) throws {
        try requireCurrentRoot(operation.root)
        try requireNamed(operation.directory.value, parent: operation.root.coordination.value, name: operation.name, directory: true)
        let file = try readFile(operation.directory.value, name: "descriptor.json", maximum: 65_536, capture: true)
        let current: DurableCatalogStageDescriptor = try canonicalDecode(file.data!)
        guard current == operation.descriptor else { throw CatalogCoordinationError.invalidCapability }
    }
    private func locked<T>(_ root: Root, operation: () throws -> T) throws -> T {
        try requireCurrentRoot(root)
        let ownership = try EditingDatabaseAccess.reserveNativeFile()
        let fd = openat(root.coordination.value, "coordination-write.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CatalogCoordinationError.invalidCapability }
        ownership.own(fd); defer { ownership.close() }
        try requireNamed(fd, parent: root.coordination.value, name: "coordination-write.lock")
        while flock(fd, LOCK_EX) != 0 { if errno != EINTR { throw posix("Katalogkoordination sperren") } }
        defer { _ = flock(fd, LOCK_UN) }
        try requireCurrentRoot(root)
        try requireNamed(fd, parent: root.coordination.value, name: "coordination-write.lock")
        return try operation()
    }

    private func readFile(_ parent: Int32, name: String, maximum: Int, capture: Bool) throws -> OpenFile {
        let ownership = try EditingDatabaseAccess.reserveNativeFile()
        let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw posix("Koordinationsdaten öffnen") }
        let handle = FD(fd, editingOwnership: ownership.own(fd))
        try requireNamed(fd, parent: parent, name: name)
        var initial = stat()
        guard fstat(fd, &initial) == 0, initial.st_size > 0, initial.st_size <= maximum else { throw ArtifactContractError.limitExceeded }
        var data = Data(), hasher = SHA256(), count: Int64 = 0
        let chunk = UnsafeMutableRawPointer.allocate(byteCount: 65_536, alignment: 16)
        defer { chunk.deallocate() }
        while count < initial.st_size {
            let n = pread(fd, chunk, min(65_536, Int(initial.st_size - count)), off_t(count))
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw CatalogCoordinationError.missingPreparedPayload }
            autoreleasepool {
                let bytes = Data(bytes: chunk, count: n)
                hasher.update(data: bytes)
                if capture { data.append(bytes) }
            }
            count += Int64(n)
        }
        var final = stat()
        guard fstat(fd, &final) == 0, Stamp(initial) == Stamp(final) else { throw CatalogCoordinationError.invalidCapability }
        try requireNamed(fd, parent: parent, name: name)
        let descriptor = try ArtifactFileDescriptor(sha256: ArtifactDigest(sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()), bytes: count)
        return OpenFile(handle: handle, descriptor: descriptor, stamp: Stamp(final), data: capture ? data : nil)
    }
    private static func readPinned(_ file: OpenFile, offset: Int64, maximum: Int) throws -> Data {
        guard offset >= 0, offset <= file.descriptor.bytes, (1...65_536).contains(maximum) else { throw ArtifactContractError.limitExceeded }
        var before = stat()
        guard fstat(file.handle.value, &before) == 0, Stamp(before) == file.stamp else { throw CatalogCoordinationError.invalidCapability }
        let count = min(maximum, Int(file.descriptor.bytes - offset))
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var done = 0
            while done < count {
                let n = pread(file.handle.value, bytes.baseAddress!.advanced(by: done), count - done, off_t(offset + Int64(done)))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw CatalogCoordinationError.missingPreparedPayload }
                done += n
            }
        }
        var after = stat()
        guard fstat(file.handle.value, &after) == 0, Stamp(after) == file.stamp else { throw CatalogCoordinationError.invalidCapability }
        return result
    }
    private func writeNew(_ data: Data, name: String, in parent: Int32) throws {
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CatalogCoordinationError.invalidCapability }
        defer { close(fd) }
        try write(data, to: fd)
        guard fsync(fd) == 0, fsync(parent) == 0 else { throw posix("Koordinationsdaten sichern") }
    }
    private func replace(_ data: Data, name: String, in parent: Int32, expected: Data) throws {
        let old = try readFile(parent, name: name, maximum: 65_536, capture: true)
        guard old.data == expected else { throw CatalogCoordinationError.invalidPhase }
        let temporary = ".write-" + UUID().uuidString.lowercased()
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CatalogCoordinationError.invalidCapability }
        var moved = false
        defer {
            if !moved, (try? requireNamed(fd, parent: parent, name: temporary)) != nil { _ = unlinkat(parent, temporary, 0) }
            close(fd)
        }
        try write(data, to: fd)
        guard fsync(fd) == 0 else { throw posix("Katalogjournal sichern") }
        try requireNamed(old.handle.value, parent: parent, name: name)
        guard renameat(parent, temporary, parent, name) == 0 else { throw posix("Katalogjournal publizieren") }
        moved = true
        guard fsync(parent) == 0 else { throw posix("Katalogjournal sichern") }
    }
    private func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw posix("Koordinationsdaten schreiben") }
                offset += n
            }
        }
    }
    private func names(_ fd: Int32, maximum: Int) throws -> [String] {
        // A new directory FD has an independent cursor; dup would share offsets.
        let scan = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard scan >= 0 else { throw CatalogCoordinationError.invalidCapability }
        guard let stream = fdopendir(scan) else { close(scan); throw posix("Koordinationsverzeichnis lesen") }
        defer { closedir(stream) }
        var output: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard output.count < maximum else { throw ArtifactContractError.limitExceeded }
            output.append(name)
            errno = 0
        }
        guard errno == 0 else { throw posix("Koordinationsverzeichnis lesen") }
        return output.sorted()
    }
    private func canonicalDecode<T: Codable>(_ data: Data) throws -> T {
        let value = try EditingContractJSON.decoder().decode(T.self, from: data)
        guard try EditingContractJSON.encoder().encode(value) == data else { throw CatalogCoordinationError.unknownJournal }
        return value
    }
    private func requireNamed(_ fd: Int32, parent: Int32, name: String, directory: Bool = false) throws {
        var owned = stat(), named = stat()
        let kind = directory ? S_IFDIR : S_IFREG
        guard fstat(fd, &owned) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              owned.st_mode & S_IFMT == kind, named.st_mode & S_IFMT == kind,
              directory || (owned.st_nlink == 1 && named.st_nlink == 1),
              owned.st_dev == named.st_dev, owned.st_ino == named.st_ino else { throw CatalogCoordinationError.invalidCapability }
    }
    private func sameFile(_ a: Int32, _ b: Int32) -> Bool {
        var x = stat(), y = stat()
        return fstat(a, &x) == 0 && fstat(b, &y) == 0 && x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }
    private func duplicate(_ fd: Int32) throws -> Int32 {
        let value = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard value >= 0 else { throw posix("Katalog-Dateihandle halten") }
        return value
    }
    private func reference(_ file: ArtifactFileDescriptor) -> MetadataCatalogFileReference {
        .present(sha256: file.sha256.sha256, byteCount: file.bytes)
    }
    private func posix(_ message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension CatalogRepository: CoordinatedCatalogPayloads {
    public func coordinationRootIdentity() throws -> UUID { try coordinationFiles.rootIdentity() }
    public func prepareDurableCatalogStage(_ prepared: PreparedLibraryCatalog,
                         descriptor: DurableCatalogStageDescriptor) throws -> DurableCatalogStage {
        // Creation is part of the coordinator's single command+journal write.
        // This public reopening path never creates authority from a descriptor.
        let values = try coordinationFiles.pendingValues()
        guard let value = values.first(where: { $0.requestSHA256 == descriptor.coordinatorRequestSHA256 && $0.body.catalog == descriptor.payload }) else {
            throw CatalogCoordinationError.invalidCapability
        }
        let journal = ValidatedCatalogCoordinatorJournal(value: value, ownerID: descriptor.payload.rootOwnerID, nonce: UUID())
        guard prepared.reference == descriptor.payload.after else { throw CatalogCoordinationError.invalidCapability }
        switch try coordinationFiles.inspect(journal) {
        case .exactBefore(let stage): return stage
        default: throw CatalogCoordinationError.invalidPhase
        }
    }
    public func inspectCatalogRecovery(_ journal: ValidatedCatalogCoordinatorJournal) throws -> CatalogRecoveryEvidence {
        try coordinationFiles.inspect(journal)
    }
    public func publishDurableCatalogStage(_ stage: DurableCatalogStage,
                         armedBy: ArmedCatalogCoordination) throws -> CatalogPublicationEvidence {
        try coordinationFiles.publish(stage, armed: armedBy)
    }
    public func abortPreparedCatalogStage(_ stage: DurableCatalogStage, decision: CatalogCoordinationAbort) throws {
        guard stage.descriptor.payload == decision.journal.value.body.catalog else { throw CatalogCoordinationError.invalidCapability }
        try coordinationFiles.cleanup(decision.journal, abort: true)
    }
    public func cleanupCompletedCatalogStage(_ journal: ValidatedCatalogCoordinatorJournal) throws {
        try coordinationFiles.cleanup(journal, abort: false)
    }
}
