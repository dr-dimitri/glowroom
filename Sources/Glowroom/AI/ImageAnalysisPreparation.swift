import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import GlowroomCore

struct ImageAnalysisNativeSourceStamp: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
    let byteCount: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    var cacheRevision: String {
        "\(device):\(inode):\(byteCount):\(modifiedSeconds):\(modifiedNanoseconds):\(changedSeconds):\(changedNanoseconds)"
    }
}

enum ImageAnalysisSourceStamp: Hashable, Sendable {
    case original(ImageAnalysisNativeSourceStamp)
    case artifact(ArtifactSourceFingerprint)
    init(device: Int32, inode: UInt64, byteCount: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64,
         changedSeconds: Int64, changedNanoseconds: Int64) {
        self = .original(.init(device: device, inode: inode, byteCount: byteCount,
            modifiedSeconds: modifiedSeconds, modifiedNanoseconds: modifiedNanoseconds,
            changedSeconds: changedSeconds, changedNanoseconds: changedNanoseconds))
    }
    var cacheRevision: String {
        switch self {
        case .original(let value): return value.cacheRevision
        case .artifact(let value): return "artifact:" + value.storeID.canonicalString + ":" + value.artifactID.canonicalString + ":" + value.manifestSHA256.sha256
        }
    }
}

struct PreparedImageAnalysisInput: Sendable {
    let bitmap: PreviewBitmap
    let sourceStamp: ImageAnalysisSourceStamp
    let rasterSHA256: String
    let colorProfile: String
    let colorProfileSHA256: String?
}

protocol ImageAnalysisPreparing: Sendable {
    func sourceStamp(for request: ImageAnalysisRequest) async throws -> ImageAnalysisSourceStamp
    func prepare(_ request: ImageAnalysisRequest) async throws -> PreparedImageAnalysisInput
}

/// Called by ImageAnalysisService's detached worker, never by MainActor. Native
/// Attachment handles its own color conversion; this stage enforces Glowroom's
/// admission size only, with the existing bounded decoder/render workers.
struct ImageAnalysisPreparer: ImageAnalysisPreparing {
    static let maximumPixelSize = 1_024
    static let maximumRasterBytes = 16 * 1_024 * 1_024
    let imagePipeline: ImagePreviewPipeline
    let renderPipeline: AdjustedPreviewPipeline

    init(imagePipeline: ImagePreviewPipeline = .shared, renderPipeline: AdjustedPreviewPipeline = .shared) {
        self.imagePipeline = imagePipeline; self.renderPipeline = renderPipeline
    }

    func sourceStamp(for request: ImageAnalysisRequest) async throws -> ImageAnalysisSourceStamp {
        try Task.checkCancellation()
        if case .artifact(let fingerprint) = request.snapshot.source {
            guard request.inputKind == .editedPreview else { throw ImageAnalysisError.invalidRequest }
            return .artifact(fingerprint)
        }
        guard case .original(let fingerprint) = request.snapshot.source else { throw ImageAnalysisError.invalidRequest }
        let url = URL(fileURLWithPath: fingerprint.standardizedPath)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw ImageAnalysisError.staleSource }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_size == fingerprint.fileSize else { throw ImageAnalysisError.staleSource }
        let modified = Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000
        // Catalog dates come through Foundation; tolerate only floating-point
        // conversion rounding, not a normal filesystem modification interval.
        guard abs(modified - fingerprint.modifiedAt.timeIntervalSince1970) <= 0.000_005 else {
            throw ImageAnalysisError.staleSource
        }
        return ImageAnalysisSourceStamp(device: value.st_dev, inode: UInt64(value.st_ino), byteCount: value.st_size,
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }

    func prepare(_ request: ImageAnalysisRequest) async throws -> PreparedImageAnalysisInput {
        try request.validate()
        let before = try await sourceStamp(for: request)
        // Explicit reanalysis must bypass both bounded raster caches even if
        // a source manages to retain every native stamp field.
        let revision = request.cachePolicy == .refreshRaster
            ? before.cacheRevision + "|fresh:" + request.id.uuidString : before.cacheRevision
        let preview = PreviewRequest(source: request.snapshot.source, pixelSize: Self.maximumPixelSize,
            allowsEmbeddedPreview: false, sourceRevision: revision)
        let source = try await imagePipeline.image(for: preview, priority: .selected)
        let settings = request.inputKind == .originalPreview ? EditSettings.neutral : request.snapshot.settings
        let bitmap = try await renderPipeline.image(source, request: preview, settings: settings,
            priority: .selected, maximumOutputPixelSize: Self.maximumPixelSize)
        try Task.checkCancellation()
        let after = try await sourceStamp(for: request)
        guard after == before else { throw ImageAnalysisError.staleSource }
        let raster = try Self.describeRaster(bitmap)
        return PreparedImageAnalysisInput(bitmap: bitmap, sourceStamp: before, rasterSHA256: raster.digest,
                                          colorProfile: raster.profile, colorProfileSHA256: raster.profileDigest)
    }

