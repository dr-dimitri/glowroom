import Foundation

public enum JPEGExportFormat: String, CaseIterable, Sendable {
    case jpeg
    case heif10HDR

    public var fileExtension: String { self == .jpeg ? "jpg" : "heic" }
    public var displayName: String { self == .jpeg ? "JPEG" : "HEIF · 10 Bit HDR" }
    public var acceptedExtensions: Set<String> { self == .jpeg ? ["jpg", "jpeg"] : ["heic", "heif"] }
}

public enum JPEGExportColorSpace: String, CaseIterable, Sendable {
    case sRGB
    case displayP3
}

public enum JPEGExportSizeMode: String, CaseIterable, Sendable {
    case original
    case longEdge
    case fit
}

public struct JPEGPixelSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum JPEGExportOptionsError: LocalizedError, Equatable, Sendable {
    case invalidQuality
    case invalidResolution
    case invalidPixelsPerInch
    case invalidSourceSize
    case dimensionsTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidQuality: "Die JPEG-Qualität muss zwischen 0 und 100 liegen."
        case .invalidResolution: "Pixelmaße müssen zwischen 1 und 65.535 liegen."
        case .invalidPixelsPerInch: "Die Druckauflösung muss zwischen 1 und 1.200 Pixel pro Zoll liegen."
        case .invalidSourceSize: "Die Pixelmaße des Originals sind ungültig."
        case .dimensionsTooLarge: "JPEG unterstützt höchstens 65.535 Pixel je Bildseite."
        }
    }
}

/// Output geometry is independent of print density; sizing always retains aspect
/// ratio and never crops. Full-size requests are not subject to preview limits.
public struct JPEGExportOptions: Equatable, Sendable {
    public var format: JPEGExportFormat
    public var colorSpace: JPEGExportColorSpace
    public var quality: Int
    public var sizeMode: JPEGExportSizeMode
    public var longEdge: Int
    public var width: Int
    public var height: Int
    public var pixelsPerInch: Int
    public var allowUpscaling: Bool

    public init(format: JPEGExportFormat = .jpeg, colorSpace: JPEGExportColorSpace = .sRGB, quality: Int = 90,
                sizeMode: JPEGExportSizeMode = .original, longEdge: Int = 2_400,
                width: Int = 2_400, height: Int = 1_600, pixelsPerInch: Int = 300,
                allowUpscaling: Bool = false) {
        self.format = format
        self.colorSpace = colorSpace
        self.quality = quality
        self.sizeMode = sizeMode
        self.longEdge = longEdge
        self.width = width
        self.height = height
        self.pixelsPerInch = pixelsPerInch
        self.allowUpscaling = allowUpscaling
    }

    public func validate() throws {
        guard (0...100).contains(quality) else { throw JPEGExportOptionsError.invalidQuality }
        guard (1...65_535).contains(longEdge), (1...65_535).contains(width),
              (1...65_535).contains(height) else { throw JPEGExportOptionsError.invalidResolution }
        guard (1...1_200).contains(pixelsPerInch) else { throw JPEGExportOptionsError.invalidPixelsPerInch }
    }

    public func outputSize(sourceWidth: Int, sourceHeight: Int) throws -> JPEGPixelSize {
        try validate()
        guard sourceWidth > 0, sourceHeight > 0,
              !sourceWidth.multipliedReportingOverflow(by: sourceHeight).overflow else {
            throw JPEGExportOptionsError.invalidSourceSize
        }
        var scale: Double
        switch sizeMode {
        case .original: scale = 1
        case .longEdge: scale = Double(longEdge) / Double(max(sourceWidth, sourceHeight))
        case .fit: scale = min(Double(width) / Double(sourceWidth), Double(height) / Double(sourceHeight))
        }
        if !allowUpscaling { scale = min(1, scale) }
        let resultWidth = max(1, (Double(sourceWidth) * scale).rounded())
        let resultHeight = max(1, (Double(sourceHeight) * scale).rounded())
        guard resultWidth.isFinite, resultHeight.isFinite, resultWidth <= 65_535, resultHeight <= 65_535 else {
            throw JPEGExportOptionsError.dimensionsTooLarge
        }
        return JPEGPixelSize(width: Int(resultWidth), height: Int(resultHeight))
    }
}
