import AppKit

/// Native pop-up menus run their own tracking loop without becoming a sheet or
/// the workspace's first responder. Keep their keys in AppKit until tracking
/// finishes, including Escape and photo-navigation/rating shortcuts.
@MainActor
final class WorkspaceMenuTracking: NSObject {
    private let menus = NSHashTable<NSMenu>.weakObjects()

    var isTracking: Bool { !menus.allObjects.isEmpty }

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didBeginTracking), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(didEndTracking), name: NSMenu.didEndTrackingNotification, object: nil)
    }

    @objc private func didBeginTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        menus.add(menu)
    }

    @objc private func didEndTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        menus.remove(menu)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        menus.removeAllObjects()
    }
}
