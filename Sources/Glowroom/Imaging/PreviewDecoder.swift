import Foundation
import ImageIO
import UniformTypeIdentifiers
import GlowroomCore

/// Decodes a library preview, not an editing rendition. Camera RAW files often
/// contain an already-rendered JPEG preview: use it when it is large enough for
/// browsing, avoiding a full RAW development for every grid cell or loupe.
enum PreviewDecoder {
    static func decode(_ request: PreviewRequest) throws -> PreviewBitmap {
        try Task.checkCancellation()
        guard let url = request.url else { throw ArtifactContractError.invalidValue("original decoder source") }
        return try autoreleasepool {
            let sourceSpan = PipelineTrace.begin(.sourceCheck)
            var sourceSpanEnded = false
            defer { if !sourceSpanEnded { sourceSpan.end() } }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw PreviewFailure.unavailable
            }
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
                throw PreviewFailure.unsupportedOrDamaged
            }
            try Task.checkCancellation()
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any]
            let sourceLongEdge: Int?
            if let width = properties?[kCGImagePropertyPixelWidth] as? NSNumber,
               let height = properties?[kCGImagePropertyPixelHeight] as? NSNumber,
               width.intValue > 0, height.intValue > 0 {
                sourceLongEdge = max(width.intValue, height.intValue)
            } else {
                sourceLongEdge = nil
            }

            sourceSpan.end(); sourceSpanEnded = true
            let decodeSpan = PipelineTrace.begin(.decode)
            defer { decodeSpan.end() }
            var options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: request.pixelSize,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: true
            ]

            if request.allowsEmbeddedPreview && isCameraRAW(source) {
                // Both FromImage flags default to false. A missing embedded
                // preview must return nil here, not start an implicit RAW decode.
                if let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    try Task.checkCancellation()
                    var requiredSize = request.pixelSize
                    if let sourceLongEdge {
                        requiredSize = min(requiredSize, sourceLongEdge)
                    }
                    if isUsefulEmbeddedPreview(preview, requestedSize: requiredSize) {
                        return PreviewBitmap(image: try materializedGrayscaleThumbnail(preview), sourceLongEdge: sourceLongEdge)
                    }
                }
                try Task.checkCancellation()
            }

            // Keep full-quality resampling for JPEG/HEIC/PNG/TIFF and for RAWs
            // without a useful embedded image. IfAbsent alone is insufficient:
            // it can return a tiny EXIF thumbnail even for a large preview.
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            if request.allowsHDR {
                options[kCGImageSourceShouldAllowFloat] = true
                options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
            }
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw PreviewFailure.unsupportedOrDamaged
            }
            try Task.checkCancellation()
            return PreviewBitmap(image: try materializedGrayscaleThumbnail(image), sourceLongEdge: sourceLongEdge,
                rangeProvenance: request.allowsHDR ? .extended(nominalSDRWhite: 1) : .sdrDecoded)
        }
    }

    /// ImageIO can return a private 16-bit gray/alpha thumbnail provider that
    /// exposes valid samples to its encoder but uploads as transparent black
    /// through Core Image. Give that layout an ordinary, immutable data provider
    /// without converting colors, precision, byte order, orientation or alpha.
    /// Reusing the private provider itself does not fix its Core Image upload.
    private static func materializedGrayscaleThumbnail(_ image: CGImage) throws -> CGImage {
        guard image.bitsPerComponent == 16, image.bitsPerPixel == 32,
              let space = image.colorSpace, space.model == .monochrome,
              [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo) else { return image }
        try Task.checkCancellation()
        // The normal decoder worker already limits previews to 4096 pixels per
        // edge and bounds concurrent decodes. This one transient Gray16+alpha
        // backing is at most 64 MiB (plus row padding); the ImageIO thumbnail is
        // released by the enclosing autoreleasepool, and the retained cache cost
        // remains the returned image's actual bytesPerRow * height.
        let byteCount = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !byteCount.overflow, byteCount.partialValue > 0,
              let data = image.dataProvider?.data, CFDataGetLength(data) >= byteCount.partialValue,
              let provider = CGDataProvider(data: data),
              let result = CGImage(width: image.width, height: image.height,
                bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel,
                bytesPerRow: image.bytesPerRow, space: space, bitmapInfo: image.bitmapInfo,
                provider: provider, decode: image.decode, shouldInterpolate: image.shouldInterpolate,
                intent: image.renderingIntent) else { throw PreviewFailure.unsupportedOrDamaged }
        try Task.checkCancellation()
        return result
    }

    private static func isCameraRAW(_ source: CGImageSource) -> Bool {
        guard let identifier = CGImageSourceGetType(source) else { return false }
        return isCameraRAWTypeIdentifier(identifier as String)
    }

    static func isCameraRAWTypeIdentifier(_ identifier: String) -> Bool {
        if UTType(identifier)?.conforms(to: .rawImage) == true { return true }
        // ImageIO can decode a RAW type even when LaunchServices has not
        // registered its UTI declaration (notably standalone/sandboxed tools).
        // Match ImageIO's actual source identifier, never just the filename:
        // e.g. com.canon.cr3-raw-image or com.adobe.raw-image.
        return identifier.hasSuffix("-raw-image") || identifier.hasSuffix(".raw-image")
    }

    static func isUsefulEmbeddedPreview(_ image: CGImage, requestedSize: Int) -> Bool {
        // Both grid and final loupe renditions must meet their requested
        // resolution. The caller can request a small progressive preview first;
        // a tiny EXIF thumbnail must never masquerade as a finished large image.
        let required = max(requestedSize, 1)
        return image.width > 0 && image.height > 0 && max(image.width, image.height) >= required
    }
}
