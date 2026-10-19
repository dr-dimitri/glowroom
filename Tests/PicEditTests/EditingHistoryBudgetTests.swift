import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Bounded editing history payloads")
struct EditingHistoryBudgetTests {
    @Test func sharedImmutableMatteIsChargedOnceAcrossSliderStatesAndRedo() throws {
        let raster = try LocalMaskRaster(width: 1_024, height: 1_024,
            bytes: Data(repeating: 173, count: 1_024 * 1_024))
        let layer = try LocalAdjustment(name: "Motiv", mask: .init(shape: .subject(raster)))
        var history = BoundedEditingHistory<EditingSnapshot>(maximumBytes: 2 * 1_024 * 1_024,
            footprint: EditingHistoryFootprint.snapshot)
        for i in 0..<125 {
            history.appendUndo(try .init(settings: .init(exposure: Double(i) / 100, localAdjustments: [layer])))
        }
        #expect(history.count == 125)
        #expect(history.byteCount >= raster.bytes.count && history.byteCount < 2 * raster.bytes.count)
        let originalCost = history.byteCount
        for i in (0..<125).reversed() {
            let popped = history.popUndo()
            let value = try #require(popped)
            #expect(value.settings.exposure == Double(i) / 100)
            history.appendRedo(value)
        }
        #expect(history.count == 125 && history.byteCount == originalCost)
        history.clearRedo()
        #expect(history.count == 0 && history.byteCount == 0)
    }

    @Test func equalPixelsInIndependentAllocationsAreBoundedAcrossAssets() throws {
        var history = BoundedEditingHistory<EditingSnapshot>(maximumBytes: 3 * 1_024 * 1_024,
            footprint: EditingHistoryFootprint.snapshot)
        for i in 0..<8 {
            let raster = try LocalMaskRaster(width: 1_024, height: 1_024,
                bytes: Data(repeating: 173, count: 1_024 * 1_024))
            let layer = try LocalAdjustment(name: "Motiv", mask: .init(shape: .subject(raster)))
            history.appendUndo(try .init(settings: .init(exposure: Double(i) / 10, localAdjustments: [layer])),
                for: i.isMultiple(of: 2) ? "A" : "B")
            #expect(history.byteCount <= 3 * 1_024 * 1_024)
        }
        #expect(history.count == 2)
        #expect(history.popUndo("A")?.settings.exposure == 0.6)
        #expect(history.popUndo("B")?.settings.exposure == 0.7)
        #expect(history.byteCount == 0)
    }

    @Test func countLimitPreservesActiveGroupAndLatestActionsThenClearsAllOwnership() throws {
        var history = BoundedEditingHistory<EditingSnapshot>(maximumStates: 4,
            footprint: EditingHistoryFootprint.snapshot)
        history.beginGroup(try .init(settings: .init(exposure: 0.25)), for: "A")
        for i in 1...10 { history.appendUndo(try .init(settings: .init(exposure: Double(i) / 10)), for: "B") }
        #expect(history.count == 4)
        #expect(history.endGroup("A")?.settings.exposure == 0.25)
        for i in (8...10).reversed() { #expect(history.popUndo("B")?.settings.exposure == Double(i) / 10) }
        #expect(!history.canUndo("B"))
        #expect(history.byteCount == 0)
        for i in 0..<10 { history.beginGroup(try .init(), for: String(i)) }
        #expect(history.count == 4)
        history.removeAll()
        #expect(history.count == 0 && history.byteCount == 0 && history.group("9") == nil)
    }
}
