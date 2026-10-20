import AppKit

/// SwiftUI's virtual AccessibilityNode implements AppKit's public Objective-C
/// accessibility selectors without declaring NSAccessibilityProtocol conformance.
/// KVC dispatches those selectors and boxes scalar/rect results without unsafe
/// casts or requiring a system-wide accessibility client permission.
@MainActor
struct WorkspaceAccessibilityElement {
    private let object: NSObject

    static func enableInProcess() {
        // Materialize SwiftUI's accessibility bridge only in this test process.
        // AppKit has no replacement protocol setter for this application flag.
        NSApplication.shared.accessibilitySetValue(NSNumber(value: true),
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    static func descendants(of root: Any?) -> [WorkspaceAccessibilityElement] {
        guard let root else { return [] }
        var pending: [Any] = [root]
        var visited = Set<ObjectIdentifier>()
        var result: [WorkspaceAccessibilityElement] = []
        while let next = pending.popLast() {
            guard let object = next as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { continue }
            let element = WorkspaceAccessibilityElement(object: object)
            result.append(element)
            pending.append(contentsOf: element.value(for: "accessibilityChildren") as? [Any] ?? [])
        }
        return result
    }

    func accessibilityIdentifier() -> String? { value(for: "accessibilityIdentifier") as? String }
    func accessibilityLabel() -> String? { value(for: "accessibilityLabel") as? String }
    func accessibilityValue() -> Any? { value(for: "accessibilityValue") }
    func accessibilityRole() -> NSAccessibility.Role? {
        (value(for: "accessibilityRole") as? String).map { NSAccessibility.Role(rawValue: $0) }
    }
    func accessibilityFrame() -> NSRect {
        (value(for: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
    }
    func isAccessibilityEnabled() -> Bool { value(for: "accessibilityEnabled") as? Bool ?? false }
    func accessibilityPerformPress() -> Bool { value(for: "accessibilityPerformPress") as? Bool ?? false }

    private func value(for key: String) -> Any? {
        let getter = NSSelectorFromString(key)
        let booleanGetter = NSSelectorFromString("is" + key.prefix(1).uppercased() + key.dropFirst())
        guard object.responds(to: getter) || object.responds(to: booleanGetter) else { return nil }
        return object.value(forKey: key)
    }
}
