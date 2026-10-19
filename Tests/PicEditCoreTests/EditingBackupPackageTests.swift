import Foundation
import Testing
@testable import PicEditCore

struct EditingBackupPackageTests {
    struct Source: Sendable { let source: EditingBackupSource; let package: EditingBackupPackageStore; let artifact: GeneratedArtifact }
    // B unit tests inject the A boundary, so these tests do not claim to parse a
    // real Editing schema. A's repository/integration suite owns that proof.
    func source(_ fixture: ArtifactTestFixture, mask: Bool = false, parentSnapshot: EditingSnapshot? = nil,
                kind: EditingBackupKind = .manual) async throws -> Source {
        let store = try await fixture.store(); let image = fixture.image(bits: 16, p3: true)
        let resource = ArtifactResourceID()
        let masks: [ArtifactMaskInput] = mask ? [.init(id: resource, coordinateSpace: .inputCanvas, immutableImage: fixture.image(alpha: false, gray: true))] : []
        let draft = try await store.stageRaster(.init(immutableImage: image), provenance: fixture.provenance(image, masks: masks.map(\.id), parentSnapshot: parentSnapshot), masks: masks)
        let publication = try await store.publish(draft, commitID: .init())
        let ownership = try await store.acquireLease(ids: [publication.artifact.id], purpose: .backup)
        let directory = try ArtifactFileIO.root(fixture.directory, create: false)
        try ArtifactFileIO.writeSmall(directory, "closed-unit-fixture.sqlite", bytes: Data("B closed SQL boundary fixture; A validates real SQL separately".utf8))
        let file = try ArtifactFileIO.openFile(directory, "closed-unit-fixture.sqlite")
        let handle = try file.handle(ownership: ownership)
        let epoch = UUID(); let artifacts = [publication.artifact]
        let snapshot = ClosedEditingSQLSnapshot(sourceStoreEpoch: epoch, database: handle, referencedArtifacts: artifacts, snapshotID: UUID())
        let source = EditingBackupSource(snapshot: snapshot, kind: kind, lease: ownership, artifactStore: store)
        let package = EditingBackupPackageStore(resources: fixture.resources, validateClosedSQL: { _, input in
            ClosedEditingSQLSnapshot(sourceStoreEpoch: epoch, database: input, referencedArtifacts: artifacts, snapshotID: UUID())
        }, catalog: CatalogRepository(directory: fixture.directory))
        return Source(source: source, package: package, artifact: publication.artifact)
    }
    @Test func automaticBackupRetainsLargeParentMattesAndRemainsReusable() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let raster = try LocalMaskRaster(width: 2_048, height: 1_536,
            bytes: Data(repeating: 173, count: 2_048 * 1_536))
        let layers = try (0..<2).map {
            try LocalAdjustment(name: "Maske \($0)", mask: .init(shape: .subject(raster), feather: 0))
        }
        let parent = try EditingSnapshot(settings: .init(localAdjustments: layers))
        let prepared = try await source(fixture, parentSnapshot: parent, kind: .automatic)
        let destination = fixture.directory.appendingPathComponent("large-parent.piceditbackup", isDirectory: true)
        let published = try await prepared.package.write(prepared.source, toNew: destination, limits: .init())
        let manifestBytes = try Data(contentsOf: destination.appendingPathComponent("manifest.json"))
        #expect(manifestBytes.count > 8_388_608 && manifestBytes.count < EditSettings.maximumEncodedBytes)
        let validated = try await prepared.package.validate(from: destination, limits: .init())
        #expect(validated.manifest.artifacts.first?.provenance.parentSnapshot == parent)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: published.manifest.createdAt)
        #expect(try await prepared.package.reusableAutomaticBackup(in: fixture.directory, day: day) == destination)
    }
    @Test func packageRoundtripMaterializesAllPixelsAndMaskWithoutOriginals() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let target = try ArtifactTestFixture(); defer { target.remove() }
        let prepared = try await source(fixture, mask: true)
        let destination = fixture.directory.appendingPathComponent("roundtrip.piceditbackup")
        let published = try await prepared.package.write(prepared.source, toNew: destination, limits: .init())
        #expect(published.manifest.artifacts == [prepared.artifact])
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("original.bin"))
        try FileManager.default.removeItem(at: target.directory.appendingPathComponent("original.bin"))
        let validated = try await prepared.package.validate(from: destination, limits: .init())
        let targetStore = try await target.store()
        let imported = try await targetStore.materialize(validated)
        #expect(imported.artifacts == [prepared.artifact])
        let raster = try await targetStore.openVerifiedRaster(prepared.artifact.id)
        #expect(raster.artifact == prepared.artifact)
        #expect(try ArtifactFileIO.digest(ArtifactTestFixture.bytes(raster.file)) == prepared.artifact.raster.file.sha256)
        let mask = try #require(prepared.artifact.resources.first)
        let maskHandle = try await targetStore.openVerifiedFile(prepared.artifact.id, role: .mask(mask.id))
        #expect(try ArtifactFileIO.digest(ArtifactTestFixture.bytes(maskHandle)) == mask.file.sha256)
        _ = try await targetStore.materialize(validated)
        let restarted = try await target.store()
        #expect(try await restarted.descriptor(prepared.artifact.id) == prepared.artifact)
        #expect(try await restarted.openVerifiedRaster(prepared.artifact.id).artifact == prepared.artifact)
    }
    @Test func existingDestinationAndSymlinkPayloadPreserveForeignBytes() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let prepared = try await source(fixture)
        let destination = fixture.directory.appendingPathComponent("existing.piceditbackup")
        let sentinel = Data("foreign existing backup".utf8); try sentinel.write(to: destination)
        await #expect(throws: ArtifactContractError.invalidValue("Sicherungsziel existiert bereits")) {
            _ = try await prepared.package.write(prepared.source, toNew: destination, limits: .init())
        }
        #expect(try Data(contentsOf: destination) == sentinel)
        let valid = fixture.directory.appendingPathComponent("valid.piceditbackup")
        _ = try await prepared.package.write(prepared.source, toNew: valid, limits: .init())
        let payload = valid.appendingPathComponent("artifacts/\(prepared.artifact.id.canonicalString)/raster.png")
        let foreign = fixture.directory.appendingPathComponent("foreign.png"); let before = try Data(contentsOf: payload); try before.write(to: foreign)
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: foreign)
        await #expect(throws: (any Error).self) { _ = try await prepared.package.validate(from: valid, limits: .init()) }
        #expect(try Data(contentsOf: foreign) == before)
    }
    @Test func unknownSchemaExtraFileAndSmallLimitsFailClosed() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let prepared = try await source(fixture)
        let destination = fixture.directory.appendingPathComponent("strict.piceditbackup")
        _ = try await prepared.package.write(prepared.source, toNew: destination, limits: .init())
        let manifest = destination.appendingPathComponent("manifest.json")
        let bytes = try Data(contentsOf: manifest)
        var json = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: manifest)
        await #expect(throws: ArtifactContractError.unsupportedVersion(99)) { _ = try await prepared.package.validate(from: destination, limits: .init()) }
        try bytes.write(to: manifest)
        let foreign = destination.appendingPathComponent("unlisted-original.txt"); let sentinel = Data([4, 5]); try sentinel.write(to: foreign)
        await #expect(throws: ArtifactContractError.corruptArtifact) { _ = try await prepared.package.validate(from: destination, limits: .init()) }
        #expect(try Data(contentsOf: foreign) == sentinel)
        try FileManager.default.removeItem(at: foreign)
        await #expect(throws: ArtifactContractError.limitExceeded) { _ = try await prepared.package.validate(from: destination, limits: .init(maximumTotalBytes: 32)) }
        #expect(try Data(contentsOf: manifest) == bytes)
    }
    @Test func closedSQLReferenceClosureAndHandleIdentityCannotBeRebased() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let prepared = try await source(fixture)
        let wrongClosure = EditingBackupPackageStore(resources: fixture.resources, validateClosedSQL: { _, handle in
            ClosedEditingSQLSnapshot(sourceStoreEpoch: prepared.source.snapshot.sourceStoreEpoch, database: handle, referencedArtifacts: [], snapshotID: UUID())
        })
        let destination = fixture.directory.appendingPathComponent("wrong-closure.piceditbackup")
        await #expect(throws: ArtifactContractError.corruptArtifact) { _ = try await wrongClosure.write(prepared.source, toNew: destination, limits: .init()) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let wrongHandle = EditingBackupPackageStore(resources: fixture.resources, validateClosedSQL: { _, _ in prepared.source.snapshot })
        await #expect(throws: ArtifactContractError.invalidCapability) { _ = try await wrongHandle.write(prepared.source, toNew: destination, limits: .init()) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let original = fixture.directory.appendingPathComponent("original.bin")
        #expect(try Data(contentsOf: original) == Data([1, 2, 3]))
    }
}

