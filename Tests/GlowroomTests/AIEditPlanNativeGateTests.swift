import CoreGraphics
import Darwin
import Foundation
import GlowroomCore
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Glowroom

/// Freeze before inference: synthetic, public-domain scenes, 12 positives,
/// 4 absent targets and 4 multi-target refusals. No personal photos or downloads.
private struct PlanGateCase: Codable, Sendable {
    let id: String
    let instruction: String
    let kind: AIEditPlanTargetKind
    let direction: Double
    let scene: Int
    let negative: Bool
    static let all: [Self] = {
        var cases: [Self] = []
        let names: [(AIEditPlanTargetKind, String)] = [(.sky, "Himmel"), (.subject, "Motiv"), (.background, "Hintergrund"), (.object, "roten Ball")]
        for (kind, name) in names {
            for scene in 0..<3 {
                let direction = scene == 1 ? 1.0 : -1.0
                cases.append(.init(id: "\(kind.rawValue)-\(scene)", instruction: "Den \(name) \(direction > 0 ? "heller" : "dunkler") machen, nur die Belichtung ändern.",
                    kind: kind, direction: direction, scene: scene, negative: false))
            }
        }
        for (index, name) in ["Himmel", "Hund", "grünen Baum", "gelben Bus"].enumerated() {
            cases.append(.init(id: "absent-\(index)", instruction: "Den \(name) dunkler machen.", kind: .unsupported, direction: -1, scene: 3, negative: true))
        }
        for (index, text) in ["Himmel dunkler und Motiv heller", "Ball und Himmel dunkler", "Hintergrund kühler und Ball heller", "Motiv dunkler und Himmel wärmer"].enumerated() {
            cases.append(.init(id: "multiple-\(index)", instruction: text, kind: .unsupported, direction: -1, scene: index % 3, negative: true))
        }
        return cases
    }()
}

