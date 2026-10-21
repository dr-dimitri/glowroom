import Combine
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Glowroom starts with a fresh missing data directory", .timeLimit(.minutes(1)))
struct GlowroomStartupTests {
    // Independent roots allow bounded parallel startup without sharing catalogs,
    // SQL files or the user's Application Support directory.
    @Test(arguments: 0..<4) @MainActor
    func freshProductionStartupAllowsCatalogChanges(run: Int) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Glowroom-Fresh-Startup-\(run)-\(UUID().uuidString)", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = CatalogRepository(directory: root)
        let semantic = try SemanticSearchService(directory: root)
        let bootstrap = ArtifactAppBootstrap(directory: root)
        let library = LibraryModel(repository: repository, semanticSearch: semantic, metadataStore: bootstrap.metadata,
            lifecycle: bootstrap.gate, coordinator: { try await bootstrap.coordinator() },
            editingDependencies: { try await bootstrap.editingDependencies() },
            catalogCleanup: { catalog, reference in
                let changed = try await bootstrap.reconcileCatalog(catalog, reference: reference)
                try await semantic.purgeRemovedAssets(retaining: Set(catalog.assets.map(\.id)))
                return changed
            })
        let editor = EditingModel(directory: root, loader: { try await bootstrap.editingDependencies() })
        editor.library = library
        library.synchronizeEditing = { [weak editor] in try await editor?.reloadAfterCatalogChange() }
        library.invalidateEditingSources = { [weak editor] in editor?.invalidateSourcesForCoordination() }
        let metadata = PhotoMetadataModel(store: bootstrap.metadata,
            suggestor: LocalPhotoMetadataSuggestor(service: LocalImageAnalysisFactory.makeSharedService()),
            library: library, editor: editor)
        library.prepareCatalogCleanup = { [weak editor, weak metadata] in
            guard editor?.isRestoring != true, editor?.isBackingUp != true else {
                throw CatalogLifecycleError.maintenanceAlreadyPending
            }
            let saved = await editor?.flush() ?? true
            guard saved || editor?.hasPendingChanges == false,
                  await metadata?.drainAcceptedWrites() ?? true else { throw ArtifactContractError.staleSnapshot }
        }

        let loaded = TestStateSignal(false)
        let observation = library.$isLoading.sink { loading in
            if !loading { loaded.update { $0 = true } }
        }
        let startup: Result<Void, Error>
        do {
            _ = try await loaded.wait("fresh production catalog startup", timeout: .seconds(10), until: { $0 })
            await library.waitForProjection()
            #expect(library.errorMessage == nil)
            #expect(library.coordinationError == nil)
            #expect(editor.errorMessage == nil)
            #expect(library.canModifyCatalog && !library.isReadOnly)
            #expect(library.catalog == LibraryCatalog())
            #expect(try repository.loadStored().reference == .absent)
            startup = .success(())
        } catch {
            startup = .failure(error)
        }
        withExtendedLifetime(observation) {}

        // Drain the production composition even if startup timed out, before
        // the deferred removal can touch any of its temporary files.
        metadata.beginTermination(); library.beginTermination(); editor.beginTermination()
        async let catalogDrained = library.drainAcceptedCatalogOperations()
        async let editingSaved = editor.finishSaving()
        async let metadataDrained = metadata.drainAcceptedWrites()
        let (_, saved, drained) = await (catalogDrained, editingSaved, metadataDrained)
        #expect(saved && drained)
        #expect(await metadata.finishSaving())
        #expect(await library.finishSaving())
        await semantic.shutdown()
        try startup.get()
    }
}
