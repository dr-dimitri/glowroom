import SwiftUI

private struct OpenAIModelsKey: EnvironmentKey {
    static let defaultValue: (AIModelsDestination) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Presentation only: selecting a card never starts model or photo work.
    var openAIModels: (AIModelsDestination) -> Void {
        get { self[OpenAIModelsKey.self] }
        set { self[OpenAIModelsKey.self] = newValue }
    }
}
