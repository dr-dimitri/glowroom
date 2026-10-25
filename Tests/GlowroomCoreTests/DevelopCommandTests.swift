import Foundation
import Testing
@testable import GlowroomCore

@Suite("Versioned development command contracts")
struct DevelopCommandTests {
    @Test func catalogAndRangesHaveOneAuthority() throws {
        let commands = DevelopCommandID.allCases.map { DevelopCommandDescriptor($0) }
        #expect(commands.count == 6)
        #expect(Set(commands.map(\.id.rawValue)).count == 6)
        #expect(commands.filter(\.isMutation).count == 4)
        let controls = EditParameter.allCases.map(DevelopControlDescriptor.init)
        for (control, parameter) in zip(controls, EditParameter.allCases) {
            #expect(control.minimum == parameter.range.lowerBound && control.maximum == parameter.range.upperBound)
        }
        #expect(try JSONDecoder().decode([DevelopCommandDescriptor].self,
            from: JSONEncoder().encode(commands)) == commands)
    }

    @Test func strictAtomicAbsolutePatch() throws {
        var baseline = EditSettings(exposure: 1, contrast: 4)
        baseline.developColor.temperature = 7_000
        let valid = DevelopNumericPatch([.init(.exposure, 0), .init(.sharpeningRadius, 1.5)])
        let applied = try valid.applying(to: baseline)
        #expect(applied.exposure == 0 && applied.sharpeningRadius == 1.5)
        #expect(applied.contrast == 4 && applied.developColor == baseline.developColor)
        #expect(try DevelopNumericPatch([]).applying(to: baseline) == baseline)
        for invalid in [DevelopNumericPatch([.init(.exposure, 2), .init(.exposure, 3)]),
                        .init([.init(control: "temperature", value: 6_500)]),
                        .init([.init(.exposure, 6)]), .init([.init(.exposure, .infinity)]),
                        .init([.init(.exposure, .nan)])] {
            #expect(throws: DevelopCommandError.invalidPatch) { try invalid.applying(to: baseline) }
        }
        #expect(baseline.exposure == 1)
    }

    @Test func versionsCommandsAndPayloadShapeFailClosed() throws {
        let target = Self.target()
        let id = DevelopCommandRequestID(sessionID: UUID(), sequence: 1)
        #expect(throws: DevelopCommandError.unsupportedVersion) {
            try DevelopCommandRequest(.get, id: id, target: target, version: 99).validate()
        }
        #expect(throws: DevelopCommandError.unknownCommand) {
            try DevelopCommandRequest(command: "develop.magic", id: id, target: target).validate()
        }
        #expect(throws: DevelopCommandError.invalidPatch) {
            try DevelopCommandRequest(.patch, id: id, target: target).validate()
        }
        #expect(throws: DevelopCommandError.invalidPatch) {
            try DevelopCommandRequest(.get, id: id, target: target, patch: .init([])).validate()
        }
    }

    @Test func dedupHasBoundedResultsAndNeverReexecutesRetiredIDs() throws {
        var ledger = DevelopCommandLedger()
        let target = Self.target()
        let first = DevelopCommandRequest(.patch, id: .init(sessionID: ledger.sessionID, sequence: 1),
            target: target, patch: .init([.init(.exposure, 1)]))
        let receipt = DevelopCommandResult(target: target, didChange: true)
        #expect(try ledger.cached(first) == nil)
        ledger.complete(first, result: .success(receipt))
        #expect(try ledger.cached(first)?.get() == receipt)
        let changed = DevelopCommandRequest(.patch, id: first.id, target: target, patch: .init([.init(.exposure, 2)]))
        #expect(throws: DevelopCommandError.requestConflict) { try ledger.cached(changed) }
        for sequence in UInt64(2)...257 {
            let request = DevelopCommandRequest(.get, id: .init(sessionID: ledger.sessionID, sequence: sequence), target: target)
            ledger.complete(request, result: .success(receipt))
        }
        #expect(ledger.count == 256 && ledger.highWater == 257)
        #expect(throws: DevelopCommandError.outcomeUnknown) { try ledger.cached(first) }
        let previousSession = DevelopCommandRequest(.get, id: .init(sessionID: UUID(), sequence: 258), target: target)
        #expect(throws: DevelopCommandError.outcomeUnknown) { try ledger.cached(previousSession) }
        let huge = DevelopCommandRequest(.get, id: .init(sessionID: ledger.sessionID, sequence: 258), target: target)
        ledger.complete(huge, result: .success(receipt), retainedBytes: 65 * 1_024 * 1_024)
        #expect(ledger.retainedBytes == 0 && ledger.count == 0)
        #expect(throws: DevelopCommandError.outcomeUnknown) { try ledger.cached(huge) }
        let invalid = DevelopCommandRequest(.patch, id: .init(sessionID: ledger.sessionID, sequence: 259),
            target: target, patch: .init([.init(.exposure, .nan)]))
        ledger.complete(invalid, result: .failure(.invalidPatch))
        #expect(throws: DevelopCommandError.invalidPatch) { try ledger.cached(invalid)?.get() }
    }

    private static func target() -> DevelopCommandTarget {
        .init(snapshot: .init(assetID: "A", source: .original(.init(fileURL: URL(fileURLWithPath: "/tmp/commands.png"),
            modifiedAt: Date(timeIntervalSince1970: 0), fileSize: 1)), settings: .neutral,
            token: .init(editSessionID: UUID(), editGeneration: 0, selectionSessionID: UUID(), selectionGeneration: 0)), localRevision: 0)
    }
}
