import Foundation
import Testing
@testable import GlowroomCore

@Suite("Versioned radial optics persistence")
struct DevelopOpticsSettingsTests {
    @Test func neutralKeepsHistoricalSnapshotBytes() throws {
        let legacy = EditSettings(developGeometry: DevelopGeometry(straightenAngle: 7, flipHorizontal: true))
        var explicit = legacy
        explicit.developGeometry.optics = try .init(distortion: -0.0)
        let before = try ArtifactJSONCodec.encode(EditingSnapshot(settings: legacy))
        #expect(try ArtifactJSONCodec.encode(EditingSnapshot(settings: explicit)) == before)
        #expect(!String(decoding: before, as: UTF8.self).contains("optics"))
        #expect(try ArtifactJSONCodec.digest(EditingSnapshot(settings: legacy)) == ArtifactJSONCodec.digest(EditingSnapshot(settings: explicit)))
    }

    @Test(arguments: [-100.0, -35, 35, 100])
    func editsRoundtripAsPartOfTheSnapshot(value: Double) throws {
        var settings = EditSettings.neutral
        settings.developGeometry.optics = try .init(distortion: value)
        let snapshot = try EditingSnapshot(settings: settings)
        let data = try ArtifactJSONCodec.encode(snapshot)
        #expect(try ArtifactJSONCodec.decode(EditingSnapshot.self, from: data) == snapshot)
        #expect(settings != .neutral)
        #expect(settings.normalized.developGeometry.optics == settings.developGeometry.optics)
        #expect(settings.developGeometry.optics.coefficient == -0.002 * value)
    }

    @Test func invalidSettingsAreRejected() throws {
        for value in [Double.nan, .infinity, -.infinity, -100.001, 100.001] {
            #expect(throws: ArtifactContractError.self) { try DevelopOpticsSettings(distortion: value) }
        }
        #expect(throws: ArtifactContractError.self) { try DevelopOpticsSettings(version: 2) }
        for json in ["{\"version\":2,\"distortion\":0}", "{\"version\":1,\"distortion\":101}",
                     "{\"version\":1,\"distortion\":null}", "{\"version\":1,\"distortion\":20,\"extra\":0}"] {
            #expect(throws: ArtifactContractError.self) {
                try ArtifactJSONCodec.decode(DevelopOpticsSettings.self, from: Data(json.utf8))
            }
        }
    }

    @Test func historicalGeometryJSONIsAnUnchangedCanonicalFixtureAndNeutralOpticsAreOmitted() throws {
        let historical = Data("{\"flipHorizontal\":true,\"flipVertical\":false,\"quarterTurns\":2,\"redEyeCorrections\":[],\"retouchStrokes\":[],\"straightenAngle\":7}".utf8)
        let geometry = try ArtifactJSONCodec.decode(DevelopGeometry.self, from: historical)
        #expect(geometry.optics == .neutral)
        #expect(try ArtifactJSONCodec.encode(geometry) == historical)
        var explicit = geometry; explicit.optics = .neutral
        #expect(try ArtifactJSONCodec.encode(explicit) == historical)
        // A present but neutral component is noncanonical at the strict
        // persistence boundary; callers must leave it absent.
        var object = try #require(JSONSerialization.jsonObject(with: historical) as? [String: Any])
        object["optics"] = ["version": 1, "distortion": 0]
        #expect(throws: ArtifactContractError.self) {
            try ArtifactJSONCodec.decode(DevelopGeometry.self, from: JSONSerialization.data(withJSONObject: object))
        }
        object["optics"] = ["version": 1, "distortion": 30, "unrecognized": 1]
        #expect(throws: ArtifactContractError.self) {
            try ArtifactJSONCodec.decode(DevelopGeometry.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }
}
