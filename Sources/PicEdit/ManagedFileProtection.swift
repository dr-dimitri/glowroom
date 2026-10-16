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
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return false }
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
            let next = current.deletingLastPathComponent()
            if next.path == current.path { return false }
            current = next
        }
    }
}
