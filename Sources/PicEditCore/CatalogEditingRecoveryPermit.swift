import Foundation

internal struct CatalogRecoveryInventory: Sendable {
    let rootOwnerID: UUID
    let catalog: MetadataCatalogFileReference
    let journalSHA256: ArtifactDigest
}

/// Only joint recovery mints this after proving every durable operation is
/// terminal. Never Codable or constructible by UI, model output or backup JSON.
public final class CatalogEditingRecoveryPermit: Sendable {
    private let files: CatalogCoordinationFiles
    private let gate: CatalogLifecycleGate
    private let maintenance: CatalogMaintenanceAdmission
    private let inventory: CatalogRecoveryInventory
    internal init(files: CatalogCoordinationFiles, gate: CatalogLifecycleGate,
                  maintenance: CatalogMaintenanceAdmission, inventory: CatalogRecoveryInventory) {
        self.files = files; self.gate = gate; self.maintenance = maintenance; self.inventory = inventory
    }
    internal func validateGate(_ expected: CatalogLifecycleGate) throws {
        guard gate === expected else { throw CatalogCoordinationError.invalidCapability }
        try gate.validateRecoveryMaintenance(maintenance)
    }
    /// All staging, backup, decoding and actor awaits finish BEFORE this call.
    /// The final synchronous install runs inside the native journal/catalog CAS.
    internal func withCriticalSection<Result>(_ operation: () throws -> Result) throws -> Result {
        try gate.validateRecoveryMaintenance(maintenance)
        return try files.withRecoveryBoundary(inventory, operation: operation)
    }
}
