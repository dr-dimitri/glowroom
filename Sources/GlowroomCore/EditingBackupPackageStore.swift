import Foundation
import Darwin

public struct EditingBackupPackageStore: EditingBackupPackageIO, Sendable {
    public typealias ClosedSQLValidator = @Sendable (URL, ArtifactFileReadHandle) async throws -> ClosedEditingSQLSnapshot
    private let resources: any ArtifactResourceAdmitting
    private let validateSQL: ClosedSQLValidator
    private let catalog: CatalogRepository?
    public init(resources: any ArtifactResourceAdmitting, catalog: CatalogRepository? = nil) {
        self.resources = resources; self.catalog = catalog
        validateSQL = { url, handle in try await EditingClosedSQLValidator.validate(privateStagedSQLURL: url, pinnedOwnership: handle) }
    }
    public init(resources: any ArtifactResourceAdmitting, validateClosedSQL: @escaping ClosedSQLValidator,
                catalog: CatalogRepository? = nil) {
        self.resources = resources; validateSQL = validateClosedSQL; self.catalog = catalog
    }
    private struct PackageOwner: Codable { let schemaVersion: Int; let application: String; let operation: UUID }
    public func write(_ source: EditingBackupSource, toNew destination: URL,
                      limits: EditingPackageLimits) async throws -> PublishedEditingBackup {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "glowroombackup" else { throw ArtifactContractError.invalidValue("Neues .glowroombackup-Verzeichnis erforderlich") }
        let ids = Set(source.snapshot.referencedArtifacts.map(\.id))
        let sourceStoreID = await source.artifactStore.storeID
        guard ids.count == source.snapshot.referencedArtifacts.count,
              source.lease.artifactIDs == ids, source.lease.storeID == sourceStoreID else { throw ArtifactContractError.invalidCapability }
        let result = try await writeSnapshot(source.snapshot, kind: source.kind, preservedManifest: nil,
            toNew: destination, limits: limits, registerAutomatic: true, protectOriginals: false) { id, role in
                try await source.artifactStore.openVerifiedFile(id, role: role)
            }
        withExtendedLifetime(source) {}; return result
    }
    public func export(from source: URL, toNew destination: URL,
                       limits: EditingPackageLimits) async throws -> PublishedEditingBackup {
        guard catalog != nil else { throw ArtifactContractError.invalidValue("Paketexport benötigt einen aktuellen Katalogschutz") }
        let verified = try await validate(from: source, limits: limits)
        let result = try await writeSnapshot(verified.snapshot, kind: verified.manifest.kind,
            preservedManifest: verified.manifest, toNew: destination, limits: limits,
            registerAutomatic: false, protectOriginals: true) { id, role in
                try await verified.openArtifactFile(id, role)
            }
        withExtendedLifetime(verified) {}; return result
    }
    private func writeSnapshot(_ snapshot: ClosedEditingSQLSnapshot, kind: EditingBackupKind,
                               preservedManifest: EditingBackupManifest?, toNew destination: URL,
                               limits: EditingPackageLimits, registerAutomatic: Bool, protectOriginals: Bool,
                               open: @escaping @Sendable (GeneratedArtifactID, ArtifactPayloadRole) async throws -> ArtifactFileReadHandle) async throws -> PublishedEditingBackup {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "glowroombackup" else { throw ArtifactContractError.invalidValue("Neues .glowroombackup-Verzeichnis erforderlich") }
        let parent = try ArtifactFileIO.root(destination.deletingLastPathComponent(), create: false)
        let name = destination.lastPathComponent
        try ArtifactFileIO.validLeaf(name)
        var target = stat()
        guard fstatat(parent.fd.value, name, &target, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw ArtifactContractError.invalidValue("Sicherungsziel existiert bereits") }
        let stage = try newDirectory(parent, ".glowroombackup-\(UUID().uuidString.lowercased()).stage")
        let stageOwnership = try ArtifactPrivateStageOwnership(stage: stage)
        let stageLease = ArtifactLease(storeID: .init(), artifactIDs: [], purpose: .restore, nonce: UUID(), releaseOwnership: { withExtendedLifetime(stageOwnership) {} })
        let owner = PackageOwner(schemaVersion: 1, application: "Glowroom.EditingBackup", operation: UUID())
        try ArtifactFileIO.writeSmall(stage, ".package-owner.json", bytes: EditingContractJSON.encoder().encode(owner), ownership: stageOwnership)
        let sql = try await copy(snapshot.database, to: stage, name: "edits.sqlite", expected: nil, ownership: stageOwnership)
        let stagedSQL = try ArtifactFileIO.openFile(stage, "edits.sqlite", limit: limits.maximumPayloadBytes)
        let sqlHandle = try stagedSQL.handle(ownership: stageLease, expected: sql)
        let closed = try await checkedSQL(stage, handle: sqlHandle)
        guard closed.sourceStoreEpoch == snapshot.sourceStoreEpoch,
              Self.sameArtifacts(closed.referencedArtifacts, snapshot.referencedArtifacts) else { throw ArtifactContractError.corruptArtifact }
        let artifacts = closed.referencedArtifacts.sorted { $0.id.canonicalString < $1.id.canonicalString }
        let manifest = preservedManifest ?? EditingBackupManifest(kind: kind, createdAt: Date(), sourceStoreEpoch: closed.sourceStoreEpoch,
            database: sql, artifacts: artifacts)
        guard manifest.sourceStoreEpoch == closed.sourceStoreEpoch, manifest.database == sql,
              Self.sameArtifacts(manifest.artifacts, artifacts) else { throw ArtifactContractError.corruptArtifact }
        let bytes = try EditingContractJSON.encoder().encode(manifest)
        try Self.checkLimits(manifest, encodedCount: bytes.count, limits: limits)
        let artifactRoot = try newDirectory(stage, "artifacts", ownership: stageOwnership)
        try await copyArtifacts(artifacts, into: artifactRoot, ownership: stageOwnership, open: open)
        try ArtifactFileIO.writeSmall(stage, "manifest.json", bytes: bytes, limit: limits.maximumManifestBytes, ownership: stageOwnership)
        _ = try await validateTree(stage, manifest: manifest, limits: limits, sqlHandle: sqlHandle)
        guard fsync(stage.fd.value) == 0 else { throw ArtifactFileIO.failure("Paketstage synchronisieren") }
        if protectOriginals {
            guard let catalog else { throw ArtifactContractError.invalidCapability }
            let inventory = try stageOwnership.inventory()
            try catalog.withBackupExportProtection(destination: destination) {
                try inventory.preflight(stage: stage)
                try ArtifactFileIO.exclusiveMove(parent, name: stage.leaf!, to: parent, newName: name)
            }
        } else if registerAutomatic && kind == .automatic {
            try publishAutomatic(stage, ownership: stageOwnership, parent: parent, destination: name,
                operation: owner.operation, manifestBytes: bytes)
        } else { try ArtifactFileIO.exclusiveMove(parent, name: stage.leaf!, to: parent, newName: name) }
        stageOwnership.disarmAfterPublication()
        // Namespace rename is the commit point. No throwing cleanup follows it.
        return PublishedEditingBackup(url: destination, manifest: manifest)
    }
    public func validate(from url: URL, limits: EditingPackageLimits) async throws -> ValidatedEditingBackup {
        guard url.isFileURL else { throw ArtifactContractError.invalidValue("Lokale Sicherung erforderlich") }
        let temporaryParent = try ArtifactFileIO.root(FileManager.default.temporaryDirectory, create: false)
        let stage = try newDirectory(temporaryParent, "glowroom-backup-validation-" + UUID().uuidString.lowercased())
        let stageOwnership = try ArtifactPrivateStageOwnership(stage: stage)
        let stageLease = ArtifactLease(storeID: .init(), artifactIDs: [], purpose: .restore, nonce: UUID(), releaseOwnership: { withExtendedLifetime(stageOwnership) {} })
        let owner = PackageOwner(schemaVersion: 1, application: "Glowroom.EditingBackup", operation: UUID())
        try ArtifactFileIO.writeSmall(stage, ".package-owner.json", bytes: EditingContractJSON.encoder().encode(owner), ownership: stageOwnership)
        let stagingLease = stageLease
        let manifest: EditingBackupManifest
        if url.pathExtension.lowercased() == "sqlite" {
            let externalParent = try ArtifactFileIO.root(url.deletingLastPathComponent(), create: false)
            let file = try ArtifactFileIO.openFile(externalParent, url.lastPathComponent, limit: limits.maximumPayloadBytes)
            let descriptor = try await withTransfer { try file.handle(ownership: nil) }
            _ = try await copy(descriptor, to: stage, name: "edits.sqlite", expected: nil, ownership: stageOwnership)
            let sql = try ArtifactFileIO.openFile(stage, "edits.sqlite", limit: limits.maximumPayloadBytes)
            let handle = try sql.handle(ownership: stagingLease)
            let closed = try await checkedSQL(stage, handle: handle)
            guard closed.referencedArtifacts.isEmpty else { throw ArtifactContractError.invalidValue("SQLite-Datei enthält Artefaktreferenzen ohne Payloads") }
            manifest = EditingBackupManifest(kind: .manual, createdAt: Date(), sourceStoreEpoch: closed.sourceStoreEpoch,
                database: try .init(sha256: handle.sha256, bytes: handle.bytes), artifacts: [])
            _ = try newDirectory(stage, "artifacts", ownership: stageOwnership)
            let bytes = try EditingContractJSON.encoder().encode(manifest)
            try ArtifactFileIO.writeSmall(stage, "manifest.json", bytes: bytes, limit: limits.maximumManifestBytes, ownership: stageOwnership)
        } else {
            guard url.pathExtension.lowercased() == "glowroombackup" else { throw ArtifactContractError.unsupportedFormat }
            let external = try ArtifactFileIO.root(url, create: false)
            let bytes = try ArtifactFileIO.readSmall(external, "manifest.json", limit: limits.maximumManifestBytes)
            manifest = try ArtifactJSONCodec.decode(EditingBackupManifest.self, from: bytes, maximum: limits.maximumManifestBytes)
            guard try EditingContractJSON.encoder().encode(manifest) == bytes else { throw ArtifactContractError.corruptArtifact }
            try Self.checkLimits(manifest, encodedCount: bytes.count, limits: limits)
            try checkNames(external, expected: ["manifest.json", "edits.sqlite", "artifacts"], optional: [".package-owner.json"])
            let sourceSQL = try ArtifactFileIO.openFile(external, "edits.sqlite", limit: limits.maximumPayloadBytes)
            let sqlHandle = try await withTransfer { try sourceSQL.handle(ownership: nil, expected: manifest.database) }
            _ = try await copy(sqlHandle, to: stage, name: "edits.sqlite", expected: manifest.database, ownership: stageOwnership)
            let externalArtifacts = try ArtifactFileIO.child(external, "artifacts")
            try checkNames(externalArtifacts, expected: Set(manifest.artifacts.map { $0.id.canonicalString }))
            // Check the entire exact fixed-role tree before any later DB restore.
            for artifact in manifest.artifacts {
                let directory = try ArtifactFileIO.child(externalArtifacts, artifact.id.canonicalString)
                try checkNames(directory, expected: Set(GeneratedArtifactStore.payloadNames(artifact)))
            }
            try checkActualTotals(external, limits: limits)
            let destination = try newDirectory(stage, "artifacts", ownership: stageOwnership)
            try await copyArtifacts(manifest.artifacts, into: destination, ownership: stageOwnership) { id, role in
                guard let artifact = manifest.artifacts.first(where: { $0.id == id }) else { throw ArtifactContractError.corruptArtifact }
                let directory = try ArtifactFileIO.child(externalArtifacts, id.canonicalString)
                let (name, expected) = try GeneratedArtifactStore.file(role, artifact: artifact)
                return try await withTransfer { try ArtifactFileIO.openFile(directory, name, limit: expected.bytes).handle(ownership: nil, expected: expected) }
            }
            try ArtifactFileIO.writeSmall(stage, "manifest.json", bytes: bytes, limit: limits.maximumManifestBytes, ownership: stageOwnership)
        }
        let sql = try ArtifactFileIO.openFile(stage, "edits.sqlite", limit: limits.maximumPayloadBytes)
        let sqlHandle = try await withTransfer { try sql.handle(ownership: stagingLease, expected: manifest.database) }
        let closed = try await validateTree(stage, manifest: manifest, limits: limits, sqlHandle: sqlHandle)
        let artifactRoot = try ArtifactFileIO.child(stage, "artifacts")
        return ValidatedEditingBackup(manifest: manifest, snapshot: closed, openArtifactFile: { id, role in
            guard let artifact = manifest.artifacts.first(where: { $0.id == id }) else { throw ArtifactContractError.corruptArtifact }
            let (name, expected) = try GeneratedArtifactStore.file(role, artifact: artifact)
            let directory = try ArtifactFileIO.child(artifactRoot, id.canonicalString)
            return try await withTransfer { try ArtifactFileIO.openFile(directory, name, limit: expected.bytes).handle(ownership: stagingLease, expected: expected) }
        }, stagingOwnership: stagingLease)
    }
    private func checkedSQL(_ stage: ArtifactDirectory, handle: ArtifactFileReadHandle) async throws -> ClosedEditingSQLSnapshot {
        let result = try await validateSQL(stage.url.appendingPathComponent("edits.sqlite"), handle)
        guard result.database === handle else { throw ArtifactContractError.invalidCapability }
        return result
    }
    private func validateTree(_ stage: ArtifactDirectory, manifest: EditingBackupManifest,
                              limits: EditingPackageLimits, sqlHandle: ArtifactFileReadHandle) async throws -> ClosedEditingSQLSnapshot {
        let bytes = try EditingContractJSON.encoder().encode(manifest)
        try Self.checkLimits(manifest, encodedCount: bytes.count, limits: limits)
        try checkNames(stage, expected: ["manifest.json", "edits.sqlite", "artifacts"], optional: [".package-owner.json"])
        let closed = try await checkedSQL(stage, handle: sqlHandle)
        guard closed.sourceStoreEpoch == manifest.sourceStoreEpoch, Self.sameArtifacts(closed.referencedArtifacts, manifest.artifacts),
              sqlHandle.sha256 == manifest.database.sha256, sqlHandle.bytes == manifest.database.bytes else { throw ArtifactContractError.corruptArtifact }
        let root = try ArtifactFileIO.child(stage, "artifacts")
        try checkNames(root, expected: Set(manifest.artifacts.map { $0.id.canonicalString }))
        for artifact in manifest.artifacts {
            let directory = try ArtifactFileIO.child(root, artifact.id.canonicalString)
            try checkNames(directory, expected: Set(GeneratedArtifactStore.payloadNames(artifact)))
            guard try GeneratedArtifactStore.readArtifact(directory) == artifact else { throw ArtifactContractError.corruptArtifact }
            let raster = try ArtifactFileIO.openFile(directory, "raster.png")
            _ = try await withTransfer { try raster.handle(ownership: nil, expected: artifact.raster.file) }
            try await ArtifactPNGCodec.validate(raster, raster: artifact.raster, resources: resources)
            for mask in artifact.resources {
                let file = try ArtifactFileIO.openFile(directory, GeneratedArtifactStore.maskName(mask.id))
                _ = try await withTransfer { try file.handle(ownership: nil, expected: mask.file) }
                try await ArtifactPNGCodec.validateMask(file, descriptor: mask, resources: resources,
                    binding: artifact.provenance.maskBindings?.first(where: { $0.resourceID == mask.id }))
            }
            for binding in artifact.provenance.maskBindings ?? [] {
                let file = try ArtifactFileIO.openFile(directory, GeneratedArtifactStore.maskDocumentName(binding.resourceID), limit: binding.documentFile.bytes)
                _ = try await withTransfer { try file.handle(ownership: nil, expected: binding.documentFile) }
                try await MaskPayloadValidation.validateDocument(file, binding: binding, resources: resources)
            }
        }
        try checkActualTotals(stage, limits: limits)
        return closed
    }
    private func checkActualTotals(_ stage: ArtifactDirectory, limits: EditingPackageLimits) throws {
        var total: Int64 = 0; var count = 0
        func add(_ directory: ArtifactDirectory, _ name: String) throws {
            let file = try ArtifactFileIO.openFile(directory, name, limit: limits.maximumPayloadBytes)
            guard total <= limits.maximumTotalBytes - file.stamp.bytes, count < limits.maximumFiles else { throw ArtifactContractError.limitExceeded }
            total += file.stamp.bytes; count += 1
        }
        for name in try ArtifactFileIO.names(stage) where name != "artifacts" { try add(stage, name) }
        let artifacts = try ArtifactFileIO.child(stage, "artifacts")
        for id in try ArtifactFileIO.names(artifacts) {
            let directory = try ArtifactFileIO.child(artifacts, id)
            for name in try ArtifactFileIO.names(directory) { try add(directory, name) }
        }
    }
    private func copyArtifacts(_ artifacts: [GeneratedArtifact], into root: ArtifactDirectory, ownership: ArtifactPrivateStageOwnership,
                               open: @escaping @Sendable (GeneratedArtifactID, ArtifactPayloadRole) async throws -> ArtifactFileReadHandle) async throws {
        // Two fixed workers overlap independent file IO; no task per artifact.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<min(2, artifacts.count) {
                group.addTask {
                    for index in stride(from: worker, to: artifacts.count, by: 2) {
                        let artifact = artifacts[index]; let directory = try newDirectory(root, artifact.id.canonicalString, ownership: ownership)
                        let roles = GeneratedArtifactStore.payloadRoles(artifact)
                        for role in roles {
                            let (name, expected) = try GeneratedArtifactStore.file(role, artifact: artifact)
                            // Acquire the source handle BEFORE our copy slot:
                            // its own verification may need the same two slots.
                            let handle = try await open(artifact.id, role)
                            _ = try await copy(handle, to: directory, name: name, expected: expected, ownership: ownership)
                        }
                        guard fsync(directory.fd.value) == 0 else { throw ArtifactFileIO.failure("Artefakt-Paketverzeichnis synchronisieren") }
                    }
                }
            }; try await group.waitForAll()
        }
        guard fsync(root.fd.value) == 0 else { throw ArtifactFileIO.failure("Paket-Artefaktwurzel synchronisieren") }
    }
    private func copy(_ handle: ArtifactFileReadHandle, to directory: ArtifactDirectory, name: String,
                      expected: ArtifactFileDescriptor?, ownership: ArtifactPrivateStageOwnership) async throws -> ArtifactFileDescriptor {
        if let expected { guard handle.bytes == expected.bytes, handle.sha256 == expected.sha256 else { throw ArtifactContractError.corruptArtifact } }
        return try await withTransfer { try ArtifactFileIO.copy(handle, into: directory, leaf: name, ownership: ownership) }
    }
    private func withTransfer<T: Sendable>(_ operation: @Sendable () throws -> T) async throws -> T {
        let slot = try await resources.acquire(kind: .transfer, bytes: 65_536, priority: .background, retaining: [])
        defer { withExtendedLifetime(slot) {} }; return try operation()
    }
    private func newDirectory(_ parent: ArtifactDirectory, _ name: String, ownership: ArtifactPrivateStageOwnership? = nil) throws -> ArtifactDirectory {
        try parent.validate(); try ArtifactFileIO.validLeaf(name)
        guard mkdirat(parent.fd.value, name, 0o700) == 0 else { throw ArtifactFileIO.failure("Eigenen Paketstage exklusiv erstellen") }
        let directory = try ArtifactFileIO.child(parent, name)
        try ownership?.recordDirectory(directory); return directory
    }
    private func checkNames(_ directory: ArtifactDirectory, expected: Set<String>, optional: Set<String> = []) throws {
        let actual = Set(try ArtifactFileIO.names(directory))
        guard expected.isSubset(of: actual), actual.isSubset(of: expected.union(optional)) else { throw ArtifactContractError.corruptArtifact }
        // Even optional known metadata must be a bounded regular single-link file.
        for name in actual.intersection(optional) { _ = try ArtifactFileIO.openFile(directory, name, limit: 4_096) }
    }
    internal static func sameArtifacts(_ a: [GeneratedArtifact], _ b: [GeneratedArtifact]) -> Bool {
        a.count == b.count && Set(a.map(\.id)).count == a.count && Set(b.map(\.id)).count == b.count && Set(a) == Set(b)
    }
    private static func checkLimits(_ manifest: EditingBackupManifest, encodedCount: Int, limits: EditingPackageLimits) throws {
        try ArtifactValueValidation.backup(manifest)
        guard manifest.schemaVersion == 1 else { throw ArtifactContractError.unsupportedVersion(manifest.schemaVersion) }
        guard manifest.createdAt.timeIntervalSinceReferenceDate.isFinite, encodedCount <= limits.maximumManifestBytes,
              manifest.artifacts.count <= limits.maximumArtifacts, Set(manifest.artifacts.map(\.id)).count == manifest.artifacts.count else { throw ArtifactContractError.limitExceeded }
        var total = Int64(encodedCount); var files = 2
        func add(_ bytes: Int64) throws { guard bytes > 0, bytes <= limits.maximumPayloadBytes, total <= limits.maximumTotalBytes - bytes else { throw ArtifactContractError.limitExceeded }; total += bytes }
        try add(manifest.database.bytes)
        for artifact in manifest.artifacts {
            let body = try EditingContractJSON.encoder().encode(GeneratedArtifactManifest(id: artifact.id, raster: artifact.raster, provenance: artifact.provenance, resources: artifact.resources))
            guard body.count <= limits.maximumArtifactManifestBytes else { throw ArtifactContractError.limitExceeded }
            let reconstructed = try GeneratedArtifactStore.artifact(EditingContractJSON.decoder().decode(GeneratedArtifactManifest.self, from: body), bytes: body)
            guard reconstructed == artifact else { throw ArtifactContractError.corruptArtifact }
            try add(Int64(body.count)); try add(artifact.raster.file.bytes); files += 2
            for resource in artifact.resources { try add(resource.file.bytes); files += 1 }
            for binding in artifact.provenance.maskBindings ?? [] { try add(binding.documentFile.bytes); files += 1 }
            guard files <= limits.maximumFiles else { throw ArtifactContractError.limitExceeded }
        }
        guard total <= limits.maximumTotalBytes, files <= limits.maximumFiles else { throw ArtifactContractError.limitExceeded }
    }
}

