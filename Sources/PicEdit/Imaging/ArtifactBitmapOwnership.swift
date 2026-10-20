import CoreGraphics
import Foundation
import PicEditCore

private final class ArtifactBitmapOwner {
    let image: CGImage
    let data: CFData
    let memory: ArtifactMemoryReservation
    init(image: CGImage, data: CFData, memory: ArtifactMemoryReservation) { self.image = image; self.data = data; self.memory = memory }
}

extension PreviewBitmap {
    /// Attach the budget to the real native provider, so an NSImage surviving a
    /// view/cache bitmap also keeps its bytes charged. No free provider copy.
    func retainingArtifactMemory(_ memory: ArtifactMemoryReservation, owner: any ArtifactResourceAdmitting) throws -> PreviewBitmap {
        guard let data = image.dataProvider?.data, CFDataGetLength(data) >= byteCost,
              let pointer = CFDataGetBytePtr(data) else { throw ArtifactContractError.corruptArtifact }
        let context = Unmanaged.passRetained(ArtifactBitmapOwner(image: image, data: data, memory: memory)).toOpaque()
        guard let provider = CGDataProvider(dataInfo: context, data: pointer, size: CFDataGetLength(data), releaseData: { context, _, _ in
            if let context { Unmanaged<ArtifactBitmapOwner>.fromOpaque(context).release() }
        }) else {
            Unmanaged<ArtifactBitmapOwner>.fromOpaque(context).release(); throw ArtifactContractError.corruptArtifact
        }
        guard let wrapped = CGImage(width: image.width, height: image.height, bitsPerComponent: image.bitsPerComponent,
            bitsPerPixel: image.bitsPerPixel, bytesPerRow: image.bytesPerRow, space: image.colorSpace!, bitmapInfo: image.bitmapInfo,
            provider: provider, decode: image.decode, shouldInterpolate: image.shouldInterpolate, intent: image.renderingIntent) else {
            throw ArtifactContractError.corruptArtifact
        }
        return PreviewBitmap(image: wrapped, sourceLongEdge: sourceLongEdge, memoryOwnership: memory, resourceOwner: owner)
    }
}
