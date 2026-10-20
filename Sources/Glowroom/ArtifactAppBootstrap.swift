import Foundation
import GlowroomCore

struct ArtifactAppDependencies: Sendable {
    let database: EditingRepository
    let artifacts: (any GeneratedArtifactStoring)?
    let artifactStoreError: String?
    let coordinator: JointCatalogCoordinator
    let metadata: PhotoMetadataRepository
    let gate: CatalogLifecycleGate
    let resources: ArtifactResourceOwner
}

/// One actual startup task owns all participants. Editor and Library observe
/// the same recovery barrier; neither can publish half-recovered state.
final class ArtifactAppBootstrap: Sendable {
    let gate: CatalogLifecycleGate
    let metadata: PhotoMetadataRepository
    let startup: Task<CatalogStartupAdmission, Error>
    private let services: Task<ArtifactAppDependencies, Error>

    init(directory: URL) {
        let gate = CatalogLifecycleGate()
        let metadata = PhotoMetadataRepository(directory: directory, gate: gate)
        self.gate = gate; self.metadata = metadata
        let services = Task.detached(priority: .userInitiated) {
            let resources = ArtifactResourceOwner(limits: try .init())
            // Opening positive artifact ownership performs no normal gate wait.
            // Mutable publications still use this exact shared lifecycle gate.
            let artifacts: (any GeneratedArtifactStoring)?
            let artifactStoreError: String?
            do {
                artifacts = try await GeneratedArtifactStore.open(in: directory, resources: resources, lifecycleGate: gate)
                artifactStoreError = nil
            } catch {
                artifacts = nil
                artifactStoreError = "Der Artefaktspeicher ist nicht verfügbar. Vorhandene Dateien bleiben erhalten.\n\n" + error.localizedDescription
            }
            let packages = EditingBackupPackageStore(resources: resources, catalog: CatalogRepository(directory: directory))
            // Real SQL identities and joint journals must still be inspected.
            // An independently damaged raster store cannot gate healthy manual
            // metadata, and a fallback must never mint ownership/publications.
            let repositoryArtifacts: any GeneratedArtifactStoring = artifacts ?? UnavailableArtifactStore(reason: artifactStoreError ?? "Der Artefaktspeicher ist nicht verfügbar.")
            let database = EditingRepository(directory: directory, artifacts: repositoryArtifacts, packages: packages, gate: gate, resources: resources)
            let coordinator = JointCatalogCoordinator(repository: CatalogRepository(directory: directory),
                editing: database, metadata: metadata, gate: gate)
            return ArtifactAppDependencies(database: database, artifacts: artifacts, artifactStoreError: artifactStoreError, coordinator: coordinator,
                                           metadata: metadata, gate: gate, resources: resources)
        }
        self.services = services
        startup = Task.detached(priority: .userInitiated) {
            do {
                let dependencies = try await services.value
                let admission = try await dependencies.coordinator.recoverAndOpen()
                // Conservative diagnostics never delete final artifacts or
                // prevent independent metadata use when editing is damaged.
                _ = try? await dependencies.database.inspectArtifactRecovery()
                return admission
            } catch {
                gate.reportStartupFailure()
                throw error
            }
        }
    }

    func editingDependencies() async throws -> EditingModelDependencies {
        let dependencies = try await services.value
        _ = try await gate.waitForStartup()
        return EditingModelDependencies(database: dependencies.database, artifacts: dependencies.artifacts,
                                        gate: gate, resources: dependencies.resources, artifactStoreError: dependencies.artifactStoreError,
            recoverDatabase: { [coordinator = dependencies.coordinator] url in
                try await coordinator.recoverEditingDatabase(from: url)
            })
    }

    func recoverEditingDatabase(from url: URL) async throws -> EditingStoreState {
        let dependencies = try await services.value
        return try await dependencies.coordinator.recoverEditingDatabase(from: url)
    }

    /// Catalog membership is durable before pruning. Independent databases can
    /// reconcile concurrently; each transaction is atomic and retryable after
    /// interruption. Never infer removal from an unavailable original file.
    func reconcileCatalog(_ catalog: LibraryCatalog, reference: MetadataCatalogFileReference) async throws -> Bool {
        let dependencies = try await services.value
        let before = try await dependencies.database.loadState()
        async let editing = dependencies.database.reconcileCatalog(catalog, reference: reference)
        async let metadata = dependencies.metadata.purgeMissingCatalogAssets(persistedCatalog: catalog, expectedReference: reference)
        let (state, _) = try await (editing, metadata)
        return before.storeEpoch != state.storeEpoch
    }

    /// Available even after a failed startup, so explicit recovery/conflict
    /// inspection remains possible without admitting ordinary writes.
    func coordinator() async throws -> any CatalogMutationCoordinating {
        try await services.value.coordinator
    }
}
