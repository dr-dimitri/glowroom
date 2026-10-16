import CryptoKit
import Darwin
import Foundation
import CoreGraphics

public actor GeneratedArtifactStore: GeneratedArtifactStoring {
    public let storeID: ArtifactStoreID
    internal let root: ArtifactDirectory
    internal let staging: ArtifactDirectory
    internal nonisolated let resources: any ArtifactResourceAdmitting
    private let gate: CatalogLifecycleGate?
    private struct DraftEntry { let nonce: UUID; let artifact: GeneratedArtifact; let directory: ArtifactDirectory; var commit: EditingCommitID? }
    private var drafts: [ArtifactDraftID: DraftEntry] = [:]
    private var leases: [UUID: Set<GeneratedArtifactID>] = [:]
    private var publications: [UUID: (GeneratedArtifactID, EditingCommitID)] = [:]
    private var metadata: [GeneratedArtifactID: GeneratedArtifact] = [:]
    private var order: [GeneratedArtifactID] = []
    private struct ValidationKey: Hashable {
        let artifactID: GeneratedArtifactID
        let manifest: ArtifactDigest
        let role: ArtifactPayloadRole
    }
    // Successful native content validation only; no FDs, images or caller/JSON
    // supplied ownership. Fresh root/manifest/open checks precede every lookup.
    private var validatedPayloads: [ValidationKey: ArtifactNativeStamp] = [:]
    private var validationOrder: [ValidationKey] = []
    private var mutating = false
    private struct MutationWaiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private var waiting: [MutationWaiter] = []
    internal struct Owner: Codable { let schemaVersion: Int; let application: String; let storeID: ArtifactStoreID }
    internal struct StageOwner: Codable { let schemaVersion: Int; let storeID: ArtifactStoreID; let draftID: ArtifactDraftID; let artifactID: GeneratedArtifactID; let nonce: UUID }
    internal struct Publication: Codable { let schemaVersion: Int; let storeID: ArtifactStoreID; let artifactID: GeneratedArtifactID; let manifest: ArtifactDigest; let draftID: ArtifactDraftID?; let commitID: EditingCommitID? }
    private init(root: ArtifactDirectory, staging: ArtifactDirectory, storeID: ArtifactStoreID,
                 resources: any ArtifactResourceAdmitting, gate: CatalogLifecycleGate?) {
        self.root = root; self.staging = staging; self.storeID = storeID; self.resources = resources; self.gate = gate
    }
    /// Async nonisolated factory performs directory/owner IO off MainActor. The
    /// caller injects the one shared resource owner and production lifecycle gate.
    public static func open(in directory: URL, resources: any ArtifactResourceAdmitting,
                            lifecycleGate: CatalogLifecycleGate? = nil) async throws -> GeneratedArtifactStore {
        let catalog = try ArtifactFileIO.root(directory, create: true)
        let root = try ArtifactFileIO.child(catalog, "GeneratedArtifacts", create: true)
        let bytes: Data
        do { bytes = try ArtifactFileIO.readSmall(root, ".owner.json", limit: 4_096) }
        catch ArtifactContractError.missingArtifact {
            guard try ArtifactFileIO.names(root).isEmpty else { throw ArtifactContractError.invalidCapability }
            let owner = Owner(schemaVersion: 1, application: "PicEdit.GeneratedArtifacts", storeID: .init())
            let encoded = try EditingContractJSON.encoder().encode(owner)
            do { try ArtifactFileIO.writeSmall(root, ".owner.json", bytes: encoded, limit: 4_096); bytes = encoded }
            catch { bytes = try ArtifactFileIO.readSmall(root, ".owner.json", limit: 4_096) }
        }
        let owner = try ArtifactJSONCodec.decode(Owner.self, from: bytes, maximum: 4_096)
        guard owner.schemaVersion == 1, owner.application == "PicEdit.GeneratedArtifacts",
              try EditingContractJSON.encoder().encode(owner) == bytes else { throw ArtifactContractError.invalidCapability }
        let staging = try ArtifactFileIO.child(root, ".staging", create: true)
        return GeneratedArtifactStore(root: root, staging: staging, storeID: owner.storeID, resources: resources, gate: lifecycleGate)
    }
    private func beginMutation() async throws {
        try Task.checkCancellation()
        if !mutating { mutating = true; return }
        guard waiting.count < 64 else { throw ArtifactContractError.limitExceeded }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiting.append(MutationWaiter(id: id, continuation: continuation))
            }
        } onCancel: { Task { await self.cancelMutationWaiter(id) } }
        // A cancellation racing a grant owns the transferred slot and must
        // hand it on once. Removing a still-queued waiter never frees live work.
        do { try Task.checkCancellation() } catch { endMutation(); throw error }
    }
    private func cancelMutationWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func endMutation() {
        if waiting.isEmpty { mutating = false } else { waiting.removeFirst().continuation.resume() }
    }
    private func lease(_ ids: Set<GeneratedArtifactID>, purpose: ArtifactLeasePurpose,
                       draft: ArtifactDraftID? = nil, publication: UUID? = nil) throws -> ArtifactLease {
        guard leases.count < 16_384 else { throw ArtifactContractError.limitExceeded }
        let nonce = UUID(); leases[nonce] = ids
        return ArtifactLease(storeID: storeID, artifactIDs: ids, purpose: purpose, nonce: nonce) { [weak self] in
            Task { await self?.release(nonce, draft: draft, publication: publication) }
        }
    }
    private func release(_ nonce: UUID, draft: ArtifactDraftID?, publication: UUID?) {
        leases.removeValue(forKey: nonce)
        if let draft { drafts.removeValue(forKey: draft) }
        if let publication { publications.removeValue(forKey: publication) }
        // Final artifacts and abandoned stages are conservatively retained.
        // Lost Swift observers never authorize recursive filesystem deletion.
    }
    public func acquireLease(ids: Set<GeneratedArtifactID>, purpose: ArtifactLeasePurpose) async throws -> ArtifactLease {
        guard ids.count <= 4_096 else { throw ArtifactContractError.limitExceeded }
        for id in ids { _ = try await descriptor(id) }; return try lease(ids, purpose: purpose)
    }
    public nonisolated func stageRaster(_ input: ArtifactRasterInput, provenance: GenerationProvenance,
                            masks: [ArtifactMaskInput] = []) async throws -> ArtifactDraft {
        // Reserve before crossing the Store actor/mutation queue. A blocked
        // synchronous codec must never accumulate uncharged queued CGImages.
        try Self.validateProvenance(provenance)
        guard masks.count <= 16, Set(masks.map(\.id)).count == masks.count,
              Set(masks.map(\.id)) == Set(provenance.maskResourceIDs) else { throw ArtifactContractError.invalidValue("Maskenressourcen") }
        let info = try ArtifactPNGCodec.shape(input.image)
        guard info.size == provenance.placement.outputSize else { throw ArtifactContractError.invalidValue("Ausgabecanvas") }
        var inputBytes = input.memoryOwnership == nil ? info.nativeBytes : 0
        var retained: [ArtifactMemoryReservation] = []
        var caps: [ObjectIdentifier: (memory: ArtifactMemoryReservation, images: [ObjectIdentifier: Int64])] = [:]
        func bind(_ image: CGImage, _ memory: ArtifactMemoryReservation, _ bytes: Int64) {
            let capID = ObjectIdentifier(memory); var entry = caps[capID] ?? (memory, [:])
            entry.images[ObjectIdentifier(image)] = bytes; caps[capID] = entry
        }
        if let memory = input.memoryOwnership { bind(input.image, memory, info.nativeBytes) }
        for mask in masks {
            let expected = mask.coordinateSpace == .inputCanvas ? provenance.placement.inputSize : provenance.placement.outputSize
            let shape = try ArtifactPNGCodec.shape(mask.image, gray: true)
            guard shape.size == expected else { throw ArtifactContractError.invalidValue("Maskencanvas") }
            if let memory = mask.memoryOwnership { bind(mask.image, memory, shape.nativeBytes) }
            else { guard shape.nativeBytes <= 536_870_912 - inputBytes else { throw ArtifactContractError.limitExceeded }; inputBytes += shape.nativeBytes }
        }
        // A copied allocation cannot reuse another buffer's charge. Count the
        // same immutable CGImage reference once, but all distinct images per cap.
        for entry in caps.values {
            var bytes: Int64 = 0
            for value in entry.images.values {
                guard value <= 536_870_912 - bytes else { throw ArtifactContractError.limitExceeded }; bytes += value
            }
            try await resources.validate(entry.memory, minimumBytes: bytes); retained.append(entry.memory)
        }
        // Bare CGImage input has no proven existing charge, so reserve all its
        // actual rows conservatively; never invent a zero-cost caller buffer.
        var inputs: ArtifactResourceLease?
        if inputBytes > 0 {
            let allocation = try await resources.acquire(kind: .retainedMemory, bytes: inputBytes, priority: .interactive, retaining: retained)
            retained.append(try await resources.retain(bytes: inputBytes, from: allocation)); inputs = allocation
        }
        defer { withExtendedLifetime((inputs, retained, input, masks)) {} }
        return try await stageReserved(input, provenance: provenance, masks: masks, retained: retained)
    }
    private func stageReserved(_ input: ArtifactRasterInput, provenance: GenerationProvenance,
                               masks: [ArtifactMaskInput], retained: [ArtifactMemoryReservation]) async throws -> ArtifactDraft {
        try await beginMutation(); defer { endMutation() }
        let id = GeneratedArtifactID(); let draftID = ArtifactDraftID(); let nonce = UUID()
        let directory = try newDirectory(staging, draftID.canonicalString)
        let owner = StageOwner(schemaVersion: 1, storeID: storeID, draftID: draftID, artifactID: id, nonce: nonce)
        try ArtifactFileIO.writeSmall(directory, ".stage.json", bytes: EditingContractJSON.encoder().encode(owner))
        let (shape, payload) = try await ArtifactPNGCodec.encode(input.image, gray: false, directory: directory, name: "raster.png", resources: resources, retaining: retained)
        let format = try ArtifactRasterFormat(size: shape.size, bitDepth: ArtifactBitDepth(rawValue: shape.bits)!, channels: shape.channels,
            profile: shape.profile!, iccSHA256: ArtifactFileIO.digest(shape.icc!))
        var descriptors: [ArtifactMaskDescriptor] = []
        for mask in masks {
            let (_, file) = try await ArtifactPNGCodec.encode(mask.image, gray: true, directory: directory,
                name: Self.maskName(mask.id), resources: resources, retaining: retained)
            descriptors.append(.init(id: mask.id, size: try ArtifactPixelSize(width: mask.image.width, height: mask.image.height), coordinateSpace: mask.coordinateSpace, file: file))
        }
        descriptors.sort { $0.id.canonicalString < $1.id.canonicalString }
        let manifest = GeneratedArtifactManifest(id: id, raster: .init(format: format, file: payload), provenance: provenance, resources: descriptors)
        let bytes = try EditingContractJSON.encoder().encode(manifest)
        guard bytes.count <= 65_536 else { throw ArtifactContractError.limitExceeded }
        let artifact = try Self.artifact(manifest, bytes: bytes)
        try ArtifactFileIO.writeSmall(directory, "artifact.json", bytes: bytes)
        _ = fsync(directory.fd.value); _ = fsync(staging.fd.value)
        drafts[draftID] = DraftEntry(nonce: nonce, artifact: artifact, directory: directory, commit: nil)
        let ownership = try lease([id], purpose: .draft, draft: draftID)
        return ArtifactDraft(id: draftID, artifact: artifact, ownerID: storeID, nonce: nonce, ownership: ownership)
    }
    public func publish(_ draft: ArtifactDraft, commitID: EditingCommitID) async throws -> PublishedArtifact {
        if let gate { return try await gate.withRepositoryAccess(domain: .artifactPublication) { try await self.publishInside(draft, commitID: commitID) } }
        return try await publishInside(draft, commitID: commitID)
    }
    private func publishInside(_ draft: ArtifactDraft, commitID: EditingCommitID) async throws -> PublishedArtifact {
        try await beginMutation(); defer { endMutation() }
        guard draft.ownerID == storeID, let entry = drafts[draft.id], entry.nonce == draft.nonce,
              entry.artifact == draft.artifact else { throw ArtifactContractError.invalidCapability }
        if let commit = entry.commit { guard commit == commitID else { throw ArtifactContractError.conflictingCommit }; return try makePublication(entry.artifact, commit: commitID) }
        let stageOwner = try ArtifactJSONCodec.decode(StageOwner.self, from: ArtifactFileIO.readSmall(entry.directory, ".stage.json"))
        guard stageOwner.schemaVersion == 1, stageOwner.storeID == storeID, stageOwner.draftID == draft.id,
              stageOwner.artifactID == entry.artifact.id, stageOwner.nonce == entry.nonce else { throw ArtifactContractError.invalidCapability }
        let actual = try readArtifact(entry.directory)
        guard actual == entry.artifact else { throw ArtifactContractError.corruptArtifact }
        try await validatePayloads(actual, directory: entry.directory)
        let binding = Publication(schemaVersion: 1, storeID: storeID, artifactID: actual.id, manifest: actual.manifestSHA256, draftID: draft.id, commitID: commitID)
        let bindingBytes = try EditingContractJSON.encoder().encode(binding)
        do {
            let existing = try ArtifactFileIO.readSmall(entry.directory, ".publication.json")
            guard existing == bindingBytes else { throw ArtifactContractError.conflictingCommit }
        } catch ArtifactContractError.missingArtifact {
            try ArtifactFileIO.writeSmall(entry.directory, ".publication.json", bytes: bindingBytes)
        }
        try entry.directory.validate()
        try ArtifactFileIO.exclusiveMove(staging, name: draft.id.canonicalString, to: root, newName: actual.id.canonicalString)
        // No throwing IO after namespace publication; retain the committed data
        // for a retry and let later integrity checks report external corruption.
        var published = entry; published.commit = commitID; drafts[draft.id] = published; cache(actual)
        return try makePublication(actual, commit: commitID)
    }
    private func makePublication(_ artifact: GeneratedArtifact, commit: EditingCommitID) throws -> PublishedArtifact {
        let nonce = UUID()
        let ownership = try lease([artifact.id], purpose: .acceptedCommit, publication: nonce)
        publications[nonce] = (artifact.id, commit)
        return PublishedArtifact(artifact: artifact, commitID: commit, ownerID: storeID, nonce: nonce, ownership: ownership)
    }
    public func validatePublication(_ publication: PublishedArtifact) async throws {
        guard publication.ownerID == storeID, let registered = publications[publication.nonce],
              registered.0 == publication.artifact.id, registered.1 == publication.commitID else { throw ArtifactContractError.invalidCapability }
        let directory = try ArtifactFileIO.child(root, publication.artifact.id.canonicalString)
        let actual = try readArtifact(directory)
        let binding = try ArtifactJSONCodec.decode(Publication.self, from: ArtifactFileIO.readSmall(directory, ".publication.json"))
        guard binding.schemaVersion == 1, binding.storeID == storeID, binding.artifactID == actual.id,
              binding.manifest == actual.manifestSHA256, binding.commitID == publication.commitID,
              actual == publication.artifact else { throw ArtifactContractError.corruptArtifact }
        try await validatePayloads(actual, directory: directory)
    }
    public func descriptor(_ id: GeneratedArtifactID) async throws -> GeneratedArtifact {
        if let cached = metadata[id] { return cached }
        let actual = try readArtifact(ArtifactFileIO.child(root, id.canonicalString))
        guard actual.id == id else { throw ArtifactContractError.corruptArtifact }; cache(actual); return actual
    }
    private func cache(_ artifact: GeneratedArtifact) {
        metadata[artifact.id] = artifact; order.removeAll { $0 == artifact.id }; order.append(artifact.id)
        while order.count > 128 { metadata.removeValue(forKey: order.removeFirst()) }
    }
    public func openVerifiedRaster(_ id: GeneratedArtifactID) async throws -> ArtifactReadHandle {
        let artifact = try await descriptor(id)
        let file = try await openVerifiedFile(id, role: .raster)
        return ArtifactReadHandle(artifact: artifact, file: file)
    }
    public func openVerifiedFile(_ id: GeneratedArtifactID, role: ArtifactPayloadRole) async throws -> ArtifactFileReadHandle {
        let artifact = try await descriptor(id); let directory = try ArtifactFileIO.child(root, id.canonicalString)
        guard try readArtifact(directory) == artifact else { throw ArtifactContractError.corruptArtifact }
        let (name, expected) = try Self.file(role, artifact: artifact)
        let ownership = try lease([id], purpose: .nativeRead)
        let pinned = try ArtifactFileIO.openFile(directory, name, limit: expected.bytes)
        return try await validatedPayloadHandle(pinned, artifact: artifact, role: role,
            ownership: ownership, expected: expected)
    }
    public func openVerifiedDraft(_ draft: ArtifactDraft) async throws -> ArtifactReadHandle {
        guard draft.ownerID == storeID, let entry = drafts[draft.id], entry.nonce == draft.nonce, entry.artifact == draft.artifact else { throw ArtifactContractError.invalidCapability }
        if entry.commit != nil { return try await openVerifiedRaster(draft.artifact.id) }
        let file = try ArtifactFileIO.openFile(entry.directory, "raster.png")
        let ownership = try lease([draft.artifact.id], purpose: .nativeRead)
        guard try readArtifact(entry.directory) == draft.artifact else { throw ArtifactContractError.corruptArtifact }
        let handle = try await validatedPayloadHandle(file, artifact: draft.artifact, role: .raster,
            ownership: ownership, expected: draft.artifact.raster.file)
        return ArtifactReadHandle(artifact: draft.artifact, file: handle)
    }
    private func validatedPayloadHandle(_ file: ArtifactPinnedFile, artifact: GeneratedArtifact,
        role: ArtifactPayloadRole, ownership: ArtifactLease?, expected: ArtifactFileDescriptor) async throws -> ArtifactFileReadHandle {
        let key = ValidationKey(artifactID: artifact.id, manifest: artifact.manifestSHA256, role: role)
        if let stamp = validatedPayloads[key], stamp == file.stamp {
            let handle = try file.handle(ownership: ownership, validatedStamp: stamp, descriptor: expected)
            touchValidation(key)
            return handle
        }
        // Different inode, ctime, mode, birth/generation, size or mtime always
        // re-hashes and decodes. Failed validation never blesses replacement data.
        validatedPayloads.removeValue(forKey: key)
        validationOrder.removeAll { $0 == key }
        let handle = try await verifiedHandle(file, ownership: ownership, expected: expected)
        switch role {
        case .raster: try await ArtifactPNGCodec.validate(file, raster: artifact.raster, resources: resources)
        case .mask(let id):
            guard let mask = artifact.resources.first(where: { $0.id == id }) else { throw ArtifactContractError.corruptArtifact }
            try await ArtifactPNGCodec.validateMask(file, descriptor: mask, resources: resources)
        case .manifest: break
        }
        // Hash/codec admission contains awaits. Rebind the ORIGINAL stamp after
        // actual native return before it becomes reusable validation evidence.
        try file.validate()
        validatedPayloads[key] = file.stamp
        touchValidation(key)
        while validationOrder.count > 128 { validatedPayloads.removeValue(forKey: validationOrder.removeFirst()) }
        return handle
    }
    private func touchValidation(_ key: ValidationKey) {
        validationOrder.removeAll { $0 == key }; validationOrder.append(key)
    }
    internal func validatePayloads(_ artifact: GeneratedArtifact, directory: ArtifactDirectory) async throws {
        let expected = Set(["artifact.json", "raster.png", ".stage.json", ".publication.json"] + artifact.resources.map { Self.maskName($0.id) })
        guard Set(try ArtifactFileIO.names(directory)).isSubset(of: expected) else { throw ArtifactContractError.corruptArtifact }
        let raster = try ArtifactFileIO.openFile(directory, "raster.png")
        _ = try await verifiedHandle(raster, ownership: nil, expected: artifact.raster.file)
        try await ArtifactPNGCodec.validate(raster, raster: artifact.raster, resources: resources)
        for mask in artifact.resources {
            let file = try ArtifactFileIO.openFile(directory, Self.maskName(mask.id)); _ = try await verifiedHandle(file, ownership: nil, expected: mask.file)
            try await ArtifactPNGCodec.validateMask(file, descriptor: mask, resources: resources)
        }
    }
    public func materialize(_ backup: ValidatedEditingBackup) async throws -> PublishedArtifactSet {
        if let gate { return try await gate.withRepositoryAccess(domain: .artifactPublication) { try await self.materializeInside(backup) } }
        return try await materializeInside(backup)
    }
    private func materializeInside(_ backup: ValidatedEditingBackup) async throws -> PublishedArtifactSet {
        try await beginMutation(); defer { endMutation() }
        let artifacts = backup.manifest.artifacts
        guard artifacts.count <= 4_096, Set(artifacts.map(\.id)).count == artifacts.count,
              EditingBackupPackageStore.sameArtifacts(backup.snapshot.referencedArtifacts, artifacts) else { throw ArtifactContractError.corruptArtifact }
        var missing: [GeneratedArtifact] = []
        // Detect all preexisting conflicts before publishing any new generation.
        for artifact in artifacts {
            if try ArtifactFileIO.names(root, maximum: 65_536).contains(artifact.id.canonicalString) {
                let directory = try ArtifactFileIO.child(root, artifact.id.canonicalString)
                guard try readArtifact(directory) == artifact else { throw ArtifactContractError.conflictingCommit }
                try await validatePayloads(artifact, directory: directory)
            } else { missing.append(artifact) }
        }
        for artifact in missing {
            let temporary = try newDirectory(staging, UUID().uuidString.lowercased())
            let roles: [ArtifactPayloadRole] = [.manifest, .raster] + artifact.resources.map { .mask($0.id) }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for worker in 0..<min(2, roles.count) {
                    group.addTask { [resources] in
                        for index in stride(from: worker, to: roles.count, by: 2) {
                            let role = roles[index]; let (name, expected) = try Self.file(role, artifact: artifact)
                            let handle = try await backup.openArtifactFile(artifact.id, role)
                            let transfer = try await resources.acquire(kind: .transfer, bytes: 65_536, priority: .background, retaining: [])
                            guard handle.sha256 == expected.sha256, handle.bytes == expected.bytes else { throw ArtifactContractError.corruptArtifact }
                            _ = try ArtifactFileIO.copy(handle, into: temporary, leaf: name)
                            withExtendedLifetime(transfer) {}
                        }
                    }
                }; try await group.waitForAll()
            }
            guard try readArtifact(temporary) == artifact else { throw ArtifactContractError.corruptArtifact }
            try await validatePayloads(artifact, directory: temporary)
            let binding = Publication(schemaVersion: 1, storeID: storeID, artifactID: artifact.id, manifest: artifact.manifestSHA256, draftID: nil, commitID: nil)
            try ArtifactFileIO.writeSmall(temporary, ".publication.json", bytes: EditingContractJSON.encoder().encode(binding))
            try ArtifactFileIO.exclusiveMove(staging, name: temporary.leaf!, to: root, newName: artifact.id.canonicalString); cache(artifact)
        }
        let ids = Set(artifacts.map(\.id)); let nonce = UUID(); let ownership = try lease(ids, purpose: .restore)
        return PublishedArtifactSet(artifacts: artifacts, ownerID: storeID, nonce: nonce, ownership: ownership)
    }
    public func recoverStagingAndReportOrphans(referenced: Set<GeneratedArtifactID>) async throws -> ArtifactRecoveryReport {
        try await beginMutation(); defer { endMutation() }
        var orphans: Set<GeneratedArtifactID> = []; var unknown: [String] = []
        for name in try ArtifactFileIO.names(root, maximum: 65_536) where name != ".owner.json" && name != ".staging" {
            guard let uuid = UUID(uuidString: name), name == uuid.uuidString.lowercased() else { unknown.append(name); continue }
            let id = GeneratedArtifactID(rawValue: uuid)
            do { _ = try readArtifact(ArtifactFileIO.child(root, name)); if !referenced.contains(id) { orphans.insert(id) } }
            catch { unknown.append(name) }
        }
        for name in try ArtifactFileIO.names(staging) { unknown.append(".staging/" + name) }
        return .init(retainedOrphans: orphans, removedOwnedStagingCount: 0, unrecognizedEntries: unknown.sorted())
    }
    internal static func maskName(_ id: ArtifactResourceID) -> String { "mask-" + id.canonicalString + ".png" }
    internal static func file(_ role: ArtifactPayloadRole, artifact: GeneratedArtifact) throws -> (String, ArtifactFileDescriptor) {
        switch role {
        case .raster: return ("raster.png", artifact.raster.file)
        case .manifest:
            let bytes = try EditingContractJSON.encoder().encode(GeneratedArtifactManifest(id: artifact.id, raster: artifact.raster, provenance: artifact.provenance, resources: artifact.resources))
            guard try ArtifactFileIO.digest(bytes) == artifact.manifestSHA256 else { throw ArtifactContractError.corruptArtifact }
            return ("artifact.json", try .init(sha256: artifact.manifestSHA256, bytes: Int64(bytes.count)))
        case .mask(let id): guard let mask = artifact.resources.first(where: { $0.id == id }) else { throw ArtifactContractError.corruptArtifact }; return (maskName(id), mask.file)
        }
    }
    internal func readArtifact(_ directory: ArtifactDirectory) throws -> GeneratedArtifact { try Self.readArtifact(directory) }
    internal static func readArtifact(_ directory: ArtifactDirectory) throws -> GeneratedArtifact {
        let bytes = try ArtifactFileIO.readSmall(directory, "artifact.json")
        let manifest = try ArtifactJSONCodec.decode(GeneratedArtifactManifest.self, from: bytes)
        guard try EditingContractJSON.encoder().encode(manifest) == bytes else { throw ArtifactContractError.corruptArtifact }
        return try artifact(manifest, bytes: bytes)
    }
    internal static func artifact(_ manifest: GeneratedArtifactManifest, bytes: Data) throws -> GeneratedArtifact {
        try ArtifactValueValidation.manifest(manifest)
        let value = try GeneratedArtifact(id: manifest.id, raster: manifest.raster, provenance: manifest.provenance, resources: manifest.resources, manifestSHA256: ArtifactFileIO.digest(bytes))
        try ArtifactValueValidation.artifact(value); return value
    }
    internal static func validateProvenance(_ value: GenerationProvenance) throws { try ArtifactValueValidation.provenance(value) }
    private func verifiedHandle(_ file: ArtifactPinnedFile, ownership: ArtifactLease?, expected: ArtifactFileDescriptor) async throws -> ArtifactFileReadHandle {
        let slot = try await resources.acquire(kind: .transfer, bytes: 65_536, priority: .background, retaining: [])
        defer { withExtendedLifetime(slot) {} }; return try file.handle(ownership: ownership, expected: expected)
    }
    internal func newDirectory(_ parent: ArtifactDirectory, _ leaf: String) throws -> ArtifactDirectory {
        try parent.validate()
        guard mkdirat(parent.fd.value, leaf, 0o700) == 0 else { throw ArtifactFileIO.failure("Eigenen Stage exklusiv erstellen") }
        return try ArtifactFileIO.child(parent, leaf)
    }
}
