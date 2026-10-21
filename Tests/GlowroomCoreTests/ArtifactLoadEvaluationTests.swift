import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import GlowroomCore

/// Explicit large, deterministic, model-free integration measurement. Ordinary
/// test runs skip its disk/codec load. Output is retained for independent review.
struct ArtifactLoadEvaluationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_ARTIFACT_LOAD_EVALUATION"] == "1"))
    func largeNativeArtifactPackageRoundtripWithoutOriginals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-Artifact-Evaluation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let restoredDirectory = root.appendingPathComponent("restored", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: restoredDirectory, withIntermediateDirectories: false)
        let resources = ArtifactLoadResources()
        let gate = CatalogLifecycleGate(requiresRecovery: false)
        let artifacts = try await GeneratedArtifactStore.open(in: sourceDirectory, resources: resources, lifecycleGate: gate)
        let packages = EditingBackupPackageStore(resources: resources, catalog: CatalogRepository(directory: sourceDirectory))
        let database = EditingRepository(directory: sourceDirectory, artifacts: artifacts, packages: packages, gate: gate, resources: resources)
        let original = root.appendingPathComponent("missing-after-acceptance.jpg")
        let originalBytes = Data([0x50, 0x49, 0x43, 0x45])
        try originalBytes.write(to: original)
        let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
        let modified = try #require(attributes[.modificationDate] as? Date)
        let fingerprint = try AssetRemapVerifier.capture(original, referenceDate: modified)
        let assetID = fingerprint.standardizedPath
        let baseline = try await database.loadState()
        let before = try await database.saveSnapshot(EditingSnapshot(settings: EditSettings(exposure: 1.25)), for: assetID,
            expected: .init(storeEpoch: baseline.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        let initialRSS = Self.peakRSS()
        let started = ContinuousClock.now
        let image = try Self.image()
        let shape = try ArtifactPNGCodec.shape(image)
        let canonical = try ArtifactPNGCodec.pixelHash(image, shape: shape)
        let format = ArtifactRasterFormat(size: shape.size, bitDepth: .eight, channels: .rgba,
            profile: .displayP3, iccSHA256: try ArtifactFileIO.digest(try #require(shape.icc)))
        let provenance = try GenerationProvenance(parentSource: .original(fingerprint), parentSnapshot: before.snapshot,
            renderedInput: .init(format: format, canonicalPixelSHA256: canonical, pipelineVersion: 1),
            placement: .init(inputSize: shape.size, outputSize: shape.size, inputOriginX: 0, inputOriginY: 0),
            pipelineVersion: 1, parameterVersion: 1, parameters: .init(values: []),
            provider: .init(providerID: "synthetic-load-fixture"), prompt: "Deterministic synthetic fixture; no model call",
            createdAt: Date(timeIntervalSinceReferenceDate: 750_000_000.125), execution: .local)
        let stageStart = ContinuousClock.now
        let draft = try await artifacts.stageRaster(.init(immutableImage: image), provenance: provenance, masks: [])
        let stageSeconds = Self.seconds(stageStart.duration(to: .now))
        let commitStart = ContinuousClock.now
        let committed = try await database.commitGenerated(.init(commitID: .init(), assetID: assetID, draft: draft,
            expected: .init(before), expectedParentSource: .original(fingerprint), nextRevision: 2))
        #expect(committed.stored.snapshot.settings == .neutral)
        let commitSeconds = Self.seconds(commitStart.duration(to: .now))
        let backupStart = ContinuousClock.now
        let backup = try await database.createBackup(automatic: false)
        let backupSeconds = Self.seconds(backupStart.duration(to: .now))
        #expect(try Data(contentsOf: original) == originalBytes)
        try FileManager.default.removeItem(at: original)

        let freshGate = CatalogLifecycleGate(requiresRecovery: false)
        let freshArtifacts = try await GeneratedArtifactStore.open(in: restoredDirectory, resources: resources, lifecycleGate: freshGate)
        let freshPackages = EditingBackupPackageStore(resources: resources, catalog: CatalogRepository(directory: restoredDirectory))
        let fresh = EditingRepository(directory: restoredDirectory, artifacts: freshArtifacts, packages: freshPackages,
            gate: freshGate, resources: resources)
        let restoreStart = ContinuousClock.now
        let restored = try await fresh.restoreBackup(from: backup)
        let restoreSeconds = Self.seconds(restoreStart.duration(to: .now))
        #expect(restored.byAsset[assetID]?.snapshot == committed.stored.snapshot)
        #expect(try await fresh.variants(for: assetID).map(\.snapshot).contains(before.snapshot))
        let reopened = try await GeneratedArtifactStore.open(in: restoredDirectory, resources: resources, lifecycleGate: freshGate)
        let handle = try await reopened.openVerifiedRaster(draft.artifact.id)
        #expect(handle.artifact.provenance == provenance)
        let fileDirectory = try ArtifactFileIO.root(restoredDirectory.appendingPathComponent("GeneratedArtifacts/" + draft.artifact.id.canonicalString), create: false)
        let decoded = try ArtifactPNGCodec.decode(ArtifactFileIO.openFile(fileDirectory, "raster.png"))
        let decodedShape = try ArtifactPNGCodec.shape(decoded)
        #expect(try ArtifactPNGCodec.pixelHash(decoded, shape: decodedShape) == canonical)
        #expect(decodedShape.icc == shape.icc)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        // The independently retained matching catalog is a separate UI fixture;
        // it is deliberately created AFTER Restore, outside the backup package.
        let folder = LibraryFolder(url: root, name: "Synthetic missing original")
        let asset = PhotoAsset(id: assetID, folderID: folder.id, fileURL: original, fileSize: 4,
            pixelWidth: 4_096, pixelHeight: 4_096, modifiedAt: modified)
        try CatalogRepository(directory: restoredDirectory).save(LibraryCatalog(folders: [folder], assets: [asset]))
        let observed = await resources.report()
        #expect(observed.peakChargedBytes <= 536_870_912)
        #expect(observed.peakCodecs <= 1 && observed.peakTransfers <= 2)
        let report = ArtifactLoadReport(schemaVersion: 1, platform: ProcessInfo.processInfo.operatingSystemVersionString,
            fixture: "4096×4096 straight RGBA8 Display P3 deterministic noise; no RAW, no model, no original decoding",
            pixels: 16_777_216, inputNativeBytes: shape.nativeBytes, rasterPNGBytes: handle.file.bytes,
            canonicalPixelSHA256: canonical.sha256, artifactManifestSHA256: handle.artifact.manifestSHA256.sha256,
            stageSeconds: stageSeconds, commitSeconds: commitSeconds, backupSeconds: backupSeconds,
            restoreSeconds: restoreSeconds, totalSeconds: Self.seconds(started.duration(to: .now)),
            observedResourcePeak: observed, processHighWaterRSSBeforeBytes: initialRSS,
            processHighWaterRSSAfterBytes: Self.peakRSS(), backup: backup.path, separateUICatalog: restoredDirectory.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let result = root.appendingPathComponent("results.json")
        try encoder.encode(report).write(to: result, options: .atomic)
        print("Artifact load evaluation: \(result.path)")
        withExtendedLifetime((image, decoded, handle, draft)) {}
    }
    private static func image() throws -> CGImage {
        let width = 4_096, height = 4_096
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let pixels = raw.bindMemory(to: UInt32.self)
            var state: UInt32 = 0x4281_72a5
            for index in pixels.indices {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5
                pixels[index] = state
            }
        }
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    private static func peakRSS() -> Int64? {
        var usage = rusage(); guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }; return Int64(usage.ru_maxrss)
    }
}

private struct ArtifactLoadResourceReport: Codable, Sendable {
    let peakChargedBytes: Int64
    let peakCodecs: Int
    let peakTransfers: Int
}
private actor ArtifactLoadResources: ArtifactResourceAdmitting {
    let owner = ArtifactResourceOwner(limits: try! .init())
    var peakBytes: Int64 = 0, peakCodecs = 0, peakTransfers = 0
    func acquire(kind: ArtifactAdmissionKind, bytes: Int64, priority: ArtifactResourcePriority,
                 retaining: [ArtifactMemoryReservation]) async throws -> ArtifactResourceLease {
        let lease = try await owner.acquire(kind: kind, bytes: bytes, priority: priority, retaining: retaining)
        let state = await owner.state()
        peakBytes = max(peakBytes, state.chargedBytes); peakCodecs = max(peakCodecs, state.runningCodecs)
        peakTransfers = max(peakTransfers, state.runningTransfers)
        return lease
    }
    func retain(bytes: Int64, from lease: ArtifactResourceLease) async throws -> ArtifactMemoryReservation {
        try await owner.retain(bytes: bytes, from: lease)
    }
    func validate(_ memory: ArtifactMemoryReservation, minimumBytes: Int64) async throws {
        try await owner.validate(memory, minimumBytes: minimumBytes)
    }
    func report() -> ArtifactLoadResourceReport {
        .init(peakChargedBytes: peakBytes, peakCodecs: peakCodecs, peakTransfers: peakTransfers)
    }
}
private struct ArtifactLoadReport: Codable {
    let schemaVersion: Int
    let platform: String
    let fixture: String
    let pixels: Int
    let inputNativeBytes: Int64
    let rasterPNGBytes: Int64
    let canonicalPixelSHA256: String
    let artifactManifestSHA256: String
    let stageSeconds: Double
    let commitSeconds: Double
    let backupSeconds: Double
    let restoreSeconds: Double
    let totalSeconds: Double
    let observedResourcePeak: ArtifactLoadResourceReport
    let processHighWaterRSSBeforeBytes: Int64?
    let processHighWaterRSSAfterBytes: Int64?
    let backup: String
    let separateUICatalog: String
}
