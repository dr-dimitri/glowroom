import Foundation
import Testing
@testable import PicEditCore

@Suite("Persistent develop geometry")
struct DevelopGeometryTests {
    @Test func geometryRoundTripKeepsPatchOrderAndDoesNotChangeOldSettings() throws {
        let geometry = try fixture()
        let bytes = try ArtifactJSONCodec.encode(geometry)
        #expect(try ArtifactJSONCodec.decode(DevelopGeometry.self, from: bytes) == geometry)
        let historical = try ArtifactJSONCodec.encode(EditingSnapshot())
        #expect(!String(decoding: historical, as: UTF8.self).contains("developGeometry"))
        let settings = EditSettings(developGeometry: geometry)
        let snapshot = try EditingSnapshot(settings: settings)
        let serialized = try ArtifactJSONCodec.encode(snapshot)
        #expect(try ArtifactJSONCodec.decode(EditingSnapshot.self, from: serialized) == snapshot)
        #expect(!settings.isNeutral)
        #expect(settings.normalized.developGeometry == geometry)
    }

    @Test func invalidRectsAndPatchesCannotBeCreatedOrDecoded() throws {
        for x in [-0.1, Double.nan, Double.infinity] {
            #expect(throws: (any Error).self) { try DevelopCropRect(x: x, y: 0, width: 0.5, height: 0.5) }
        }
        #expect(throws: (any Error).self) { try DevelopCropRect(x: 0.8, y: 0.1, width: 0.3, height: 0.5) }
        #expect(throws: (any Error).self) { try DevelopCropRect(x: 0, y: 0, width: 0, height: 0.5) }
        #expect(throws: (any Error).self) {
            try DevelopRetouchStroke(source: .init(x: 0.1, y: 0.1), target: .init(x: 0.5, y: 0.5), radius: .nan)
        }
        #expect(throws: (any Error).self) {
            try DevelopRedEyeCorrection(center: .init(x: 0.5, y: 0.5), radiusX: 0.1, radiusY: 0.6)
        }
        let malformed = Data("{\"quarterTurns\":4,\"flipHorizontal\":false,\"flipVertical\":false,\"retouchStrokes\":[],\"redEyeCorrections\":[]}".utf8)
        #expect(throws: (any Error).self) { try ArtifactJSONCodec.decode(DevelopGeometry.self, from: malformed) }
    }

    @Test func normalizationAndAggregateLimitsKeepCanonicalGeometry() throws {
        let full = try DevelopCropRect(x: 0, y: 0, width: 1, height: 1)
        #expect(DevelopGeometry(crop: full, quarterTurns: -4).normalized == .neutral)
        #expect(DevelopGeometry(quarterTurns: -1).normalized.quarterTurns == 3)
        var geometry = try fixture()
        geometry.retouchStrokes.append(geometry.retouchStrokes[0])
        #expect(throws: (any Error).self) { try geometry.validate() }
        geometry = .init(retouchStrokes: try (0...DevelopGeometry.maximumRetouchStrokes).map { _ in
            try DevelopRetouchStroke(source: .init(x: 0.1, y: 0.1), target: .init(x: 0.5, y: 0.5), radius: 0.02)
        })
        #expect(throws: (any Error).self) { try geometry.validate() }
        geometry = .init(redEyeCorrections: try (0...DevelopGeometry.maximumRedEyeCorrections).map { _ in
            try DevelopRedEyeCorrection(center: .init(x: 0.5, y: 0.5), radiusX: 0.02, radiusY: 0.02)
        })
        #expect(throws: (any Error).self) { try geometry.validate() }
    }

    @Test func strictSnapshotRejectsUnknownFieldsAtEveryGeometryLevel() throws {
        let bytes = try ArtifactJSONCodec.encode(EditingSnapshot(settings: .init(developGeometry: fixture())))
        let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for target in ["geometry", "crop", "patch", "point", "eye"] {
            var object = original
            var settings = try #require(object["settings"] as? [String: Any])
            var geometry = try #require(settings["developGeometry"] as? [String: Any])
            if target == "geometry" { geometry["unexpected"] = true }
            else if target == "crop" {
                var crop = try #require(geometry["crop"] as? [String: Any]); crop["unexpected"] = true; geometry["crop"] = crop
            } else if target == "eye" {
                var eyes = try #require(geometry["redEyeCorrections"] as? [[String: Any]])
                eyes[0]["unexpected"] = true; geometry["redEyeCorrections"] = eyes
            } else {
                var patches = try #require(geometry["retouchStrokes"] as? [[String: Any]])
                if target == "patch" { patches[0]["unexpected"] = true }
                else {
                    var point = try #require(patches[0]["source"] as? [String: Any]); point["unexpected"] = true; patches[0]["source"] = point
                }
                geometry["retouchStrokes"] = patches
            }
            settings["developGeometry"] = geometry; object["settings"] = settings
            #expect(throws: (any Error).self) {
                try ArtifactJSONCodec.decode(EditingSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }
    }

    private func fixture() throws -> DevelopGeometry {
        .init(crop: try .init(x: 0.1, y: 0.2, width: 0.6, height: 0.5), quarterTurns: 1, flipHorizontal: true,
            retouchStrokes: try [
                .init(mode: .clone, source: .init(x: 0.1, y: 0.2), target: .init(x: 0.7, y: 0.4), radius: 0.03),
                .init(source: .init(x: 0.2, y: 0.3), target: .init(x: 0.6, y: 0.5), radius: 0.04, feather: 0.8)
            ], redEyeCorrections: try [.init(center: .init(x: 0.5, y: 0.4), radiusX: 0.02, radiusY: 0.03)])
    }
}