extension EditingBackupPackageTests {
    private func automatic(_ source: EditingBackupSource) -> EditingBackupSource {
        EditingBackupSource(snapshot: source.snapshot, kind: .automatic, lease: source.lease, artifactStore: source.artifactStore)
    }
    private func currentDay() -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: Date())
    }
    @Test func automaticDailyReuseAndSevenPackageRotationSurviveNewAdapter() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let prepared = try await source(fixture)
        var backups: [PublishedEditingBackup] = []
        for index in 0..<9 {
            // Packages are directories. Keep the same URL directory hint as a
            // restarted adapter's returned package URL, including its slash.
            let destination = fixture.directory.appendingPathComponent("automatic-\(index).piceditbackup", isDirectory: true)
            backups.append(try await prepared.package.write(automatic(prepared.source), toNew: destination, limits: .init()))
        }
        let manual = fixture.directory.appendingPathComponent("manual.piceditbackup")
        _ = try await prepared.package.write(prepared.source, toNew: manual, limits: .init())
        let legacy = fixture.directory.appendingPathComponent("auto-2000-01-01-foreign.sqlite")
        let sentinel = Data("legacy user bytes".utf8); try sentinel.write(to: legacy)
        // A new stateless adapter has no in-memory publication registry to trust.
        let restarted = EditingBackupPackageStore(resources: fixture.resources, validateClosedSQL: { _, handle in
            ClosedEditingSQLSnapshot(sourceStoreEpoch: prepared.source.snapshot.sourceStoreEpoch, database: handle,
                referencedArtifacts: [prepared.artifact], snapshotID: UUID())
        }, catalog: CatalogRepository(directory: fixture.directory))
        let sorted = backups.sorted {
            if $0.manifest.createdAt != $1.manifest.createdAt { return $0.manifest.createdAt > $1.manifest.createdAt }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        let reused = try #require(try await restarted.reusableAutomaticBackup(in: fixture.directory, day: currentDay()))
        let newest = try #require(sorted.first)
        #expect(reused == newest.url)
        #expect(reused.hasDirectoryPath)
        try await restarted.pruneAutomaticBackups(in: fixture.directory, keepingNewest: 7)
        for backup in sorted.prefix(7) { #expect(FileManager.default.fileExists(atPath: backup.url.path)) }
        for backup in sorted.dropFirst(7) { #expect(!FileManager.default.fileExists(atPath: backup.url.path)) }
        #expect(FileManager.default.fileExists(atPath: manual.path))
        #expect(try Data(contentsOf: legacy) == sentinel)
        #expect(try await restarted.reusableAutomaticBackup(in: fixture.directory, day: "2000-01-01") == nil)
    }
    @Test func automaticReceiptNeverBlessesReplacementOrUnknownPackageContents() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let prepared = try await source(fixture)
        let replaced = fixture.directory.appendingPathComponent("replaced.piceditbackup")
        _ = try await prepared.package.write(automatic(prepared.source), toNew: replaced, limits: .init())
        let payload = replaced.appendingPathComponent("artifacts/\(prepared.artifact.id.canonicalString)/raster.png")
        let payloadBytes = try Data(contentsOf: payload); try payloadBytes.write(to: payload, options: .atomic)
        #expect(try await prepared.package.reusableAutomaticBackup(in: fixture.directory, day: currentDay()) == nil)
        let unknown = fixture.directory.appendingPathComponent("unknown-child.piceditbackup")
        _ = try await prepared.package.write(automatic(prepared.source), toNew: unknown, limits: .init())
        let foreign = unknown.appendingPathComponent("foreign-original.txt"); let sentinel = Data([44]); try sentinel.write(to: foreign)
        let good = fixture.directory.appendingPathComponent("good.piceditbackup")
        _ = try await prepared.package.write(automatic(prepared.source), toNew: good, limits: .init())
        try await prepared.package.pruneAutomaticBackups(in: fixture.directory, keepingNewest: 1)
        #expect(try Data(contentsOf: payload) == payloadBytes)
        #expect(try Data(contentsOf: foreign) == sentinel)
        #expect(FileManager.default.fileExists(atPath: good.path))
    }
    @Test func copiedAutomaticPackageCannotInheritCreationReceiptAndReceiptScanIsBounded() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let prepared = try await source(fixture)
        let original = fixture.directory.appendingPathComponent("copied.piceditbackup")
        _ = try await prepared.package.write(automatic(prepared.source), toNew: original, limits: .init())
        let temporary = fixture.directory.appendingPathComponent("foreign-copy.piceditbackup")
        try FileManager.default.copyItem(at: original, to: temporary)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: temporary, to: original)
        #expect(try await prepared.package.reusableAutomaticBackup(in: fixture.directory, day: currentDay()) == nil)
        try await prepared.package.pruneAutomaticBackups(in: fixture.directory, keepingNewest: 1)
        #expect(FileManager.default.fileExists(atPath: original.path))
        for _ in 0..<64 {
            let name = ".automatic-receipt-" + UUID().uuidString.lowercased() + ".json"
            try Data().write(to: fixture.directory.appendingPathComponent(name))
        }
        await #expect(throws: ArtifactContractError.limitExceeded) {
            try await prepared.package.pruneAutomaticBackups(in: fixture.directory, keepingNewest: 1)
        }
        #expect(FileManager.default.fileExists(atPath: original.path))
    }
}

