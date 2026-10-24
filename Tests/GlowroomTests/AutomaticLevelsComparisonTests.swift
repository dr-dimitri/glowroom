import CoreGraphics
import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Automatic Levels reproducible comparisons", .serialized, .timeLimit(.minutes(3)))
struct AutomaticLevelsComparisonTests {
    @Test(arguments: [ToneProcessingVersion.legacyV1, .consistentV2])
    func allPreregisteredSyntheticMotifsPassIndependentQualityGates(version: ToneProcessingVersion) throws {
        let manifest = try AutomaticLevelsComparisonManifest.load()
        for scene in manifest.scenes {
            try autoreleasepool {
                let fixture = try AutomaticLevelsComparisonFixture.make(scene, manifest: manifest)
                let run = try AutomaticLevelsComparisonRun(bitmap: fixture.bitmap, settings: .init(toneProcessingVersion: version))
                verify(run, scene: scene, gates: manifest.gates)
                if scene.id == "saturated-p3" {
                    #expect(run.analysis.estimate != .noProposal(.hdrSource))
                    #expect(run.analysis.estimate != .noProposal(.unsupportedDomain))
                    let pre = try run.preLevelsRaster()
                    let visible = stride(from: 0, to: pre.pixels.count, by: 4).filter { pre.pixels[$0 + 3] > 0 }
                    #expect(visible.contains { pre.pixels[$0] < 0 || pre.pixels[$0 + 1] < 0 || pre.pixels[$0 + 2] < 0 })
                    #expect(visible.contains { max(pre.pixels[$0], pre.pixels[$0 + 1], pre.pixels[$0 + 2]) > 1 })
                }
                if ["flat", "transparent"].contains(scene.id) {
                    #expect(run.referenceLevels == nil && run.referenceUnavailable != nil,
                            "Degenerate raw endpoints must never be normalized into a claimed reference")
                }
            }
        }
    }

    @Test func independentPairedMetricsCannotHideNewClippingBehindRecoveredPixels() throws {
        let baseline = FloatAnalysisRaster(width: 4, height: 1,
            pixels: [0, 0.2, 0.2, 1, 0.2, 0.2, 0.2, 1, 1, 1, 1, 0.25, 0.2, 0.2, 0.2, 0.25])
        let candidate = FloatAnalysisRaster(width: 4, height: 1,
            pixels: [0.2, 0.2, 0.2, 1, -0.1, 0, 0, 1, 0.2, 0.2, 0.2, 0.25, 0.25, 0.25, 0.25, 0.25])
        let metrics = try AutomaticLevelsComparisonMetrics.measure(baseline: baseline, candidate: candidate)
        #expect(metrics.visibleEquivalent == 2.5)
        #expect(metrics.baseline.anyLower == metrics.candidate.anyLower)
        #expect(metrics.newlyClipped.anyLower == 1 && metrics.newlyClipped.allBlack == 1)
        #expect(metrics.baseline.allWhite == metrics.candidate.allWhite)
        #expect(metrics.newlyClipped.anyUpper == 0.25 && metrics.newlyClipped.allWhite == 0.25)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_LEVELS_REPORT"] == "1"))
    func optionalSyntheticPNGAndHTMLReport() throws {
        let manifest = try AutomaticLevelsComparisonManifest.load()
        let output = try AutomaticLevelsComparisonFiles.freshDirectory(prefix: "glowroom-levels-comparison")
        try Data(contentsOf: AutomaticLevelsComparisonManifest.url).write(to: output.appendingPathComponent("manifest.json"))
        var records: [[String: Any]] = [], sections: [String] = []
        for version in [ToneProcessingVersion.legacyV1, .consistentV2] {
            for scene in manifest.scenes {
                try autoreleasepool {
                    let fixture = try AutomaticLevelsComparisonFixture.make(scene, manifest: manifest)
                    let run = try AutomaticLevelsComparisonRun(bitmap: fixture.bitmap, settings: .init(toneProcessingVersion: version))
                    verify(run, scene: scene, gates: manifest.gates)
                    let id = "\(scene.id)-\(version.rawValue)"
                    let record = try run.write(id: id, title: scene.title, inputHash: fixture.inputSHA256,
                                               directory: output, gates: manifest.gates)
                    records.append(record.json); sections.append(record.html)
                }
            }
        }
        try finishReport(directory: output, records: records, sections: sections, privatePhotos: false,
            coverage: ["synthetic_motifs": manifest.scenes.map(\.id),
                       "photographic_quality_claim": false, "private_inputs": "none"])
        print("Automatic Levels synthetic report: \(output.path)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_LEVELS_LOCAL_IMAGES"]?.isEmpty == false))
    func optionalPrivateJPEGReportIsSeparateAndLeavesEveryOriginalUnchanged() async throws {
        guard let path = ProcessInfo.processInfo.environment["GLOWROOM_LEVELS_LOCAL_IMAGES"], !path.isEmpty else { return }
        let inputDirectory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let output = try AutomaticLevelsComparisonFiles.freshDirectory(prefix: "glowroom-levels-private-comparison")
        let manifest = try AutomaticLevelsComparisonManifest.load()
        try Data(contentsOf: AutomaticLevelsComparisonManifest.url).write(to: output.appendingPathComponent("manifest.json"))
        let coverage = try localCoverage()
        var records: [[String: Any]] = [], sections: [String] = [], missing: [String] = [], failed: [String] = []
        let decoder = ImagePreviewPipeline(concurrencyLimit: 1, diskCache: nil)
        for index in 1...7 {
            let name = "test_picture\(index).jpg"
            let url = inputDirectory.appendingPathComponent(name)
            guard FileManager.default.isReadableFile(atPath: url.path) else { missing.append(name); continue }
            do {
                let before = try AutomaticLevelsComparisonFiles.sourceHash(url)
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let request = PreviewRequest(url: url, modifiedAt: values.contentModificationDate ?? .distantPast,
                    pixelSize: 256, fileSize: Int64(values.fileSize ?? 0), allowsEmbeddedPreview: false)
                // One bounded decode, then reuse these pixels for all three paths.
                // JPEGs are never presented as RAW performance measurements.
                let bitmap = try await decoder.image(for: request, priority: .selected)
                let run = try AutomaticLevelsComparisonRun(bitmap: bitmap, settings: .newEditingSettings)
                verifySafety(run, gates: manifest.gates)
                let record = try run.write(id: "photo-\(index)", title: name, inputHash: before,
                                           directory: output, gates: manifest.gates)
                var json = record.json
                json["manual_motif_annotations"] = coverage[name] ?? []
                let after = try AutomaticLevelsComparisonFiles.sourceHash(url)
                json["source_unchanged"] = after == before
                records.append(json); sections.append(record.html)
                #expect(after == before, "A comparison must never write a source photograph")
            } catch is CancellationError { throw CancellationError() }
            catch {
                failed.append(name)
                records.append(["id": "photo-\(index)", "title": name, "status": "error", "error": String(describing: error)])
                sections.append("<section><h2>\(name)</h2><p>Fehler: \(AutomaticLevelsComparisonFiles.escaped(String(describing: error)))</p></section>")
            }
        }
        let required = ["lowContrast", "backlit", "lowKey", "highKey", "saturated"]
        let covered = Set(coverage.filter { !missing.contains($0.key) && !failed.contains($0.key) }.flatMap { $0.value })
        try finishReport(directory: output, records: records, sections: sections, privatePhotos: true,
            coverage: ["missing_files": missing, "failed_files": failed, "manual_annotations": coverage,
                       "annotation_scope": "Human visual genre annotation only; no numeric ground truth",
                       "missing_photographic_motifs": required.filter { !covered.contains($0) },
                       "raw_performance_measured": false])
        print("Automatic Levels PRIVATE local report (do not upload): \(output.path)")
        #expect(missing.isEmpty, "Explicit local report requested seven JPEGs; missing files are listed in report.json")
        #expect(failed.isEmpty, "Local decoding/analysis errors are listed explicitly in report.json")
    }

    private func verify(_ run: AutomaticLevelsComparisonRun, scene: AutomaticLevelsComparisonManifest.Scene,
                        gates: AutomaticLevelsComparisonManifest.Gates) {
        verifySafety(run, gates: gates)
        switch scene.gate {
        case .spread:
            guard case .value = run.analysis.estimate else { Issue.record("\(scene.id): a useful gray spread is mandatory"); return }
            #expect((run.productionMetrics.robustSpan ?? 0) >= (run.baselineMetrics.robustSpan ?? 0) + gates.minimumGraySpanImprovement,
                    "\(scene.id): the preregistered range-improvement gate must not be lowered")
            #expect(run.productionMetrics.monotoneGrayRamp)
            #expect(run.productionMetrics.maximumGrayChannelSpread <= gates.maximumGrayChannelSpread)
        case .lowKey:
            #expect(run.analysis.estimate == .noProposal(.lowKey))
            #expect((run.productionMetrics.median ?? 1) <= gates.maximumLowKeyMedian)
        case .highKey:
            #expect(run.analysis.estimate == .noProposal(.highKey))
            #expect((run.productionMetrics.median ?? 0) >= gates.minimumHighKeyMedian)
        case .unchanged:
            guard case .noProposal = run.analysis.estimate else { Issue.record("\(scene.id): a flat/invisible source must remain unchanged"); return }
            #expect(run.production.pixels == run.baseline.pixels)
        case .safe: break
        }
    }

    private func verifySafety(_ run: AutomaticLevelsComparisonRun, gates: AutomaticLevelsComparisonManifest.Gates) {
        let metrics = run.productionMetrics
        let limit = gates.newClippingFraction * metrics.visibleEquivalent + gates.newClippingAllowance
        #expect(metrics.newlyClipped.values.allSatisfy { $0 <= limit })
        #expect(metrics.maximumAlphaError <= gates.maximumAlphaError)
        #expect(abs(run.analysis.diagnostics.visibleEquivalent - metrics.visibleEquivalent) <= 0.000_001,
                "The independent comparison and analysis must use the same alpha-weighted sample support")
        if case .value(let levels) = run.analysis.estimate {
            #expect((try? levels.validate()) != nil)
            #expect(levels.red.isNeutral && levels.green.isNeutral && levels.blue.isNeutral)
            #expect(levels.master.gamma == 1 && levels.master.outputBlack == 0 && levels.master.outputWhite == 1)
            #expect(!levels.master.clampInput && !levels.master.clampOutput)
            #expect(run.analysis.diagnostics.attempts.contains { attempt in
                attempt.candidate.levels == levels && attempt.candidate.strength == run.analysis.diagnostics.acceptedStrength && attempt.gateFailures.isEmpty
            }, "The measured candidate must be exactly the saved Levels replacement")
        }
    }

    private func localCoverage() throws -> [String: [String]] {
        guard let path = ProcessInfo.processInfo.environment["GLOWROOM_LEVELS_LOCAL_COVERAGE"], !path.isEmpty else { return [:] }
        let values = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let names = Set((1...7).map { "test_picture\($0).jpg" })
        let allowed = Set(["lowContrast", "backlit", "lowKey", "highKey", "saturated"])
        guard values.keys.allSatisfy(names.contains), values.values.flatMap({ $0 }).allSatisfy(allowed.contains) else {
            throw AutomaticLevelsComparisonError.invalidManifest
        }
        return values
    }

    private func finishReport(directory: URL, records: [[String: Any]], sections: [String], privatePhotos: Bool,
                              coverage: [String: Any]) throws {
        let repository = AutomaticLevelsComparisonManifest.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = ["Sources/GlowroomCore/AutomaticLevelsPolicy.swift", "Sources/GlowroomCore/AutomaticLevelsHistogram.swift",
            "Sources/GlowroomCore/AutomaticLevelsReference.swift", "Sources/GlowroomCore/AutomaticLevelsProposal.swift",
            "Sources/Glowroom/Imaging/AutomaticLevelsEstimator.swift", "Sources/Glowroom/Imaging/PairedLevelsClipping.swift",
            "Sources/Glowroom/Imaging/FloatAnalysis.swift", "Sources/Glowroom/Imaging/EditRenderer.swift",
            "Tests/GlowroomTests/AutomaticLevelsComparisonFixtures.swift", "Tests/GlowroomTests/AutomaticLevelsComparisonTests.swift"]
        let sourceHashes = try Dictionary(uniqueKeysWithValues: sources.map {
            ($0, try AutomaticLevelsComparisonFiles.sourceHash(repository.appendingPathComponent($0)))
        })
        let metadata: [String: Any] = [
            "schema_version": 1, "manifest_sha256": AutomaticLevelsComparisonFiles.sha256(try Data(contentsOf: AutomaticLevelsComparisonManifest.url)),
            "scope": "Algorithmic 0.6%-tail reference, not GIMP/GEGL pixel parity; no performance or general photographic superiority claim",
            "private": privatePhotos, "coverage": coverage, "records": records,
            "implementation_sha256": sourceHashes, "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
            "policy": ["algorithm_version": AutomaticLevelsPolicy.algorithmVersion,
                       "reference_commit": AutomaticLevelsPolicy.referenceCommit,
                       "histogram_bins": AutomaticLevelsPolicy.binCount, "tail_fraction": AutomaticLevelsPolicy.tailFraction,
                       "minimum_visible_equivalent": AutomaticLevelsPolicy.minimumVisibleEquivalent,
                       "minimum_robust_span": AutomaticLevelsPolicy.minimumRobustSpan,
                       "minimum_iqr": AutomaticLevelsPolicy.minimumInterquartileRange,
                       "key_range": [AutomaticLevelsPolicy.keyRange.lowerBound, AutomaticLevelsPolicy.keyRange.upperBound],
                       "gain_range": [AutomaticLevelsPolicy.gainRange.lowerBound, AutomaticLevelsPolicy.gainRange.upperBound],
                       "maximum_key_shift": AutomaticLevelsPolicy.maximumKeyShift, "strengths": AutomaticLevelsPolicy.strengths]
        ]
        try AutomaticLevelsComparisonFiles.writeJSON(metadata, to: directory.appendingPathComponent("report.json"))
        let warning = privatePhotos ? "PRIVATER LOKALER BERICHT · Nicht hochladen oder committen." : "Ausschließlich synthetische Motive; keine Behauptung fotografischer Überlegenheit."
        let coverageJSON = try JSONSerialization.data(withJSONObject: coverage, options: [.sortedKeys, .prettyPrinted])
        let html = """
        <!doctype html><html lang="de"><meta charset="utf-8"><title>Automatische Levels – Vergleich</title>
        <style>body{font:15px system-ui;margin:2rem;max-width:1250px;background:#191b1f;color:#eee}section{margin:2rem 0;padding:1rem;background:#24272d}figure{margin:0}img{width:100%;image-rendering:auto;background:repeating-conic-gradient(#777 0 25%,#aaa 0 50%) 0/16px 16px}.images{display:grid;grid-template-columns:repeat(3,1fr);gap:1rem}pre{white-space:pre-wrap;overflow-wrap:anywhere}small{color:#ccd}</style>
        <h1>Automatische Levels: Baseline · 0,6-%-Referenz · Produktion</h1><p>\(warning)</p>
        <p><a href="report.json">Vollständiger JSON-Bericht mit Quellprüfung und Implementierungs-Hashes</a></p>
        <p>PNG-Bilder sind farbgemanagte, auf SDR begrenzte sRGB-Ansichten. Alle numerischen Gates messen Float-RGB im tatsächlichen Ausgabezielprofil vor Begrenzung und Quantisierung. Die Referenz implementiert das 0,6-%-Prinzip mit 4096 signed-sRGB-Bins unabhängig; sie ist kein GIMP-/GEGL-Render. Gleiche Tail-Abstände gehen weiter nach innen.</p>
        <details><summary>Motivabdeckung</summary><pre>\(AutomaticLevelsComparisonFiles.escaped(String(decoding: coverageJSON, as: UTF8.self)))</pre></details>
        \(sections.joined(separator: "\n"))</html>
        """
        try Data(html.utf8).write(to: directory.appendingPathComponent("index.html"), options: .atomic)
    }
}

