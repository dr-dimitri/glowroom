#!/usr/bin/env swift
// PREPARED ONLY: not compiled or executed. No package dependencies/downloads.
// Default prints a plan; real execution requires --run and --window <Root lease>.
import Foundation
import CryptoKit
import CoreImage
import CoreGraphics
import Dispatch
import Darwin

typealias JSONObject = [String: Any]
let root = URL(fileURLWithPath: "/private/tmp/picedit-inpainting-gate", isDirectory: true)
let helperSHA = "e85c762c68aea5b10cd1ff2e7b5d56802c4875dcc9b844f2b6ab798d3fd1980d"
let fixtureSHA = "799d51e22631500e9caa2fbdd2c09403788d55d4248ddeacc9cc0db0c4a7a2d5"
let configurationSHA = "a356133c9769b71a55fff3a43b706942df1c477cf757075055549a394a1c2450"
let memoryLimit: UInt64 = 6 * 1024 * 1024 * 1024
let pythonPath = "/usr/bin/env"
enum Failure: Error { case code(String) }
final class StopControl: @unchecked Sendable {
    let lock = NSLock(); var interrupted = false; var deadline = Double.infinity
    func request() { lock.lock(); interrupted = true; lock.unlock() }
    func setDeadline(_ value: Double) { lock.lock(); deadline = value; lock.unlock() }
    func check() throws {
        lock.lock(); let stop = interrupted || now() >= deadline; lock.unlock()
        if stop { throw Failure.code("interrupted-or-window-deadline") }
    }
}
let stopControl = StopControl()
func require(_ value: Bool, _ code: String) throws { if !value { throw Failure.code(code) } }
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func ownPeakRSS() -> UInt64 { var r = rusage(); getrusage(RUSAGE_SELF, &r); return UInt64(max(0, r.ru_maxrss)) }
func json(_ url: URL) throws -> JSONObject {
    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? JSONObject else { throw Failure.code("invalid-json-object") }
    return value
}
func writeJSON(_ value: Any, _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
}
func pipeChunk(_ handle: FileHandle) throws -> Data? {
    var bytes = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
        if count > 0 { return Data(bytes.prefix(count)) }
        if count == 0 { return nil }
        if errno != EINTR { throw Failure.code("pipe-read-failed") }
    }
}
func hash(_ url: URL, gitBlob: Bool = false) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var sha = SHA256(); var sha1 = Insecure.SHA1()
    if gitBlob {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
        sha1.update(data: Data("blob \(size.int64Value)\0".utf8))
    }
    while try autoreleasepool(invoking: { () throws -> Bool in
        guard let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty else { return false }
        try stopControl.check()
        if gitBlob { sha1.update(data: block) } else { sha.update(data: block) }
        return true
    }) {}
    return (gitBlob ? Array(sha1.finalize()) : Array(sha.finalize())).map { String(format: "%02x", $0) }.joined()
}

