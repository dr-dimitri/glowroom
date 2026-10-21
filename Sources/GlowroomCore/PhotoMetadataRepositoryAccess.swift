import Foundation

extension PhotoMetadataRepository {
    func withMetadataAccess<T:Sendable>(_ operation:@escaping @Sendable () async throws->T) async throws -> T {
        if let lifecycleGate {return try await lifecycleGate.withRepositoryAccess(domain:.photoMetadata,operation:operation)}
        return try await operation()
    }
    public func record(assetID:String) async throws -> PhotoMetadataRecord? {
        try await withMetadataAccess {
            return try await self._metadata_record(assetID:assetID)
        }
    }
    public func searchState() async -> PhotoMetadataSearchState {
        do {return try await withMetadataAccess {await self._metadata_searchState()}}
        catch {publishUnavailable(error);return state}
    }
    public func updates() async -> AsyncStream<PhotoMetadataSearchState> {
        do {return try await withMetadataAccess {await self._metadata_updates()}}
        catch {publishUnavailable(error);let current = state;return AsyncStream {$0.yield(current);$0.finish()}}
    }
    public func finishSaving() async -> Bool {
        do {return try await withMetadataAccess {await self._metadata_finishSaving()}}catch {publishUnavailable(error);return false}
    }
    public func saveManualDraft(_ operation:MetadataManualDraftOperation) async throws -> MetadataCommitResult {
        try await withMetadataAccess {
            return try await self._metadata_saveManualDraft(operation)
        }
    }
    public func saveAIDraft(_ operation:MetadataAIDraftOperation) async throws -> MetadataCommitResult {
        try await withMetadataAccess {
            return try await self._metadata_saveAIDraft(operation)
        }
    }
    public func setDraftState(_ operation:MetadataDraftStateOperation) async throws -> MetadataCommitResult {
        try await withMetadataAccess {
            return try await self._metadata_setDraftState(operation)
        }
    }
    public func confirm(_ operation:MetadataConfirmOperation) async throws -> MetadataCommitResult {
        try await withMetadataAccess {
            return try await self._metadata_confirm(operation)
        }
    }
    public func reconcile(_ snapshot:MetadataCatalogSnapshot) async throws -> MetadataReconciliationResult {
        try await withMetadataAccess {
            return try await self._metadata_reconcile(snapshot)
        }
    }
    public func stageCatalogChange(_ change:MetadataCatalogChange) async throws -> MetadataCatalogChangeReceipt {
        try await withMetadataAccess {
            try await self.ensureNoCoordinatedPending()
            return try await self._metadata_stageCatalogChange(change)
        }
    }
    public func completeCatalogChange(id:UUID,persistedCatalog snapshot:MetadataCatalogSnapshot) async throws -> MetadataReconciliationResult {
        try await withMetadataAccess {
            try await self.ensureNoCoordinatedPending()
            return try await self._metadata_completeCatalogChange(id:id, persistedCatalog:snapshot)
        }
    }
    public func recoverCatalogChanges(persistedCatalog snapshot:MetadataCatalogSnapshot) async throws -> MetadataReconciliationResult {
        try await withMetadataAccess {
            try await self.ensureNoCoordinatedPending()
            return try await self._metadata_recoverCatalogChanges(persistedCatalog:snapshot)
        }
    }
    public func resolveCatalogChange(_ operation:MetadataCatalogResolutionOperation) async throws -> MetadataReconciliationResult {
        try await withMetadataAccess {
            try await self.ensureNoCoordinatedPending()
            return try await self._metadata_resolveCatalogChange(operation)
        }
    }
    public func prepareImport(source:URL,protection:MetadataFileProtectionSnapshot) async throws -> MetadataImportReview {
        try await withMetadataAccess {
            return try await self._metadata_prepareImport(source:source, protection:protection)
        }
    }
    public func discardImport(reviewID:UUID) async {
        do {try await withMetadataAccess {await self._metadata_discardImport(reviewID:reviewID)}}catch {publishUnavailable(error)}
    }
    public func commitImport(_ operation:MetadataImportOperation) async throws -> MetadataCommitResult {
        try await withMetadataAccess {
            return try await self._metadata_commitImport(operation)
        }
    }
    public func exportConfirmed(destination:URL,protection:MetadataFileProtectionSnapshot) async throws -> MetadataExportResult {
        try await withMetadataAccess {
            return try await self._metadata_exportConfirmed(destination:destination, protection:protection)
        }
    }
}
