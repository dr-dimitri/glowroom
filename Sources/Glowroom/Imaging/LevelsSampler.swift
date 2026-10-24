import CoreImage
import Foundation
import GlowroomCore

enum LevelsSamplingError: Error, Equatable, LocalizedError {
    case invalidGeometry
    case insufficientCoverage
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidGeometry: "Diese Bildstelle passt nicht zur angezeigten Vorschau. Warte auf die aktuelle Vorschau und versuche es erneut."
        case .insufficientCoverage: "Die Probe enthält zu wenig sichtbare Bildfläche. Wähle eine weniger transparente Bildstelle."
        case .unavailable: "Die Bildprobe konnte nicht berechnet werden. Der bisherige Stand bleibt erhalten."
        }
    }
}

struct LevelsSampleReport: Equatable, Sendable {
    let sample: LevelsPickerSample
    let proxyWidth: Int
    let proxyHeight: Int
    /// Window origin uses top-left proxy pixel coordinates, independent of CI.
    let windowX: Int
    let windowY: Int
    let windowWidth: Int
    let windowHeight: Int
    let validPixelCount: Int
    let visibleEquivalent: Double
    var windowPixelCount: Int { windowWidth * windowHeight }
}

/// Sampling uses the actual accepted adaptive renderer input (at most 4096²),
/// with a fixed 5×5 window clipped at its raster edges. No source resize, file
/// read, decode, histogram or full CPU raster is performed by this helper.
enum LevelsSampler {
    static let windowEdge = 5
    static let minimumCoverageFraction = 0.25
    static let minimumVisibleEquivalent = 1.0
    static let maximumReadbackBytes = 5 * 5 * 4 * MemoryLayout<Float>.stride

    /// The existing bounded analysis/render worker owns context and admission.
    /// Read linear premultiplied RGBAf, unpremultiply each valid pixel, encode
    /// each straight component, THEN average encoded RGB with alpha weights.
    static func sample(graph: CIImage, extent requestedExtent: CGRect? = nil,
                       normalizedTopLeft point: CGPoint, context: CIContext) throws -> LevelsSampleReport {
        try Task.checkCancellation()
        let extent = requestedExtent ?? graph.extent
        guard [extent.minX, extent.minY, extent.width, extent.height, point.x, point.y].allSatisfy(\.isFinite),
              extent.width >= 1, extent.height >= 1, extent.width <= 4_096, extent.height <= 4_096,
              extent.width.rounded() == extent.width, extent.height.rounded() == extent.height,
              extent.minX.rounded() == extent.minX, extent.minY.rounded() == extent.minY,
              graph.extent.contains(extent), (0...1).contains(point.x), (0...1).contains(point.y) else {
            throw LevelsSamplingError.invalidGeometry
        }
        let width = Int(extent.width), height = Int(extent.height)
        let centerX = min(width - 1, Int((point.x * CGFloat(width)).rounded(.down)))
        let centerY = min(height - 1, Int((point.y * CGFloat(height)).rounded(.down)))
        let left = max(0, centerX - 2), top = max(0, centerY - 2)
        let right = min(width, centerX + 3), bottom = min(height, centerY + 3)
        let windowWidth = right - left, windowHeight = bottom - top
        let bounds = CGRect(x: extent.minX + CGFloat(left), y: extent.maxY - CGFloat(bottom),
                            width: CGFloat(windowWidth), height: CGFloat(windowHeight))
        // Mark invalid pixels invisible before readback: a backend/color
        // conversion must not turn a NaN into plausible opaque black. The
        // point kernel is evaluated only for the requested 25-pixel ROI.
        guard let visible = visibilityKernel?.apply(extent: bounds, arguments: [graph]) else {
            throw LevelsSamplingError.unavailable
        }
        var pixels = [Float](repeating: 0, count: windowWidth * windowHeight * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(visible, toBitmap: bytes.baseAddress!, rowBytes: windowWidth * 4 * MemoryLayout<Float>.stride,
                           bounds: bounds, format: .RGBAf, colorSpace: FloatAnalysis.workingSpace)
        }
        try Task.checkCancellation()
        return try reduce(pixels: pixels, proxyWidth: width, proxyHeight: height,
                          windowX: left, windowY: top, windowWidth: windowWidth, windowHeight: windowHeight)
    }

    /// Only 25 pixels: serial reduction avoids scheduling/synchronization cost.
    /// Kept separate for nonfinite/coverage tests without backend NaN rewriting.
    static func reduce(pixels: [Float], proxyWidth: Int, proxyHeight: Int,
                       windowX: Int, windowY: Int, windowWidth: Int, windowHeight: Int) throws -> LevelsSampleReport {
        guard proxyWidth > 0, proxyHeight > 0, proxyWidth <= 4_096, proxyHeight <= 4_096,
              windowWidth > 0, windowHeight > 0, windowWidth <= windowEdge, windowHeight <= windowEdge,
              windowX >= 0, windowY >= 0, windowX <= proxyWidth - windowWidth, windowY <= proxyHeight - windowHeight,
              pixels.count == windowWidth * windowHeight * 4 else { throw LevelsSamplingError.invalidGeometry }
        var red = 0.0, green = 0.0, blue = 0.0, mass = 0.0
        var valid = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            try Task.checkCancellation()
            let alpha = Double(pixels[offset + 3])
            guard alpha.isFinite, alpha > 0, alpha <= 1 else { continue }
            let components = (0..<3).map { Double(pixels[offset + $0]) / alpha }
            guard components.allSatisfy({ $0.isFinite && Float($0).isFinite }) else { continue }
            let encoded = components.map(SignedSRGB.encode)
            guard encoded.allSatisfy(\.isFinite) else { continue }
            red += encoded[0] * alpha; green += encoded[1] * alpha; blue += encoded[2] * alpha
            mass += alpha; valid += 1
        }
        let threshold = max(minimumVisibleEquivalent, minimumCoverageFraction * Double(windowWidth * windowHeight))
        guard mass >= threshold else { throw LevelsSamplingError.insufficientCoverage }
        let sample = LevelsPickerSample(red: red / mass, green: green / mass, blue: blue / mass)
        try sample.validate()
        return LevelsSampleReport(sample: sample, proxyWidth: proxyWidth, proxyHeight: proxyHeight,
            windowX: windowX, windowY: windowY, windowWidth: windowWidth, windowHeight: windowHeight,
            validPixelCount: valid, visibleEquivalent: mass)
    }

    private static let visibilityKernel = CIColorKernel(source: """
        float pickerFinite(float value) { return value == value && abs(value) <= 3.402823e38 ? 1.0 : 0.0; }
        kernel vec4 levelsPickerVisible(__sample original) {
            if (pickerFinite(original.a) < 0.5 || original.a <= 0.0 || original.a > 1.0) return vec4(0.0);
            vec3 straight = original.rgb / original.a;
            if (pickerFinite(straight.r) < 0.5 || pickerFinite(straight.g) < 0.5 || pickerFinite(straight.b) < 0.5) return vec4(0.0);
            return original;
        }
        """)
}