final class NativeSession: @unchecked Sendable {
    let process = Process()
    let input = Pipe(), output = Pipe(), errors = Pipe()
    let condition = NSCondition(), readers = DispatchGroup()
    var queued: [JSONObject] = [], fatal: String?, stdoutEnded = false, exited = false
    var eventCount = 0, eventBytes = 0, stderrBytes = 0
    let eventFile: FileHandle, stderrFile: FileHandle, directory: URL
    var stopped = false
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let eventsURL = directory.appendingPathComponent("native-events.jsonl")
        let errorsURL = directory.appendingPathComponent("native-stderr.bin")
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errorsURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        eventFile = try FileHandle(forWritingTo: eventsURL); stderrFile = try FileHandle(forWritingTo: errorsURL)
        process.executableURL = root.appendingPathComponent("evaluation-helper-float-diagnostic-unbatched")
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }; self.condition.lock(); self.exited = true
            self.condition.broadcast(); self.condition.unlock()
        }
        try process.run()
        readers.enter(); DispatchQueue.global(qos: .userInitiated).async { self.readOutput(); self.readers.leave() }
        readers.enter(); DispatchQueue.global(qos: .utility).async { self.readErrors(); self.readers.leave() }
        do { _ = try wait(target: "ready", id: nil, timeout: 5) }
        catch { _ = stop(); throw error }
    }
    func fail(_ reason: String) { condition.lock(); fatal = reason; condition.broadcast(); condition.unlock() }
    func readOutput() {
        var partial = Data()
        do {
            while let block = try pipeChunk(output.fileHandleForReading), !block.isEmpty {
                partial.append(block)
                while let end = partial.firstIndex(of: 10) {
                    let line = Data(partial[..<end]); partial.removeSubrange(...end)
                    try require(line.count <= 65_536, "protocol-line-bound")
                    guard let event = try JSONSerialization.jsonObject(with: line) as? JSONObject,
                          (event["protocol"] as? Int) == 1 else { throw Failure.code("protocol-json") }
                    eventCount += 1; eventBytes += line.count + 1
                    try require(eventCount <= 25_000 && eventBytes <= 64 * 1024 * 1024, "protocol-total-bound")
                    try eventFile.write(contentsOf: line + Data([10]))
                    condition.lock()
                    if queued.count >= 1024 { fatal = "protocol-queue-bound" }
                    else { queued.append(event) }
                    condition.broadcast(); condition.unlock()
                }
                try require(partial.count <= 65_536, "protocol-partial-bound")
            }
            try require(partial.isEmpty, "protocol-truncated-line")
        } catch { fail("protocol-reader-failed") }
        condition.lock(); stdoutEnded = true; condition.broadcast(); condition.unlock()
    }
    func readErrors() {
        do {
            while let block = try pipeChunk(errors.fileHandleForReading), !block.isEmpty {
                let old = stderrBytes; stderrBytes += block.count
                if old < 1024 * 1024 { try stderrFile.write(contentsOf: block.prefix(1024 * 1024 - old)) }
            }
        } catch { fail("stderr-reader-failed") }
    }
    func send(_ value: JSONObject) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10)
        try require(data.count <= 65_536, "request-bound")
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    func next(deadline: Double) throws -> JSONObject {
        try stopControl.check()
        try require(now() < deadline, "operation-timeout")
        condition.lock(); defer { condition.unlock() }
        while queued.isEmpty {
            try stopControl.check()
            if let fatal { throw Failure.code(fatal) }
            if stdoutEnded { throw Failure.code("native-output-ended") }
            let remaining = deadline - now(); if remaining <= 0 { throw Failure.code("operation-timeout") }
            _ = condition.wait(until: Date(timeIntervalSinceNow: min(remaining, 1)))
        }
        return queued.removeFirst()
    }
    func wait(target: String, id: String?, timeout: Double, cancelAtStep: Int? = nil) throws -> JSONObject {
        let begin = now(); var deadline = begin + timeout; var cancelledAt: Double?
        while true {
            let event = try next(deadline: deadline)
            if let memory = event["memory"] as? JSONObject {
                let rss = (memory["peakRSSBytes"] as? NSNumber)?.uint64Value ?? 0
                let footprint = (memory["peakFootprintBytes"] as? NSNumber)?.uint64Value ?? 0
                try require(max(rss, footprint) <= memoryLimit, "native-memory-gate")
                try require(max(rss, footprint) + ownPeakRSS() <= memoryLimit, "conservative-combined-memory-gate")
            }
            let matches = id == nil || (event["id"] as? String) == id
            if matches, event["event"] as? String == "progress", let cancelAtStep,
               let step = event["step"] as? Int, step >= cancelAtStep, cancelledAt == nil {
                cancelledAt = now(); try send(["operation": "cancel", "id": "cancel-probe"])
                deadline = min(deadline, cancelledAt! + 5)
            }
            if matches && event["event"] as? String == target {
                var result = event; result["driverElapsedSeconds"] = now() - begin
                if let cancelledAt { result["cancelLatencyUntilNativeReturnSeconds"] = now() - cancelledAt }
                result["nativePID"] = Int(process.processIdentifier)
                result["sameProcessContextLeaseHeldUntilThisNativeReturn"] = true
                return result
            }
        }
    }
    func operation(_ request: JSONObject, timeout: Double, cancelAtStep: Int? = nil) throws -> JSONObject {
        let id = request["id"] as! String
        try writeJSON(request, directory.appendingPathComponent("request-\(id).json"))
        try send(request)
        do { return try wait(target: "completed", id: id, timeout: timeout, cancelAtStep: cancelAtStep) }
        catch { try? send(["operation": "cancel", "id": "guard-cancel"]); throw error }
    }
    @discardableResult func stop() -> JSONObject {
        if stopped { return ["alreadyStopped": true] }; stopped = true
        if process.isRunning {
            try? send(["operation": "cancel", "id": "close"]); try? send(["operation": "shutdown"])
            let deadline = now() + 5
            condition.lock()
            while !exited && now() < deadline { _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1)) }
            condition.unlock()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit() // Lease is never released merely because Swift stopped waiting.
        if readers.wait(timeout: .now() + 5) == .timedOut {
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
            readers.wait() // No log readers outlive their closed archive handles.
        }
        try? input.fileHandleForWriting.close(); try? eventFile.close(); try? stderrFile.close()
        return ["nativeExitStatus": Int(process.terminationStatus), "confirmedProcessEnded": !process.isRunning,
                "nativePID": Int(process.processIdentifier), "eventCount": eventCount, "eventBytes": eventBytes,
                "stderrBytes": stderrBytes, "leaseReleasedOnlyAfterProcessExit": true]
    }
}

