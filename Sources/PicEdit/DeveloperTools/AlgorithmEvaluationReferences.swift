import Foundation
import PicEditCore

/// Developer-only adapter contract: both sides receive the SAME oriented,
/// developed, straight-alpha linear-sRGB pixels. No decoder or display transform
/// belongs inside an isolated reference algorithm. These helpers have no app UI
/// or production rendering entry point.
protocol AlgorithmEvaluationReference {
    var id: String { get }
    func render(_ input: AlgorithmEvaluationRaster, settings: EditSettings) throws -> AlgorithmEvaluationRaster
}

struct AlgorithmEvaluationIdentity: AlgorithmEvaluationReference {
    let id = "unchanged"
    func render(_ input: AlgorithmEvaluationRaster, settings: EditSettings) throws -> AlgorithmEvaluationRaster { input }
}

/// RGB-only Lightcraft references need this explicit bridge. Matrices are
/// derived from the sRGB/Rec.2020 D65 primary chromaticities, not copied from
/// Lightcraft. Signed and >1 components are preserved; alpha never enters the
/// matrix. A spatial reference must additionally implement alpha-aware support.
enum AlgorithmEvaluationColorBridge {
    static func toRec2020(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        (0.627403895934699 * r + 0.329283038377883 * g + 0.043313065687418 * b,
         0.069097289358232 * r + 0.919540395075459 * g + 0.011362315566309 * b,
         0.016391438875150 * r + 0.088013307877226 * g + 0.895595253247624 * b)
    }
    static func fromRec2020(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        (1.660491002108435 * r - 0.587641138788550 * g - 0.072849863319885 * b,
         -0.124550474521590 * r + 1.132899897125960 * g - 0.008349422604370 * b,
         -0.018150763354905 * r - 0.100578898008007 * g + 1.118729661362912 * b)
    }
}

struct AlgorithmEvaluationNeutralRec2020: AlgorithmEvaluationReference {
    let id = "neutral-rec2020"
    func render(_ input: AlgorithmEvaluationRaster, settings: EditSettings) throws -> AlgorithmEvaluationRaster {
        var pixels = input.pixels
        // Tiny control fixtures: serial work avoids a second nested worker pool.
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let linear = AlgorithmEvaluationColorBridge.toRec2020(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
            let restored = AlgorithmEvaluationColorBridge.fromRec2020(linear.0, linear.1, linear.2)
            pixels[i] = Float(restored.0); pixels[i + 1] = Float(restored.1); pixels[i + 2] = Float(restored.2)
        }
        return try AlgorithmEvaluationRaster(width: input.width, height: input.height, pixels: pixels)
    }
}
