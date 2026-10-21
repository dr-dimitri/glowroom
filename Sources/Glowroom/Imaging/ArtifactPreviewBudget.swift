import Foundation
import GlowroomCore

/// Known immutable raster metadata bounds four-channel native decode buffers.
/// RGB may decode as noneSkipLast; its persistent three channels are not a
/// promise of a packed three-channel ImageIO bitmap.
struct ArtifactPreviewBudget: Sendable {
    let nativeBytes: Int64
    let outputBytes: Int64
    let peakBytes: Int64
    let outputWidth: Int
    let outputHeight: Int
    let bits: Int
    var retiresOtherCaches: Bool { peakBytes > 256 * 1_024 * 1_024 }

    init(format: ArtifactRasterFormat, pixelSize: Int) throws {
        guard (64...4_096).contains(pixelSize), format.schemaVersion == 1, format.orientation == .up else {
            throw ArtifactContractError.invalidValue("preview format")
        }
        bits = format.bitDepth.rawValue
        outputWidth = min(pixelSize, format.size.width)
        outputHeight = min(pixelSize, format.size.height)
        nativeBytes = try Self.bytes(width: format.size.width, height: format.size.height, bits: bits)
        outputBytes = try Self.bytes(width: outputWidth, height: outputHeight, bits: bits)
        let (nativePeak, a) = nativeBytes.multipliedReportingOverflow(by: 3)
        let (outputPeak, b) = outputBytes.multipliedReportingOverflow(by: 2)
        let (rasterPeak, c) = nativePeak.addingReportingOverflow(outputPeak)
        let (total, d) = rasterPeak.addingReportingOverflow(65_536)
        guard !a, !b, !c, !d else { throw ArtifactContractError.limitExceeded }
        peakBytes = total
        guard peakBytes <= 536_870_912 else { throw ArtifactPreviewFailure.rasterTooLarge }
    }

    private static func bytes(width: Int, height: Int, bits: Int) throws -> Int64 {
        guard width > 0, height > 0, [8, 16].contains(bits) else { throw ArtifactContractError.unsupportedFormat }
        let (row, a) = Int64(width).multipliedReportingOverflow(by: Int64(4 * (bits / 8)))
        let (padded, b) = row.addingReportingOverflow(255)
        guard !a, !b else { throw ArtifactContractError.limitExceeded }
        let (total, c) = (padded / 256 * 256).multipliedReportingOverflow(by: Int64(height))
        guard !c else { throw ArtifactContractError.limitExceeded }
        return total
    }

    func validate(_ bitmap: PreviewBitmap) throws {
        guard bitmap.image.width <= outputWidth, bitmap.image.height <= outputHeight,
              bitmap.image.bitsPerComponent <= bits, bitmap.image.bitsPerPixel <= 4 * bits,
              bitmap.byteCost > 0, Int64(bitmap.byteCost) <= outputBytes else {
            throw ArtifactContractError.limitExceeded
        }
    }
}

enum ArtifactPreviewFailure: LocalizedError, Equatable, Sendable {
    case resourcesBusy, rasterTooLarge
    var errorDescription: String? {
        switch self {
        case .resourcesBusy:
            return "Für diese Vorschau ist momentan nicht genügend freier Bildspeicher verfügbar. Noch verwendete Bilder bleiben geschützt. Versuche es nach Abschluss der laufenden Arbeit erneut."
        case .rasterTooLarge:
            return "Dieses Bild überschreitet das Speicherlimit für eine sichere Vorschau."
        }
    }
}

enum ArtifactPreviewAdmission {
    /// The existing decoder lane remains occupied during these two short waits.
    /// Cache retirement drops only cache ownership; native readers stay charged.
    static func perform<T: Sendable>(retireCaches: @Sendable () async -> Void,
        operation: @Sendable () async throws -> T) async throws -> T {
        for attempt in 0..<3 {
            do { return try await operation() }
            catch ArtifactResourceError.capacityExceeded { }
            catch ArtifactResourceError.queueFull { }
            catch { throw error }
            guard attempt < 2 else { throw ArtifactPreviewFailure.resourcesBusy }
            await retireCaches()
            try await Task.sleep(for: .milliseconds(attempt == 0 ? 10 : 20))
        }
        throw ArtifactPreviewFailure.resourcesBusy
    }
}
