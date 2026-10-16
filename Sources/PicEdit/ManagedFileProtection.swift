import Darwin
import Foundation

/// Small synchronous path checks run only in the caller's background file job.
/// Compare real directory identities so /var aliases and case spelling cannot
/// bypass protection of an installed immutable model directory.
struct ManagedDirectoryFamily: Equatable, Sendable {
    let parent: URL
    let childNamePrefix: String
}

enum ManagedFileProtection {
    static func managedFiles(in directory: URL) -> [URL] {
        let databases = ["edits.sqlite", "photo-metadata.sqlite", "cloud-usage.sqlite", "semantic-index.sqlite"]
        return databases.flatMap { base in [base, base + "-wal", base + "-shm", base + "-journal"] }
            .map { directory.appendingPathComponent($0, isDirectory: false) }
            + ["catalog.json", "catalog-write.lock"].map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    static func managedDirectories(in directory: URL) -> [URL] {
        ["SemanticModels", "MetadataCatalogStaging", "GeneratedArtifacts", "EditingTransactions", "EditBackups"]
            .map { directory.appendingPathComponent($0, isDirectory: true) }
    }

    static func managedFamilies(in directory: URL) -> [ManagedDirectoryFamily] {
        ["semantic-index-quarantine-", "photo-metadata-quarantine-"]
            .map { ManagedDirectoryFamily(parent: directory, childNamePrefix: $0) }
    }

    static func protects(_ target: URL, directory: URL) -> Bool {
        let normalized = target.resolvingSymlinksInPath().standardizedFileURL
        var candidate = stat()
        let exists = stat(target.path, &candidate) == 0
        for file in managedFiles(in: directory) {
            if file.resolvingSymlinksInPath().standardizedFileURL == normalized { return true }
            var original = stat()
            if exists, stat(file.path, &original) == 0,
               original.st_dev == candidate.st_dev, original.st_ino == candidate.st_ino { return true }
        }
        return managedDirectories(in: directory).contains { containsDestination(target, in: $0) }
            || managedFamilies(in: directory).contains { containsDestination(target, in: $0) }
    }

    /// Families cover immutable quarantine directories created after a dialog
    /// captures its request, without enumerating files on MainActor.
    static func containsDestination(_ target: URL, in family: ManagedDirectoryFamily) -> Bool {
        guard target.isFileURL, family.parent.isFileURL, !family.childNamePrefix.isEmpty else { return false }
        var root = stat()
        guard stat(family.parent.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR,
              let physical = realpath(target.deletingLastPathComponent().path, nil) else { return false }
        defer { free(physical) }
        var current = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        while true {
            guard let parent = strictParent(of: current) else { return false }
            var metadata = stat()
            if stat(parent.path, &metadata) == 0,
               metadata.st_dev == root.st_dev, metadata.st_ino == root.st_ino {
                return current.lastPathComponent.hasPrefix(family.childNamePrefix)
            }
            current = parent
        }
    }

    static func containsDestination(_ target: URL, in root: URL) -> Bool {
        guard target.isFileURL, root.isFileURL else { return false }
        var rootMetadata = stat()
        guard stat(root.path, &rootMetadata) == 0,
              rootMetadata.st_mode & S_IFMT == S_IFDIR,
              let parent = realpath(target.deletingLastPathComponent().path, nil) else { return false }
        defer { free(parent) }
        var current = URL(fileURLWithPath: String(cString: parent), isDirectory: true)
        while true {
            var metadata = stat()
            if stat(current.path, &metadata) == 0,
               metadata.st_dev == rootMetadata.st_dev, metadata.st_ino == rootMetadata.st_ino { return true }
            guard let next = strictParent(of: current) else { return false }
            current = next
        }
    }

    /// Foundation can represent a URL root's parent with additional `..`
    /// components. Native paths must strictly shorten, so failed containment
    /// checks cannot turn into an unbounded URL-parent loop.
    private static func strictParent(of url: URL) -> URL? {
        let path = url.path
        guard path != "/", !path.isEmpty else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent.utf8.count < path.utf8.count else { return nil }
        return URL(fileURLWithPath: parent, isDirectory: true)
    }

}