extension EditingBackupPackageTests {
    @Test func automaticRotationProtectsFreshCatalogOriginalsThroughDirectAndAliasPaths() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let prepared = try await source(fixture)
        var packages: [PublishedEditingBackup] = []
        for index in 0..<3 {
            packages.append(try await prepared.package.write(automatic(prepared.source),
                toNew: fixture.directory.appendingPathComponent("catalog-protected-\(index).piceditbackup"), limits: .init()))
        }
        let sorted = packages.sorted {
            if $0.manifest.createdAt != $1.manifest.createdAt { return $0.manifest.createdAt > $1.manifest.createdAt }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        let old = Array(sorted.dropFirst())
        let direct = old[0].url.appendingPathComponent("artifacts/\(prepared.artifact.id.canonicalString)/raster.png")
        let aliasedRaster = old[1].url.appendingPathComponent("artifacts/\(prepared.artifact.id.canonicalString)/raster.png")
        let alias = fixture.directory.appendingPathComponent("imported-original-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: aliasedRaster.deletingLastPathComponent())
        let aliasURL = alias.appendingPathComponent("raster.png")
        let before = try Data(contentsOf: direct); let aliasBefore = try Data(contentsOf: aliasURL)
        let folder = LibraryFolder(url: fixture.directory)
        let directAsset = PhotoAsset(folderID: folder.id, fileURL: direct, format: "PNG")
        var aliasAsset = PhotoAsset(id: "stored-alias-original", folderID: folder.id, fileURL: aliasURL, format: "PNG")
        // Preserve a legacy/un-normalized stored alias, as catalog decoding does.
        aliasAsset.fileURL = aliasURL
        let catalog = CatalogRepository(directory: fixture.directory)
        try catalog.save(.init(folders: [folder], assets: [directAsset, aliasAsset]))
        try await prepared.package.pruneAutomaticBackups(in: fixture.directory, keepingNewest: 1)
        #expect(try Data(contentsOf: direct) == before)
        #expect(try Data(contentsOf: aliasURL) == aliasBefore)
        // Fresh protection must be consulted again, not cached forever. Once
        // the user removes the imports, only the latest automatic package stays.
        try catalog.save(.init())
        try await prepared.package.pruneAutomaticBackups(in: fixture.directory, keepingNewest: 1)
        for package in old { #expect(!FileManager.default.fileExists(atPath: package.url.path)) }
        #expect(FileManager.default.fileExists(atPath: sorted[0].url.path))
    }
    @Test func missingCatalogProtectionRefusesRotationWithoutDeletingSuccessfulPackages() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let prepared = try await source(fixture)
        let destination = fixture.directory.appendingPathComponent("no-catalog-context.piceditbackup")
        _ = try await prepared.package.write(automatic(prepared.source), toNew: destination, limits: .init())
        let noCatalog = EditingBackupPackageStore(resources: fixture.resources)
        await #expect(throws: ArtifactContractError.invalidValue("Automatische Rotation benötigt einen aktuellen Katalogschutz")) {
            try await noCatalog.pruneAutomaticBackups(in: fixture.directory, keepingNewest: 1)
        }
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }
}