private extension EditingBackupPackageStore {
    struct DirectoryIdentity: Codable, Equatable, Sendable {
        let device: Int64; let inode: UInt64
        let birthSeconds: Int64; let birthNanos: Int64; let generation: UInt32
        init(_ stamp: ArtifactNativeStamp) {
            device = stamp.device; inode = stamp.inode; birthSeconds = stamp.birthSeconds
            birthNanos = stamp.birthNanos; generation = stamp.generation
        }
    }
    struct AutomaticReceipt: Codable, Sendable {
        let schemaVersion: Int
        let application: String
        let operation: UUID
        let destination: String
        let parent: DirectoryIdentity
        let manifestSHA256: ArtifactDigest
        let inventory: ArtifactOwnershipInventory
    }
    struct AutomaticCandidate: Sendable {
        let name: String
        let stamp: ArtifactNativeStamp
        let receipt: AutomaticReceipt
        let manifest: EditingBackupManifest
    }
    static var receiptLimit: Int { 8_388_608 }
    static func receiptName(_ operation: UUID) -> String { ".automatic-receipt-" + operation.uuidString.lowercased() + ".json" }
    static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func validDay(_ day: String) -> Bool {
        let bytes = Array(day.utf8)
        return bytes.count == 10 && bytes.enumerated().allSatisfy { index, byte in
            index == 4 || index == 7 ? byte == 45 : (48...57).contains(byte)
        }
    }
    func publishAutomatic(_ stage: ArtifactDirectory, ownership: ArtifactPrivateStageOwnership,
                          parent: ArtifactDirectory, destination: String, operation: UUID,
                          manifestBytes: Data) throws {
        let inventory = try ownership.inventory()
        let receipt = AutomaticReceipt(schemaVersion: 1, application: "Glowroom.AutomaticBackup", operation: operation,
            destination: destination, parent: DirectoryIdentity(try ArtifactFileIO.nativeStamp(parent.fd.value)),
            manifestSHA256: try ArtifactFileIO.digest(manifestBytes), inventory: inventory)
        let bytes = try EditingContractJSON.encoder().encode(receipt)
        guard bytes.count <= Self.receiptLimit else { throw ArtifactContractError.limitExceeded }
        try ArtifactFileIO.withAutomaticBackupLock(parent) {
            // Receipt is durable before the package namespace is published. A
            // crash in between leaves an inert receipt with no matching inode.
            try inventory.preflight(stage: stage)
            try checkReceiptBudget(parent, addingBytes: bytes.count)
            let leaf = Self.receiptName(operation)
            let file = try ArtifactFileIO.writeSmall(parent, leaf, bytes: bytes, limit: Self.receiptLimit)
            do { try ArtifactFileIO.exclusiveMove(parent, name: stage.leaf!, to: parent, newName: destination) }
            catch { ArtifactFileIO.removeOwnedFile(parent, leaf, fd: file.fd); throw error }
        }
    }
    func checkReceiptBudget(_ parent: ArtifactDirectory, addingBytes: Int) throws {
        let names = try ArtifactFileIO.names(parent).filter { $0.hasPrefix(".automatic-receipt-") && $0.hasSuffix(".json") }
        guard names.count < 64 else { throw ArtifactContractError.limitExceeded }
        var total = Int64(addingBytes)
        for name in names {
            let file = try ArtifactFileIO.openFile(parent, name, limit: Int64(Self.receiptLimit))
            guard file.stamp.bytes <= 67_108_864 - total else { throw ArtifactContractError.limitExceeded }
            total += file.stamp.bytes
        }
    }
    func automaticCandidates(_ parent: ArtifactDirectory) throws -> [AutomaticCandidate] {
        var result: [AutomaticCandidate] = []; var count = 0; var total: Int64 = 0
        for name in try ArtifactFileIO.names(parent) where name.hasPrefix(".automatic-receipt-") && name.hasSuffix(".json") {
            try Task.checkCancellation(); count += 1
            guard count <= 64 else { throw ArtifactContractError.limitExceeded }
            // Unknown/corrupt receipts and all their possible payloads remain.
            do {
                let file = try ArtifactFileIO.openFile(parent, name, limit: Int64(Self.receiptLimit))
                guard file.stamp.bytes <= 67_108_864 - total else { throw ArtifactContractError.limitExceeded }
                total += file.stamp.bytes
                let bytes = try ArtifactFileIO.readSmall(parent, name, limit: Self.receiptLimit)
                let receipt = try ArtifactJSONCodec.decode(AutomaticReceipt.self, from: bytes, maximum: Self.receiptLimit)
                guard receipt.schemaVersion == 1, receipt.application == "Glowroom.AutomaticBackup",
                      name == Self.receiptName(receipt.operation) else { continue }
                let candidate = AutomaticCandidate(name: name, stamp: file.stamp, receipt: receipt,
                    manifest: try automaticManifest(parent, receipt: receipt))
                try file.validate(); result.append(candidate)
            } catch is CancellationError { throw CancellationError() }
            catch ArtifactContractError.limitExceeded { throw ArtifactContractError.limitExceeded }
            catch { continue }
        }
        return result.sorted {
            if $0.manifest.createdAt != $1.manifest.createdAt { return $0.manifest.createdAt > $1.manifest.createdAt }
            return $0.receipt.destination < $1.receipt.destination
        }
    }
    func automaticManifest(_ parent: ArtifactDirectory, receipt: AutomaticReceipt) throws -> EditingBackupManifest {
        try ArtifactFileIO.validLeaf(receipt.destination)
        guard receipt.destination.hasSuffix(".glowroombackup"),
              receipt.parent == DirectoryIdentity(try ArtifactFileIO.nativeStamp(parent.fd.value)) else { throw ArtifactContractError.invalidCapability }
        try receipt.inventory.validate()
        let directory = try ArtifactFileIO.child(parent, receipt.destination)
        try receipt.inventory.preflight(stage: directory)
        let bytes = try ArtifactFileIO.readSmall(directory, "manifest.json", limit: EditSettings.maximumEncodedBytes)
        guard try ArtifactFileIO.digest(bytes) == receipt.manifestSHA256 else { throw ArtifactContractError.corruptArtifact }
        let manifest = try ArtifactJSONCodec.decode(EditingBackupManifest.self, from: bytes, maximum: EditSettings.maximumEncodedBytes)
        try Self.checkLimits(manifest, encodedCount: bytes.count, limits: EditingPackageLimits())
        guard manifest.kind == .automatic else { throw ArtifactContractError.invalidCapability }
        let ownerBytes = try ArtifactFileIO.readSmall(directory, ".package-owner.json", limit: 4_096)
        let owner = try ArtifactJSONCodec.decode(PackageOwner.self, from: ownerBytes, maximum: 4_096)
        guard owner.schemaVersion == 1, owner.application == "Glowroom.EditingBackup", owner.operation == receipt.operation else { throw ArtifactContractError.invalidCapability }
        var files: Set<[String]> = [["manifest.json"], ["edits.sqlite"], [".package-owner.json"]]
        var directories: Set<[String]> = [[], ["artifacts"]]
        for artifact in manifest.artifacts {
            let path = ["artifacts", artifact.id.canonicalString]; directories.insert(path)
            for name in GeneratedArtifactStore.payloadNames(artifact) { files.insert(path + [name]) }
        }
        guard Set(receipt.inventory.files.map(\.path)) == files,
              Set(receipt.inventory.directories.map(\.path)) == directories else { throw ArtifactContractError.invalidCapability }
        return manifest
    }
    func verifyCandidate(_ candidate: AutomaticCandidate, parent: ArtifactDirectory) throws -> ArtifactPinnedFile {
        let file = try ArtifactFileIO.openFile(parent, candidate.name, limit: Int64(Self.receiptLimit))
        guard file.stamp == candidate.stamp,
              try automaticManifest(parent, receipt: candidate.receipt) == candidate.manifest else { throw ArtifactContractError.sourceChanged }
        try file.validate(); return file
    }
    func backupDirectoryIfPresent(_ url: URL) throws -> ArtifactDirectory? {
        guard url.isFileURL else { throw ArtifactContractError.invalidValue("Lokales Sicherungsverzeichnis erforderlich") }
        do { return try ArtifactFileIO.root(url, create: false) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
    }
}

public extension EditingBackupPackageStore {
    func reusableAutomaticBackup(in directory: URL, day: String) async throws -> URL? {
        guard Self.validDay(day) else { throw ArtifactContractError.invalidValue("Sicherungstag yyyy-MM-dd") }
        guard let parent = try backupDirectoryIfPresent(directory) else { return nil }
        let candidate = try ArtifactFileIO.withAutomaticBackupLock(parent) {
            try automaticCandidates(parent).first { Self.dayStamp($0.manifest.createdAt) == day }
        }
        guard let candidate else { return nil }
        let url = directory.appendingPathComponent(candidate.receipt.destination, isDirectory: true)
        // Full SQL/closure/PNG/hash verification runs OUTSIDE the directory lock,
        // under the existing bounded transfer/codec resources.
        do {
            let validated = try await validate(from: url, limits: EditingPackageLimits())
            guard validated.manifest == candidate.manifest else { return nil }
            return try ArtifactFileIO.withAutomaticBackupLock(parent) {
                _ = try verifyCandidate(candidate, parent: parent)
                withExtendedLifetime(validated) {}; return url
            }
        } catch is CancellationError { throw CancellationError() }
        catch { return nil } // A new automatic backup can replace no old bytes.
    }
    func pruneAutomaticBackups(in directory: URL, keepingNewest: Int) async throws {
        guard (1...64).contains(keepingNewest) else { throw ArtifactContractError.limitExceeded }
        guard let parent = try backupDirectoryIfPresent(directory) else { return }
        guard let catalog else { throw ArtifactContractError.invalidValue("Automatische Rotation benötigt einen aktuellen Katalogschutz") }
        // Discover outside the catalog lock, then acquire locks only in the
        // shared order Catalog -> Backup. All identities are checked again.
        let candidates = try ArtifactFileIO.withAutomaticBackupLock(parent) {
            Array(try automaticCandidates(parent).dropFirst(keepingNewest))
        }
        guard !candidates.isEmpty else { return }
        let roots = candidates.map { directory.appendingPathComponent($0.receipt.destination, isDirectory: true) }
        try catalog.withBackupPruningProtection(deletionRoots: roots) { protected in
            guard protected.count == candidates.count else { throw ArtifactContractError.invalidCapability }
            try ArtifactFileIO.withAutomaticBackupLock(parent) {
                for (candidate, protectsOriginal) in zip(candidates, protected) where !protectsOriginal {
                    try Task.checkCancellation()
                    let receiptFile = try verifyCandidate(candidate, parent: parent)
                    let stage = try ArtifactFileIO.child(parent, candidate.receipt.destination)
                    // Whole-tree preflight precedes deletion; each leaf is then
                    // reopened nofollow/single-link and checked against CREATION,
                    // not scan-time, identity immediately before unlink.
                    try candidate.receipt.inventory.removeOwnedTree(stage: stage)
                    try receiptFile.validate()
                    ArtifactFileIO.removeOwnedFile(parent, candidate.name, fd: receiptFile.fd)
                }
            }
        }
    }
}
