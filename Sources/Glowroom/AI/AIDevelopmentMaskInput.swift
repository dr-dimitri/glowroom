import CoreImage
import GlowroomCore

/// The model sees the selected area at its real developed brightness. Dimmed
/// surroundings identify arbitrary masks, including inversions and refinements.
/// This bounded display-only image is never persisted or used as edited pixels.
enum AIDevelopmentMaskInput {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let softwareContext = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])

    static func fullCanvasSnapshot(_ snapshot: AIEditingSnapshot) -> AIEditingSnapshot {
        var settings = snapshot.settings
        settings.developGeometry = DevelopGeometry(retouchStrokes: settings.developGeometry.retouchStrokes,
            redEyeCorrections: settings.developGeometry.redEyeCorrections)
        return AIEditingSnapshot(assetID: snapshot.assetID, source: snapshot.source, settings: settings,
            token: snapshot.token, persistedVersion: snapshot.persistedVersion)
    }

    static func render(_ bitmap: PreviewBitmap, mask: LocalAdjustmentMask) throws -> PreviewBitmap {
        try Task.checkCancellation()
        let input = CIImage(cgImage: bitmap.image)
        // Layer strength controls the accepted correction, not which object the
        // model inspects. Otherwise a 20% mask would dim its own selected area.
        var selection = mask
        selection.opacity = 1
        let coverage = try LocalAdjustmentRenderer.maskImage(selection, extent: input.extent)
        let dimmed = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.15, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.15, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.15, w: 0)])
        let result = input.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: dimmed, kCIInputMaskImageKey: coverage])
        let colorSpace = bitmap.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let image = context.createCGImage(result, from: input.extent, format: .RGBA8, colorSpace: colorSpace)
            ?? softwareContext.createCGImage(result, from: input.extent, format: .RGBA8, colorSpace: colorSpace)
        else { throw AIDevelopmentError.missingPreview }
        try Task.checkCancellation()
        return PreviewBitmap(image: image)
    }
}
