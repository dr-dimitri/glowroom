import Foundation
import Combine

/// Inspection runs on the model-store actor. Opening a panel may check an
/// installation, but never downloads weights or starts inference.
@MainActor
final class AICorrectionReadiness: ObservableObject {
    typealias CheckModel = @Sendable () async throws -> Bool
    enum State: Equatable {
        case checking, ready, missing, failed(String)
    }
    @Published private(set) var state: State = .checking
    private let checkModel: CheckModel

    init(checkModel: @escaping CheckModel) { self.checkModel = checkModel }

    func refresh() async {
        state = .checking
        do {
            let ready = try await checkModel()
            try Task.checkCancellation()
            state = ready ? .ready : .missing
        } catch is CancellationError { }
        catch { state = .failed(error.localizedDescription) }
    }

    static func installedModel() async throws -> Bool {
        #if arch(arm64)
        return try await LLMModelStore.shared.installation() != nil
        #else
        return false
        #endif
    }
}