    static func describeRaster(_ bitmap: PreviewBitmap) throws -> (digest: String, profile: String, profileDigest: String?) {
        try Task.checkCancellation()
        let image = bitmap.image
        let (byteCount, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow, byteCount > 0, byteCount <= maximumRasterBytes,
              image.width > 0, image.height > 0, max(image.width, image.height) <= maximumPixelSize,
              let providerData = image.dataProvider?.data else { throw ImageAnalysisError.inputLimitExceeded }
        let data = providerData as Data
        guard data.count >= byteCount else { throw ImageAnalysisError.invalidRequest }
        let profileData = image.colorSpace?.copyICCData() as Data?
        let profileDigest = profileData.map { hex(SHA256.hash(data: $0)) }
        let profile = image.colorSpace?.name.map { String($0) } ?? "unnamed color space model \(image.colorSpace?.model.rawValue ?? -1)"
        guard profile.utf8.count <= 512 else { throw ImageAnalysisError.inputLimitExceeded }
        let componentCount = image.colorSpace?.numberOfComponents ?? 0
        guard componentCount <= 32 else { throw ImageAnalysisError.inputLimitExceeded }
        let decode = image.decode.map { pointer in
            UnsafeBufferPointer(start: pointer, count: componentCount * 2).map { Double($0).bitPattern.description }.joined(separator: ",")
        } ?? "default"
        let header = "Glowroom-native-raster-v1|\(image.width)|\(image.height)|\(image.bitsPerComponent)|\(image.bitsPerPixel)|\(image.bitmapInfo.rawValue)|\(image.renderingIntent.rawValue)|\(image.shouldInterpolate)|\(image.isMask)|\(decode)|up|\(profileDigest ?? profile)|"
        var hasher = SHA256()
        hasher.update(data: Data(header.utf8))
        // Padding is not pixel input. Exclude uninitialized scanline padding so
        // an identical CGImage interpretation has a reproducible fingerprint.
        let rowBytes = (image.width * image.bitsPerPixel + 7) / 8
        guard rowBytes > 0, rowBytes <= image.bytesPerRow else { throw ImageAnalysisError.invalidRequest }
        let unusedBytes = try Self.unusedComponentBytes(image)
        let unusedTailBits = (8 - (image.width * image.bitsPerPixel) % 8) % 8
        for row in 0..<image.height {
            if row % 64 == 0 { try Task.checkCancellation() }
            let start = row * image.bytesPerRow
            if unusedBytes.isEmpty && unusedTailBits == 0 {
                hasher.update(data: data[start..<(start + rowBytes)])
            } else {
                // X channels and packed scanline tail bits are not interpreted
                // by CGImage. Canonicalize them like scanline padding, without
                // rendering, changing color, or modifying the attached image.
                var pixels = Data(data[start..<(start + rowBytes)])
                pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                    if !unusedBytes.isEmpty {
                        let pixelBytes = image.bitsPerPixel / 8
                        for pixel in 0..<image.width {
                            for byte in unusedBytes { bytes[pixel * pixelBytes + byte] = 0 }
                        }
                    }
                    if unusedTailBits != 0 { bytes[rowBytes - 1] &= UInt8(truncatingIfNeeded: 0xff << unusedTailBits) }
                }
                hasher.update(data: pixels)
            }
        }
        return (hex(hasher.finalize()), profile, profileDigest)
    }

    private static func unusedComponentBytes(_ image: CGImage) throws -> [Int] {
        guard image.alphaInfo == .noneSkipFirst || image.alphaInfo == .noneSkipLast else { return [] }
        let componentBits = image.bitsPerComponent, pixelBits = image.bitsPerPixel
        // ImageIO's X-channel rasters use complete 8/16/32-bit components.
        // Reject an unknown packed layout rather than hash unidentified padding.
        guard componentBits > 0, componentBits % 8 == 0, pixelBits % componentBits == 0,
              pixelBits / componentBits == (image.colorSpace?.numberOfComponents ?? 0) + 1 else {
            throw ImageAnalysisError.invalidRequest
        }
        let componentBytes = componentBits / 8, pixelBytes = pixelBits / 8
        let first = image.alphaInfo == .noneSkipFirst ? 0 : pixelBytes - componentBytes
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let wordBytes: Int
        switch order {
        case .byteOrder16Little: wordBytes = 2
        case .byteOrder32Little: wordBytes = 4
        case .byteOrderDefault, .byteOrder16Big, .byteOrder32Big: wordBytes = 1
        default: throw ImageAnalysisError.invalidRequest
        }
        guard pixelBytes % wordBytes == 0 else { throw ImageAnalysisError.invalidRequest }
        return (first..<(first + componentBytes)).map { byte in
            (byte / wordBytes) * wordBytes + wordBytes - 1 - byte % wordBytes
        }
    }
}

private func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
}