extension EditingBackupPackageTests {
    @Test func nativeExportPreservesClosedSnapshotPixelsMasksAndSourcePackage() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let prepared = try await source(fixture, mask: true)
        let local = fixture.directory.appendingPathComponent("local-backup.piceditbackup")
        let original = try await prepared.package.write(prepared.source, toNew: local, limits: .init())
        let sourceManifest = try Data(contentsOf: local.appendingPathComponent("manifest.json"))
        let exported = fixture.directory.appendingPathComponent("exported.piceditbackup")
        let publication = try await prepared.package.export(from: local, toNew: exported, limits: .init())
        #expect(publication.manifest == original.manifest)
        #expect(try Data(contentsOf: exported.appendingPathComponent("manifest.json")) == sourceManifest)
        #expect(try Data(contentsOf: local.appendingPathComponent("manifest.json")) == sourceManifest)
        let verified = try await prepared.package.validate(from: exported, limits: .init())
        #expect(verified.manifest == original.manifest)
        #expect(verified.snapshot.database.sha256 == original.manifest.database.sha256)
        let raster = try await verified.openArtifactFile(prepared.artifact.id, .raster)
        #expect(try ArtifactFileIO.digest(ArtifactTestFixture.bytes(raster)) == prepared.artifact.raster.file.sha256)
        let mask = try #require(prepared.artifact.resources.first)
        let handle = try await verified.openArtifactFile(prepared.artifact.id, .mask(mask.id))
        #expect(try ArtifactFileIO.digest(ArtifactTestFixture.bytes(handle)) == mask.file.sha256)
    }
    @Test func nativeExportRefusesExistingOrCatalogOriginalTargetAndBrokenSource() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let prepared = try await source(fixture)
        let local = fixture.directory.appendingPathComponent("export-source.piceditbackup")
        _ = try await prepared.package.write(prepared.source, toNew: local, limits: .init())
        let existing = fixture.directory.appendingPathComponent("existing-export.piceditbackup")
        let sentinel = Data("foreign original target".utf8); try sentinel.write(to: existing)
        await #expect(throws: ArtifactContractError.invalidValue("Sicherungsziel existiert bereits")) {
            _ = try await prepared.package.export(from: local, toNew: existing, limits: .init())
        }
        #expect(try Data(contentsOf: existing) == sentinel)
        let destination = fixture.directory.appendingPathComponent("missing-original.piceditbackup")
        let folder = LibraryFolder(url: fixture.directory)
        let original = PhotoAsset(folderID: folder.id, fileURL: destination, format: "PNG")
        try CatalogRepository(directory: fixture.directory).save(.init(folders: [folder], assets: [original]))
        await #expect(throws: PhotoMetadataError.protectedPath) {
            _ = try await prepared.package.export(from: local, toNew: destination, limits: .init())
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let payload = local.appendingPathComponent("artifacts/\(prepared.artifact.id.canonicalString)/raster.png")
        let foreign = fixture.directory.appendingPathComponent("foreign-source.png")
        let before = try Data(contentsOf: payload); try before.write(to: foreign)
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: foreign)
        let rejected = fixture.directory.appendingPathComponent("invalid-source-export.piceditbackup")
        await #expect(throws: (any Error).self) {
            _ = try await prepared.package.export(from: local, toNew: rejected, limits: .init())
        }
        #expect(!FileManager.default.fileExists(atPath: rejected.path))
        #expect(try Data(contentsOf: foreign) == before)
    }
}

