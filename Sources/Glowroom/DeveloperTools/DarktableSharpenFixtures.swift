import Foundation

enum DarktableSharpenFixtures {
    typealias Raster = AlgorithmEvaluationRaster
    struct Fixture: Sendable {
        let scene: String
        let input: Raster
        let truth: Raster
        let acceptance: Bool
        var isEdge: Bool { scene == "slanted-edge" || scene == "broad-edge" }
    }
    static let scenes = ["slanted-edge", "broad-edge", "line-pairs", "impulse", "fine-texture", "noisy-flat", "blurred-truth", "alpha-signed-hdr"]

    static func edgeX(y: Int, width: Int, height: Int, acceptance: Bool) -> Double {
        // Keep the fixed +/-24-pixel halo ROI inside even extreme portrait
        // rasters accepted by the CLI. Clamping changes only synthetic geometry.
        let center = Double(width) * 0.5 + 0.125 * (Double(y) - Double(height) * 0.5) + (acceptance ? 0.37 : -0.23)
        return min(Double(width - 25), max(24, center))
    }
    static func make(scene: String, acceptance: Bool, width: Int = 256, height: Int = 160) throws -> Fixture {
        guard scenes.contains(scene), width >= 64, height >= 32, width <= 8192, height <= 8192,
              width * height <= 32_000_000 else { throw DarktableSharpenReference.Failure.invalid }
        let phase = acceptance ? 0.37 : -0.23
        var truth = [Float](repeating: 0, count: width * height * 4)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            if y.isMultiple(of: 32) { try Task.checkCancellation() }
            for x in 0..<width {
                let i = y * width + x, p = i * 4, xx = Double(x) + phase, yy = Double(y)
                let value: Double
                switch scene {
                case "slanted-edge", "broad-edge":
                    value = Double(x) < edgeX(y: y, width: width, height: height, acceptance: acceptance) ? 0.12 : 0.62
                case "line-pairs": value = 0.32 + 0.12 * (sin(xx * Double.pi / 2) >= 0 ? 1 : -1)
                case "impulse": value = abs(x - width / 2) <= 1 && abs(y - height / 2) <= 1 ? 0.7 : 0.2
                case "fine-texture": value = 0.32 + 0.035 * sin(xx * 1.8) + 0.02 * cos(yy * 1.6 + xx * 0.4)
                case "noisy-flat": value = 0.3
                case "blurred-truth": value = 0.3 + 0.04 * sin(xx * 1.3) + (x > width / 2 ? 0.13 : 0)
                default: value = 1.3 + 0.2 * sin(xx * 0.9)
                }
                values[i] = Float(value)
                for c in 0..<3 { truth[p + c] = Float(value) }
                truth[p + 3] = 1
            }
        }
        let alpha = [Float](repeating: 1, count: width * height)
        var soft = try DarktableSharpenReference.blur(values, width: width, height: height, sigma: scene == "broad-edge" ? 2 : 0.85, alpha: alpha)
        if scene == "slanted-edge" || scene == "broad-edge" {
            // Analytic Gaussian edge avoids tuning/acceptance raster-phase alias.
            let sigma = scene == "broad-edge" ? 2.0 : 0.85
            for y in 0..<height { for x in 0..<width {
                let distance = Double(x) - edgeX(y: y, width: width, height: height, acceptance: acceptance)
                soft[y * width + x] = Float(0.12 + 0.5 * 0.5 * (1 + erf(distance / (sigma * sqrt(2)))))
            } }
        }
        var state: UInt64 = acceptance ? 0x174ace : 0x174a11
        func noise() -> Float {
            // Fixed split seeds, bounded uniform noise with known variance.
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(state >> 40) / Double(1 << 24) - 0.5) * 0.012
        }
        var input = truth
        for i in 0..<values.count {
            let p = i * 4, x = i % width
            let n = scene == "noisy-flat" ? noise() : 0
            for c in 0..<3 { input[p + c] = soft[i] + n }
            if scene == "alpha-signed-hdr" {
                let a: Float = x < width / 4 ? 0 : x < width / 2 ? 0.4 : 1
                input[p] = -0.04; input[p + 1] = soft[i] * 1.4; input[p + 2] = soft[i] * 0.8; input[p + 3] = a
                truth[p] = -0.04; truth[p + 1] = values[i] * 1.4; truth[p + 2] = values[i] * 0.8; truth[p + 3] = a
            }
        }
        return Fixture(scene: scene, input: try Raster(width: width, height: height, pixels: input),
                       truth: try Raster(width: width, height: height, pixels: truth), acceptance: acceptance)
    }
}