@Suite("Frozen semantic mask edit plan quality gate", .serialized)
struct AIEditPlanNativeGateTests {
    @Test func frozenMatrixHasRequiredCoverage() {
        #expect(PlanGateCase.all.count == 20)
        #expect(PlanGateCase.all.filter { !$0.negative }.count == 12)
        #expect(PlanGateCase.all.filter { $0.id.hasPrefix("absent") }.count == 4)
        #expect(PlanGateCase.all.filter { $0.id.hasPrefix("multiple") }.count == 4)
        #expect(Set(PlanGateCase.all.map(\.id)).count == 20)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_EDIT_PLAN_GATE_OUTPUT"] != nil), .timeLimit(.minutes(60)))
    func installedModelsEvaluateFrozenMatrix() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["GLOWROOM_EDIT_PLAN_GATE_OUTPUT"])
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        try #require(root.path.hasPrefix("/private/tmp/") || root.path.hasPrefix("/tmp/"))
        try #require(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try JSONEncoder().encode(PlanGateCase.all).write(to: root.appendingPathComponent("frozen-cases.json"), options: .withoutOverwriting)
        var reports: [[String: Any]] = []
        var positives = 0, negatives = 0
        // Native inference and its measurements intentionally stay serial. This
        // uses the same single shared inference budget as the explicit workflow.
        for item in PlanGateCase.all {
            let image = try scene(item.scene)
            let url = root.appendingPathComponent(item.id + ".png")
            try png(image, at: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let snapshot = AIEditingSnapshot(assetID: item.id,
                source: .original(.init(fileURL: url, modifiedAt: try #require(attributes[.modificationDate] as? Date),
                    fileSize: try #require(attributes[.size] as? NSNumber).int64Value)),
                settings: .neutral, token: .init(editSessionID: UUID(), editGeneration: 0, selectionSessionID: UUID(), selectionGeneration: 0))
            var runs: [[String: Any]] = []
            let preparer = ImageAnalysisPreparer(imagePipeline: ImagePreviewPipeline(), renderPipeline: AdjustedPreviewPipeline())
            for pass in ["cold-app-cache", "warm-app-cache"] {
                let log = PlanGateTrace()
                let service = AIEditPlanService(preparer: preparer,
                    trace: { stage, ms, success in await log.record(stage: stage.rawValue, ms: ms, success: success) })
                let start = ContinuousClock.now
                var row: [String: Any] = ["pass": pass]
                do {
                    let response = try await service.propose(snapshot: snapshot, instruction: item.instruction)
                    let score = try selectionScore(response.plan.layer, kind: item.kind, scene: item.scene)
                    let correct = !item.negative && response.plan.target.kind == item.kind
                        && score >= 0.6 && response.plan.layer.settings.exposure * item.direction > 0
                    row["plan"] = true; row["target"] = response.plan.target.kind.rawValue
                    row["iou"] = score; row["exposure"] = response.plan.layer.settings.exposure; row["pass_gate"] = correct
                    try ArtifactJSONCodec.encode(response.plan.layer).write(to: root.appendingPathComponent("\(item.id)-\(pass)-layer.json"))
                } catch {
                    let refused = error as? AIEditPlanError == .unsupportedRequest
                        || error as? AutomaticMaskError == .noSky || error as? AutomaticMaskError == .noSubject
                    row["plan"] = false; row["error"] = String(describing: error)
                    row["pass_gate"] = item.negative && refused
                    row["schema_error"] = error as? AIEditPlanError == .invalidResponse || error as? AIDevelopmentError == .invalidResponse
                }
                row["total_ms"] = milliseconds(start.duration(to: .now))
                row["stages"] = await log.rows
                var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
                row["cumulative_process_peak_rss_bytes"] = usage.ru_maxrss
                runs.append(row)
                print("EDIT-PLAN-GATE \(item.id) \(pass): \(row["pass_gate"] ?? false), \(row["error"] ?? row["target"] ?? "unknown")")
            }
            if runs.allSatisfy({ $0["pass_gate"] as? Bool == true }) {
                if item.negative { negatives += 1 } else { positives += 1 }
            }
            // Same services, explicit annotated target. This baseline is never
            // inferred from the candidate's output, so failures remain visible.
            if !item.negative {
                let log = PlanGateTrace()
                let service = AIEditPlanService(trace: { stage, ms, success in await log.record(stage: stage.rawValue, ms: ms, success: success) })
                var row: [String: Any] = ["pass": "explicit-reference"]
                do {
                    let target = try AIEditPlanTarget(kind: item.kind, description: item.kind == .object ? "roter Ball" : item.kind.rawValue, summary: "Vorab annotiertes Ziel")
                    let response = try await service.explicitReference(snapshot: snapshot, instruction: item.instruction, target: target)
                    row["plan"] = true; row["iou"] = try selectionScore(response.plan.layer, kind: item.kind, scene: item.scene)
                    row["exposure"] = response.plan.layer.settings.exposure
                } catch { row["plan"] = false; row["error"] = String(describing: error) }
                row["stages"] = await log.rows; runs.append(row)
            }
            reports.append(["id": item.id, "negative": item.negative, "runs": runs])
            try writeReport(reports, positives: positives, negatives: negatives, root: root)
            let measuredPositive = reports.filter { $0["negative"] as? Bool == false }.count
            let measuredNegative = reports.count - measuredPositive
            let goImpossible = positives + 12 - measuredPositive < 11 || negatives + 8 - measuredNegative < 8
            if goImpossible, ProcessInfo.processInfo.environment["GLOWROOM_EDIT_PLAN_GATE_COMPLETE_MATRIX"] != "1" {
                // Once Go is impossible, more minute-long native calls cannot
                // change the release decision. Preserve all measurements and
                // explicitly name the unmeasured cases instead of wasting work.
                try writeReport(reports, positives: positives, negatives: negatives, root: root, stoppedEarly: true)
                print("EDIT-PLAN-GATE NO-GO: threshold impossible after \(reports.count)/20 cases; remaining cases unmeasured")
                return
            }
        }
        // A research No-Go is an expected test outcome; fake contract tests must
        // pass separately. No test flag can turn the product gate on.
        print("EDIT-PLAN-GATE decision=\(positives >= 11 && negatives == 8 ? "numerical-pass-unqualified" : "NO-GO") positives=\(positives)/12 negatives=\(negatives)/8 output=\(root.path)")
    }

    private func writeReport(_ rows: [[String: Any]], positives: Int, negatives: Int, root: URL, stoppedEarly: Bool = false) throws {
        let report: [String: Any] = ["contract": 1, "cases_completed": rows.count, "positive_passes": positives, "negative_refusals": negatives,
            "decision": rows.count == 20 ? (positives >= 11 && negatives == 8 ? "numerical-pass-unqualified" : "NO-GO") : (stoppedEarly ? "NO-GO" : "INCOMPLETE"),
            "stopped_early": stoppedEarly,
            "product_enabled": false, "iou_threshold": 0.6, "qwen_revision": LLMModelDescriptor.qwen35.revision,
            "sky_revision": SkyMaskApprovedPackage.revision, "subject_revision": SubjectMattingModelInterface.sourceRevision,
            "limits": "Synthetic 384x256 images; no general photo-quality claim. High-water RSS is cumulative Darwin whole-process bytes, including test runtime and native caches. Cold means new app source/render caches; OS, model validation and shader caches are not flushed. Model services release weights after each inference. Native editor acceptance remains required even for a numerical pass.", "cases": rows]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("report.json"), options: .atomic)
    }

    /// Pixel-exact top-left annotation, set before the first model call.
    private func selectionScore(_ layer: LocalAdjustment, kind: AIEditPlanTargetKind, scene: Int) throws -> Double {
        let raster: LocalMaskRaster
        switch layer.mask.shape { case .sky(let value), .subject(let value): raster = value; default: return 0 }
        var intersection = 0.0, union = 0.0
        for y in 0..<raster.height {
            for x in 0..<raster.width {
                let px = (Double(x) + 0.5) / Double(raster.width), py = (Double(y) + 0.5) / Double(raster.height)
                let cx = 0.43 + Double(scene) * 0.05, cy = 0.67
                let ball = pow((px - cx) / 0.14, 2) + pow((py - cy) / 0.21, 2) <= 1
                let expected = kind == .sky ? py < 0.4 : kind == .background ? !ball : ball
                var actual = Double(raster.bytes[y * raster.width + x]) / 255
                if layer.mask.isInverted { actual = 1 - actual }
                intersection += expected ? actual : 0
                union += expected ? 1 : actual
            }
        }
        return union > 0 ? intersection / union : 0
    }

    private func scene(_ index: Int) throws -> CGImage {
        let width = 384, height = 256
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { storage in
            let pixels = storage.bindMemory(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let px = (Double(x) + 0.5) / Double(width), py = (Double(y) + 0.5) / Double(height)
                let cx = 0.43 + Double(index) * 0.05
                let ball = pow((px - cx) / 0.14, 2) + pow((py - 0.67) / 0.21, 2) <= 1
                let p = (y * width + x) * 4
                let color: (UInt8, UInt8, UInt8)
                if index == 3 { color = (170, 160, 145) }
                else if ball { color = (UInt8(190 + x % 35), 35, 25) }
                else if py < 0.4 { color = (UInt8(90 + y / 3), UInt8(160 + y / 4), 230) }
                else { color = (65, UInt8(105 + (x + y) % 35), 45) }
                pixels[p] = color.0; pixels[p+1] = color.1; pixels[p+2] = color.2; pixels[p+3] = 255
            } }
        }
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func png(_ image: CGImage, at url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }
    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}

private actor PlanGateTrace {
    private(set) var rows: [[String: String]] = []
    func record(stage: String, ms: Double, success: Bool) { rows.append(["stage": stage, "ms": String(ms), "success": String(success)]) }
}
