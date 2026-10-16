import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Testing
@testable import PicEditCore

struct ArtifactTestFixture: Sendable {
    let directory: URL
    let resources: ArtifactResourceOwner
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("picedit-artifact-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        resources = ArtifactResourceOwner(limits: try .init())
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("original.bin"))
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func store() async throws -> GeneratedArtifactStore { try await GeneratedArtifactStore.open(in: directory, resources: resources) }
    func image(bits: Int = 8, alpha: Bool = true, p3: Bool = false, gray: Bool = false,
               premultiplied: Bool = false, width: Int = 3, height: Int = 2) -> CGImage {
        let count = gray ? 1 : alpha ? 4 : 3
        var data = Data()
        for pixel in 0..<width * height { for channel in 0..<count {
            let value: UInt16 = alpha && !gray && channel == 3 ? [0, 16_384, 32_768, 49_152, 65_535, 255][pixel % 6] : UInt16((pixel * 3907 + channel * 1379 + 137) % 65_536)
            if bits == 8 { data.append(UInt8(value >> 8)) }
            else { data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(value >> 8)) }
        } }
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        let alphaInfo: CGImageAlphaInfo = gray || !alpha ? .none : premultiplied ? .premultipliedLast : .last
        var bitmap = CGBitmapInfo(rawValue: alphaInfo.rawValue)
        if bits == 16 { bitmap.insert(.byteOrder16Little) }
        return CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * count,
            bytesPerRow: width * count * bits / 8, space: space, bitmapInfo: bitmap,
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    func provenance(_ image: CGImage, masks: [ArtifactResourceID] = []) throws -> GenerationProvenance {
        let shape = try ArtifactPNGCodec.shape(image)
        let format = try ArtifactRasterFormat(size: shape.size, bitDepth: ArtifactBitDepth(rawValue: shape.bits)!, channels: shape.channels,
            profile: shape.profile!, iccSHA256: ArtifactFileIO.digest(shape.icc!))
        let source = try OriginalSourceFingerprint(standardizedPath: directory.appendingPathComponent("original.bin").path,
            fileSize: 3, modifiedAt: Date(timeIntervalSinceReferenceDate: 42),
            nativeRevision: .init(device: 1, inode: 2, fileSize: 3, modifiedSeconds: 17, modifiedNanoseconds: 0, changedSeconds: 18, changedNanoseconds: 0))
        return try GenerationProvenance(parentSource: .original(source), parentSnapshot: .init(),
            renderedInput: .init(format: format, canonicalPixelSHA256: ArtifactPNGCodec.pixelHash(image, shape: shape), pipelineVersion: 1),
            placement: .init(inputSize: shape.size, outputSize: shape.size, inputOriginX: 0, inputOriginY: 0),
            pipelineVersion: 1, parameterVersion: 1, parameters: .init(values: []),
            provider: .init(providerID: "synthetic-test"), createdAt: Date(timeIntervalSinceReferenceDate: 123.125), execution: .local,
            maskResourceIDs: masks)
    }
    static func bytes(_ handle: ArtifactFileReadHandle) throws -> Data {
        var bytes = Data(); var offset: Int64 = 0
        while offset < handle.bytes { let part = try handle.read(offset: offset); guard !part.isEmpty else { throw ArtifactContractError.corruptArtifact }; bytes.append(part); offset += Int64(part.count) }
        return bytes
    }
    static func decode(_ handle: ArtifactFileReadHandle) throws -> CGImage {
        let bytes = try bytes(handle)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ArtifactContractError.corruptArtifact }; return image
    }
}