enum DarktableSharpenMetrics {
    typealias Raster = AlgorithmEvaluationRaster
    static func luminance(_ raster: Raster) -> [Double] {
        (0..<(raster.width * raster.height)).map { i in
            let p = i * 4
            return 0.2126 * Double(raster.pixels[p]) + 0.7152 * Double(raster.pixels[p + 1]) + 0.0722 * Double(raster.pixels[p + 2])
        }
    }
    static func edgeSlope(_ output: Raster, acceptance: Bool) -> Double {
        let w = output.width, h = output.height
        guard w >= 3, h > 16 else { return 0 }
        func at(_ x: Int, _ y: Int) -> Double {
            let p = (y * w + x) * 4
            return 0.2126 * Double(output.pixels[p]) + 0.7152 * Double(output.pixels[p + 1]) + 0.0722 * Double(output.pixels[p + 2])
        }
        var sum = 0.0
        for y in 8..<(h - 8) {
            let center = Int(DarktableSharpenFixtures.edgeX(y: y, width: w, height: h, acceptance: acceptance))
            var slope = 0.0
            for x in max(1, center - 6)...min(w - 2, center + 6) { slope = max(slope, at(x + 1, y) - at(x - 1, y)) }
            sum += slope
        }
        return sum / Double(h - 16)
    }
    static func measure(_ output: Raster, fixture: DarktableSharpenFixtures.Fixture) throws -> [String: Double] {
        guard output.width == fixture.input.width, output.height == fixture.input.height else { throw DarktableSharpenReference.Failure.invalid }
        let w = output.width, h = output.height, y = luminance(output), truth = luminance(fixture.truth)
        var alphaError = 0.0, hidden = 0.0, error = 0.0, sum = 0.0, squares = 0.0, count = 0.0
        for p in stride(from: 0, to: output.pixels.count, by: 4) {
            alphaError = max(alphaError, abs(Double(output.pixels[p + 3] - fixture.input.pixels[p + 3])))
            if output.pixels[p + 3] == 0 {
                for c in 0..<3 { hidden = max(hidden, abs(Double(output.pixels[p + c]))) }
            }
        }
        for row in 8..<(h - 8) { for x in 8..<(w - 8) {
            let i = row * w + x, p = i * 4
            guard fixture.input.pixels[p + 3] > 0 else { continue }
            error += pow(y[i] - truth[i], 2); sum += y[i]; squares += y[i] * y[i]; count += 1
        } }
        guard count > 0 else { throw DarktableSharpenReference.Failure.invalid }
        var result = ["truth_rmse": sqrt(error / count), "detail_contrast": sqrt(max(0, squares / count - pow(sum / count, 2))),
                      "noise_std": sqrt(max(0, squares / count - pow(sum / count, 2))),
                      "alpha_error": alphaError, "hidden_rgb": hidden, "visible_samples": count]
        if fixture.isEdge {
            var slope = 0.0, overshoot = 0.0, undershoot = 0.0, width = 0.0, rows = 0.0
            for row in 8..<(h - 8) {
                let center = Int(DarktableSharpenFixtures.edgeX(y: row, width: w, height: h, acceptance: fixture.acceptance))
                var localSlope = 0.0, high = 0.62, low = 0.12, haloPixels = 0.0
                for x in max(1, center - 24)...min(w - 2, center + 24) {
                    let v = y[row * w + x]
                    high = max(high, v); low = min(low, v)
                    if abs(x - center) <= 6 { localSlope = max(localSlope, (y[row * w + x + 1] - y[row * w + x - 1]) * 0.5 / 0.5) }
                    if v > 0.62 + 0.0005 * 0.5 || v < 0.12 - 0.0005 * 0.5 { haloPixels += 1 }
                }
                slope += localSlope; overshoot += (high - 0.62) / 0.5; undershoot += (0.12 - low) / 0.5
                width += haloPixels; rows += 1
            }
            result["edge_slope"] = slope / rows; result["overshoot"] = overshoot / rows
            result["undershoot"] = undershoot / rows; result["halo_total"] = (overshoot + undershoot) / rows
            result["halo_width_pixels"] = width / rows; result["edge_rows"] = rows
        }
        return result
    }
}
