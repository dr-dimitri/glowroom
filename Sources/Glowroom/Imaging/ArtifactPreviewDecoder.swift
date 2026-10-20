import CoreGraphics
import Foundation
import ImageIO
import GlowroomCore

/// Only routing metadata is retained here. Opening occurs after the existing
/// ImagePreviewPipeline has reserved its normal decoder slot.
actor ArtifactPreviewAccess {
    static let shared = ArtifactPreviewAccess()
    struct Opened: Sendable { let handle: ArtifactReadHandle; let resources: any ArtifactResourceAdmitting }
    private var stores: [ArtifactStoreID: (store: any GeneratedArtifactStoring, resources: any ArtifactResourceAdmitting)] = [:]
    func register(_ store: any GeneratedArtifactStoring, resources: any ArtifactResourceAdmitting) async {
        stores[await store.storeID] = (store, resources)
    }
    func open(_ expected: ArtifactSourceFingerprint) async throws -> Opened {
        guard let entry = stores[expected.storeID] else { throw ArtifactContractError.missingArtifact }
        let handle = try await entry.store.openVerifiedRaster(expected.artifactID)
        guard handle.artifact.id == expected.artifactID,
              handle.artifact.manifestSHA256 == expected.manifestSHA256,
              handle.artifact.raster == expected.raster,
              handle.file.sha256 == expected.raster.file.sha256,
              handle.file.bytes == expected.raster.file.bytes else { throw ArtifactContractError.corruptArtifact }
        return Opened(handle: handle, resources: entry.resources)
    }
}

private final class ArtifactProviderOwner {
    let handle: ArtifactReadHandle
    init(_ handle: ArtifactReadHandle) { self.handle = handle }
}

extension PreviewDecoder {
    static func decodeArtifact(_ handle: ArtifactReadHandle, expected: ArtifactSourceFingerprint,
                               pixelSize: Int) throws -> PreviewBitmap {
        try Task.checkCancellation()
        guard handle.artifact.id == expected.artifactID,
              handle.artifact.manifestSHA256 == expected.manifestSHA256,
              handle.artifact.raster == expected.raster else { throw ArtifactContractError.corruptArtifact }
        return try autoreleasepool {
            let owner = Unmanaged.passRetained(ArtifactProviderOwner(handle)).toOpaque()
            var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil,
                releaseBytePointer: nil, getBytesAtPosition: { context, destination, offset, count in
                    guard let context, offset >= 0, count >= 0 else { return 0 }
                    let handle = Unmanaged<ArtifactProviderOwner>.fromOpaque(context).takeUnretainedValue().handle.file
                    var copied = 0
                    do {
                        while copied < count {
                            try Task.checkCancellation()
                            let (position, overflow) = offset.addingReportingOverflow(Int64(copied))
                            guard !overflow else { return 0 }
                            let bytes = try handle.read(offset: position, maximumCount: min(65_536, count - copied))
                            if bytes.isEmpty { break }
                            bytes.withUnsafeBytes { buffer in
                                if let base = buffer.baseAddress { destination.advanced(by: copied).copyMemory(from: base, byteCount: buffer.count) }
                            }
                            copied += bytes.count
                        }
                        return copied
                    } catch { return 0 }
                }, releaseInfo: { context in
                    if let context { Unmanaged<ArtifactProviderOwner>.fromOpaque(context).release() }
                })
            guard let provider = CGDataProvider(directInfo: owner, size: handle.file.bytes, callbacks: &callbacks) else {
                Unmanaged<ArtifactProviderOwner>.fromOpaque(owner).release()
                throw ArtifactContractError.corruptArtifact
            }
            guard let source = CGImageSourceCreateWithDataProvider(provider, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw ArtifactContractError.corruptArtifact }
            try Task.checkCancellation()
            let size = expected.raster.format.size
            return PreviewBitmap(image: image, sourceLongEdge: max(size.width, size.height))
        }
    }
}
