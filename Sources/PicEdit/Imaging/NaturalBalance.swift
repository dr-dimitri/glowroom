import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Version 1 operates on the color-managed, developed image, not sensor values.
/// Statistics and optional local face recognition are independent of edit sliders.
struct NaturalBalanceAnalysis: Sendable {
    let offsets: [Double]
    let colorBoost: Double
    let faceCount: Int

    // Injected normalized Vision rectangles make recognition-dependent behavior
    // reproducible in synthetic tests without depending on a model's detections.
    static func analyze(_ image: CGImage, faceRegions: [CGRect]? = nil) throws -> Self {
        try Task.checkCancellation()
        let scale = min(1, 256 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let proxy = try pixels.withUnsafeMutableBytes { data -> CGImage in
            guard let context = CGContext(data: data.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw EditRenderError.unavailable
            }
            context.interpolationQuality = .high
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let proxy = context.makeImage() else { throw EditRenderError.unavailable }
            return proxy
        }
        try Task.checkCancellation()
        var histogram = [Double](repeating: 0, count: 256)
        var weight = 0.0, sum = 0.0, squaredSum = 0.0, colorSum = 0.0, colorWeight = 0.0
        var darkMass = 0.0, brightMass = 0.0
        // <=65,536 samples: one serial CPU reduction is cheaper than another
        // worker pool/readback. Existing bounded render workers overlap I/O.
        for row in 0..<height {
            if row.isMultiple(of: 32) { try Task.checkCancellation() }
            for column in 0..<width {
                let i = (row * width + column) * 4
                let alpha = Double(pixels[i + 3])
                guard alpha > 0 else { continue }
                let r = Double(pixels[i]) / alpha
                let g = Double(pixels[i + 1]) / alpha
                let b = Double(pixels[i + 2]) / alpha
                let y = min(1, 0.2126 * r + 0.7152 * g + 0.0722 * b)
                let coverage = alpha / 255
                histogram[min(255, Int((y * 255).rounded()))] += coverage
                weight += coverage
                sum += y * coverage
                squaredSum += y * y * coverage
                darkMass += max(0, (0.28 - y) / 0.28) * coverage
                brightMass += max(0, (y - 0.72) / 0.28) * coverage
                if y > 0.10 && y < 0.90 {
                    let maximum = max(r, g, b), minimum = min(r, g, b)
                    colorSum += (maximum - minimum) / max(maximum, 0.001) * coverage
                    colorWeight += coverage
                }
            }
        }
        guard weight > 0 else { return Self(offsets: Array(repeating: 0, count: 7), colorBoost: 0, faceCount: 0) }
        func percentile(_ fraction: Double) -> Double {
            var accumulated = 0.0
            for (i, frequency) in histogram.enumerated() {
                accumulated += frequency
                if accumulated >= weight * fraction { return Double(i) / 255 }
            }
            return 1
        }
        func unit(_ x: Double) -> Double { min(1, max(0, x)) }
        let span = percentile(0.95) - percentile(0.05)
        let mean = sum / weight
        // Variance also sees small subjects missed by the 5/95% percentiles.
        // The same noise floor still leaves near-flat fields unchanged.
        let deviation = sqrt(max(0, squaredSum / weight - mean * mean))
        let position = unit((max(span, 2 * deviation) - 0.025) / 0.12)
        let confidence = position * position * (3 - 2 * position)
        // Flat fields and near-flat noise supply no evidence for correction.
        guard confidence > 0 else { return Self(offsets: Array(repeating: 0, count: 7), colorBoost: 0, faceCount: 0) }

        // A bounded on-device Vision request adds portrait protection even on
        // Macs without the optional language/image model. Failure leaves the
        // conservative statistical path available; no cloud or extra RAW decode.
        let regions = try faceRegions ?? detectFaces(proxy)
        let faces = regions.count
        let portraitLuminance = faceLuminance(pixels, width: width, height: height, regions: regions)
        // Preserve low/high-key intent: a dark scene need not become daylight.
        // Portraits permit a little more shadow opening, still globally bounded.
        let lowKey = unit((0.38 - percentile(0.85)) / 0.30)
        let highKey = unit((percentile(0.15) - 0.62) / 0.30)
        let shadowRestraint = 1 - (faces > 0 ? 0.25 : 0.55) * lowKey
        let highlightRestraint = 1 - 0.55 * highKey
        let tailImportance = 0.30 + 0.70 * unit(abs(mean - 0.5) / 0.30)
        let statisticalShadows = max(unit((0.28 - percentile(0.20)) / 0.25),
            unit(darkMass / weight / 0.25) * tailImportance)
        // A small backlit portrait can be invisible to global percentiles.
        // Read the central face regions, then increase the bounded global fill
        // only when bright-background evidence also exists. No face pixels are
        // painted separately and no target skin color or identity is inferred.
        let portraitFill = portraitLuminance.map {
            unit((0.50 - $0) / 0.32) * unit((percentile(0.80) - 0.65) / 0.25)
        } ?? 0
        let shadows = max(statisticalShadows, portraitFill) * confidence * shadowRestraint
        let highlights = max(unit((percentile(0.80) - 0.72) / 0.25),
            unit(brightMass / weight / 0.25) * tailImportance) * confidence * highlightRestraint
        let globalMiddle = (min(0.045, max(0, (0.40 - mean) * 0.22)) * shadowRestraint
            - min(0.045, max(0, (mean - 0.60) * 0.22)) * highlightRestraint) * confidence
        // In mixed lighting the global average describes the background, not
        // necessarily the subject. Keep the middle neutral there. A detected
        // backlit face below mid-gray must also never be darkened by that mean.
        let middle = portraitFill > 0 ? max(0.02 * portraitFill * confidence, globalMiddle)
            : shadows > 0 && highlights > 0 ? 0 : globalMiddle
        let contrast = unit((0.60 - span) / 0.40) * confidence * (1 - max(shadows, highlights))
        // Fixed endpoints + ordered knots + monotone cubic interpolation keep
        // gradients intact. No local blur means no halos at trees/sky boundaries.
        let lowOuter = 0.045 * shadows + 0.2 * middle
        let lowInner = 0.09 * shadows + 0.55 * middle - 0.025 * contrast
        let highInner = -0.09 * highlights + 0.55 * middle + 0.025 * contrast
        let highOuter = -0.045 * highlights + 0.2 * middle
        // A bright background must never darken an observed shadow subject;
        // likewise a dark scene must never push observed highlights higher.
        let offsets = [0, shadows > 0 ? max(0.045 * shadows, lowOuter) : lowOuter,
            shadows > 0 ? max(0.09 * shadows, lowInner) : lowInner, middle,
            highlights > 0 ? min(-0.09 * highlights, highInner) : highInner,
            highlights > 0 ? min(-0.045 * highlights, highOuter) : highOuter, 0]
        let saturation = colorWeight > 0 ? colorSum / colorWeight : 0
        // The scene supplies the ceiling; per-pixel chroma, hue and headroom
        // protection below make already colorful subjects respond less.
        let colorBoost = 0.32 * (1 - 0.75 * saturation) * confidence * (faces > 0 ? 0.75 : 1)
        return Self(offsets: offsets, colorBoost: colorBoost, faceCount: faces)
    }

    private static func faceLuminance(_ pixels: [UInt8], width: Int, height: Int, regions: [CGRect]) -> Double? {
        var histogram = [Double](repeating: 0, count: 256)
        var weight = 0.0
        for region in regions.prefix(8) {
            let center = region.insetBy(dx: region.width * 0.2, dy: region.height * 0.2)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !center.isNull, !center.isEmpty else { continue }
            let x0 = max(0, min(width, Int(center.minX * Double(width))))
            let x1 = max(x0, min(width, Int(ceil(center.maxX * Double(width)))))
            // Vision's normalized origin is lower-left; bitmap rows are top-down.
            let y0 = max(0, min(height, Int((1 - center.maxY) * Double(height))))
            let y1 = max(y0, min(height, Int(ceil((1 - center.minY) * Double(height)))))
            for row in y0..<y1 { for column in x0..<x1 {
                let i = (row * width + column) * 4
                let alpha = Double(pixels[i + 3])
                guard alpha > 0 else { continue }
                let y = (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / alpha
                let coverage = alpha / 255
                histogram[min(255, max(0, Int((y * 255).rounded())))] += coverage
                weight += coverage
            } }
        }
        guard weight > 0 else { return nil }
        var accumulated = 0.0
        for (i, value) in histogram.enumerated() {
            accumulated += value
            if accumulated >= weight * 0.5 { return Double(i) / 255 }
        }
        return nil
    }

    private static func detectFaces(_ image: CGImage) throws -> [CGRect] {
        try Task.checkCancellation()
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision1
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            try Task.checkCancellation()
            return []
        }
        try Task.checkCancellation()
        return Array((request.results ?? []).filter { $0.confidence >= 0.6 }.prefix(8)).map(\.boundingBox)
    }
}

enum NaturalBalanceRenderer {
    static func apply(to image: CIImage, original: CGImage, amount: Double,
                      colorAmount: Double, extent: CGRect) throws -> CIImage {
        try Task.checkCancellation()
        let strength = amount.isFinite ? min(1, max(0, amount / 100)) : 0
        guard strength > 0 else { return image }
        let analysis = try NaturalBalanceAnalysisCache.shared.analysis(for: original)
        let curve = AutoToneCurve(ordinates: zip(AutoToneCurve.abscissae, analysis.offsets).map { $0 + strength * $1 })
        let color = colorAmount.isFinite ? min(1, max(0, colorAmount / 100)) : 0
        let boost = analysis.colorBoost * strength * color
        guard !curve.isIdentity || boost > 0 else { return image }
        let vectors = curve.coefficients.map { CIVector(x: $0[0], y: $0[1], z: $0[2], w: $0[3]) }
        guard let result = kernel?.apply(extent: extent, arguments: [image] + vectors + [boost]) else {
            throw EditRenderError.unavailable
        }
        try Task.checkCancellation()
        return result
    }