struct GeneratedArtifactStoreTests {
    struct RasterCase: Sendable { let bits: Int; let alpha: Bool; let p3: Bool }
    static let formats = [8, 16].flatMap { bits in [false, true].flatMap { alpha in [false, true].map { RasterCase(bits: bits, alpha: alpha, p3: $0) } } }
    @Test(arguments: formats)
    func nativeRoundtripSurvivesRestartWithoutOriginal(format: RasterCase) async throws {
        let bits = format.bits, alpha = format.alpha, p3 = format.p3
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let image = fixture.image(bits: bits, alpha: alpha, p3: p3)
        let store = try await fixture.store()
        let provenance = try fixture.provenance(image)
        let draft = try await store.stageRaster(.init(immutableImage: image), provenance: provenance, masks: [])
        let commit = EditingCommitID(); let publication = try await store.publish(draft, commitID: commit)
        try await store.validatePublication(publication)
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("original.bin"))
        let reopened = try await fixture.store()
        let reopenedID = await reopened.storeID; let originalID = await store.storeID
        #expect(reopenedID == originalID)
        let handle = try await reopened.openVerifiedRaster(draft.artifact.id)
        #expect(handle.artifact == publication.artifact)
        let decoded = try ArtifactTestFixture.decode(handle.file)
        #expect(try ArtifactPNGCodec.pixelHash(decoded, shape: ArtifactPNGCodec.shape(decoded)) == ArtifactPNGCodec.pixelHash(image, shape: ArtifactPNGCodec.shape(image)))
        let decodedICC = decoded.colorSpace?.copyICCData() as Data?
        let sourceICC = image.colorSpace?.copyICCData() as Data?
        #expect(decodedICC == sourceICC)
        #expect(handle.artifact.provenance == provenance)
        #expect(handle.artifact.raster.format.bitDepth.rawValue == bits)
    }
    @Test func sameDraftCommitReplaysAndDifferentCommitIsRejected() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let store = try await fixture.store(); let image = fixture.image()
        let draft = try await store.stageRaster(.init(immutableImage: image), provenance: fixture.provenance(image), masks: [])
        let commit = EditingCommitID(); let first = try await store.publish(draft, commitID: commit)
        let repeated = try await store.publish(draft, commitID: commit)
        #expect(first.artifact == repeated.artifact)
        await #expect(throws: ArtifactContractError.conflictingCommit) { _ = try await store.publish(draft, commitID: .init()) }
        let recovery = try await store.recoverStagingAndReportOrphans(referenced: [])
        #expect(recovery.retainedOrphans == [first.artifact.id])
        try await store.validatePublication(repeated)
    }
    @Test func foreignStoreCannotClaimDraftOrPublication() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let other = try ArtifactTestFixture(); defer { other.remove() }
        let store = try await fixture.store(); let foreign = try await other.store(); let image = fixture.image()
        let draft = try await store.stageRaster(.init(immutableImage: image), provenance: fixture.provenance(image), masks: [])
        await #expect(throws: ArtifactContractError.invalidCapability) { _ = try await foreign.publish(draft, commitID: .init()) }
        let publication = try await store.publish(draft, commitID: .init())
        await #expect(throws: ArtifactContractError.invalidCapability) { try await foreign.validatePublication(publication) }
    }
    @Test func pinnedReadRejectsSameByteForeignReplacementAndMissingPayload() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let store = try await fixture.store(); let image = fixture.image()
        let draft = try await store.stageRaster(.init(immutableImage: image), provenance: fixture.provenance(image), masks: [])
        _ = try await store.publish(draft, commitID: .init())
        let opened = try await store.openVerifiedRaster(draft.artifact.id)
        let path = fixture.directory.appendingPathComponent("GeneratedArtifacts/\(draft.artifact.id.canonicalString)/raster.png")
        let bytes = try Data(contentsOf: path); try bytes.write(to: path, options: .atomic)
        #expect(throws: ArtifactContractError.corruptArtifact) { _ = try opened.file.read(offset: 0) }
        try FileManager.default.removeItem(at: path)
        await #expect(throws: ArtifactContractError.missingArtifact) { _ = try await store.openVerifiedRaster(draft.artifact.id) }
    }
    @Test func unsupportedAlphaAndWrongMaskGeometryPreserveOriginal() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let store = try await fixture.store(); let good = fixture.image(); let bad = fixture.image(premultiplied: true)
        let original = fixture.directory.appendingPathComponent("original.bin"); let before = try Data(contentsOf: original)
        await #expect(throws: ArtifactContractError.unsupportedFormat) { _ = try await store.stageRaster(.init(immutableImage: bad), provenance: fixture.provenance(good), masks: []) }
        let maskID = ArtifactResourceID(); let wrong = fixture.image(alpha: false, gray: true, width: 2)
        await #expect(throws: ArtifactContractError.invalidValue("Maskencanvas")) {
            _ = try await store.stageRaster(.init(immutableImage: good), provenance: fixture.provenance(good, masks: [maskID]),
                masks: [.init(id: maskID, coordinateSpace: .inputCanvas, immutableImage: wrong)])
        }
        #expect(try Data(contentsOf: original) == before)
    }
    @Test func ordinaryGray8MaskKeepsExactSamplesAndNoProfileMetadata() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let store = try await fixture.store(); let image = fixture.image(); let mask = fixture.image(alpha: false, gray: true)
        let maskID = ArtifactResourceID()
        let draft = try await store.stageRaster(.init(immutableImage: image), provenance: fixture.provenance(image, masks: [maskID]),
            masks: [.init(id: maskID, coordinateSpace: .inputCanvas, immutableImage: mask)])
        _ = try await store.publish(draft, commitID: .init())
        let handle = try await store.openVerifiedFile(draft.artifact.id, role: .mask(maskID))
        let decoded = try ArtifactTestFixture.decode(handle)
        #expect(try ArtifactPNGCodec.pixelHash(decoded, shape: ArtifactPNGCodec.shape(decoded, gray: true)) == ArtifactPNGCodec.pixelHash(mask, shape: ArtifactPNGCodec.shape(mask, gray: true)))
        let directory = try ArtifactFileIO.root(fixture.directory.appendingPathComponent("GeneratedArtifacts/\(draft.artifact.id.canonicalString)"), create: false)
        let structure = try ArtifactPNGCodec.inspect(ArtifactFileIO.openFile(directory, GeneratedArtifactStore.maskName(maskID)))
        #expect(structure.type == 0 && structure.icc == nil && structure.bits == 8)
    }
}


