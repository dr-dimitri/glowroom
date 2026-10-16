import Foundation
import PicEditCore

/// Immutable metadata captured after repository load/receipt. This never opens a
/// raster or stat()s an original while a grid/inspector builds a request.
struct EditingSourceResolver: EditingSourceResolving {
    let artifacts: [GeneratedArtifactID: ArtifactSourceFingerprint]
    func resolve(asset: PhotoAsset, snapshot: EditingSnapshot, intent: EditingRenderIntent) async throws -> ResolvedEditingSource {
        try Self.resolve(asset: asset, snapshot: snapshot, intent: intent, artifacts: artifacts)
    }
    static func resolve(asset: PhotoAsset, snapshot: EditingSnapshot, intent: EditingRenderIntent,
                        artifacts: [GeneratedArtifactID: ArtifactSourceFingerprint]) throws -> ResolvedEditingSource {
        let settings = intent == .currentEditing ? snapshot.settings : .neutral
        if intent == .importedOriginal {
            return .original(fingerprint: .init(fileURL: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize), nativeRevision: nil, settings: .neutral)
        }
        switch snapshot.source {
        case .original:
            return .original(fingerprint: .init(fileURL: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize), nativeRevision: nil, settings: settings)
        case .artifact(let id):
            guard let fingerprint = artifacts[id] else { throw ArtifactContractError.missingArtifact }
            return .artifact(fingerprint: fingerprint, settings: settings)
        }
    }
}

extension ResolvedEditingSource {
    var identity: AISourceIdentity {
        switch self { case .original(let value, _, _): return .original(value); case .artifact(let value, _): return .artifact(value) }
    }
    var settings: EditSettings {
        switch self { case .original(_, _, let value), .artifact(_, let value): return value }
    }
}

extension AISourceIdentity {
    var originalPathCost: Int { if case .original(let value) = self { return value.standardizedPath.utf8.count }; return 256 }
}
