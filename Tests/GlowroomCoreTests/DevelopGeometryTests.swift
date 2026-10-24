import Foundation
import Testing
@testable import GlowroomCore

@Suite("Persistent develop geometry")
struct DevelopGeometryTests {
    @Test func legacyReplacementBytesKeepZeroOffsetsAndMovedReplacementsRoundTrip() throws {
        let historical = Data("{\"bounds\":{\"height\":0.4,\"width\":0.3,\"x\":0.1,\"y\":0.2},\"height\":1,\"rgba\":\"FB4o/w==\",\"width\":1}".utf8)
        let decoded = try ArtifactJSONCodec.decode(DevelopRetouchReplacement.self, from: historical)
        #expect(decoded.offsetX == 0 && decoded.offsetY == 0)
        #expect(try ArtifactJSONCodec.encode(decoded) == historical)
        let explicitZero = try DevelopRetouchReplacement(bounds: decoded.bounds, width: decoded.width,
            height: decoded.height, rgba: decoded.rgba, offsetX: 0, offsetY: -0.0)
        #expect(try ArtifactJSONCodec.encode(explicitZero) == historical)

        for offsets in [(0.5, 0.0), (-0.25, 0.5), (0.5, -0.5)] {
            let moved = try DevelopRetouchReplacement(bounds: .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                width: 1, height: 1, rgba: decoded.rgba, offsetX: offsets.0, offsetY: offsets.1)
            let bytes = try ArtifactJSONCodec.encode(moved)
            #expect(try ArtifactJSONCodec.decode(DevelopRetouchReplacement.self, from: bytes) == moved)
            if offsets.1 == 0 { #expect(!String(decoding: bytes, as: UTF8.self).contains("offsetY")) }
            let point = try LocalMaskPoint(x: 0.5, y: 0.5)
            let stroke = try DevelopRetouchStroke(source: point, target: point, radius: 0.05, replacement: moved)
            let snapshot = try EditingSnapshot(settings: .init(developGeometry: .init(retouchStrokes: [stroke])))
            #expect(try ArtifactJSONCodec.decode(EditingSnapshot.self, from: ArtifactJSONCodec.encode(snapshot)) == snapshot)
        }
    }

    @Test func replacementOffsetsMustBeFiniteBoundedAndKeepAPositiveImageIntersection() throws {
        let bounds = try DevelopCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let pixels = Data([20, 30, 40, 255])
        for invalid in [Double.nan, .infinity, -.infinity, -1.01, 1.01, -1, 1, -0.75, 0.75] {
            #expect(throws: ArtifactContractError.self) {
                try DevelopRetouchReplacement(bounds: bounds, width: 1, height: 1, rgba: pixels, offsetX: invalid)
            }
            #expect(throws: ArtifactContractError.self) {
                try DevelopRetouchReplacement(bounds: bounds, width: 1, height: 1, rgba: pixels, offsetY: invalid)
            }
        }
        let valid = try DevelopRetouchReplacement(bounds: bounds, width: 1, height: 1, rgba: pixels)
        let encoded = try ArtifactJSONCodec.encode(valid)
        let original = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for axis in ["offsetX", "offsetY"] {
            for invalid in [-1.01, 1.01, -0.75, 0.75] {
                var malformed = original; malformed[axis] = invalid
                #expect(throws: ArtifactContractError.self) {
                    try ArtifactJSONCodec.decode(DevelopRetouchReplacement.self,
                        from: JSONSerialization.data(withJSONObject: malformed))
                }
            }
        }
        // Partly off-canvas context remains valid while its ROI intersects.
        for offset in [-0.749_999, 0.749_999] {
            _ = try DevelopRetouchReplacement(bounds: bounds, width: 1, height: 1,
                rgba: pixels, offsetX: offset, offsetY: offset)
        }
    }

    @Test func historicalRetouchBytesRemainUnchangedAndNewSelectionsRoundTrip() throws {
        let historical = Data("{\"feather\":0.5,\"id\":\"00000000-0000-0000-0000-000000000001\",\"mode\":\"heal\",\"opacity\":1,\"radius\":0.04,\"source\":{\"x\":0.2,\"y\":0.3},\"target\":{\"x\":0.6,\"y\":0.5}}".utf8)
        let decoded = try ArtifactJSONCodec.decode(DevelopRetouchStroke.self, from: historical)
        #expect(decoded.path.isEmpty && decoded.mask == nil)
        #expect(try ArtifactJSONCodec.encode(decoded) == historical)
        let path = try [LocalMaskPoint(x: 0.6, y: 0.5), .init(x: 0.7, y: 0.8)]
        let mask = try LocalMaskRaster(width: 2, height: 2, bytes: Data([0, 128, 255, 0]))
        for selection in [(path, Optional<LocalMaskRaster>.none), ([], Optional(mask)), (path, Optional(mask))] {
            let stroke = try DevelopRetouchStroke(source: decoded.source, target: decoded.target,
                radius: decoded.radius, path: selection.0, mask: selection.1)
            let snapshot = try EditingSnapshot(settings: .init(developGeometry: .init(retouchStrokes: [stroke])))
            #expect(try ArtifactJSONCodec.decode(EditingSnapshot.self, from: ArtifactJSONCodec.encode(snapshot)) == snapshot)
        }
    }

    @Test func retouchSelectionsEnforceIndividualAndAggregateBounds() throws {
        let point = try LocalMaskPoint(x: 0.4, y: 0.4)
        let maximumPath = [LocalMaskPoint](repeating: point, count: DevelopRetouchStroke.maximumPathPoints)
        let largeMask = try LocalMaskRaster(width: 257, height: 2, bytes: Data(count: 514))
        #expect(throws: (any Error).self) {
            try DevelopRetouchStroke(source: point, target: point, radius: 0.1, path: maximumPath + [point])
        }
        #expect(throws: (any Error).self) {
            try DevelopRetouchStroke(source: point, target: point, radius: 0.1, mask: largeMask)
        }
        let paths = try (0..<8).map { _ in try DevelopRetouchStroke(source: point, target: point, radius: 0.1, path: maximumPath) }
        try DevelopGeometry(retouchStrokes: paths).validate()
        let extraPath = try DevelopRetouchStroke(source: point, target: point, radius: 0.1, path: maximumPath)
        #expect(throws: (any Error).self) { try DevelopGeometry(retouchStrokes: paths + [extraPath]).validate() }
        let mask = try LocalMaskRaster(width: 256, height: 256, bytes: Data(count: 65_536))
        let masked = try (0..<16).map { _ in try DevelopRetouchStroke(source: point, target: point, radius: 0.1, mask: mask) }
        try DevelopGeometry(retouchStrokes: masked).validate()
        let extraMask = try DevelopRetouchStroke(source: point, target: point, radius: 0.1, mask: mask)
        #expect(throws: (any Error).self) { try DevelopGeometry(retouchStrokes: masked + [extraMask]).validate() }
    }

    @Test func strictSnapshotsRejectUnknownPathPointAndMaskFields() throws {
        let point = try LocalMaskPoint(x: 0.2, y: 0.3)
        let mask = try LocalMaskRaster(width: 2, height: 2, bytes: Data([0, 0, 255, 0]))
        let replacement = try DevelopRetouchReplacement(bounds: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            width: 1, height: 1, rgba: Data([20, 30, 40, 255]))
        let stroke = try DevelopRetouchStroke(source: point, target: point, radius: 0.1, path: [point], mask: mask,
            replacement: replacement)
        let bytes = try ArtifactJSONCodec.encode(EditingSnapshot(settings: .init(developGeometry: .init(retouchStrokes: [stroke]))))
        let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for target in ["path", "mask", "replacement"] {
            var object = original
            var settings = try #require(object["settings"] as? [String: Any])
            var geometry = try #require(settings["developGeometry"] as? [String: Any])
            var strokes = try #require(geometry["retouchStrokes"] as? [[String: Any]])
            if target == "path" {
                var path = try #require(strokes[0]["path"] as? [[String: Any]])
                path[0]["unexpected"] = true; strokes[0]["path"] = path
            } else {
                var nested = try #require(strokes[0][target] as? [String: Any])
                nested["unexpected"] = true; strokes[0][target] = nested
            }
            geometry["retouchStrokes"] = strokes; settings["developGeometry"] = geometry; object["settings"] = settings
            #expect(throws: (any Error).self) {
                try ArtifactJSONCodec.decode(EditingSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }
    }

    @Test func frozenReplacementRoundTripsAndRejectsMalformedDimensionsAndBytes() throws {
        let bounds = try DevelopCropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let replacement = try DevelopRetouchReplacement(bounds: bounds, width: 2, height: 1,
            rgba: Data([20, 30, 40, 255, 60, 70, 80, 128]))
        let point = try LocalMaskPoint(x: 0.2, y: 0.3)
        let stroke = try DevelopRetouchStroke(source: point, target: point, radius: 0.1,
            path: [point], replacement: replacement)
        let snapshot = try EditingSnapshot(settings: .init(developGeometry: .init(retouchStrokes: [stroke])))
        #expect(try ArtifactJSONCodec.decode(EditingSnapshot.self, from: ArtifactJSONCodec.encode(snapshot)) == snapshot)
        for (width, height, bytes) in [(0, 1, 0), (1, 0, 0), (801, 1, 3204), (1, 801, 3204), (2, 1, 7)] {
            #expect(throws: (any Error).self) {
                try DevelopRetouchReplacement(bounds: bounds, width: width, height: height, rgba: Data(count: bytes))
            }
        }
        let encoded = try ArtifactJSONCodec.encode(replacement)
        var malformed = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        malformed["rgba"] = Data([1, 2]).base64EncodedString()
        #expect(throws: (any Error).self) {
            try ArtifactJSONCodec.decode(DevelopRetouchReplacement.self, from: JSONSerialization.data(withJSONObject: malformed))
        }
        let maximum = try DevelopRetouchReplacement(bounds: bounds, width: 800, height: 800, rgba: Data(count: 2_560_000))
        let largeStroke = try DevelopRetouchStroke(source: point, target: point, radius: 0.1, replacement: maximum)
        try DevelopGeometry(retouchStrokes: [largeStroke]).validate()
        #expect(throws: (any Error).self) {
            try DevelopGeometry(retouchStrokes: [largeStroke, stroke]).validate()
        }
    }

    @Test func maximumFrozenReplacementSurvivesSnapshotSQLBackupAndRestore() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let artifacts = try await fixture.store()
        let packages = EditingBackupPackageStore(resources: fixture.resources,
            catalog: CatalogRepository(directory: fixture.directory))
        let gate = CatalogLifecycleGate(requiresRecovery: false)
        let repository = EditingRepository(directory: fixture.directory, artifacts: artifacts, packages: packages, gate: gate)
        let replacement = try DevelopRetouchReplacement(bounds: .init(x: 0, y: 0, width: 1, height: 1),
            width: 800, height: 800, rgba: Data(repeating: 173, count: 2_560_000))
        let point = try LocalMaskPoint(x: 0.5, y: 0.5)
        let stroke = try DevelopRetouchStroke(source: point, target: point, radius: 0.1, replacement: replacement)
        let snapshot = try EditingSnapshot(settings: .init(developGeometry: .init(retouchStrokes: [stroke])))
        let encoded = try ArtifactJSONCodec.encode(snapshot)
        #expect(encoded.count > 2_097_152 && encoded.count < 4_194_304)
        #expect(try ArtifactJSONCodec.decode(EditingSnapshot.self, from: encoded) == snapshot)
        let empty = try await repository.loadState()
        let first = try await repository.saveSnapshot(snapshot, for: "photo",
            expected: .init(storeEpoch: empty.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        let reopened = EditingRepository(directory: fixture.directory, artifacts: artifacts, packages: packages, gate: gate)
        #expect(try await reopened.loadState().byAsset["photo"]?.snapshot == snapshot)
        let backup = try await repository.createBackup(automatic: false)
        let updated = try await repository.saveSnapshot(.init(), for: "photo", expected: .init(first), revision: 2)
        let restored = try await repository.restoreBackup(from: backup)
        #expect(restored.byAsset["photo"]?.snapshot == snapshot)
        #expect(restored.storeEpoch != first.version.storeEpoch)
        let restoredPhoto = try #require(restored.byAsset["photo"])
        #expect(restoredPhoto.version.revision > updated.version.revision)
        let afterRestore = EditingRepository(directory: fixture.directory, artifacts: artifacts, packages: packages, gate: gate)
        #expect(try await afterRestore.loadState().byAsset["photo"]?.snapshot == snapshot)
        #expect(try ArtifactJSONCodec.encode(restoredPhoto.snapshot) == encoded)
    }

    @Test func replacementStringAllowanceRemainsBoundedAndRejectsInvalidPixels() throws {
        let maximumBytes = DevelopRetouchReplacement.maximumDimension * DevelopRetouchReplacement.maximumDimension * 4
        let bounds = try DevelopCropRect(x: 0, y: 0, width: 1, height: 1)
        let replacement = try DevelopRetouchReplacement(bounds: bounds, width: 800, height: 800,
            rgba: Data(repeating: 173, count: maximumBytes))
        let canonical = try ArtifactJSONCodec.encode(replacement)
        let original = try #require(JSONSerialization.jsonObject(with: canonical) as? [String: Any])
        for failure in ["tooManyBytes", "tooFewBytes", "invalidBase64", "invalidDimensions"] {
            var malformed = original
            switch failure {
            case "tooManyBytes": malformed["rgba"] = Data(count: maximumBytes + 4).base64EncodedString()
            case "tooFewBytes": malformed["rgba"] = Data(count: maximumBytes - 4).base64EncodedString()
            case "invalidBase64":
                let base64 = try #require(original["rgba"] as? String)
                malformed["rgba"] = "!" + String(base64.dropFirst())
            default: malformed["width"] = 801
            }
            #expect(throws: (any Error).self) {
                try ArtifactJSONCodec.decode(DevelopRetouchReplacement.self,
                    from: JSONSerialization.data(withJSONObject: malformed), maximum: EditSettings.maximumEncodedBytes)
            }
        }
        // The allowance is for a typed repair data field, not arbitrary text
        // or unrelated objects that happen to use the same property name.
        let oversized = String(repeating: "a", count: 2_097_153)
        let objects: [[String: Any]] = [["name": oversized], ["unrelated": ["rgba": oversized]]]
        for object in objects {
            let bytes = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) {
                var scanner = ArtifactJSONScanner(bytes, maximum: EditSettings.maximumEncodedBytes)
                try scanner.validate()
            }
        }
    }
    @Test func straighteningDefaultsPreserveHistoricalCanonicalBytes() throws {
        let historical = Data("{\"flipHorizontal\":false,\"flipVertical\":false,\"quarterTurns\":1,\"redEyeCorrections\":[],\"retouchStrokes\":[]}".utf8)
        let decoded = try ArtifactJSONCodec.decode(DevelopGeometry.self, from: historical)
        #expect(decoded.straightenAngle == 0 && decoded.constrainToImage)
        #expect(try ArtifactJSONCodec.encode(decoded) == historical)
        #expect(try ArtifactJSONCodec.encode(DevelopGeometry(quarterTurns: 1)) == historical)
        for angle in [-45.0, -12.5, 0, 19.25, 45] {
            for constrained in [false, true] {
                let geometry = DevelopGeometry(straightenAngle: angle, constrainToImage: constrained)
                #expect(try ArtifactJSONCodec.decode(DevelopGeometry.self, from: ArtifactJSONCodec.encode(geometry)) == geometry)
                let snapshot = try EditingSnapshot(settings: .init(developGeometry: geometry))
                #expect(try ArtifactJSONCodec.decode(EditingSnapshot.self, from: ArtifactJSONCodec.encode(snapshot)) == snapshot)
            }
        }
    }

    @Test func straighteningRejectsInvalidAngles() throws {
        for angle in [-45.01, 45.01, Double.nan, .infinity, -.infinity] {
            #expect(throws: (any Error).self) { try DevelopGeometry(straightenAngle: angle).validate() }
        }
        let malformed = Data("{\"flipHorizontal\":false,\"flipVertical\":false,\"quarterTurns\":0,\"redEyeCorrections\":[],\"retouchStrokes\":[],\"straightenAngle\":46}".utf8)
        #expect(throws: (any Error).self) { try ArtifactJSONCodec.decode(DevelopGeometry.self, from: malformed) }
    }

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
