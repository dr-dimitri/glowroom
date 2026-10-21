import CoreGraphics
import CoreImage
import Foundation
import GlowroomCore

/// One-time edge guidance before the immutable selection is saved. The caller
/// holds the automatic-mask lease; Core Image schedules its own pixel work.
/// Slider movement and export only reuse the resulting Gray8 raster.
enum AutomaticMaskRefiner {
    private static let context = makeContext(softwareRenderer: false)
    private static let softwareContext = makeContext(softwareRenderer: true)

    private static func makeContext(softwareRenderer: Bool) -> CIContext {
        CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                            .workingFormat: CIFormat.RGBAf,
                            .cacheIntermediates: false, .useSoftwareRenderer: softwareRenderer])
    }

    static func refine(_ raster: LocalMaskRaster, guide: CGImage,
                       softwareRenderer: Bool = false) throws -> LocalMaskRaster {
        try Task.checkCancellation()
        let extent = CGRect(x: 0, y: 0, width: raster.width, height: raster.height)
        guard let provider = CGDataProvider(data: raster.bytes as CFData),
              let mask = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8,
                bitsPerPixel: 8, bytesPerRow: raster.width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw AutomaticMaskError.unavailable }
        let input = CIImage(cgImage: mask, options: [.colorSpace: NSNull()])
        let guidance = CIImage(cgImage: guide).transformed(by: CGAffineTransform(
            scaleX: extent.width / CGFloat(guide.width), y: extent.height / CGFloat(guide.height)))
            .cropped(to: extent)
        let filtered = try guided(input, guide: guidance, extent: extent,
                                  radius: max(3, Double(max(raster.width, raster.height)) / 256))
        // Coverage has no ICC transfer curve. Quantize only after refinement;
        // never interpret the mask as display-gray or apply a hard threshold.
        let renderer = softwareRenderer ? softwareContext : context
        guard let result = renderer.createCGImage(filtered, from: extent, format: .RGBA8, colorSpace: nil),
              let data = result.dataProvider?.data, let base = CFDataGetBytePtr(data) else {
            if !softwareRenderer { return try refine(raster, guide: guide, softwareRenderer: true) }
            throw AutomaticMaskError.unavailable
        }
        try Task.checkCancellation()
        var bytes = Data(count: raster.width * raster.height)
        bytes.withUnsafeMutableBytes { storage in
            for y in 0..<raster.height {
                let row = base.advanced(by: y * result.bytesPerRow)
                let output = storage.bindMemory(to: UInt8.self)
                for x in 0..<raster.width { output[y * raster.width + x] = row[x * 4] }
            }
        }
        try Task.checkCancellation()
        return try LocalMaskRaster(width: raster.width, height: raster.height, bytes: bytes)
    }

    /// RGB guided filter (He, Sun, Tang, ECCV 2010, equations 14–16).
    /// RGB covariance retains chromatic edges even at equal luminance. All
    /// moments stay float data in one Core Image graph, including negative
    /// coefficients; only the final coverage is clamped/quantized. Box-filter
    /// dependencies are ordered, while Core Image parallelizes the pixels.
    private static func guided(_ mask: CIImage, guide: CIImage, extent: CGRect,
                               radius: Double) throws -> CIImage {
        func mean(_ image: CIImage) -> CIImage {
            image.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
        }
        func apply(_ kernel: CIColorKernel?, _ arguments: [Any]) throws -> CIImage {
            guard let result = kernel?.apply(extent: extent, arguments: arguments) else { throw AutomaticMaskError.unavailable }
            return result
        }
        let meanGuide = mean(guide), meanMask = mean(mask)
        let squares = mean(try apply(squareKernel, [guide]))
        let crosses = mean(try apply(crossKernel, [guide]))
        let products = mean(try apply(productKernel, [guide, mask]))
        let a = try apply(coefficientKernel, [meanGuide, meanMask, squares, crosses, products, 0.0001])
        let b = try apply(interceptKernel, [a, meanGuide, meanMask])
        return try apply(reconstructionKernel, [mean(a), mean(b), guide, mask])
    }

    private static let squareKernel = CIColorKernel(source: """
        kernel vec4 maskGuideSquares(__sample i) { return vec4(i.rgb * i.rgb, 1.0); }
        """)
    private static let crossKernel = CIColorKernel(source: """
        kernel vec4 maskGuideCrosses(__sample i) { return vec4(i.r*i.g, i.r*i.b, i.g*i.b, 1.0); }
        """)
    private static let productKernel = CIColorKernel(source: """
        kernel vec4 maskGuideProducts(__sample i, __sample p) { return vec4(i.rgb * p.r, 1.0); }
        """)
    private static let coefficientKernel = CIColorKernel(source: """
        kernel vec4 maskGuideCoefficients(__sample i, __sample p, __sample squares,
                                          __sample crosses, __sample products, float epsilon) {
            vec3 diagonal = max(squares.rgb - i.rgb*i.rgb, vec3(0.0)) + vec3(epsilon);
            vec3 off = crosses.rgb - vec3(i.r*i.g, i.r*i.b, i.g*i.b);
            vec3 cov = products.rgb - i.rgb*p.r;
            float rr = diagonal.r, gg = diagonal.g, bb = diagonal.b;
            float rg = off.r, rb = off.g, gb = off.b;
            float A = gg*bb-gb*gb, B = rb*gb-rg*bb, C = rg*gb-rb*gg;
            float D = rr*bb-rb*rb, E = rb*rg-rr*gb, F = rr*gg-rg*rg;
            float det = max(rr*A + rg*B + rb*C, epsilon*epsilon*epsilon);
            vec3 a = vec3(dot(vec3(A,B,C), cov), dot(vec3(B,D,E), cov), dot(vec3(C,E,F), cov)) / det;
            return vec4(a, 1.0);
        }
        """)
    private static let interceptKernel = CIColorKernel(source: """
        kernel vec4 maskGuideIntercept(__sample a, __sample i, __sample p) {
            return vec4(vec3(p.r - dot(a.rgb, i.rgb)), 1.0);
        }
        """)
    private static let reconstructionKernel = CIColorKernel(source: """
        kernel vec4 maskGuideReconstruct(__sample a, __sample b, __sample i, __sample original) {
            // A semantic matte may already overreach fine branches. Guided
            // smoothing must not spread that error into definite background.
            // Keep its support and only reduce image-inconsistent coverage.
            float coverage = min(original.r, clamp(dot(a.rgb, i.rgb) + b.r, 0.0, 1.0));
            return vec4(vec3(coverage), 1.0);
        }
        """)
}