    private static let kernel = CIColorKernel(source: """
        kernel vec4 naturalBalance(__sample original, vec4 c0, vec4 c1, vec4 c2, vec4 c3, vec4 c4, vec4 c5, float boost) {
            vec4 o = unpremultiply(original);
            vec3 magnitude = abs(o.rgb);
            vec3 rgb = sign(o.rgb) * mix(12.92 * magnitude, 1.055 * pow(magnitude, vec3(1.0 / 2.4)) - vec3(0.055), step(vec3(0.0031308), magnitude));
            float y = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
            float x = clamp(y, 0.0, 1.0);
            vec4 c = c5;
            float t = (x - 0.94) / 0.06;
            if (x < 0.06) { c = c0; t = x / 0.06; }
            else if (x < 0.25) { c = c1; t = (x - 0.06) / 0.19; }
            else if (x < 0.50) { c = c2; t = (x - 0.25) / 0.25; }
            else if (x < 0.75) { c = c3; t = (x - 0.50) / 0.25; }
            else if (x < 0.94) { c = c4; t = (x - 0.75) / 0.19; }
            float target = clamp(((c.x * t + c.y) * t + c.z) * t + c.w, 0.0, 1.0);
            float lo = min(min(rgb.r, rgb.g), rgb.b);
            float hi = max(max(rgb.r, rgb.g), rgb.b);
            float saturation = clamp((hi - lo) / max(hi, 0.000001), 0.0, 1.0);
            // Broad warm-hue protection is deliberately conservative: no face
            // detection is required to protect skin, wood and sunset colors.
            float warm = smoothstep(0.0, 0.10, rgb.r - rgb.g) * (1.0 - smoothstep(-0.02, 0.05, rgb.b - rgb.g));
            float colorWeight = pow(1.0 - saturation, 2.0) * (1.0 - 0.70 * warm);
            colorWeight *= smoothstep(0.025, 0.16, y) * (1.0 - smoothstep(0.80, 0.98, y));
            vec3 chroma = rgb - vec3(y);
            // Do not multiply shadow chroma by a large exposure ratio (which
            // amplifies chroma noise). Retain existing color when dimming lights.
            float gain = min(1.18, target / max(y, 0.000001)) * (1.0 + boost * colorWeight);
            float lower = min(lo, 1.0 / 255.0);
            float upper = max(hi, 1.0 - 1.0 / 255.0);
            float maximum = max(max(chroma.r, chroma.g), chroma.b);
            float minimum = min(min(chroma.r, chroma.g), chroma.b);
            gain = min(gain, (upper - target) / max(maximum, 0.000001));
            gain = min(gain, (target - lower) / max(-minimum, 0.000001));
            vec3 adjusted = vec3(target) + max(0.0, gain) * chroma;
            if (y <= 0.0 || y >= 1.0) { adjusted = rgb; }
            magnitude = abs(adjusted);
            vec3 linear = sign(adjusted) * mix(magnitude / 12.92, pow((magnitude + vec3(0.055)) / 1.055, vec3(2.4)), step(vec3(0.04045), magnitude));
            return premultiply(vec4(linear, o.a));
        }
        """)
}