final class PreviewProbe: @unchecked Sendable {
    // One bounded background renderer; Core Image chooses its execution backend.
    let queue = DispatchQueue(label: "picedit.synthetic-preview", qos: .userInitiated)
    let lock = NSLock(), group = DispatchGroup(), colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    var context: CIContext? = CIContext(options: [.cacheIntermediates: false])
    var stopped = true, samples: [Double] = [], renderSamples: [Double] = [], skipped = 0, checksum: UInt64 = 0
    let image: CIImage
    init() {
        image = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 23,
            "inputColor0": CIColor(red: 0.2, green: 0.45, blue: 0.7),
            "inputColor1": CIColor(red: 0.8, green: 0.3, blue: 0.1)])!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
    }
    func render(_ index: Int) -> Double {
        let begin = now()
        let processed = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": sin(Double(index) * 0.13) * 0.5])
            .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0.9, "inputContrast": 1.05])
        var pixels = [UInt8](repeating: 0, count: 256 * 256 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context!.render(processed, toBitmap: bytes.baseAddress!, rowBytes: 256 * 4,
                bounds: CGRect(x: 0, y: 0, width: 256, height: 256), format: .RGBA8, colorSpace: colorSpace)
        }
        for index in stride(from: 0, to: pixels.count, by: 4096) { checksum = (checksum &* 1099511628211) ^ UInt64(pixels[index]) }
        return now() - begin
    }
    func start() {
        lock.lock(); stopped = false; samples = []; renderSamples = []; skipped = 0; checksum = 0; lock.unlock()
        group.enter(); queue.async {
            let origin = now(); var previous = -1
            while true {
                self.lock.lock(); let stop = self.stopped; self.lock.unlock(); if stop { break }
                let index = max(previous + 1, Int((now() - origin) / 0.1))
                if previous >= 0 { self.skipped += max(0, index - previous - 1) }; previous = index
                let elapsed = autoreleasepool { self.render(index) }
                self.renderSamples.append(elapsed)
                self.samples.append(max(elapsed, now() - (origin + Double(index) * 0.1)))
                if self.samples.count >= 2500 { break }
                let delay = origin + Double(index + 1) * 0.1 - now()
                if delay > 0 { Thread.sleep(forTimeInterval: min(delay, 0.1)) }
            }
            self.group.leave()
        }
    }
    func stop() -> JSONObject {
        lock.lock(); stopped = true; lock.unlock(); group.wait()
        let sorted = samples.sorted()
        func quantile(_ q: Double) -> Double { sorted.isEmpty ? 0 : sorted[Int(ceil(Double(sorted.count - 1) * q))] }
        return ["sampleCount": sorted.count, "p50Seconds": quantile(0.5), "p95Seconds": quantile(0.95),
            "p99Seconds": quantile(0.99), "maximumSeconds": sorted.last ?? 0, "coalescedFrameCount": skipped,
            "checksum": String(checksum), "source": "procedural256x256-checkerboard", "targetIntervalSeconds": 0.1,
            "execution": "CIContext-auto-single-background-renderer", "actualPicEditUIOrRAWTest": false,
            "latencyDefinition": "scheduled-coalesced-request-to-render-return; includes scheduling and GPU wait",
            "maximumRenderOnlySeconds": renderSamples.max() ?? 0]
    }
    func baseline() -> JSONObject {
        for index in 0..<5 { _ = autoreleasepool { render(index) } }
        start(); Thread.sleep(forTimeInterval: 3); var value = stop(); value["discardedWarmupRenders"] = 5
        value["modelContextResidentButNoModelCompute"] = true; return value
    }
    func release() { context?.clearCaches(); context = nil }
}

