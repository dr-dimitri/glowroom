import Darwin
import Foundation

/// Small synchronous path checks run only in the caller's background file job.
/// Compare real directory identities so /var aliases and case spelling cannot
/// bypass protection of an installed immutable model directory.
enum ManagedFileProtection {
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
