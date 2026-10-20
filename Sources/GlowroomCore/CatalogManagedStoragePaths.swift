import Foundation

/// Shared path inventory for UI preflight and the final native export boundary.
/// Constructing it performs no database/model work or filesystem enumeration.
public enum CatalogManagedStoragePaths {
    public static func files(in directory: URL) -> [URL] {
        ["edits.sqlite", "photo-metadata.sqlite", "cloud-usage.sqlite", "semantic-index.sqlite"]
            .flatMap { base in [base, base + "-wal", base + "-shm", base + "-journal"] }
            .map { directory.appendingPathComponent($0, isDirectory: false) }
            + ["catalog.json", "catalog-write.lock", "edits.sqlite-recovery.json"].map { directory.appendingPathComponent($0, isDirectory: false) }
    }
    public static func directories(in directory: URL) -> [URL] {
        ["SemanticModels", "MetadataCatalogStaging", "GeneratedArtifacts", "EditingTransactions", "CatalogCoordination",
         "EditBackups", "EditingSnapshots", "EditMigrationArchives", "EditingRecoveryArchives", "Recovery"]
            .map { directory.appendingPathComponent($0, isDirectory: true) }
    }
    public static func families(in directory: URL) -> [MetadataProtectedDirectoryFamily] {
        ["semantic-index-quarantine-", "photo-metadata-quarantine-", CatalogCoordinationFiles.rootStagePrefix]
            .map { .init(parent: directory, childNamePrefix: $0) }
    }
    static func protection(in directory: URL) -> MetadataFileProtectionSnapshot {
        .init(originalURLs: [], managedFileURLs: files(in: directory), managedDirectoryURLs: directories(in: directory),
              managedDirectoryFamilies: families(in: directory))
    }
}