struct Case {
    let id: String, fixture: JSONObject, mask: JSONObject, role: String
    func request(stamp: String) -> JSONObject {
        ["operation": "generate", "id": id, "source": fixture["source"]!, "mask": mask["path"]!,
         "output": "outputs/\(stamp)-\(id).png", "prompt": fixture["prompt"]!,
         "negativePrompt": fixture["negativePrompt"]!, "seed": 4281]
    }
}
func fixtureCases(_ fixtures: [JSONObject], repeatedWarm: Bool) -> [Case] {
    var cases: [Case] = []
    for (index, fixture) in fixtures.enumerated() {
        for mask in fixture["masks"] as! [JSONObject] {
            let id = "\(fixture["id"]!)-\(mask["kind"]!)"
            cases.append(Case(id: id, fixture: fixture, mask: mask, role: cases.isEmpty ? "cold-context-first-generation" : "warm-context-fixture"))
            if index == 0 && repeatedWarm {
                for warm in 1...3 { cases.append(Case(id: "warm-repeat-\(warm)", fixture: fixture, mask: mask, role: "identical-fixture-warm-repeat")) }
            }
        }
    }
    return cases
}
func verifyInputs() throws -> [JSONObject] {
    try require(try hash(root.appendingPathComponent("fixtures-manifest.json")) == fixtureSHA, "fixture-manifest-hash")
    try require(try hash(root.appendingPathComponent("model-manifest.json")) == "666bdfbe19edd25cdf677b28d53055a19ce0983a0dde0223f35ec3091fc5ae79", "model-manifest-hash")
    try require(try hash(root.appendingPathComponent("evaluation-helper-float-diagnostic-unbatched")) == helperSHA, "helper-hash")
    let fixtures = try json(root.appendingPathComponent("fixtures-manifest.json"))["fixtures"] as! [JSONObject]
    for fixture in fixtures {
        try require(try hash(root.appendingPathComponent(fixture["source"] as! String)) == fixture["sourceFileSHA256"] as! String, "source-hash")
        for mask in fixture["masks"] as! [JSONObject] {
            try require(try hash(root.appendingPathComponent(mask["path"] as! String)) == mask["fileSHA256"] as! String, "mask-hash")
        }
    }
    let manifest = try json(root.appendingPathComponent("model-manifest.json"))
    for item in manifest["files"] as! [JSONObject] {
        let url = root.appendingPathComponent("model").appendingPathComponent(item["installedPath"] as! String)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try require(attributes[.type] as? FileAttributeType == .typeRegular, "model-file-type")
        try require((attributes[.size] as! NSNumber).int64Value == (item["bytes"] as! NSNumber).int64Value, "model-file-size")
        if let expected = item["sha256"] as? String { try require(try hash(url) == expected, "model-weight-hash") }
        else { try require(try hash(url, gitBlob: true) == item["gitBlobSHA1"] as! String, "model-metadata-hash") }
    }
    return fixtures
}

