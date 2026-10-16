import Foundation

extension EditingRepository {
    /// Read-only diagnosis from one SQL snapshot. Published or unknown payloads
    /// are retained; the artifact store does not delete or infer missing sources.
    @discardableResult public func inspectArtifactRecovery() async throws -> ArtifactRecoveryReport {
        try await gate.withRepositoryAccess(domain:.editing) {try await self.inspectRecovery()}
    }
    func inspectRecovery() async throws -> ArtifactRecoveryReport {
        try await acquireMutation();defer{releaseMutation()}
        let db = try connection()
        let referenced:Set<GeneratedArtifactID> = try sql.read(db) {
            try EditingSQLite.exec(db,"BEGIN DEFERRED")
            do {
                let state = try Self.readState(db,version:2)
                let ids = Set(try EditingClosedSQLValidator.closure(db,state:state).map(\.id))
                try EditingSQLite.exec(db,"COMMIT");return ids
            } catch {try? EditingSQLite.exec(db,"ROLLBACK");throw error}
        }
        // Keep the same repository mutation slot across the actor hop so the
        // report is bound to this complete active+variant+provenance closure.
        let report = try await artifacts.recoverStagingAndReportOrphans(referenced:referenced)
        artifactRecoveryReport = report
        return report
    }
}
