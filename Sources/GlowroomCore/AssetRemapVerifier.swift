import CryptoKit
import Darwin
import Foundation

/// Native verification is deliberately serialized. Bookmark/path metadata never
/// mints a capability without independently matching file identity or contents.
public actor AssetRemapVerifier: AssetRemapVerifying {
    public init() {}
    public func verify(_ proposal: AssetRemapProposal) async throws -> VerifiedAssetRemap {
        try Task.checkCancellation()
        guard !proposal.entries.isEmpty,
              Set(proposal.entries.map(\.oldAssetID)).count == proposal.entries.count,
              Set(proposal.entries.map(\.newAssetID)).count == proposal.entries.count else { throw ArtifactContractError.invalidValue("remap identities") }
        let bookmarkHash = SHA256.hash(data: proposal.bookmarkData).map { String(format: "%02x", $0) }.joined()
        guard proposal.bookmarkSHA256.sha256 == bookmarkHash else { throw ArtifactContractError.sourceChanged }
        var stale = false
        let root = try URL(resolvingBookmarkData: proposal.resolvedBookmarkData ?? proposal.bookmarkData, options: [.withSecurityScope, .withoutUI],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, FilePathComparison.canonicalPath(root) == FilePathComparison.canonicalPath(proposal.resolvedFolderURL) else {
            throw ArtifactContractError.sourceChanged
        }
        let scoped = root.startAccessingSecurityScopedResource(); defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        for entry in proposal.entries {
            try Task.checkCancellation()
            let parts = entry.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !entry.relativePath.hasPrefix("/"), !entry.relativePath.utf8.contains(0) else { throw ArtifactContractError.invalidValue("remap relative path") }
            let target = root.appendingPathComponent(entry.relativePath)
            guard FilePathComparison.canonicalPath(target) == FilePathComparison.canonicalPath(URL(fileURLWithPath: entry.relocated.standardizedPath)),
                  entry.newAssetID == entry.relocated.standardizedPath,
                  entry.oldAssetID == entry.previous.standardizedPath else { throw ArtifactContractError.sourceChanged }
            let current = try Self.capture(target, referenceDate: entry.relocated.modifiedAt)
            guard current.nativeRevision == entry.relocated.nativeRevision,
                  current.fileSize == entry.relocated.fileSize else { throw ArtifactContractError.sourceChanged }
            let nativeMatches = entry.previous.resourceIdentifier != nil && entry.previous.volumeIdentifier != nil &&
                entry.previous.resourceIdentifier == current.resourceIdentifier && entry.previous.volumeIdentifier == current.volumeIdentifier &&
                entry.previous.nativeRevision.device == current.nativeRevision.device && entry.previous.nativeRevision.inode == current.nativeRevision.inode
            if !nativeMatches {
                guard let expectedHash = entry.previous.contentSHA256,
                      try Self.hash(target) == expectedHash else { throw ArtifactContractError.sourceChanged }
            }
        }
        let encoded = try EditingContractJSON.encoder().encode(proposal)
        let digest = try ArtifactDigest(sha256: SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined())
        return VerifiedAssetRemap(proposal: proposal, verifiedFileEvidenceSHA256: digest)
    }

    public nonisolated static func capture(_ url: URL, referenceDate: Date) throws -> OriginalSourceFingerprint {
        guard url.isFileURL else { throw ArtifactContractError.sourceChanged }
        let ownership = try EditingDatabaseAccess.reserveNativeFile()
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ArtifactContractError.sourceChanged }
        ownership.own(fd); defer { ownership.close() }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else { throw ArtifactContractError.sourceChanged }
        let revision = try OriginalSourceRevision(device: Int64(value.st_dev), inode: UInt64(value.st_ino), fileSize: value.st_size,
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int32(value.st_mtimespec.tv_nsec),
            changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int32(value.st_ctimespec.tv_nsec))
        let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey])
        func identity(_ value: Any?) -> Data? {
            guard let object = value as? NSSecureCoding else { return nil }
            return try? NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: true)
        }
        return try OriginalSourceFingerprint(standardizedPath: url.standardizedFileURL.path, fileSize: value.st_size,
            modifiedAt: referenceDate, nativeRevision: revision,
            resourceIdentifier: identity(values.fileResourceIdentifier), volumeIdentifier: identity(values.volumeIdentifier))
    }
    private nonisolated static func hash(_ url: URL) throws -> ArtifactDigest {
        let ownership = try EditingDatabaseAccess.reserveNativeFile()
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ArtifactContractError.sourceChanged }
        ownership.own(fd); defer { ownership.close() }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { throw ArtifactContractError.sourceChanged }
        // FileHandle borrows the descriptor. Only the reservation may close it,
        // after any concurrent SQLite scope on the same inode actually ends.
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try file.read(upToCount: 65_536) ?? Data() }
            if chunk.isEmpty { break }; hash.update(data: chunk)
        }
        return try ArtifactDigest(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