func main() throws {
    signal(SIGPIPE, SIG_IGN)
    let arguments = Array(CommandLine.arguments.dropFirst())
    func option(_ name: String, _ fallback: String) -> String {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return fallback }
        return arguments[index + 1]
    }
    let mode = option("--mode", "full"), phase = option("--phase", "all"), window = option("--window", "")
    try require(["full", "coverage"].contains(mode) && ["all", "series", "cancel"].contains(phase), "invalid-option")
    if !arguments.contains("--run") {
        print("PREPARED ONLY. full=10 generations (cold +3 identical warm repeats +6 other cases); coverage=7 generations (6 context-warm, no identical repeat benchmark). phase=all/series/cancel. Requires --run --window <Root-exclusive-lease>. No helper/model is started by this default.")
        return
    }
    try require(!window.isEmpty && window.count <= 64, "explicit-exclusive-window-required")
    let maximumTotal = Double(option("--max-total-seconds", "2400")) ?? 0
    try require(maximumTotal >= 300 && maximumTotal <= 3600, "invalid-window-duration")
    stopControl.setDeadline(now() + maximumTotal)
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
    interrupt.setEventHandler { stopControl.request() }; terminate.setEventHandler { stopControl.request() }
    interrupt.resume(); terminate.resume(); defer { interrupt.cancel(); terminate.cancel() }
    let lockFD = open(root.appendingPathComponent("series-exclusive.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    try require(lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0, "another-series-active")
    defer { flock(lockFD, LOCK_UN); close(lockFD) }
    let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = formatter.string(from: Date()) + "-" + String(UUID().uuidString.prefix(8)).lowercased()
    let directory = root.appendingPathComponent("reports/\(stamp)-native-series-\(mode)")
    try require(!FileManager.default.fileExists(atPath: directory.path), "run-directory-already-exists")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let reportURL = directory.appendingPathComponent("series-report.json")
    var report: JSONObject = ["status": "preflight", "mode": mode, "phase": phase, "windowID": window,
        "fixtureManifestSHA256": fixtureSHA, "baseNativeConfigurationSHA256": configurationSHA, "helperSHA256": helperSHA,
        "harnessSourceSHA256": try hash(root.appendingPathComponent("evaluate-inpainting-series.swift")),
        "harnessExecutableSHA256": try hash(URL(fileURLWithPath: CommandLine.arguments[0])),
        "postprocessSourceSHA256": try hash(root.appendingPathComponent("series-postprocess.py")),
        "contextColdDefinition": "new helper process/model context; OS/file/Metal caches not purged",
        "qualityStatus": "unverified-manual-review-required", "backendGo": false, "operations": [JSONObject](),
        "maximumTotalSeconds": maximumTotal,
        "gates": ["loadSeconds": 45, "generationSeconds": 180, "coldTotalSeconds": 240, "cancelSeconds": 5,
                  "memoryBytes": memoryLimit, "previewP95Seconds": 0.25, "previewP95BaselineMultiplier": 2],
        "noNetworkOrDownload": true]
    var session: NativeSession?; var preview: PreviewProbe?
    do {
        if arguments.contains("--protocol-smoke") {
            session = try NativeSession(directory: directory.appendingPathComponent("protocol-smoke-context"))
            report["protocolSmokeStop"] = session!.stop(); session = nil
            report["status"] = "protocol-ready-and-shutdown-pass-no-model-loaded"
            report["allOwnNativeProcessesEnded"] = true
            try writeJSON(report, reportURL); print("PROTOCOL_SMOKE_PASS \(reportURL.path)"); return
        }
        let fixtures = try verifyInputs(); report["preflight"] = "all-files-verified-before-model-load"
        let cases = fixtureCases(fixtures, repeatedWarm: mode == "full")
        report["plannedGenerations"] = cases.count; try writeJSON(report, reportURL)
        if phase != "cancel" {
            let coldStart = now(); session = try NativeSession(directory: directory.appendingPathComponent("series-context"))
            let loaded = try session!.operation(["operation": "load", "id": "load", "backend": "metal"], timeout: 45)
            report["load"] = loaded; try require(loaded["status"] as? String == "success", "load-failed")
            for (index, item) in cases.enumerated() {
                let withPreview = index == 1
                if withPreview { preview = PreviewProbe(); report["previewBaseline"] = preview!.baseline(); preview!.start() }
                let request = item.request(stamp: stamp)
                var result = try session!.operation(request, timeout: 180)
                if withPreview {
                    let concurrent = preview!.stop(); report["previewConcurrent"] = concurrent
                    let baseline = report["previewBaseline"] as! JSONObject
                    let p95 = concurrent["p95Seconds"] as! Double, base = baseline["p95Seconds"] as! Double
                    report["previewGatePassed"] = p95 <= 0.25 && p95 <= base * 2 && (concurrent["sampleCount"] as! Int) > 0
                    preview!.release(); preview = nil
                }
                result["caseID"] = item.id; result["fixtureID"] = item.fixture["id"]!; result["maskKind"] = item.mask["kind"]!
                result["role"] = item.role; result["request"] = request; result["nativeGeometry"] = item.fixture["size"]!
                if index == 0 { report["coldEndToEndSeconds"] = now() - coldStart }
                var operations = report["operations"] as! [JSONObject]; operations.append(result); report["operations"] = operations
                try writeJSON(report, reportURL)
                try require(result["status"] as? String == "success", "native-generation-failed")
                try require(result["configurationSHA256"] == nil || result["configurationSHA256"] as? String == configurationSHA, "configuration-drift")
                let actual = result["nativeConfiguration"] as? JSONObject
                try require(actual?["actualBatchedCFG"] as? Bool == false && actual?["vaeRuntimeBackend"] as? String == "CPU" && actual?["diffusionRuntimeBackend"] as? String == "MTL0", "actual-native-config-drift")
                if index == 0 { try require((report["coldEndToEndSeconds"] as! Double) <= 240, "cold-total-gate") }
                print("Completed \(index+1)/\(cases.count): \(item.id); quality still unverified")
                fflush(stdout)
            }
            report["seriesContextStop"] = session!.stop(); session = nil
        }
        if phase != "series" {
            // Separate fresh process/context. Never cancel a shared series context then reuse it.
            session = try NativeSession(directory: directory.appendingPathComponent("cancel-context"))
            let cancelLoad = try session!.operation(["operation": "load", "id": "load", "backend": "metal"], timeout: 45)
            report["cancelLoad"] = cancelLoad
            try require(cancelLoad["status"] as? String == "success", "cancel-context-load-failed")
            var request = cases[0].request(stamp: stamp); request["id"] = "cancel-probe"
            request["output"] = "outputs/\(stamp)-cancel-must-not-publish.png"
            let cancelledPath = root.appendingPathComponent(request["output"] as! String)
            try require(!FileManager.default.fileExists(atPath: cancelledPath.path), "cancel-output-already-exists")
            let cancelled = try session!.operation(request, timeout: 180, cancelAtStep: 2)
            report["cancellation"] = cancelled
            report["cancelNoOutputPublished"] = !FileManager.default.fileExists(atPath: cancelledPath.path)
            let latency = cancelled["cancelLatencyUntilNativeReturnSeconds"] as? Double ?? .infinity
            report["cancelGatePassed"] = cancelled["code"] as? String == "cancelled" && latency <= 5 && !FileManager.default.fileExists(atPath: cancelledPath.path)
            report["cancelContextStop"] = session!.stop(); session = nil
        }
        report["status"] = "native-series-ended-awaiting-postprocessing-and-visual-review"
    } catch {
        if let preview { report["previewInterrupted"] = preview.stop(); preview.release() }
        report["status"] = "technical-failure-preserved-partial-results"
        if case Failure.code(let code) = error { report["errorCode"] = code } else { report["errorCode"] = "io-or-framework-error" }
    }
    if let session { report["emergencyContextStop"] = session.stop() }
    report["allOwnNativeProcessesEnded"] = true; report["ownPeakRSSBytes"] = ownPeakRSS()
    let operations = report["operations"] as! [JSONObject]
    report["contextWarmGenerationCount"] = max(0, operations.count - 1)
    report["identicalFixtureWarmRepeatCount"] = operations.filter { $0["role"] as? String == "identical-fixture-warm-repeat" }.count
    report["identicalFixtureWarmSeconds"] = operations.filter { $0["role"] as? String == "identical-fixture-warm-repeat" }.compactMap { $0["seconds"] as? Double }
    report["seriesNativePIDCount"] = Set(operations.compactMap { $0["nativePID"] as? Int }).count
    report["previewAndCancelMetricGatesPassed"] = (phase == "cancel" || report["previewGatePassed"] as? Bool == true) && (phase == "series" || report["cancelGatePassed"] as? Bool == true)
    try writeJSON(report, reportURL)
    print("MODEL_PROCESSES_ENDED \(reportURL.path)"); fflush(stdout)
    // CPU-only image postprocessing occurs after confirmed helper exit, never in model timings.
    if phase != "cancel" {
        let post = Process(); post.executableURL = URL(fileURLWithPath: pythonPath)
        post.arguments = ["python3", root.appendingPathComponent("series-postprocess.py").path, "--report", reportURL.path]
        let logURL = directory.appendingPathComponent("postprocess.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL); post.standardOutput = log; post.standardError = log
        try post.run(); post.waitUntilExit(); try log.close()
        report["postprocessExitStatus"] = Int(post.terminationStatus)
        if post.terminationStatus != 0 { report["status"] = "postprocess-failure-native-data-preserved" }
        try writeJSON(report, reportURL)
    }
    print("REPORT \(reportURL.path)")
    let postprocessExit = report["postprocessExitStatus"] as? Int
    if report["status"] as? String == "technical-failure-preserved-partial-results" || (postprocessExit != nil && postprocessExit != 0) { throw Failure.code("series-failed-see-report") }
    if report["previewAndCancelMetricGatesPassed"] as? Bool != true { throw Failure.code("measured-metric-gate-failed-see-report") }
}

do { try main() }
catch { fputs("Inpainting series failed; see bounded local report.\n", stderr); exit(1) }
