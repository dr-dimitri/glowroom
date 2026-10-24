import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Levels inspector validated transactions")
struct LevelsInspectorTests {
    @Test(arguments: ToneProcessingVersion.allCases)
    func aParameterTransactionPreservesEveryOtherChannelAndSetting(version: ToneProcessingVersion) throws {
        let baseline = EditSettings(exposure: 1.2, contrast: -15, texture: 20,
            naturalBalanceAmount: 45, developColor: .init(temperature: 8_000, tint: 12, profile: .vivid, hdrEnabled: true),
            levels: .init(master: .init(gamma: 1.4), red: .init(inputBlack: 0.1, inputWhite: 0.8),
                          green: .init(outputBlack: 0.1), blue: .init(clampOutput: true)),
            toneProcessingVersion: version)
        let actual = try LevelsUIParameter.gamma.applying(2, channel: .red, to: baseline)
        var expected = baseline
        expected.levels.red.gamma = 2
        #expect(actual == expected)
        #expect(actual.levels.transferFunction == baseline.levels.transferFunction)
        #expect(actual.levels.version == baseline.levels.version)
    }

    @Test func invalidInputNeverNormalizesOrPartiallyChangesTheSnapshot() throws {
        let baseline = EditSettings(exposure: 0.7,
            levels: .init(master: .init(inputBlack: 0.3, inputWhite: 0.8, outputBlack: 0.2, outputWhite: 0.9)))
        let cases: [(LevelsUIParameter, Double)] = [(.inputBlack, 0.8), (.inputBlack, 0.9),
            (.inputWhite, 0.3), (.inputWhite, 0.300_001), (.gamma, 0.09), (.gamma, 10.01),
            (.outputBlack, 1), (.outputWhite, 0.1)]
        for (parameter, value) in cases {
            #expect(throws: (any Error).self) { try parameter.applying(value, channel: .master, to: baseline) }
            #expect(baseline.levels.master.inputBlack == 0.3 && baseline.levels.master.inputWhite == 0.8)
        }
        for parameter in LevelsUIParameter.allCases {
            for value in [-Double.infinity, Double.infinity, Double.nan] {
                #expect(throws: (any Error).self) { try parameter.applying(value, channel: .master, to: baseline) }
            }
        }
        let constant = try LevelsUIParameter.outputWhite.applying(0.2, channel: .master, to: baseline)
        #expect(constant.levels.master.outputBlack == constant.levels.master.outputWhite)
    }

    @Test func everyPositionOfTheSliderRangePreservesValidEndpoints() throws {
        let curves = [LevelsCurve.neutral,
            LevelsCurve(inputBlack: 0.3, inputWhite: 0.300_01).normalized,
            LevelsCurve(inputBlack: 0.9999, inputWhite: 1).normalized,
            LevelsCurve(outputBlack: 0, outputWhite: 0),
            LevelsCurve(outputBlack: 1, outputWhite: 1)]
        for curve in curves {
            let baseline = EditSettings(levels: .init(master: curve))
            for parameter in LevelsUIParameter.allCases {
                let range = parameter.sliderRange(for: curve)
                #expect(range.contains(curve[keyPath: parameter.keyPath]))
                for index in 0...64 {
                    let value = range.lowerBound + (range.upperBound - range.lowerBound) * Double(index) / 64
                    let result = try parameter.applying(value, channel: .master, to: baseline)
                    try result.levels.master.validate()
                }
            }
        }
    }

    @Test(arguments: ToneProcessingVersion.allCases) @MainActor
    func aGroupedLevelsGestureHasOneUndoStepAndPersistsAllChannels(version: ToneProcessingVersion) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-LevelsUI-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = EditingModel(directory: directory)
        try await waitLoaded(editor)
        let baseline = EditSettings(exposure: 0.5,
            levels: .init(master: .init(gamma: 1.2), green: .init(outputBlack: 0.08)),
            toneProcessingVersion: version)
        editor.setSettings(baseline, for: "A")
        editor.selectEditingFunction(.crop, assetID: "A")
        editor.selectEditingFunction(.adjustments, assetID: "A")
        editor.beginEditing(assetID: "A")
        for value in [1.5, 1.8, 2.0] {
            let next = try LevelsUIParameter.gamma.applying(value, channel: .red, to: editor.settings(for: "A"))
            editor.setSettings(next, for: "A")
        }
        editor.endEditing(assetID: "A")
        let accepted = editor.settings(for: "A")
        #expect(accepted.levels.red.gamma == 2)
        editor.undo(assetID: "A")
        #expect(editor.settings(for: "A") == baseline)
        #expect(!editor.canUndo(assetID: "A"))
        editor.redo(assetID: "A")
        #expect(editor.settings(for: "A") == accepted)
        let revision = editor.localRevision(for: "A")
        #expect(throws: (any Error).self) {
            try LevelsUIParameter.inputWhite.applying(0, channel: .red, to: editor.settings(for: "A"))
        }
        #expect(editor.localRevision(for: "A") == revision)
        #expect(await editor.flush())
        let reopened = EditingModel(directory: directory)
        try await waitLoaded(reopened)
        #expect(reopened.settings(for: "A") == accepted)
    }

    @MainActor
    private func waitLoaded(_ model: EditingModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isLoading && model.canEdit)
    }
}
