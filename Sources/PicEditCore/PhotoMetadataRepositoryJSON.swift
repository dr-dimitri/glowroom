import Foundation
import CSQLite

struct PhotoMetadataRetainedReview {
    let summary: MetadataImportReview
    let document: MetadataJSONDocument
    let expected: [String:MetadataRecordVersion]
    let conflictAssetByID: [UUID:String]
    let accountedCost: Int
    var touchedAt: ContinuousClock.Instant
}

extension PhotoMetadataRepository {
    func protectedStoreURLs() -> [URL] {
        let directory = fileURL.deletingLastPathComponent()
        var urls = ["photo-metadata.sqlite","photo-metadata.sqlite-journal","photo-metadata.sqlite-wal","photo-metadata.sqlite-shm","catalog.json","catalog-write.lock","edits.sqlite","edits.sqlite-wal","edits.sqlite-shm","cloud-usage.sqlite","semantic-index.sqlite"].map { directory.appendingPathComponent($0) }
        urls.append(directory.appendingPathComponent("MetadataCatalogStaging",isDirectory:true))
        return urls
    }
    func checkProtectedSources(_ check: PhotoMetadataFiles.DestinationCheck,on db:OpaquePointer) throws {
        try ensureCatalogSourceMapCurrent(on:db)
        for source in catalogByID.values {
            if Task.isCancelled { throw PhotoMetadataError.cancelled }
            try autoreleasepool { try check.checkFile(URL(fileURLWithPath:source.original.standardizedPath,isDirectory:false)) }
        }
        // Stream historical rows with the SQL cursor's per-row autorelease pool.
        // Imported paths without locally observed stamps remain inert: no crawl
        // and no invented native authority. A match stops before the next row.
        try allRows(db) { row in
            if Task.isCancelled { throw PhotoMetadataError.cancelled }
            hooks.didReadProtectionRecord()
            for source in [row.associationSource,row.confirmedSource,row.draft?.source] {
                if let source, source.nativeStamp != nil {
                    try check.checkFile(URL(fileURLWithPath:source.original.standardizedPath,isDirectory:false))
                }
            }
        }
        // At most one bounded pending journal exists, not the whole history.
        for journal in try journals(on:db,pendingOnly:true) {
            for url in journal.receipt.protectedSourceURLs { try check.checkFile(url) }
        }
    }
    public func prepareImport(source:URL,protection:MetadataFileProtectionSnapshot) throws -> MetadataImportReview {
        let db = try connection()
        try PhotoMetadataFiles.checkDestination(source,protection:protection,extra:protectedStoreURLs()) { try self.checkProtectedSources($0,on:db) }
        retainedReview = nil
        let data = try PhotoMetadataFiles.read(source,maximum:PhotoMetadataLimits.maximumJSONDocumentBytes)
        let decoded = try PhotoMetadataPortableJSON.decode(data), document = decoded.document
        let now = ContinuousClock.now
        if let old = retainedReview, old.touchedAt.duration(to:now) > .seconds(PhotoMetadataLimits.maximumImportReviewIdleSeconds) { retainedReview = nil }
        // Replacing the single retained review is deliberate; a stale dialog ID
        // cannot discard or commit the new one. No caller receives the body.
        var expected:[String:MetadataRecordVersion] = [:], conflicts:[MetadataImportConflict] = []
        var missing = 0, unassigned = 0, cost = decoded.accountedCost
        for entry in document.entries {
            let row = try readRow(entry.assetID,on:db)
            expected[entry.assetID] = row?.version ?? .absent
            if (row?.version.confirmedRevision ?? 0) > 0 {
                let old = row!.confirmed
                cost += (old.title.utf8.count + old.description.utf8.count + old.tags.reduce(0) { $0+$1.utf8.count } + old.language.utf8.count)*2 + 1_024
                guard data.count + cost <= PhotoMetadataLimits.maximumRetainedImportCost else { throw PhotoMetadataError.limitExceeded(.importReview) }
                conflicts.append(.init(id:UUID(),assetID:entry.assetID,expectedVersion:row!.version,existing:old,incoming:entry.fields))
            } else { missing += 1 }
            if catalogByID[entry.assetID] == nil { unassigned += 1 }
            cost += entry.assetID.utf8.count*2 + 256
            guard data.count + cost <= PhotoMetadataLimits.maximumRetainedImportCost else { throw PhotoMetadataError.limitExceeded(.importReview) }
        }
        let summary = MetadataImportReview(id:UUID(),sourceURL:source,exportID:document.exportID,
            contentSHA256:PhotoMetadataInternalCodec.sha256(data),sourceByteCount:Int64(data.count),entryCount:document.entries.count,
            missingCount:missing,unassignedCount:unassigned,conflicts:conflicts)
        retainedReview = .init(summary:summary,document:document,expected:expected,
            conflictAssetByID:Dictionary(uniqueKeysWithValues:conflicts.map { ($0.id,$0.assetID) }),accountedCost:cost,touchedAt:now)
        return summary
    }
    public func discardImport(reviewID:UUID) { if retainedReview?.summary.id == reviewID { retainedReview = nil } }
    static func importedOrigin(_ origin:MetadataFieldOrigin,exportID:UUID,revision:Int64) -> MetadataFieldOrigin {
        let originalAI:MetadataAIFieldOrigin?
        switch origin { case .manual:originalAI = nil;case .confirmedAI(let a):originalAI = a;case .imported(let a):originalAI = a.originalAI }
        return .imported(.init(exportID:exportID,originalRevision:revision,originalAI:originalAI))
    }
    func applyImport(_ entry:MetadataJSONEntry,fields:Set<PhotoMetadataField>,policy:MetadataTagPolicy,exportID:UUID,row:inout PhotoMetadataRow) throws {
        let origin = entry.provenance, existing = row.confirmedProvenance
        var next = row.confirmed
        if fields.contains(.title) { next.title = entry.fields.title }
        if fields.contains(.description) { next.description = entry.fields.description }
        if fields.contains(.language) { next.language = entry.fields.language }
        if fields.contains(.tags) { next.tags = try PhotoTextNormalization.mergingTags(existing:next.tags,incoming:entry.fields.tags,policy:policy) }
        next = try PhotoTextNormalization.normalize(next)
        let tagOrigins = next.tags.map { tag -> MetadataTagOrigin in
            if policy == .append || !fields.contains(.tags), let previous = existing.tags.first(where:{ PhotoTextNormalization.tagKey($0.value) == PhotoTextNormalization.tagKey(tag) }) { return previous }
            let incoming = origin.tags.first { PhotoTextNormalization.tagKey($0.value) == PhotoTextNormalization.tagKey(tag) }!
            return .init(value:tag,origin:Self.importedOrigin(incoming.origin,exportID:exportID,revision:entry.originalRevision))
        }
        row.confirmedProvenance = .init(title:fields.contains(.title) ? Self.importedOrigin(origin.title,exportID:exportID,revision:entry.originalRevision) : existing.title,
            description:fields.contains(.description) ? Self.importedOrigin(origin.description,exportID:exportID,revision:entry.originalRevision) : existing.description,
            tags:tagOrigins,language:fields.contains(.language) ? Self.importedOrigin(origin.language,exportID:exportID,revision:entry.originalRevision) : existing.language)
        let outdated = row.draft.map { [.pending,.edited].contains($0.state) } == true
        try row.advance(confirmed:true,ai:outdated)
        row.confirmed = next; row.confirmedAt = entry.confirmedAt
        row.confirmedSource = entry.source.map { .init(original:$0.original,analyzedRaster:$0.analyzedRaster) }
        row.associationSource = nil
        row.isOrphaned = catalogByID[row.assetID] == nil
        row.sourceChanged = catalogByID[row.assetID].map { current in
            row.confirmedSource.map { !Self.sameCurrentSource($0,current) } ?? false
        } == true
        if outdated, let d = row.draft {
            row.draft = .init(id:d.id,revision:row.version.aiDraftRevision,baseConfirmedRevision:d.baseConfirmedRevision,fields:d.fields,source:d.source,
                state:.outdated,createdAt:d.createdAt,modifiedAt:Date(),editedFields:d.editedFields)
        }
    }
    public func commitImport(_ operation:MetadataImportOperation) throws -> MetadataCommitResult {
        guard PhotoMetadataValidation.digest(operation.reviewContentSHA256),
              Set(operation.decisions.map(\.conflictID)).count == operation.decisions.count else { throw PhotoMetadataError.validation(.invalidDecision) }
        for decision in operation.decisions {
            try PhotoMetadataValidation.version(decision.expectedVersion)
            if case .replace(let fields,_) = decision.action, fields.isEmpty { throw PhotoMetadataError.validation(.invalidFieldSelection) }
        }
        let hash = try PhotoMetadataInternalCodec.digest(kind:"import",payload:operation), db = try connection()
        if let prior = try receipt(operation.id,digest:hash,on:db) { refreshSearch(db); return .init(receipt:prior,searchState:state) }
        guard let review = retainedReview, review.summary.id == operation.reviewID,
              review.summary.contentSHA256 == operation.reviewContentSHA256 else { throw PhotoMetadataError.reviewMissingOrExpired }
        guard review.touchedAt.duration(to:.now) <= .seconds(PhotoMetadataLimits.maximumImportReviewIdleSeconds) else {
            retainedReview = nil; throw PhotoMetadataError.reviewMissingOrExpired
        }
        let decisions = Dictionary(uniqueKeysWithValues:operation.decisions.map { ($0.conflictID,$0) })
        guard decisions.keys.allSatisfy({ review.conflictAssetByID[$0] != nil }) else { throw PhotoMetadataError.validation(.invalidDecision) }
        let byAsset = Dictionary(uniqueKeysWithValues:operation.decisions.map { (review.conflictAssetByID[$0.conflictID]!,$0) })
        let result = try sql.transaction(db,beforeCommit:hooks.beforeCommit) {
            if let prior = try receipt(operation.id,digest:hash,on:db) { return prior }
            // Imported source-change/orphan flags also use this complete map.
            try ensureCatalogSourceMapCurrent(on:db)
            // Whole-import CAS before the first mutation, even for entries the
            // user kept. A reviewed document can never partially slip through.
            for entry in review.document.entries {
                try ensureNotBlocked(entry.assetID,on:db)
                guard (try readRow(entry.assetID,on:db)?.version ?? .absent) == review.expected[entry.assetID] else { throw PhotoMetadataError.importConflict }
                if let decision = byAsset[entry.assetID], decision.expectedVersion != review.expected[entry.assetID] { throw PhotoMetadataError.importConflict }
            }
            var affected:[MetadataAffectedRecord] = []
            for entry in review.document.entries {
                var row = try readRow(entry.assetID,on:db) ?? .init(assetID:entry.assetID)
                let fields:Set<PhotoMetadataField>, policy:MetadataTagPolicy
                if row.version.confirmedRevision > 0 {
                    guard let decision = byAsset[entry.assetID], case .replace(let chosen,let tags) = decision.action else { continue }
                    fields = chosen; policy = tags
                } else { fields = Set(PhotoMetadataField.allCases); policy = .replace }
                try applyImport(entry,fields:fields,policy:policy,exportID:review.document.exportID,row:&row)
                try saveRow(row,on:db); affected.append(.init(assetID:row.assetID,version:row.version))
            }
            if !affected.isEmpty { try bumpSearch(db) }
            let value = MetadataWriteReceipt(operationID:operation.id,payloadSHA256:hash,committedAt:Date(),affected:affected,disposition:.applied)
            try saveReceipt(value,on:db); return value
        }
        if retainedReview?.summary.id == operation.reviewID { retainedReview = nil }
        refreshSearch(db); return .init(receipt:result,searchState:state)
    }
    public func exportConfirmed(destination:URL,protection:MetadataFileProtectionSnapshot) throws -> MetadataExportResult {
        let db = try connection(), exportID = UUID(), now = Date()
        let envelope = try PhotoMetadataPortableJSON.encoder().encode(MetadataJSONDocument(exportID:exportID,exportedAt:now,entries:[]))
        let marker = Data("\"entries\":[]".utf8)
        guard let range = envelope.range(of:marker) else { throw PhotoMetadataError.exportFailure }
        var prefix = Data(envelope[..<range.lowerBound]); prefix.append(Data("\"entries\":[".utf8))
        let suffix = Data(envelope[(range.upperBound-1)...])
        let extra = protectedStoreURLs()
        var count = 0
        let result = try PhotoMetadataFiles.atomicExport(destination,protection:protection,extra:extra,additionalProtection:{ try self.checkProtectedSources($0,on:db) },beforePublish:{
            try self.hooks.beforeExportPublish()
            // A catalog save may precede its queued reconciliation. Refuse to
            // publish with that obsolete protection snapshot; the next attempt
            // uses the newly reconciled complete original set.
        },publication:{ operation in
            try CatalogRepository(directory:self.fileURL.deletingLastPathComponent()).withPublicationLock { actual in
                guard actual == self.catalogReference else { throw PhotoMetadataError.catalogConflict }
                try operation()
            }
        }) { write in
            try write(prefix)
            try allRows(db) { row in
                guard row.version.confirmedRevision > 0 else { return }
                guard count < PhotoMetadataLimits.maximumJSONEntries else { throw PhotoMetadataError.limitExceeded(.jsonEntries) }
                let entry = MetadataJSONEntry(assetID:row.assetID,fields:row.confirmed,originalRevision:row.version.confirmedRevision,
                    confirmedAt:row.confirmedAt!,source:row.confirmedSource.map { .init(original:$0.original,analyzedRaster:$0.analyzedRaster) },provenance:row.confirmedProvenance)
                let bytes = try autoreleasepool { try PhotoMetadataPortableJSON.encoder().encode(entry) }
                guard bytes.count <= PhotoMetadataLimits.maximumJSONEntryBytes else { throw PhotoMetadataError.limitExceeded(.jsonEntry) }
                if count > 0 { try write(Data([44])) }; try write(bytes); count += 1
            }
            try write(suffix)
        }
        return .init(destination:destination,exportID:exportID,entryCount:count,byteCount:result.0,sha256:result.1)
    }
}
