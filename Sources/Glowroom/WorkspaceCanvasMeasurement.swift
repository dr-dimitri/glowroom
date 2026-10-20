import SwiftUI

private struct WorkspaceCanvasMeasurementKey: EnvironmentKey {
    static let defaultValue: ((CGSize) -> Void)? = nil
}

extension EnvironmentValues {
    /// Opt-in native acceptance diagnostics. Uses the canvas's existing geometry
    /// observation; the app installs no observer or additional state publications.
    var workspaceCanvasMeasurement: ((CGSize) -> Void)? {
        get { self[WorkspaceCanvasMeasurementKey.self] }
        set { self[WorkspaceCanvasMeasurementKey.self] = newValue }
    }
}