extension EditingBackupPackageTests {
    @Test func nativeExportProtectsAbsentThenCreatedManagedDirectoryThroughVarAlias() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let prepared = try await source(fixture)
        let local = fixture.directory.appendingPathComponent("managed-export-source.piceditbackup")
        _ = try await prepared.package.write(prepared.source, toNew: local, limits: .init())
        let physical = fixture.directory.resolvingSymlinksInPath().path
        let aliasPath: String
        if physical.hasPrefix("/private/var/") { aliasPath = String(physical.dropFirst("/private".count)) }
        else if physical.hasPrefix("/private/tmp/") { aliasPath = String(physical.dropFirst("/private".count)) }
        else { aliasPath = fixture.directory.path }
        let aliasDirectory = URL(fileURLWithPath: aliasPath, isDirectory: true)
        let protectedRoot = fixture.directory.appendingPathComponent("SemanticModels", isDirectory: true)
        let destination = aliasDirectory.appendingPathComponent("SemanticModels/late-export.piceditbackup", isDirectory: true)
        let catalog = CatalogRepository(directory: fixture.directory)
        #expect(!FileManager.default.fileExists(atPath: protectedRoot.path))
        #expect(throws: PhotoMetadataError.protectedPath) {
            try catalog.withBackupExportProtection(destination: destination) {
                Issue.record("Missing managed-root protection must stop publication")
            }
        }
        // The same destination is still forbidden if storage appears after a
        // dialog/preflight. The real native export must perform its own check.
        try FileManager.default.createDirectory(at: protectedRoot, withIntermediateDirectories: false)
        await #expect(throws: PhotoMetadataError.protectedPath) {
            _ = try await prepared.package.export(from: local, toNew: destination, limits: .init())
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: local.appendingPathComponent("manifest.json").path))
    }
}
