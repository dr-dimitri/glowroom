import Foundation
import Darwin
import CSQLite
import Testing
@testable import PicEditCore

@Suite("Artifact provenance closure uses a bounded heap stack", .serialized, .timeLimit(.minutes(2)))
struct EditingArtifactClosureTests {
    @Test func all4096AllowedAncestorsSurviveAnActualSwiftWorkerStack() async throws {
        let fixture = try ClosureSQLFixture()
        let artifacts = try fixture.chain(4_096)
        try fixture.install(artifacts,active:artifacts.last!.id)
        // Explicitly run the REAL Core function on a Swift background worker,
        // where the previous recursive DFS exhausted its ~512KiB native stack.
        let result = try await Task.detached {try fixture.evaluate()}.value
        #expect(result.count == 4_096)
        #expect(Set(result.map(\.id)) == Set(artifacts.map(\.id)))
        #expect(result.map(\.id.canonicalString) == artifacts.map(\.id.canonicalString).sorted())
    }
    @Test func a4097thAncestorStillFailsAtTheExistingBoundary() async throws {
        let fixture = try ClosureSQLFixture(),artifacts = try fixture.chain(4_097)
        try fixture.install(artifacts,active:artifacts.last!.id)
        #expect(throws:ArtifactContractError.missingArtifact) {try fixture.evaluate()}
    }
    @Test func cycleIsRejectedBeforeAnyUnfinishedParentCanBePublished() throws {
        let fixture = try ClosureSQLFixture(),id = GeneratedArtifactID()
        // Own canonical hash is valid. Its claimed parent points to itself;
        // descent must detect visiting before postorder parent-hash comparison.
        let parent = ArtifactSourceFingerprint(storeID:fixture.storeID,artifactID:id,
            manifestSHA256:fixture.digest,raster:fixture.raster)
        let artifact = try fixture.artifact(id:id,parent:parent)
        try ArtifactValueValidation.artifact(artifact)
        try fixture.install([artifact],active:id)
        #expect(throws:ArtifactContractError.corruptArtifact) {try fixture.evaluate()}
    }
    @Test(arguments:["manifest","raster"])
    func parentFingerprintMismatchCannotBecomeACompleteResult(kind:String) throws {
        let fixture = try ClosureSQLFixture(),parent = try fixture.artifact()
        let different = try ArtifactDigest(sha256:String(repeating:"b",count:64))
        let raster = kind == "raster" ? RasterDescriptor(format:fixture.raster.format,
            file:try .init(sha256:different,bytes:fixture.raster.file.bytes)) : parent.raster
        let fingerprint = ArtifactSourceFingerprint(storeID:fixture.storeID,artifactID:parent.id,
            manifestSHA256:kind == "manifest" ? different : parent.manifestSHA256,raster:raster)
        let child = try fixture.artifact(parent:fingerprint)
        try fixture.install([parent,child],active:child.id)
        #expect(throws:ArtifactContractError.corruptArtifact) {try fixture.evaluate()}
    }
    @Test func variantOnlyRootsAndSharedAncestorsAreIncludedExactlyOnce() throws {
        let fixture = try ClosureSQLFixture(),chain = try fixture.chain(8)
        let shared = fixture.fingerprint(chain[3])
        let other = try fixture.artifact(parent:shared)
        try fixture.install(chain+[other],active:chain.last!.id,variants:[other.id,chain[0].id])
        let result = try fixture.evaluate()
        #expect(result.count == 9 && Set(result.map(\.id)).count == 9)
        #expect(Set(result.map(\.id)) == Set((chain+[other]).map(\.id)))
    }
    @Test func missingParentStillFailsClosed() throws {
        let fixture = try ClosureSQLFixture()
        let absent = ArtifactSourceFingerprint(storeID:fixture.storeID,artifactID:.init(),
            manifestSHA256:fixture.digest,raster:fixture.raster)
        let child = try fixture.artifact(parent:absent)
        try fixture.install([child],active:child.id)
        #expect(throws:ArtifactContractError.missingArtifact) {try fixture.evaluate()}
    }
    @Test func cancellationIsObservedDuringActualSQLTraversal() async throws {
        let fixture = try ClosureSQLFixture(),chain = try fixture.chain(512)
        try fixture.install(chain,active:chain.last!.id)
        let cancellation = ClosureTraversalCancellation()
        await #expect(throws:CancellationError.self) {
            _ = try await Task.detached {try fixture.evaluate(cancelDuringSQL:cancellation)}.value
        }
        #expect(cancellation.didCancel)
        // A canceled reader changed no rows; the same snapshot remains usable.
        #expect(try fixture.evaluate().count == 512)
    }
}

