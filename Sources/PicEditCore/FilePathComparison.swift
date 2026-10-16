import Darwin
import Foundation

/// Native comparison only; never changes persisted source URLs or asset IDs.
/// Resolve the reachable prefix, then append the lexical rest so missing and
/// offline leaves compare through the same aliases as their existing parents.
/// Call from a background worker. This value is not a file-write capability;
/// callers still pin/revalidate descriptors and reject unsafe final leaves.
public enum FilePathComparison {
    public static func canonicalPath(_ url: URL) -> String {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { return url.path }
        var prefix = url.path
        var remainder: [String] = []
        var followedLinks = 0
        for _ in 0..<4_096 {
            if let actual = realpath(prefix,nil) {
                let resolved = String(cString:actual); free(actual)
                var components = resolved.split(separator:"/").map(String.init)
                for component in remainder.reversed() {
                    if component == ".." { if !components.isEmpty { components.removeLast() } }
                    else if component != "." && !component.isEmpty { components.append(component) }
                }
                return "/" + components.joined(separator:"/")
            }
            // readlink also works for a relative alias whose target is missing.
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath:prefix) {
                followedLinks += 1
                guard followedLinks <= 40 else { return url.path }
                prefix = target.hasPrefix("/") ? target : (prefix as NSString).deletingLastPathComponent + "/" + target
                continue
            }
            if prefix == "/" { return url.path }
            let parent = (prefix as NSString).deletingLastPathComponent
            guard parent.hasPrefix("/"), parent.utf8.count < prefix.utf8.count else { return url.path }
            remainder.append((prefix as NSString).lastPathComponent); prefix = parent
        }
        return url.path
    }
}
