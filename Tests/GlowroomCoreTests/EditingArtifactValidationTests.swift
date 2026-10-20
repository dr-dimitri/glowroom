import Foundation
import Testing
@testable import GlowroomCore

@Suite("Artifact wire format and recursive corruption boundaries")
struct EditingArtifactValidationTests {
    @Test func exactReferenceDateBitsSurviveCanonicalProvenanceRoundtrip() async throws {
        let f = try EditingFixture(),parent = try await f.save(exposure:1.25),draft = try await f.draft(parent:parent)
        let encoded = try ArtifactJSONCodec.encode(draft.artifact)
        let decoded = try ArtifactJSONCodec.decode(GeneratedArtifact.self,from:encoded)
        #expect(decoded == draft.artifact)
        #expect(decoded.provenance.createdAt.timeIntervalSinceReferenceDate.bitPattern == draft.artifact.provenance.createdAt.timeIntervalSinceReferenceDate.bitPattern)
        #expect(try ArtifactJSONCodec.encode(decoded) == encoded)
    }
    @Test func duplicateUnknownInactiveAndOversizedJSONRejectBeforeDecode() throws {
        let value = try EditingSnapshot(),data = try ArtifactJSONCodec.encode(value)
        let original = String(decoding:data,as:UTF8.self)
        let duplicate = original.replacingOccurrences(of:"\"schemaVersion\":2",with:"\"schemaVersion\":2,\"schemaVersion\":2")
        let unknown = "{\"unexpected\":null,"+original.dropFirst()
        for input in [Data(duplicate.utf8),Data(unknown.utf8),Data("{\"schemaVersion\":2,\"source\":{\"kind\":\"original\",\"artifactID\":null},\"settings\":{}}".utf8)] {
            #expect(throws:(any Error).self) {try ArtifactJSONCodec.decode(EditingSnapshot.self,from:input)}
        }
        #expect(throws:ArtifactContractError.limitExceeded) {try ArtifactJSONCodec.decode(EditingSnapshot.self,from:data,maximum:data.count-1)}
    }
    @Test func synthesizedCodableCannotAdmitNegativeBytesOrInvalidExpectedState() throws {
        let file = Data("{\"sha256\":\"\(String(repeating:"a",count:64))\",\"bytes\":-1}".utf8)
        #expect(throws:(any Error).self) {try ArtifactJSONCodec.decode(ArtifactFileDescriptor.self,from:file)}
        let expected = try EditingExpectedState(storeEpoch:UUID(),revision:nil,snapshot:nil)
        var object = try #require(JSONSerialization.jsonObject(with:ArtifactJSONCodec.encode(expected)) as? [String:Any])
        object["revision"] = -1
        #expect(throws:(any Error).self) {try ArtifactJSONCodec.decode(EditingExpectedState.self,from:JSONSerialization.data(withJSONObject:object))}
        object["revision"] = NSNull();object["snapshot"] = try JSONSerialization.jsonObject(with:ArtifactJSONCodec.encode(EditingSnapshot()))
        #expect(throws:(any Error).self) {try ArtifactJSONCodec.decode(EditingExpectedState.self,from:JSONSerialization.data(withJSONObject:object))}
    }
    @Test func wrongSchemasAlphaAndNativeNanosecondsNeverNormalizeIntoValidValues() async throws {
        let f = try EditingFixture(),parent = try await f.save(exposure:0),draft = try await f.draft(parent:parent)
        var format = try jsonObject(draft.artifact.raster.format)
        format["schemaVersion"] = 99
        #expect(throws:(any Error).self) {try ArtifactJSONCodec.decode(ArtifactRasterFormat.self,from:JSONSerialization.data(withJSONObject:format))}
        format["schemaVersion"] = 1;format["alpha"] = "none"
        #expect(throws:(any Error).self) {try ArtifactJSONCodec.decode(ArtifactRasterFormat.self,from:JSONSerialization.data(withJSONObject:format))}
        if case .original(let original) = draft.artifact.provenance.parentSource {
            var native = try jsonObject(original.nativeRevision);native["changedNanoseconds"] = 1_000_000_000
            #expect(throws:(any Error).self) {try ArtifactJSONCodec.decode(OriginalSourceRevision.self,from:JSONSerialization.data(withJSONObject:native))}
        }else{Issue.record("Synthetic original expected")}
    }
    @Test func duplicateParameterAndGeometryMismatchRejectSynthesizedDecoders() async throws {
        let parameter = GenerationParameter(key:.steps,value:.integer(5))
        let invalid = Data("{\"schemaVersion\":1,\"values\":[\(String(decoding:try ArtifactJSONCodec.encode(parameter),as:UTF8.self)),\(String(decoding:try ArtifactJSONCodec.encode(parameter),as:UTF8.self))]}".utf8)
        #expect(throws:(any Error).self) {try ArtifactJSONCodec.decode(GenerationParameters.self,from:invalid)}
        let f = try EditingFixture(),parent = try await f.save(exposure:0),draft = try await f.draft(parent:parent)
        var provenance = try jsonObject(draft.artifact.provenance)
        var placement = try #require(provenance["placement"] as? [String:Any]);placement["inputOriginX"] = 1;provenance["placement"] = placement
        #expect(throws:(any Error).self) {try ArtifactJSONCodec.decode(GenerationProvenance.self,from:JSONSerialization.data(withJSONObject:provenance))}
    }
    @Test func tamperedManifestHashAndMissingMaskBindingReject() async throws {
        let f = try EditingFixture(),parent = try await f.save(exposure:0),draft = try await f.draft(parent:parent)
        var artifact = try jsonObject(draft.artifact)
        artifact["manifestSHA256"] = String(repeating:"f",count:64)
        #expect(throws:ArtifactContractError.corruptArtifact) {try ArtifactJSONCodec.decode(GeneratedArtifact.self,from:JSONSerialization.data(withJSONObject:artifact))}
        let m = ArtifactMaskDescriptor(id:.init(),size:try .init(width:1,height:1),coordinateSpace:.inputCanvas,file:try .init(sha256:.init(sha256:String(repeating:"a",count:64)),bytes:10))
        let manifest = GeneratedArtifactManifest(id:draft.artifact.id,raster:draft.artifact.raster,provenance:draft.artifact.provenance,resources:[m])
        #expect(throws:(any Error).self) {try ArtifactJSONCodec.decode(GeneratedArtifactManifest.self,from:ArtifactJSONCodec.encode(manifest))}
    }
    @Test func immutableLegacySQLRepeatedValidationHasStableVirtualEpochAndNoMutation() async throws {
        let f = try EditingFixture();try editingLegacy(f.directory)
        let original = try Data(contentsOf:f.repository.fileURL)
        let handle = ArtifactFileReadHandle(bytes:Int64(original.count),sha256:try ArtifactJSONCodec.digestBytes(original),ownership:nil) {offset,count in
            original.subdata(in:Int(offset)..<min(original.count,Int(offset)+count))
        }
        let first = try await EditingClosedSQLValidator.validate(privateStagedSQLURL:f.repository.fileURL,pinnedOwnership:handle)
        let second = try await EditingClosedSQLValidator.validate(privateStagedSQLURL:f.repository.fileURL,pinnedOwnership:handle)
        #expect(first.sourceStoreEpoch == second.sourceStoreEpoch)
        #expect(first.referencedArtifacts.isEmpty && second.referencedArtifacts.isEmpty)
        #expect(first.database === handle && second.database === handle)
        #expect(try Data(contentsOf:f.repository.fileURL) == original)
        #expect(try editingScalar(f.repository.fileURL,"PRAGMA user_version") == 1)
    }
}
private func jsonObject<T:Encodable>(_ value:T) throws -> [String:Any] {try #require(JSONSerialization.jsonObject(with:ArtifactJSONCodec.encode(value)) as? [String:Any])}
