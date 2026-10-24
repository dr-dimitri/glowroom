import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Frozen develop display identity")
struct DevelopPreviewIdentityTests {
    @Test func everyRevisionBoundaryChangesRenderIdentityEvenWhenThePixelsCanBeShared() {
        let session = UUID()
        let selection = DevelopSelectionIdentity(sessionID: UUID(), generation: 2)
        let baseline = revision(session: session, selection: selection)
        let variants = [
            revision(asset: "B", session: session, selection: selection),
            revision(session: UUID(), selection: selection),
            revision(session: session, generation: 4, selection: selection),
            revision(session: session, local: 6, selection: selection),
            revision(session: session, selection: .init(sessionID: UUID(), generation: 2)),
            revision(session: session, selection: .init(sessionID: selection.sessionID, generation: 4)),
            revision(session: session, selection: nil),
            revision(session: session, selection: selection, intent: .currentSourceWithoutSettings),
            revision(session: session, selection: selection, intent: .importedOriginal)
        ]
        let token = UUID()
        let original = identity(revision: baseline, token: token)
        let changed = variants.map { identity(revision: $0, token: token) }
        #expect(changed.allSatisfy { $0 != original })
        #expect(Set(changed + [original]).count == variants.count + 1)
        #expect(original.revision == baseline, "A finished frame keeps its captured revision")
    }

    @Test func sourceLoadTokenProgressiveReadinessAndFullSettingsArePartOfTheRenderTaskIdentity() {
        let token = UUID()
        let original = identity(revision: nil, token: token)
        #expect(identity(revision: nil, token: UUID()) != original)
        #expect(identity(revision: nil, token: nil) != original)
        #expect(identity(revision: nil, token: token, ready: false) != original)
        var color = original.settings
        color.developColor.temperature = 5_500
        var geometry = original.settings
        geometry.developGeometry.quarterTurns = 1
        var levels = original.settings
        levels.levels.master.gamma = 2
        for settings in [color, geometry, levels] {
            let changed = DevelopPreviewRenderIdentity(request: original.request, settings: settings,
                revision: nil, sourceToken: token, finalSourceReady: true)
            #expect(changed != original)
        }
        let refresh = PreviewRequest(source: original.request.source, pixelSize: original.request.pixelSize,
            sourceRevision: "new-source")
        #expect(DevelopPreviewRenderIdentity(request: refresh, settings: original.settings,
            revision: nil, sourceToken: token, finalSourceReady: true) != original)
    }

    private func revision(asset: String = "A", session: UUID, generation: UInt64 = 3, local: Int64 = 5,
                          selection: DevelopSelectionIdentity?, intent: EditingRenderIntent = .currentEditing) -> DevelopPreviewRevision {
        .init(assetID: asset, editorSessionID: session, editorGeneration: generation,
              localRevision: local, selection: selection, intent: intent)
    }

    private func identity(revision: DevelopPreviewRevision?, token: UUID?, ready: Bool = true) -> DevelopPreviewRenderIdentity {
        .init(request: PreviewRequest(url: URL(fileURLWithPath: "/synthetic/frozen.png"),
            modifiedAt: .distantPast, pixelSize: 2_400, allowsEmbeddedPreview: false),
            settings: .neutral, revision: revision, sourceToken: token, finalSourceReady: ready)
    }
}
