import Foundation

public enum AutomaticLevelsProposalReason: String, Codable, Equatable, Sendable {
    case insufficientSamples, insufficientRange, lowKey, highKey, noUsefulImprovement
}

public enum AutomaticLevelsProposal: Equatable, Sendable {
    case stencil(AutomaticLevelsProposalStencil)
    case noProposal(AutomaticLevelsProposalReason)
}

public struct AutomaticLevelsCandidateChecks: Codable, Equatable, Sendable {
    public let validEndpoints: Bool
    public let usefulGain: Bool
    public let boundedGain: Bool
    public let boundedKeyShift: Bool
    public var isEligible: Bool { validEndpoints && usefulGain && boundedGain && boundedKeyShift }
}

public struct AutomaticLevelsCandidate: Codable, Equatable, Sendable {
    public let strength: Double
    public let endpoints: AutomaticLevelsEndpoints
    public let gain: Double
    public let keyShift: Double
    public let checks: AutomaticLevelsCandidateChecks
    /// Present only when every fixed Core quality gate passes. The native
    /// paired clipping and full-image range proofs must still accept it.
    public let levels: LevelsSettings?
}

/// A small immutable recipe, without histograms, sample pixels or image owners.
/// Every stored/evaluated candidate comes from these same endpoint formulas.
public struct AutomaticLevelsProposalStencil: Equatable, Sendable {
    public let reference: AutomaticLevelsRGBEndpoints
    public let common: AutomaticLevelsEndpoints
    public let visibleEquivalent: Double
    public let keyProxy: Double
    public let statistics: AutomaticLevelsRGBStatistics

    public static func make(histogram: AutomaticLevelsHistogram) -> AutomaticLevelsProposal {
        guard histogram.visibleEquivalent >= AutomaticLevelsPolicy.minimumVisibleEquivalent else {
            return .noProposal(.insufficientSamples)
        }
        let statistics = histogram.statistics
        guard statistics.maximumRobustSpan >= AutomaticLevelsPolicy.minimumRobustSpan,
              statistics.maximumInterquartileRange >= AutomaticLevelsPolicy.minimumInterquartileRange else {
            return .noProposal(.insufficientRange)
        }
        let key = statistics.keyProxy
        guard key >= AutomaticLevelsPolicy.keyRange.lowerBound else { return .noProposal(.lowKey) }
        guard key <= AutomaticLevelsPolicy.keyRange.upperBound else { return .noProposal(.highKey) }
        let reference = AutomaticLevelsReference.estimate(histogram: histogram)
        let common = AutomaticLevelsEndpoints(black: min(reference.red.black, min(reference.green.black, reference.blue.black)),
            white: max(reference.red.white, max(reference.green.white, reference.blue.white)))
        let stencil = Self(reference: reference, common: common, visibleEquivalent: histogram.visibleEquivalent,
                           keyProxy: key, statistics: statistics)
        guard AutomaticLevelsPolicy.strengths.contains(where: {
            (try? stencil.evaluate(at: $0, preserving: .neutral).checks.isEligible) == true
        }) else { return .noProposal(.noUsefulImprovement) }
        return .stencil(stencil)
    }

    public func evaluate(at strength: Double, preserving metadata: LevelsSettings) throws -> AutomaticLevelsCandidate {
        guard strength.isFinite, strength > 0, strength <= 1 else { throw LevelsValidationError.invalidCurve }
        let black = strength * common.black
        let white = 1 - strength * (1 - common.white)
        let span = white - black
        let gain = 1 / span
        let keyShift = abs((keyProxy - black) / span - keyProxy)
        let endpoints = AutomaticLevelsEndpoints(black: black, white: white)
        // Full replacement of Levels: individual channels, gamma, output
        // bounds and all clamps reset. Only domain/version metadata survives.
        let replacement = LevelsSettings(master: LevelsCurve(inputBlack: black, inputWhite: white),
            transferFunction: metadata.transferFunction, version: metadata.version)
        let valid = black.isFinite && white.isFinite && gain.isFinite && keyShift.isFinite &&
            (try? replacement.validate()) != nil
        let checks = AutomaticLevelsCandidateChecks(validEndpoints: valid,
            usefulGain: gain.isFinite && gain >= AutomaticLevelsPolicy.gainRange.lowerBound,
            boundedGain: gain.isFinite && gain <= AutomaticLevelsPolicy.gainRange.upperBound,
            boundedKeyShift: keyShift.isFinite && keyShift <= AutomaticLevelsPolicy.maximumKeyShift)
        return AutomaticLevelsCandidate(strength: strength, endpoints: endpoints, gain: gain, keyShift: keyShift,
            checks: checks, levels: checks.isEligible ? replacement : nil)
    }

    /// Nil means this strength fails the published parameter/gain/key policy.
    /// Native consumers use evaluate to retain the exact per-attempt gate flags.
    public func candidate(at strength: Double, preserving metadata: LevelsSettings) throws -> LevelsSettings? {
        try evaluate(at: strength, preserving: metadata).levels
    }
}
