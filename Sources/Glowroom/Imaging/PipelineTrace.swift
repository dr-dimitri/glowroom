import Foundation
import os.signpost

/// Content-free timing shared by the real app and its Release harness. Spans
/// overlap (analysis is inside graph construction); they must not be summed.
/// No paths, image pixels or edit parameters are recorded.
enum PipelineTrace {
    enum Phase: String, Sendable {
        case sourceCheck, decode, analysis, decodeQueue, renderQueue
        case filterGraph, render, uiHandoff, previewRequest, editedRequest
        case maskRasterization, maskOverlayGraph, maskOverlayImage
    }
    struct Sample: Sendable {
        let phase: Phase
        let nanoseconds: UInt64
    }
    typealias Observer = @Sendable (Sample) -> Void
    @TaskLocal static var observer: Observer?
    private static let log = OSLog(subsystem: "de.glowroom.app", category: .pointsOfInterest)

    struct Span: Sendable {
        let phase: Phase
        let started: UInt64
        let observer: Observer?
        let id: OSSignpostID

        func end() {
            os_signpost(.end, log: PipelineTrace.log, name: "Pipeline phase", signpostID: id,
                        "%{public}@", phase.rawValue)
            observer?(Sample(phase: phase, nanoseconds: DispatchTime.now().uptimeNanoseconds - started))
        }
    }

    static func begin(_ phase: Phase) -> Span {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Pipeline phase", signpostID: id,
                    "%{public}@", phase.rawValue)
        return Span(phase: phase, started: DispatchTime.now().uptimeNanoseconds, observer: observer, id: id)
    }

    static func measure<T>(_ phase: Phase, _ operation: () throws -> T) rethrows -> T {
        let span = begin(phase)
        defer { span.end() }
        return try operation()
    }
}
