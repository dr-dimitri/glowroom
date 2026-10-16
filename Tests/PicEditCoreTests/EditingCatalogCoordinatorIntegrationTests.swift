import Foundation
import Testing
@testable import PicEditCore

@Suite("Real SQL and catalog coordinator crash recovery")
struct EditingCatalogCoordinatorIntegrationTests {
    @Test func eachDurableCrashPhaseRecoversWithoutRebasingOriginalCommands() async throws {
        let phases:[CatalogCoordinationCheckpoint] = [.preparedJournal,.editingPrepared,.armedJournal,.editingCommitted,.catalogPublished,.completedJournal]
        for phase in phases {
            let f = try await EditingCoordinatorFixture.make(crashAt:phase)
            defer{try? FileManager.default.removeItem(at:f.root)}
            do {try await f.execute();Issue.record("Expected injected \(phase)")}
            catch EditingCoordinatorCrash.injected {}
            let originalCommand = try ArtifactJSONCodec.encode(f.plan.proposal)
            let originalMetadataBytes = f.change.map{try! PhotoMetadataInternalCodec.encode($0)}
            let fresh = try await f.restart()
            _ = try await fresh.coordinator.recoverAndOpen()
            #expect(try await fresh.coordinator.pending().isEmpty)
            let state = try await fresh.editing.loadState()
            let beforeArm = ["preparedJournal","editingPrepared"].contains(String(describing:phase))
            if beforeArm {
                #expect(state.byAsset[f.oldID]?.snapshot == f.stored.snapshot)
                #expect(state.byAsset[f.newID] == nil)
                #expect(try f.catalog.loadStored().reference == f.before.reference)
            } else {
                #expect(state.byAsset[f.oldID] == nil)
                #expect(state.byAsset[f.newID]?.snapshot == f.stored.snapshot)
                #expect(state.tombstones[f.oldID]! > f.stored.version.revision)
                #expect(state.byAsset[f.newID]!.version.revision > f.stored.version.revision)
                #expect(try f.catalog.loadStored().reference == f.after.reference)
            }
            // Original immutable command bytes survive every phase/restart.
            let operation = f.directory.appendingPathComponent("CatalogCoordination").appendingPathComponent(f.plan.proposal.operationID.canonicalString)
            #expect(try Data(contentsOf:operation.appendingPathComponent("editing-command.json")) == originalCommand)
            if let originalMetadataBytes {#expect(try Data(contentsOf:operation.appendingPathComponent("metadata-command.json")) == originalMetadataBytes)}
            let once = try await fresh.editing.loadState()
            _ = try await fresh.coordinator.recoverAndOpen()
            #expect(try await fresh.editing.loadState().byAsset == once.byAsset)
            #expect(try await fresh.editing.loadState().tombstones == once.tombstones)
        }
    }
    @Test func optionalMetadataParticipantCompletesAndNewLibrarySessionCanReconcile() async throws {
        let f = try await EditingCoordinatorFixture.make(metadata:true)
        defer{try? FileManager.default.removeItem(at:f.root)}
        try await f.execute()
        let metadata = try #require(f.metadata),row = try #require(try await metadata.record(assetID:f.newID))
        #expect(row.confirmed.title == "Bestätigtes Haus")
        #expect(row.confirmedSource?.original.standardizedPath == f.oldID)
        #expect(row.associationSource?.original.standardizedPath == f.newID)
        #expect(row.sourceChanged == false && row.isOrphaned == false)
        let snapshot = MetadataCatalogSnapshot(catalogSessionID:UUID(),catalogGeneration:1,persistedReference:f.after.reference,assets:await MetadataCatalogSourceReader.assets(f.after.catalog.assets))
        let reconciled = try await metadata.reconcile(snapshot)
        #expect(reconciled.changes.isEmpty)
        let after = try #require(try await metadata.record(assetID:f.newID))
        #expect(after.confirmed.title == row.confirmed.title && !after.sourceChanged)
        let fresh = try await f.restart();_ = try await fresh.coordinator.recoverAndOpen()
        #expect(try await fresh.metadata?.record(assetID:f.newID)?.confirmed.title == "Bestätigtes Haus")
    }
    @Test func requiredMissingEditingStoreIsNotRecreatedAfterArming() async throws {
        let f = try await EditingCoordinatorFixture.make(metadata:true,crashAt:.armedJournal)
        defer{try? FileManager.default.removeItem(at:f.root)}
        do {try await f.execute()}catch EditingCoordinatorCrash.injected{}
        let retained = f.directory.appendingPathComponent("retained-edits.sqlite")
        try FileManager.default.moveItem(at:f.editing.fileURL,to:retained)
        let bytes = try Data(contentsOf:retained),catalogBytes = try Data(contentsOf:f.catalog.fileURL)
        let fresh = try await f.restart()
        do {_ = try await fresh.coordinator.recoverAndOpen();Issue.record("Missing required participant must fence startup")}catch{}
        #expect(!FileManager.default.fileExists(atPath:f.editing.fileURL.path))
        #expect(try Data(contentsOf:retained) == bytes)
        #expect(try Data(contentsOf:f.catalog.fileURL) == catalogBytes)
        await #expect(throws:CatalogLifecycleError.recoveryRequired) {try await fresh.editing.loadState()}
        await #expect(throws:CatalogLifecycleError.recoveryRequired) {try await fresh.metadata?.record(assetID:f.oldID)}
    }
    @Test func replacedRequiredMetadataStoreUUIDCannotBeAcceptedAsSameParticipant() async throws {
        let f = try await EditingCoordinatorFixture.make(metadata:true,crashAt:.armedJournal)
        defer{try? FileManager.default.removeItem(at:f.root)}
        do {try await f.execute()}catch EditingCoordinatorCrash.injected{}
        let metadata = try #require(f.metadata)
        try metadataSQL(metadata.fileURL,"UPDATE metadata_identity SET store_id='\(UUID().uuidString.lowercased())'")
        let bytes = try Data(contentsOf:metadata.fileURL),editing = try Data(contentsOf:f.editing.fileURL),catalog = try Data(contentsOf:f.catalog.fileURL)
        let fresh = try await f.restart()
        await #expect(throws:CatalogCoordinationError.participantIdentityMismatch(.photoMetadata)) {try await fresh.coordinator.recoverAndOpen()}
        #expect(try Data(contentsOf:metadata.fileURL) == bytes)
        #expect(try Data(contentsOf:f.editing.fileURL) == editing)
        #expect(try Data(contentsOf:f.catalog.fileURL) == catalog)
    }
    @Test func externallyChangedCatalogNeverGetsOverwrittenDuringRecovery() async throws {
        let f = try await EditingCoordinatorFixture.make(crashAt:.armedJournal)
        defer{try? FileManager.default.removeItem(at:f.root)}
        do {try await f.execute()}catch EditingCoordinatorCrash.injected{}
        let foreign = Data("foreign catalog bytes".utf8);try foreign.write(to:f.catalog.fileURL)
        let edits = try Data(contentsOf:f.editing.fileURL),fresh = try await f.restart()
        do {_ = try await fresh.coordinator.recoverAndOpen();Issue.record("External catalog must be preserved")}catch{}
        #expect(try Data(contentsOf:f.catalog.fileURL) == foreign)
        #expect(try Data(contentsOf:f.editing.fileURL) == edits)
    }
    @Test func actualAfterWithoutOriginalEditingReceiptNeverFabricatesSuccess() async throws {
        let f = try await EditingCoordinatorFixture.make(crashAt:.catalogPublished)
        defer{try? FileManager.default.removeItem(at:f.root)}
        do {try await f.execute()}catch EditingCoordinatorCrash.injected{}
        #expect(try f.catalog.loadStored().reference == f.after.reference)
        try editingSQL(f.editing.fileURL,"DELETE FROM editing_remaps")
        let bytes = try Data(contentsOf:f.editing.fileURL),catalog = try Data(contentsOf:f.catalog.fileURL)
        let fresh = try await f.restart()
        do {_ = try await fresh.coordinator.recoverAndOpen();Issue.record("Catalog after is not SQL receipt proof")}catch{}
        #expect(try Data(contentsOf:f.editing.fileURL) == bytes)
        #expect(try Data(contentsOf:f.catalog.fileURL) == catalog)
    }
    @Test func independentCorruptEditingStoreDoesNotDisableRealMetadataAfterEmptyInventory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Independent-Stores-\(UUID())",isDirectory:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let media = root.appendingPathComponent("Media",isDirectory:true),directory = root.appendingPathComponent("Store",isDirectory:true)
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        let file = media.appendingPathComponent("photo.bin");try Data([1,2,3,4]).write(to:file)
        let folder = LibraryFolder(url:media),asset = PhotoAsset(folderID:folder.id,fileURL:file,fileSize:4)
        let catalog = CatalogRepository(directory:directory);try catalog.save(.init(folders:[folder],assets:[asset]))
        let corrupt = Data("damaged editing must survive".utf8);try corrupt.write(to:directory.appendingPathComponent("edits.sqlite"))
        let resources = ArtifactResourceOwner(limits:try .init()),gate = CatalogLifecycleGate()
        let artifacts = try await GeneratedArtifactStore.open(in:directory,resources:resources,lifecycleGate:gate)
        let editing = EditingRepository(directory:directory,artifacts:artifacts,packages:EditingBackupPackageStore(resources:resources),gate:gate)
        let metadata = PhotoMetadataRepository(directory:directory,gate:gate),coordinator = JointCatalogCoordinator(repository:catalog,editing:editing,metadata:metadata,gate:gate)
        _ = try await coordinator.recoverAndOpen()
        _ = try await metadata.reconcile(.init(catalogSessionID:UUID(),catalogGeneration:1,persistedReference:catalog.loadStored().reference,assets:[.init(assetID:asset.id,source:MetadataCatalogSourceReader.source(asset))]))
        let manual = try await metadata.saveManualDraft(.init(header:.init(assetID:asset.id,expectedVersion:.absent),mutation:.save(fields:.init(title:"Metadata remains available"),baseConfirmedRevision:0)))
        let row = try #require(manual.currentRecord)
        let confirmed = try await metadata.confirm(.init(header:.init(assetID:asset.id,expectedVersion:row.version),values:row.manualDraft!.fields,fields:[.title],source:MetadataCatalogSourceReader.source(asset),origin:.manual(expectedManualDraftRevision:row.version.manualDraftRevision,reviewedConfirmedRevision:0)))
        #expect(confirmed.currentRecord?.confirmed.title == "Metadata remains available")
        do{_ = try await editing.loadState();Issue.record("Editing corruption must stay visible")}catch{}
        #expect(try Data(contentsOf:editing.fileURL) == corrupt)
    }
}
private enum EditingCoordinatorCrash:Error {case injected}
private struct EditingCoordinatorFixture:Sendable {
    let root:URL,directory:URL,oldID:String,newID:String
    let catalog:CatalogRepository,before:StoredLibraryCatalog,after:PreparedLibraryCatalog
    let resources:ArtifactResourceOwner,gate:CatalogLifecycleGate,artifacts:GeneratedArtifactStore,editing:EditingRepository
    let metadata:PhotoMetadataRepository?,coordinator:JointCatalogCoordinator
    let stored:StoredEditingState,plan:VerifiedAssetRemap,change:MetadataCatalogChange?
    static func make(metadata includeMetadata:Bool = false,crashAt:CatalogCoordinationCheckpoint? = nil) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Real-Joint-\(UUID())",isDirectory:true)
        let directory = root.appendingPathComponent("Store",isDirectory:true),oldRoot = root.appendingPathComponent("Before",isDirectory:true),newRoot = root.appendingPathComponent("After",isDirectory:true)
        try FileManager.default.createDirectory(at:oldRoot,withIntermediateDirectories:true)
        let file = oldRoot.appendingPathComponent("photo.bin"),pixels = Data([4,3,2,1]);try pixels.write(to:file)
        let values = try FileManager.default.attributesOfItem(atPath:file.path),date = try #require(values[.modificationDate] as? Date)
        let oldBookmark = try oldRoot.bookmarkData(options:[.withSecurityScope],includingResourceValuesForKeys:nil,relativeTo:nil)
        let folder = LibraryFolder(url:oldRoot,bookmarkData:oldBookmark),asset = PhotoAsset(folderID:folder.id,fileURL:file,fileSize:4,pixelWidth:1,pixelHeight:1,modifiedAt:date)
        let library = LibraryCatalog(folders:[folder],assets:[asset]),catalog = CatalogRepository(directory:directory)
        try catalog.save(library);let before = try catalog.loadStored()
        let resources = ArtifactResourceOwner(limits:try .init()),gate = CatalogLifecycleGate()
        let artifacts = try await GeneratedArtifactStore.open(in:directory,resources:resources,lifecycleGate:gate)
        let packages = EditingBackupPackageStore(resources:resources),editing = EditingRepository(directory:directory,artifacts:artifacts,packages:packages,gate:gate)
        let metadata:PhotoMetadataRepository? = includeMetadata ? .init(directory:directory,gate:gate) : nil
        let coordinator = JointCatalogCoordinator(repository:catalog,editing:editing,metadata:metadata,gate:gate,checkpoint:{phase in
            if let crashAt,String(describing:crashAt) == String(describing:phase) {throw EditingCoordinatorCrash.injected}
        })
        _ = try await coordinator.recoverAndOpen()
        let empty = try await editing.loadState()
        let stored = try await editing.saveSnapshot(EditingSnapshot(settings:EditSettings(exposure:1.25)),for:asset.id,expected:.init(storeEpoch:empty.storeEpoch,revision:nil,snapshot:nil),revision:7)
        let oldMetadataSource = MetadataCatalogSourceReader.source(asset)
        if let metadata {
            _ = try await metadata.reconcile(.init(catalogSessionID:UUID(),catalogGeneration:1,persistedReference:before.reference,assets:[.init(assetID:asset.id,source:oldMetadataSource)]))
            _ = try await metadata.confirm(.init(header:.init(assetID:asset.id,expectedVersion:.absent),values:.init(title:"Bestätigtes Haus",language:"de"),fields:[.title,.language],source:oldMetadataSource,origin:.manual(expectedManualDraftRevision:nil,reviewedConfirmedRevision:0)))
        }
        let captured = try AssetRemapVerifier.capture(file,referenceDate:date)
        let previous = try OriginalSourceFingerprint(standardizedPath:captured.standardizedPath,fileSize:captured.fileSize,modifiedAt:captured.modifiedAt,nativeRevision:captured.nativeRevision,resourceIdentifier:captured.resourceIdentifier,volumeIdentifier:captured.volumeIdentifier,contentSHA256:ArtifactJSONCodec.digestBytes(pixels))
        try FileManager.default.moveItem(at:oldRoot,to:newRoot)
        let newFile = newRoot.appendingPathComponent("photo.bin"),freshBookmark = try newRoot.bookmarkData(options:[.withSecurityScope],includingResourceValuesForKeys:nil,relativeTo:nil)
        let movedAsset = PhotoAsset(folderID:folder.id,fileURL:newFile,fileSize:4,pixelWidth:1,pixelHeight:1,modifiedAt:date)
        var movedFolder = folder;movedFolder.url = newRoot;movedFolder.bookmarkData = freshBookmark
        let after = try catalog.prepare(.init(folders:[movedFolder],assets:[movedAsset]))
        let operationID = EditingRemapID(),identity = CatalogPreparedPayloadIdentity(operationID:operationID.rawValue,rootOwnerID:try catalog.coordinationRootIdentity(),before:before.reference,after:after.reference)
        let proposal = try AssetRemapProposal(operationID:operationID,catalog:identity,folderID:folder.id,bookmarkSHA256:ArtifactJSONCodec.digestBytes(oldBookmark),bookmarkData:oldBookmark,resolvedFolderURL:newRoot,catalogSessionID:UUID(),catalogGeneration:1,expectedStoreEpoch:empty.storeEpoch,expectedByAsset:[asset.id:.init(stored),movedAsset.id:try .init(storeEpoch:empty.storeEpoch,revision:nil,snapshot:nil)],entries:[.init(oldAssetID:asset.id,newAssetID:movedAsset.id,relativePath:"photo.bin",previous:previous,relocated:AssetRemapVerifier.capture(newFile,referenceDate:date))],resolvedBookmarkData:freshBookmark)
        let verified = try await AssetRemapVerifier().verify(proposal)
        let change:MetadataCatalogChange?
        if let metadata {
            let current = try #require(try await metadata.record(assetID:asset.id)),newSource = MetadataCatalogSourceReader.source(movedAsset)
            change = .init(id:operationID.rawValue,before:before.reference,after:after.reference,relocations:[.init(oldAssetID:asset.id,newAssetID:movedAsset.id,oldSource:oldMetadataSource,newSource:newSource,proof:.init(folderID:folder.id,bookmarkSHA256:proposal.bookmarkSHA256.sha256,oldRoot:oldRoot,newRoot:newRoot,relativePath:"photo.bin",verification:MetadataCatalogSourceReader.verification(before:oldMetadataSource,after:newSource)))],expectedRecords:[.init(assetID:asset.id,version:current.version),.init(assetID:movedAsset.id,version:.absent)])
        }else{change = nil}
        return .init(root:root,directory:directory,oldID:asset.id,newID:movedAsset.id,catalog:catalog,before:before,after:after,resources:resources,gate:gate,artifacts:artifacts,editing:editing,metadata:metadata,coordinator:coordinator,stored:stored,plan:verified,change:change)
    }
    func execute() async throws {
        let maintenance = try await gate.beginMaintenance(.coordination(plan.proposal.operationID.rawValue))
        let preparation = try await coordinator.prepare(catalog:after,expected:before.reference,editing:plan,metadata:change,maintenance:maintenance)
        let armed = try await coordinator.arm(preparation)
        _ = try await coordinator.finish(armed)
        try await gate.finishMaintenance(maintenance)
    }
    struct Restarted:Sendable {let gate:CatalogLifecycleGate,editing:EditingRepository,metadata:PhotoMetadataRepository?,coordinator:JointCatalogCoordinator}
    func restart() async throws -> Restarted {
        let gate = CatalogLifecycleGate(),store = try await GeneratedArtifactStore.open(in:directory,resources:resources,lifecycleGate:gate)
        let editing = EditingRepository(directory:directory,artifacts:store,packages:EditingBackupPackageStore(resources:resources),gate:gate)
        let metadata:PhotoMetadataRepository? = self.metadata == nil ? nil : .init(directory:directory,gate:gate)
        return .init(gate:gate,editing:editing,metadata:metadata,coordinator:.init(repository:CatalogRepository(directory:directory),editing:editing,metadata:metadata,gate:gate))
    }
}
