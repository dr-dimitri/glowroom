import Foundation
import GlowroomCore

/// Compare matching target-profile, straight RGB samples BEFORE SDR clamp and
/// quantization. Aggregate differences are insufficient: clipping removed at
/// one pixel must never conceal a newly clipped pixel somewhere else.
enum PairedLevelsClipping {
    enum ValidationError: Error, Equatable {
        case incompatibleRaster
        case invalidAlpha
        case nonfiniteSample
    }

    struct Mass: Equatable, Sendable {
        var anyLower = 0.0
        var anyUpper = 0.0
        var allBlack = 0.0
        var allWhite = 0.0
    }

    struct Result: Equatable, Sendable {
        let visibleEquivalent: Double
        let baseline: Mass
        let candidate: Mass
        let newlyClipped: Mass
        let limit: Double

        var isWithinBudget: Bool {
            visibleEquivalent > 0 && newlyClipped.anyLower <= limit && newlyClipped.anyUpper <= limit &&
                newlyClipped.allBlack <= limit && newlyClipped.allWhite <= limit
        }
    }

    /// Both rasters must come from the same input extent, sample positions and
    /// target profile. The native estimator establishes that identity before
    /// readback; dimensions and each unmodified Float alpha are checked here.
    /// <=65,536 paired pixels stay serial on the existing admitted analysis
    /// lane: another pool would add scheduling and synchronization per candidate.
    static func measure(baseline: FloatAnalysisRaster, candidate: FloatAnalysisRaster) throws -> Result {
        guard baseline.width > 0, baseline.height > 0,
              baseline.width <= FloatAnalysis.maximumPixelSize, baseline.height <= FloatAnalysis.maximumPixelSize,
              baseline.width == candidate.width, baseline.height == candidate.height,
              baseline.pixels.count == baseline.width * baseline.height * 4,
              candidate.pixels.count == baseline.pixels.count else { throw ValidationError.incompatibleRaster }
        var baselineMass = Mass(), candidateMass = Mass(), newMass = Mass()
        var total = 0.0
        for row in 0..<baseline.height {
            try Task.checkCancellation()
            for column in 0..<baseline.width {
                let offset = (row * baseline.width + column) * 4
                let alpha = baseline.pixels[offset + 3]
                let otherAlpha = candidate.pixels[offset + 3]
                guard alpha.isFinite, otherAlpha.isFinite, alpha >= 0, alpha <= 1,
                      alpha == otherAlpha else { throw ValidationError.invalidAlpha }
                guard alpha > 0 else { continue }
                let weight = Double(alpha)
                let br = Double(baseline.pixels[offset]) / weight
                let bg = Double(baseline.pixels[offset + 1]) / weight
                let bb = Double(baseline.pixels[offset + 2]) / weight
                let cr = Double(candidate.pixels[offset]) / weight
                let cg = Double(candidate.pixels[offset + 1]) / weight
                let cb = Double(candidate.pixels[offset + 2]) / weight
                guard br.isFinite, bg.isFinite, bb.isFinite, cr.isFinite, cg.isFinite, cb.isFinite else {
                    throw ValidationError.nonfiniteSample
                }
                let bMin = min(br, min(bg, bb)), bMax = max(br, max(bg, bb))
                let cMin = min(cr, min(cg, cb)), cMax = max(cr, max(cg, cb))
                // Exact target-profile 0/1 boundaries. A nominal source-white
                // unit is used only by the HDR proof, never by these SDR flags.
                let bLower = bMin <= 0, cLower = cMin <= 0
                let bUpper = bMax >= 1, cUpper = cMax >= 1
                let bBlack = bMax <= 0, cBlack = cMax <= 0
                let bWhite = bMin >= 1, cWhite = cMin >= 1
                total += weight
                if bLower { baselineMass.anyLower += weight }
                if bUpper { baselineMass.anyUpper += weight }
                if bBlack { baselineMass.allBlack += weight }
                if bWhite { baselineMass.allWhite += weight }
                if cLower { candidateMass.anyLower += weight }
                if cUpper { candidateMass.anyUpper += weight }
                if cBlack { candidateMass.allBlack += weight }
                if cWhite { candidateMass.allWhite += weight }
                if !bLower && cLower { newMass.anyLower += weight }
                if !bUpper && cUpper { newMass.anyUpper += weight }
                if !bBlack && cBlack { newMass.allBlack += weight }
                if !bWhite && cWhite { newMass.allWhite += weight }
            }
        }
        return Result(visibleEquivalent: total, baseline: baselineMass, candidate: candidateMass,
            newlyClipped: newMass, limit: AutomaticLevelsPolicy.tailFraction * total + 1)
    }
}
