import Foundation

/// Independently implemented 0.6%-tail principle described by GIMP reference
/// commit 7d518c7971e80719ce30f70ec44b55e49ab2aeb7. This evaluates Glowroom's
/// 4096-bin signed-sRGB input; it does not promise GIMP application's pixels,
/// histogram resolution, transfer function, clamps or color-management output.
public enum AutomaticLevelsReference {
    public static func estimate(histogram: AutomaticLevelsHistogram) -> AutomaticLevelsRGBEndpoints {
        AutomaticLevelsRGBEndpoints(
            red: endpoints(histogram.redBins, mass: histogram.visibleEquivalent),
            green: endpoints(histogram.greenBins, mass: histogram.visibleEquivalent),
            blue: endpoints(histogram.blueBins, mass: histogram.visibleEquivalent))
    }

    private static func endpoints(_ bins: [Double], mass: Double) -> AutomaticLevelsEndpoints {
        guard mass > 0 else { return AutomaticLevelsEndpoints(black: 0, white: 0) }
        let target = AutomaticLevelsPolicy.tailFraction * mass
        let last = AutomaticLevelsPolicy.binCount - 1
        // Compare adjacent cumulative tail masses, not interpolated quantiles.
        // Strict improvement chooses the boundary; equal distances keep moving
        // inward, including across empty plateaus. Mass units avoid dividing
        // both sides by N and preserve analytic rational ties such as N=125.
        func boundary(fromHigh: Bool) -> Double {
            var cumulative = 0.0
            for distance in 0..<last {
                let index = fromHigh ? last - distance : distance
                let neighbor = fromHigh ? index - 1 : index + 1
                cumulative += bins[index]
                let next = cumulative + bins[neighbor]
                if abs(cumulative - target) < abs(next - target) {
                    return Double(neighbor) / Double(last)
                }
            }
            return fromHigh ? 1 : 0
        }
        return AutomaticLevelsEndpoints(black: boundary(fromHigh: false), white: boundary(fromHigh: true))
    }
}
