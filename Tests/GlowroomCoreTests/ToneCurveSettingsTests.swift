import Foundation
import Testing
@testable import GlowroomCore

@Suite("Versioned monotone point curves")
struct ToneCurveSettingsTests {
    private var sCurve: ToneCurve { .init(points: [.init(x: 0, y: 0.02), .init(x: 0.25, y: 0.15), .init(x: 0.75, y: 0.85), .init(x: 1, y: 0.98)]) }

    @Test func controlPointsAreExactAndDenseCurvesAreMonotoneWithoutOvershoot() throws {
        let fixtures = [sCurve,
            ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.001, y: 0.6), .init(x: 0.501, y: 0.6), .init(x: 0.502, y: 1), .init(x: 1, y: 1)]),
            ToneCurve(points: [.init(x: 0, y: 0.5), .init(x: 1, y: 0.5)]),
            ToneCurve(points: (0..<16).map { .init(x: Double($0) / 15, y: pow(Double($0) / 15, 3)) })]
        for curve in fixtures {
            try curve.validate()
            for point in curve.points { #expect(abs(try curve.value(for: point.x) - point.y) < 1e-12) }
            var previous = -Double.infinity
            for index in 0...16_384 {
                let x = Double(index) / 16_384, y = try curve.value(for: x)
                let segment = curve.points.firstIndex { $0.x >= x }.map { max(1, $0) }!
                #expect(y >= previous - 1e-12)
                #expect(y >= curve.points[segment - 1].y - 1e-12)
                #expect(y <= curve.points[segment].y + 1e-12)
                previous = y
            }
        }
    }

    @Test func negativeAndHDRContinuationUseUnitSlopeAfterEachCurve() throws {
        let curve = sCurve
        for input in [-4.0, -0.25, 1.25, 8] {
            let expected = input < 0 ? curve.points[0].y + input : curve.points.last!.y + input - 1
            #expect(abs(try curve.value(for: input) - expected) < 1e-12)
        }
        let settings = ToneCurveSettings(master: curve, red: curve)
        let output = try settings.rgb(red: -2, green: 4, blue: 0.5)
        #expect(abs(output.red - (-1.96)) < 1e-12)
        #expect(abs(output.green - 3.98) < 1e-12)
        #expect(abs(output.blue - 0.5) < 1e-12)
        #expect(try ToneCurve.neutral.value(for: -2) == -2)
        #expect(try ToneCurve.neutral.value(for: 8) == 8)
        #expect(throws: ToneCurveValidationError.unrepresentableValue) { try curve.value(for: .nan) }
        #expect(throws: ToneCurveValidationError.unrepresentableValue) { try curve.value(for: .infinity) }
        #expect(throws: ToneCurveValidationError.unrepresentableValue) { try curve.value(for: Double(Float.greatestFiniteMagnitude) * 2) }
    }

    @Test func invalidKnotsAndUnrecognizedVersionsAreRejectedRatherThanRepaired() throws {
        let fixtures = [
            ToneCurve(points: []), ToneCurve(points: [.init(x: 0, y: 0)]),
            ToneCurve(points: [.init(x: 0.01, y: 0), .init(x: 1, y: 1)]),
            ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.99, y: 1)]),
            ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.6), .init(x: 1, y: 0.5)]),
            ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.5), .init(x: 0.5, y: 0.6), .init(x: 1, y: 1)]),
            ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.000_999_9, y: 0.5), .init(x: 1, y: 1)]),
            ToneCurve(points: [.init(x: 0, y: -0.1), .init(x: 1, y: 1)]),
            ToneCurve(points: [.init(x: 0, y: 0), .init(x: 1, y: 1.01)]),
            ToneCurve(points: [.init(x: 0, y: .nan), .init(x: 1, y: 1)]),
            ToneCurve(points: [.init(x: 0, y: 0), .init(x: .infinity, y: 1)]),
            ToneCurve(points: (0..<17).map { .init(x: Double($0) / 16, y: Double($0) / 16) })]
        for fixture in fixtures {
            #expect(throws: (any Error).self) { try fixture.validate() }
            #expect(throws: (any Error).self) { try JSONEncoder().encode(fixture) }
            #expect(fixture.normalized == .neutral)
        }
        let bytes = try JSONEncoder().encode(ToneCurveSettings(master: sCurve))
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["version"] = 2
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ToneCurveSettings.self, from: JSONSerialization.data(withJSONObject: object)) }
        object["version"] = 1; object["transferFunction"] = "future"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ToneCurveSettings.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func roundTripAndChannelResetPreserveTheOtherCurves() throws {
        var settings = ToneCurveSettings(master: sCurve, red: .init(points: [.init(x: 0, y: 0.1), .init(x: 1, y: 0.9)]))
        let bytes = try ArtifactJSONCodec.encode(settings)
        #expect(try ArtifactJSONCodec.decode(ToneCurveSettings.self, from: bytes) == settings)
        #expect(try ArtifactJSONCodec.encode(ArtifactJSONCodec.decode(ToneCurveSettings.self, from: bytes)) == bytes)
        settings[.red] = .neutral
        #expect(settings.red.isNeutral && settings.master == sCurve)
        let extraIdentity = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.4, y: 0.4), .init(x: 1, y: 1)])
        #expect(extraIdentity.isNeutral)
        #expect(extraIdentity.normalized.points.count == 3)
        for value in [-1.0, 0, 0.2, 0.5, 1, 8] { #expect(try extraIdentity.value(for: value) == value) }
    }

    @Test func minimumSpacingBoundaryAndPointCountLimitsAreEnforced() throws {
        try ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.001, y: 0.5), .init(x: 1, y: 1)]).validate()
        try ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.001_000_1, y: 0.5), .init(x: 1, y: 1)]).validate()
        #expect(throws: ToneCurveValidationError.invalidPoints) {
            try ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.000_999_9, y: 0.5), .init(x: 1, y: 1)]).validate()
        }
        for count in [15, 16] {
            try ToneCurve(points: (0..<count).map { .init(x: Double($0) / Double(count - 1), y: Double($0) / Double(count - 1)) }).validate()
        }
    }

    @Test func historicalSnapshotBytesRemainUnchangedAndNewCurvesAreStrictlyVersioned() throws {
        let legacy = Data(#"{"schemaVersion":2,"settings":{"autoToneAmount":100,"blacks":7,"clarity":0,"colorNoiseReduction":0,"contrast":0,"dehaze":0,"exposure":0,"highlights":0,"luminanceNoiseReduction":0,"saturation":0,"shadows":0,"texture":0,"vibrance":0,"whites":-1},"source":{"kind":"original"}}"#.utf8)
        let snapshot = try ArtifactJSONCodec.decode(EditingSnapshot.self, from: legacy)
        #expect(snapshot.settings.toneCurves.isNeutral)
        #expect(try ArtifactJSONCodec.encode(snapshot) == legacy)
        #expect(try ArtifactJSONCodec.digest(snapshot) == ArtifactJSONCodec.digestBytes(legacy))
        let settings = EditSettings(exposure: 0.4, toneCurves: .init(master: sCurve, red: sCurve))
        let accepted = try EditingSnapshot(settings: settings)
        let bytes = try ArtifactJSONCodec.encode(accepted)
        #expect(try ArtifactJSONCodec.decode(EditingSnapshot.self, from: bytes) == accepted)
        #expect(!String(decoding: try ArtifactJSONCodec.encode(EditSettings.neutral), as: UTF8.self).contains("toneCurves"))
        let base = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for malformed in ["unknown", "missing", "neutral", "version", "null", "points"] {
            var object = base
            var controls = try #require(object["settings"] as? [String: Any])
            var curves = try #require(controls["toneCurves"] as? [String: Any])
            switch malformed {
            case "unknown": curves["future"] = true
            case "missing": curves.removeValue(forKey: "blue")
            case "neutral": curves = try #require(JSONSerialization.jsonObject(with: ArtifactJSONCodec.encode(ToneCurveSettings.neutral)) as? [String: Any])
            case "version": curves["version"] = 2
            case "points": curves["master"] = ["points": [["x": 0, "y": 0], ["x": 0.0001, "y": 0.5], ["x": 1, "y": 1]]]
            default: break
            }
            controls["toneCurves"] = malformed == "null" ? NSNull() : curves
            object["settings"] = controls
            #expect(throws: (any Error).self) {
                try ArtifactJSONCodec.decode(EditingSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }
        #expect(try EditParameter.exposure.applying(1, to: settings).toneCurves == settings.toneCurves)
        #expect(settings.resettingAdjustments.toneCurves.isNeutral)
    }

    @Test func durableBackupRestoreAndRestartReproduceAllFourCurves() async throws {
        let fixture = try EditingFixture(), state = try await fixture.repository.loadState()
        let settings = EditSettings(toneCurves: .init(master: sCurve, red: sCurve, green: sCurve, blue: sCurve))
        let original = try EditingSnapshot(settings: settings)
        let stored = try await fixture.repository.saveSnapshot(original, for: fixture.id,
            expected: .init(storeEpoch: state.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        let backup = try await fixture.repository.createBackup(automatic: false)
        _ = try await fixture.repository.saveSnapshot(.init(), for: fixture.id, expected: .init(stored), revision: 2)
        let restored = try await fixture.repository.restoreBackup(from: backup)
        #expect(restored.byAsset[fixture.id]?.snapshot == original)
        #expect(try await fixture.reopen().loadState().byAsset[fixture.id]?.snapshot == original)
    }

    @Test func neutralExtraPointsCannotSplitTheDurableReceiptFromTheSavedSnapshot() async throws {
        let fixture = try EditingFixture(), state = try await fixture.repository.loadState()
        let identity = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.5), .init(x: 1, y: 1)])
        let submittedSettings = EditSettings(toneCurves: .init(master: identity)).normalized
        let submitted = try EditingSnapshot(settings: submittedSettings)
        let receipt = try await fixture.repository.saveSnapshot(submitted, for: fixture.id,
            expected: .init(storeEpoch: state.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        let persisted = try #require(try await fixture.reopen().loadState().byAsset[fixture.id])
        #expect(receipt.snapshot == persisted.snapshot, "A receipt must describe the exact canonical snapshot stored in SQL")
        #expect(submitted.settings.toneCurves == .neutral)
        #expect(try ArtifactJSONCodec.decode(EditingSnapshot.self, from: ArtifactJSONCodec.encode(submitted)) == submitted)
        var changed = submittedSettings
        changed.toneCurves.master = .init(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.6), .init(x: 1, y: 1)])
        let second = try EditingSnapshot(settings: changed)
        let secondReceipt = try await fixture.repository.saveSnapshot(second, for: fixture.id, expected: .init(receipt), revision: 2)
        #expect(secondReceipt.snapshot == second)
        #expect(try await fixture.reopen().loadState().byAsset[fixture.id]?.snapshot == second)
    }

    @Test func editSettingsRejectAnOmittedNoncanonicalIdentityButStandaloneCurvesRemainLossless() throws {
        let identity = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.5), .init(x: 1, y: 1)])
        let standalone = ToneCurveSettings(master: identity)
        #expect(standalone.normalized == .neutral)
        #expect(try ArtifactJSONCodec.decode(ToneCurveSettings.self, from: ArtifactJSONCodec.encode(standalone)) == standalone)
        let noncanonical = EditSettings(toneCurves: standalone)
        #expect(throws: (any Error).self) { try ArtifactJSONCodec.encode(noncanonical) }
        #expect(throws: (any Error).self) { try EditingSnapshot(settings: noncanonical) }
        #expect(noncanonical.normalized == .neutral)
        #expect(try ArtifactJSONCodec.encode(noncanonical.normalized) == ArtifactJSONCodec.encode(EditSettings.neutral))
    }
}
