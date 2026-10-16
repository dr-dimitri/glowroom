import Darwin
import Foundation

/// Native comparison only; never changes persisted source URLs or asset IDs.
/// Resolve the reachable prefix, then append the lexical rest so missing and
/// offline leaves compare through the same aliases as their existing parents.
/// Call from a background worker. This value is not a file-write capability;
/// callers still pin/revalidate descriptors and reject unsafe final leaves.
public enum FilePathComparison {
    public static func canonicalPath(_ url: URL) -> String { resolvedPath(url)?.path ?? url.path }

    /// Only for conservative write protection. Case folding is enabled from the
    /// reachable prefix's native volume capability, never for library membership
    /// or persisted IDs. An unknown capability cannot authorize an export.
    public static func protectionKey(_ url: URL) -> String? {
        guard let resolved = resolvedPath(url), let sensitive = caseSensitive(at:resolved.prefix) else { return nil }
        return nameKey(resolved.path,caseSensitive:sensitive)
    }
    static func protectionNameKey(_ name: String, at directory: URL) -> String? {
        guard let resolved = resolvedPath(directory), let sensitive = caseSensitive(at:resolved.prefix) else { return nil }
        return nameKey(name,caseSensitive:sensitive)
    }
    private static func caseSensitive(at reachablePrefix: String) -> Bool? {
        let value = pathconf(reachablePrefix,_PC_CASE_SENSITIVE)
        if value == 1 { return true }; if value == 0 { return false }; return nil
    }
    private static func nameKey(_ value: String, caseSensitive: Bool) -> String {
        caseSensitive ? value : value.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX"))
    }
    private static func resolvedPath(_ url: URL) -> (path:String,prefix:String)? {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { return nil }
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
                return ("/" + components.joined(separator:"/"),resolved)
            }
            // readlink also works for a relative alias whose target is missing.
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath:prefix) {
                followedLinks += 1
                guard followedLinks <= 40 else { return nil }
                prefix = target.hasPrefix("/") ? target : (prefix as NSString).deletingLastPathComponent + "/" + target
                continue
            }
            if prefix == "/" { return nil }
            let parent = (prefix as NSString).deletingLastPathComponent
            guard parent.hasPrefix("/"), parent.utf8.count < prefix.utf8.count else { return nil }
            remainder.append((prefix as NSString).lastPathComponent); prefix = parent
        }
        return nil
    }
}