private struct AutomaticLevelsComparisonRun {
    let bitmap: PreviewBitmap
    let settings: EditSettings
    let session: EditRenderer.Session
    let target: CGColorSpace
    let analysis: AutomaticLevelsAnalysis
    let baseline: FloatAnalysisRaster
    let production: FloatAnalysisRaster
    let reference: FloatAnalysisRaster?
    let referenceEndpoints: AutomaticLevelsRGBEndpoints
    let referenceLevels: LevelsSettings?
    let referenceUnavailable: String?
    let baselineMetrics: AutomaticLevelsComparisonMetrics
    let productionMetrics: AutomaticLevelsComparisonMetrics

    init(bitmap: PreviewBitmap, settings original: EditSettings) throws {
        self.bitmap = bitmap
        var global = original
        global.levels = LevelsSettings(transferFunction: original.levels.transferFunction, version: original.levels.version)
        global.localAdjustments = []; global.developGeometry = .neutral
        settings = global
        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: true)
        self.session = session
        guard let target = FloatAnalysis.extendedTargetSpace(try EditRenderer.developedOutputColorSpace(for: bitmap.image, hdrEnabled: false)) else {
            throw AutomaticLevelsComparisonError.unavailableProfile
        }
        self.target = target
        let context = session.context(for: .consistentV2)
        var cache = AutomaticLevelsEstimator.Cache()
        analysis = try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: original, session: session, cache: &cache)
        let graph = try EditRenderer.globalGraph(bitmap, settings: global, session: session)
        baseline = try FloatAnalysis.raster(graph, context: context, colorSpace: target)
        baselineMetrics = try AutomaticLevelsComparisonMetrics.measure(baseline: baseline, candidate: baseline)
        let preGraph = try EditRenderer.globalLevelsInputGraph(bitmap, settings: global, session: session)
        let pre = try FloatAnalysis.raster(preGraph, context: context, colorSpace: FloatAnalysis.workingSpace)
        var histogram = AutomaticLevelsHistogramBuilder()
        for i in stride(from: 0, to: pre.pixels.count, by: 4) {
            let alpha = Double(pre.pixels[i + 3])
            histogram.add(encodedRed: alpha > 0 ? SignedSRGB.encode(Double(pre.pixels[i]) / alpha) : 0,
                          green: alpha > 0 ? SignedSRGB.encode(Double(pre.pixels[i + 1]) / alpha) : 0,
                          blue: alpha > 0 ? SignedSRGB.encode(Double(pre.pixels[i + 2]) / alpha) : 0, alpha: alpha)
        }
        referenceEndpoints = AutomaticLevelsReference.estimate(histogram: histogram.finish())
        var proposed = global
        if case .value(let levels) = analysis.estimate { proposed.levels = levels }
        production = proposed.levels.isNeutral ? baseline : try FloatAnalysis.raster(
            EditRenderer.globalGraph(bitmap, settings: proposed, session: session), context: context, colorSpace: target)
        productionMetrics = try AutomaticLevelsComparisonMetrics.measure(baseline: baseline, candidate: production)
        // Never normalize degenerate endpoints: doing so would invent a GIMP
        // result that the independently calculated raw reference never proposed.
        let raw = LevelsSettings(red: .init(inputBlack: referenceEndpoints.red.black, inputWhite: referenceEndpoints.red.white),
            green: .init(inputBlack: referenceEndpoints.green.black, inputWhite: referenceEndpoints.green.white),
            blue: .init(inputBlack: referenceEndpoints.blue.black, inputWhite: referenceEndpoints.blue.white),
            transferFunction: original.levels.transferFunction, version: original.levels.version)
        do {
            try raw.validate()
            var refSettings = global; refSettings.levels = raw
            reference = try FloatAnalysis.raster(EditRenderer.globalGraph(bitmap, settings: refSettings, session: session),
                                                context: context, colorSpace: target)
            referenceLevels = raw; referenceUnavailable = nil
        } catch {
            reference = nil; referenceLevels = nil
            referenceUnavailable = "Raw reference is degenerate or unrepresentable: \(error)"
        }
    }

    func preLevelsRaster() throws -> FloatAnalysisRaster {
        try FloatAnalysis.raster(EditRenderer.globalLevelsInputGraph(bitmap, settings: settings, session: session),
                                 context: session.context(for: .consistentV2), colorSpace: FloatAnalysis.workingSpace)
    }

    func write(id: String, title: String, inputHash: String, directory: URL,
               gates: AutomaticLevelsComparisonManifest.Gates) throws -> (json: [String: Any], html: String) {
        let destination = directory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let context = session.context(for: .consistentV2)
        func png(_ raster: FloatAnalysisRaster, name: String) throws {
            let data = raster.pixels.withUnsafeBytes { Data($0) }
            let graph = CIImage(bitmapData: data, bytesPerRow: raster.width * 16,
                size: CGSize(width: raster.width, height: raster.height), format: .RGBAf, colorSpace: target)
            guard let image = context.createCGImage(graph, from: graph.extent, format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, deferred: false) else {
                throw AutomaticLevelsComparisonError.invalidRaster
            }
            try AutomaticLevelsComparisonFiles.writePNG(image, to: destination.appendingPathComponent(name + ".png"))
        }
        try png(baseline, name: "baseline"); try png(production, name: "production")
        if let reference { try png(reference, name: "gimp-principle-reference") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: encoder.encode(value)) }
        let diagnostic = analysis.diagnostics
        let proof = diagnostic.sourceProof
        let attempts: [[String: Any]] = try diagnostic.attempts.map { attempt in
            var result: [String: Any] = ["candidate": try object(attempt.candidate), "failed_native_gates": attempt.gateFailures.map(\.rawValue)]
            if let pair = attempt.clipping {
                result["paired_clipping"] = ["visible_equivalent": pair.visibleEquivalent, "limit_mass": pair.limit,
                    "new_any_lower": pair.newlyClipped.anyLower, "new_any_upper": pair.newlyClipped.anyUpper,
                    "new_all_black": pair.newlyClipped.allBlack, "new_all_white": pair.newlyClipped.allWhite]
            }
            return result
        }
        let accepted: Any
        let status: String
        switch analysis.estimate {
        case .value(let levels): accepted = try object(levels); status = "value"
        case .noProposal(let reason): accepted = NSNull(); status = "noProposal: \(reason)"
        }
        var json: [String: Any] = ["id": id, "title": title, "input_sha256": inputHash,
            "settings_sha256": AutomaticLevelsComparisonFiles.sha256(try encoder.encode(settings)),
            "processing_version": settings.toneProcessingVersion.rawValue,
            "input_dimensions": [diagnostic.inputWidth, diagnostic.inputHeight],
            "target_linear_profile": (target.name as String?) ?? "unknown", "status": status,
            "reference_status": referenceUnavailable ?? "available: independent GIMP 0.6%-principle RGB spread",
            "accepted_levels": accepted, "accepted_strength": diagnostic.acceptedStrength.map { $0 as Any } ?? NSNull(),
            "attempts": attempts,
            "baseline_metrics": baselineMetrics.json, "production_metrics": productionMetrics.json,
            "independent_limit_mass": gates.newClippingFraction * productionMetrics.visibleEquivalent + gates.newClippingAllowance]
        json["reference_raw_endpoints"] = try object(referenceEndpoints)
        json["reference_levels"] = try referenceLevels.map { try object($0) } ?? NSNull()
        json["common_initial_endpoints"] = try diagnostic.common.map { try object($0) } ?? NSNull()
        json["statistics"] = try diagnostic.statistics.map { try object($0) } ?? NSNull()
        let sourceProof: [String: Any] = ["raster_identity": proof.sourceIdentity.uuidString,
            "width": proof.width, "height": proof.height, "range": String(describing: proof.rangeProvenance),
            "nominal_sdr_white": proof.nominalSDRWhite.map { $0 as Any } ?? NSNull(),
            "maximum_luminance": proof.maximumLuminance.map { $0 as Any } ?? NSNull()]
        json["source_proof"] = sourceProof
        if let domain = diagnostic.domain {
            json["domain"] = ["version": domain.toneProcessingVersion.rawValue, "levels_version": domain.levelsVersion.rawValue,
                "transfer_function": domain.transferFunction.rawValue, "source_profile": domain.sourceProfile,
                "target_profile": domain.targetProfile, "working_space": domain.workingSpace, "histogram_transfer": domain.histogramTransfer]
        }
        if let reference { json["reference_metrics"] = try AutomaticLevelsComparisonMetrics.measure(baseline: baseline, candidate: reference).json }
        try AutomaticLevelsComparisonFiles.writeJSON(json, to: destination.appendingPathComponent("metrics.json"))
        let e = AutomaticLevelsComparisonFiles.escaped
        let refImage = reference == nil ? "<p>Referenz nicht verfügbar: \(e(referenceUnavailable ?? "unknown"))</p>"
            : "<img src=\"\(id)/gimp-principle-reference.png\" alt=\"0,6-Prozent-Prinzipreferenz\">"
        let encoded = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted])
        let html = "<section><h2>\(e(title)) · \(e(String(describing: settings.toneProcessingVersion)))</h2><p>\(e(status))</p><div class=\"images\"><figure><figcaption>Baseline: Levels neutral</figcaption><img src=\"\(id)/baseline.png\" alt=\"Baseline\"></figure><figure><figcaption>GIMP-Prinzipreferenz</figcaption>\(refImage)</figure><figure><figcaption>Konservative Produktion</figcaption><img src=\"\(id)/production.png\" alt=\"Produktion\"></figure></div><details><summary>Endpunkte, Clipping, Farbe und Provenienz</summary><pre>\(e(String(decoding: encoded, as: UTF8.self)))</pre></details></section>"
        return (json, html)
    }
}