private actor ArtifactValidationResources: ArtifactResourceAdmitting {
    struct Counts: Equatable, Sendable { let codecs: Int; let transfers: Int }
    private let owner: ArtifactResourceOwner
    private var codecs = 0, transfers = 0
    init() throws { owner = ArtifactResourceOwner(limits: try .init()) }
    func acquire(kind: ArtifactAdmissionKind, bytes: Int64, priority: ArtifactResourcePriority,
                 retaining: [ArtifactMemoryReservation]) async throws -> ArtifactResourceLease {
        let lease = try await owner.acquire(kind: kind, bytes: bytes, priority: priority, retaining: retaining)
        if kind == .codec { codecs += 1 }
        if kind == .transfer { transfers += 1 }
        return lease
    }
    func retain(bytes: Int64, from lease: ArtifactResourceLease) async throws -> ArtifactMemoryReservation {
        try await owner.retain(bytes: bytes, from: lease)
    }
    func validate(_ memory: ArtifactMemoryReservation, minimumBytes: Int64) async throws {
        try await owner.validate(memory, minimumBytes: minimumBytes)
    }
    func counts() -> Counts { .init(codecs: codecs, transfers: transfers) }
}

extension GeneratedArtifactStoreTests {
    @Test func repeatedFreshRasterAndMaskOpensReuseOnlySuccessfulNativeValidation() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let store = try await fixture.store(), image = fixture.image()
        let maskID = ArtifactResourceID(), mask = fixture.image(alpha: false, gray: true)
        let draft = try await store.stageRaster(.init(immutableImage: image), provenance: fixture.provenance(image, masks: [maskID]),
            masks: [.init(id: maskID, coordinateSpace: .inputCanvas, immutableImage: mask)])
        _ = try await store.publish(draft, commitID: .init())
        let resources = try ArtifactValidationResources()
        let reopened = try await GeneratedArtifactStore.open(in: fixture.directory, resources: resources)
        let first = try await reopened.openVerifiedRaster(draft.artifact.id)
        _ = try await reopened.openVerifiedFile(draft.artifact.id, role: .mask(maskID))
        let cold = await resources.counts()
        #expect(cold.codecs == 2 && cold.transfers == 4)
        for _ in 0..<4 {
            let raster = try await reopened.openVerifiedRaster(draft.artifact.id)
            let maskFile = try await reopened.openVerifiedFile(draft.artifact.id, role: .mask(maskID))
            #expect(try ArtifactTestFixture.bytes(raster.file) == ArtifactTestFixture.bytes(first.file))
            #expect(maskFile.sha256 == draft.artifact.resources.first?.file.sha256)
        }
        let warm = await resources.counts()
        #expect(warm == cold, "Native cache hits do not acquire another codec or stream-hash transfer")
        // Warm content evidence cannot bypass the fresh manifest read.
        let manifest = fixture.directory.appendingPathComponent("GeneratedArtifacts/\(draft.artifact.id.canonicalString)/artifact.json")
        var bytes = try Data(contentsOf: manifest); bytes.append(0x20)
        try bytes.write(to: manifest, options: .atomic)
        await #expect(throws: ArtifactContractError.corruptArtifact) { _ = try await reopened.openVerifiedRaster(draft.artifact.id) }
    }

    @Test func sameByteNewInodeRequiresFullValidationAndOldReaderRemainsInvalid() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let store = try await fixture.store(), image = fixture.image()
        let draft = try await store.stageRaster(.init(immutableImage: image), provenance: fixture.provenance(image), masks: [])
        _ = try await store.publish(draft, commitID: .init())
        let resources = try ArtifactValidationResources()
        let reopened = try await GeneratedArtifactStore.open(in: fixture.directory, resources: resources)
        let old = try await reopened.openVerifiedRaster(draft.artifact.id)
        let cold = await resources.counts()
        let directory = try ArtifactFileIO.root(fixture.directory.appendingPathComponent("GeneratedArtifacts/\(draft.artifact.id.canonicalString)"), create: false)
        let oldStamp = try ArtifactFileIO.openFile(directory, "raster.png").stamp
        let path = directory.url.appendingPathComponent("raster.png")
        let bytes = try Data(contentsOf: path); try bytes.write(to: path, options: .atomic)
        let newStamp = try ArtifactFileIO.openFile(directory, "raster.png").stamp
        #expect(!oldStamp.sameObject(newStamp))
        #expect(throws: ArtifactContractError.corruptArtifact) { _ = try old.file.read(offset: 0) }
        let replacement = try await reopened.openVerifiedRaster(draft.artifact.id)
        #expect(try ArtifactTestFixture.bytes(replacement.file) == bytes)
        let changed = await resources.counts()
        #expect(changed.codecs == cold.codecs + 1 && changed.transfers == cold.transfers + 2)
        _ = try await reopened.openVerifiedRaster(draft.artifact.id)
        #expect(await resources.counts() == changed)
    }

    @Test func restoredMtimeNeverHidesSameInodeContentChangesFromValidationCache() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let store = try await fixture.store(), image = fixture.image()
        let draft = try await store.stageRaster(.init(immutableImage: image), provenance: fixture.provenance(image), masks: [])
        _ = try await store.publish(draft, commitID: .init())
        let resources = try ArtifactValidationResources()
        let reopened = try await GeneratedArtifactStore.open(in: fixture.directory, resources: resources)
        _ = try await reopened.openVerifiedRaster(draft.artifact.id)
        let cold = await resources.counts()
        let directory = try ArtifactFileIO.root(fixture.directory.appendingPathComponent("GeneratedArtifacts/\(draft.artifact.id.canonicalString)"), create: false)
        let file = try ArtifactFileIO.openFile(directory, "raster.png")
        let writer = open(directory.url.appendingPathComponent("raster.png").path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        #expect(writer >= 0); guard writer >= 0 else { return }; defer { close(writer) }
        var before = stat(); #expect(fstat(writer, &before) == 0)
        // Same native bytes and mtime, changed ctime: full codec validation is
        // still required. The cache never treats mtime/size as identity proof.
        let originalByte = try file.read(offset: 0, count: 1)
        #expect(originalByte.withUnsafeBytes { pwrite(writer, $0.baseAddress!, 1, 0) } == 1)
        var times = [before.st_atimespec, before.st_mtimespec]
        #expect(futimens(writer, &times) == 0 && fsync(writer) == 0)
        let revised = try ArtifactFileIO.openFile(directory, "raster.png")
        #expect(revised.stamp.sameObject(file.stamp))
        #expect(revised.stamp.modifiedSeconds == file.stamp.modifiedSeconds && revised.stamp.modifiedNanos == file.stamp.modifiedNanos)
        #expect(revised.stamp != file.stamp)
        _ = try await reopened.openVerifiedRaster(draft.artifact.id)
        let revalidated = await resources.counts()
        #expect(revalidated.codecs == cold.codecs + 1 && revalidated.transfers == cold.transfers + 2)
        // A new ctime with corrupted bytes and exactly restored mtime must fail
        // at full digest validation before any fresh codec is admitted.
        var changedByte: UInt8 = originalByte[0] ^ 0xff
        #expect(pwrite(writer, &changedByte, 1, 0) == 1)
        #expect(futimens(writer, &times) == 0 && fsync(writer) == 0)
        await #expect(throws: ArtifactContractError.corruptArtifact) { _ = try await reopened.openVerifiedRaster(draft.artifact.id) }
        let rejected = await resources.counts()
        #expect(rejected.codecs == revalidated.codecs && rejected.transfers == revalidated.transfers + 1)
        await #expect(throws: ArtifactContractError.corruptArtifact) { _ = try await reopened.openVerifiedRaster(draft.artifact.id) }
    }
}
