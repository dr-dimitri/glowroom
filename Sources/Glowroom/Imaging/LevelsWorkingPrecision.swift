import GlowroomCore
import CoreImage
import CryptoKit
import Foundation

extension EditSettings {
    /// New Levels use Float even on a legacy tone receipt. This selects buffer
    /// precision only: the saved tone algorithm and its kernels stay unchanged.
    var usesFloatWorkingGraph: Bool {
        toneProcessingVersion == .consistentV2 || !levels.isNeutral
    }

    /// Reuse the existing conservative Float allocation plan without changing
    /// the processing version passed to any pixel operation.
    var workingMemoryVersion: ToneProcessingVersion {
        usesFloatWorkingGraph ? .consistentV2 : .legacyV1
    }

    /// Two additional RGBAf planes cover the node/range reduction and, when
    /// later filters are active, its final finite-value proof. No CPU full-frame
    /// buffer or histogram is allocated by Levels.
    var additionalLevelsBytesPerPixel: UInt64 { levels.isNeutral ? 0 : 32 }
}

extension PreviewBitmap {
    /// A resize is a new raster derivation. Equal direct resizes share a proof;
    /// half/Float resizes and multi-step resizes must never share that proof.
    /// Hashing this tiny descriptor avoids retaining either source or pixels.
    func rangeIdentityForResize(width: Int, height: Int, format: CIFormat, precise: Bool) -> UUID {
        let descriptor = "\(rangeSourceIdentity.uuidString):\(image.width):\(image.height):\(image.bitsPerComponent):\(image.bitsPerPixel):\(width):\(height):\(format.rawValue):\(precise)"
        let bytes = Array(SHA256.hash(data: Data(descriptor.utf8)).prefix(16))
        return UUID(uuid: bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
    }
}
