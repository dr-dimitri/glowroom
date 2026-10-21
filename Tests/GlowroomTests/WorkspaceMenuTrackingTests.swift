import AppKit
import Testing
@testable import Glowroom

@Suite("Workspace native menu tracking", .serialized)
@MainActor
struct WorkspaceMenuTrackingTests {
    @Test func openMenuPreservesAnActiveCanvasPickerUntilTheNextEscape() {
        let input = DevelopCropNativeInputView(frame: .zero)
        var cancellations = 0
        input.onCancel = { cancellations += 1 }
        let menu = NSMenu(title: "Zoom")
        let center = NotificationCenter.default
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        defer {
            center.post(name: NSMenu.didEndTrackingNotification, object: menu)
            input.invalidate()
        }
        #expect(!input.cancelForEscape())
        #expect(cancellations == 0)
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(input.cancelForEscape())
        #expect(cancellations == 1)
    }

    @Test func nestedMenusKeepTrackingUntilEveryMenuEnds() {
        let tracking = WorkspaceMenuTracking()
        defer { tracking.stop() }
        let parent = NSMenu(title: "Zoom")
        let child = NSMenu(title: "More")
        let unrelated = NSMenu(title: "Other")
        let center = NotificationCenter.default
        #expect(!tracking.isTracking)
        center.post(name: NSMenu.didBeginTrackingNotification, object: parent)
        center.post(name: NSMenu.didBeginTrackingNotification, object: child)
        center.post(name: NSMenu.didEndTrackingNotification, object: unrelated)
        #expect(tracking.isTracking)
        center.post(name: NSMenu.didEndTrackingNotification, object: child)
        #expect(tracking.isTracking)
        center.post(name: NSMenu.didEndTrackingNotification, object: parent)
        #expect(!tracking.isTracking)
    }

    @Test func dismantlingStopsObservationAndReleasesTrackedMenus() {
        let tracking = WorkspaceMenuTracking()
        let menu = NSMenu(title: "Zoom")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(tracking.isTracking)
        tracking.stop()
        #expect(!tracking.isTracking)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(!tracking.isTracking)
    }
}