/// Only metadata and canonical SQL blobs are synthesized: no raster codecs,
/// source image decodes, model calls or per-artifact files. Inserts reuse ONE
/// prepared statement inside ONE transaction, including the oversized fixture.
private final class ClosureSQLFixture:@unchecked Sendable {
    let directory:URL,sql:EditingSQLite,db:OpaquePointer
    let storeID = ArtifactStoreID()
    let digest:ArtifactDigest,raster:RasterDescriptor,original:OriginalSourceFingerprint
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Closure-"+UUID().uuidString,isDirectory:true)
        digest = try .init(sha256:String(repeating:"a",count:64))
        let size = try ArtifactPixelSize(width:2,height:2)
        let format = ArtifactRasterFormat(size:size,bitDepth:.eight,channels:.rgba,profile:.displayP3,iccSHA256:digest)
        raster = RasterDescriptor(format:format,file:try .init(sha256:digest,bytes:32))
        original = try .init(standardizedPath:"/synthetic/closure-original",fileSize:1,
            modifiedAt:Date(timeIntervalSinceReferenceDate:750_000_000),nativeRevision:.init(device:1,inode:1,fileSize:1,
                modifiedSeconds:1,modifiedNanoseconds:0,changedSeconds:1,changedNanoseconds:0))
        sql = EditingSQLite(directory:directory)
        db = try sql.open(validateRows:EditingRepository.validateRows)
    }
    deinit {try? sql.closeForReplacement();try? FileManager.default.removeItem(at:directory)}
    func fingerprint(_ artifact:GeneratedArtifact) -> ArtifactSourceFingerprint {
        .init(storeID:storeID,artifactID:artifact.id,manifestSHA256:artifact.manifestSHA256,raster:artifact.raster)
    }
    func artifact(id:GeneratedArtifactID = .init(),parent:ArtifactSourceFingerprint? = nil) throws -> GeneratedArtifact {
        let source:EditingSourceFingerprint = parent.map(EditingSourceFingerprint.artifact) ?? .original(original)
        let sourceRef:EditableSourceRef = parent.map{.artifact($0.artifactID)} ?? .original
        let provenance = try GenerationProvenance(parentSource:source,parentSnapshot:.init(source:sourceRef),
            renderedInput:.init(format:raster.format,canonicalPixelSHA256:digest,pipelineVersion:1),
            placement:.init(inputSize:raster.format.size,outputSize:raster.format.size,inputOriginX:0,inputOriginY:0),
            pipelineVersion:1,parameterVersion:1,parameters:.init(values:[]),provider:.init(providerID:"test.closure"),
            createdAt:original.modifiedAt,execution:.local)
        let manifest = GeneratedArtifactManifest(id:id,raster:raster,provenance:provenance)
        return try .init(id:id,raster:raster,provenance:provenance,manifestSHA256:ArtifactJSONCodec.digest(manifest))
    }
    func chain(_ count:Int) throws -> [GeneratedArtifact] {
        var result:[GeneratedArtifact] = [];result.reserveCapacity(count)
        for _ in 0..<count {result.append(try artifact(parent:result.last.map(fingerprint)))}
        return result
    }
    func install(_ artifacts:[GeneratedArtifact],active:GeneratedArtifactID,variants:[GeneratedArtifactID] = []) throws {
        try sql.transaction(db) {
            try EditingSQLite.statement(db,"INSERT INTO generated_artifacts(id,descriptor) VALUES(?,?)") { statement in
                for artifact in artifacts {
                    try EditingSQLite.bind(artifact.id.canonicalString,1,statement)
                    try EditingSQLite.bind(ArtifactJSONCodec.encode(artifact),2,statement)
                    try EditingSQLite.done(statement)
                    guard sqlite3_reset(statement) == SQLITE_OK,sqlite3_clear_bindings(statement) == SQLITE_OK else {throw EditingRepositoryError.storageFailure}
                }
            }
            try EditingRepository.write(.init(source:.artifact(active)),id:"closure",revision:1,on:db)
            for id in variants {
                try EditingSQLite.statement(db,"INSERT INTO editing_variants(id,asset_id,snapshot,created_at) VALUES(?,?,?,?)") {statement in
                    try EditingSQLite.bind(EditingVariantID().canonicalString,1,statement)
                    try EditingSQLite.bind("closure",2,statement)
                    try EditingSQLite.bind(ArtifactJSONCodec.encode(EditingSnapshot(source:.artifact(id))),3,statement)
                    guard sqlite3_bind_double(statement,4,750_000_000) == SQLITE_OK else {throw EditingRepositoryError.storageFailure}
                    try EditingSQLite.done(statement)
                }
            }
        }
    }
    func evaluate(cancelDuringSQL cancellation:ClosureTraversalCancellation? = nil) throws -> [GeneratedArtifact] {
        let state = try sql.read(db){try EditingRepository.readState(db,version:2)}
        return try sql.read(db) {
            if let cancellation {
                sqlite3_progress_handler(db,1,{ pointer in
                    guard let pointer else {return 0}
                    Unmanaged<ClosureTraversalCancellation>.fromOpaque(pointer).takeUnretainedValue().step()
                    return 0 // Do NOT interrupt SQLite: Core must observe Task cancellation.
                },Unmanaged.passUnretained(cancellation).toOpaque())
            }
            defer{sqlite3_progress_handler(db,0,nil,nil)}
            return try EditingClosedSQLValidator.closure(db,state:state)
        }
    }
}
private final class ClosureTraversalCancellation:@unchecked Sendable {
    private var instructions = 0
    private(set) var didCancel = false
    // SQLite invokes this only on the one owning Swift task. The test reads
    // didCancel only after that task's actual return, never concurrently.
    func step(){
        instructions += 1
        if instructions == 2_048 {
            withUnsafeCurrentTask {task in if let task {task.cancel();didCancel = true}}
        }
    }
}
