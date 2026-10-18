#if PICEDIT_IMAGE_GENERATION_EVALUATION
import Foundation
import CryptoKit
import CoreImage
import CoreGraphics
import Dispatch
import Darwin
import PicEditCore

// Explicit developer-only native probe. The ordinary app has no native SDK,
// model installer or model-loading hook. Inputs are self-authored fixtures only.
private typealias JSONObject = [String: Any]
private var root = URL(fileURLWithPath: "/tmp/picedit-evaluation", isDirectory: true)
private let fixtureSHA = "799d51e22631500e9caa2fbdd2c09403788d55d4248ddeacc9cc0db0c4a7a2d5"
private let configurationSHA = "a356133c9769b71a55fff3a43b706942df1c477cf757075055549a394a1c2450"
private let memoryLimit: UInt64 = 6 * 1024 * 1024 * 1024
private enum Failure: Error { case code(String) }
private final class StopControl: @unchecked Sendable {
    let lock = NSLock(); var interrupted = false; var deadline = Double.infinity
    func request() { lock.lock(); interrupted = true; lock.unlock() }
    func setDeadline(_ value: Double) { lock.lock(); deadline = value; lock.unlock() }
    func check() throws {
        lock.lock(); let stop = interrupted || now() >= deadline; lock.unlock()
        if stop { throw Failure.code("interrupted-or-window-deadline") }
    }
}
private let stopControl = StopControl()
private func require(_ value: Bool, _ code: String) throws { if !value { throw Failure.code(code) } }
// mach_continuous_time includes system sleep. No suspended time is subtracted.
private func now() -> Double {
    var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
    return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
}
private func ownPeakRSS() -> UInt64 { var r = rusage(); getrusage(RUSAGE_SELF, &r); return UInt64(max(0, r.ru_maxrss)) }
private func json(_ url: URL) throws -> JSONObject {
    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? JSONObject else { throw Failure.code("invalid-json-object") }
    return value
}
private func writeJSON(_ value: Any, _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
}
private func pipeChunk(_ handle: FileHandle) throws -> Data? {
    var bytes = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
        if count > 0 { return Data(bytes.prefix(count)) }
        if count == 0 { return nil }
        if errno != EINTR { throw Failure.code("pipe-read-failed") }
    }
}
private func hash(_ url: URL, gitBlob: Bool = false) throws -> String {
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

private final class NativeSession: @unchecked Sendable {
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
        process.executableURL = root.appendingPathComponent("evaluation-helper-current")
        process.arguments = [root.path]
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
        // A completion can wake this wait after sleep or just after timeout.
        // Check again before consuming it; timer delivery is not the deadline.
        try stopControl.check()
        try require(now() < deadline, "operation-timeout")
        if let fatal { throw Failure.code(fatal) }
        return queued.removeFirst()
    }
    func wait(target: String, id: String?, timeout: Double, cancelAtStep: Int? = nil) throws -> JSONObject {
        let begin = now(); var deadline = begin + timeout; var cancelledAt: Double?
        while true {
            let event = try next(deadline: deadline)
            if event["event"] as? String == "completed" {
                try require(event["memory"] is JSONObject, "missing-native-memory-metric")
            }
            if let memory = event["memory"] as? JSONObject {
                guard let rssNumber = memory["peakRSSBytes"] as? NSNumber,
                      let footprintNumber = memory["peakFootprintBytes"] as? NSNumber,
                      [rssNumber, footprintNumber].allSatisfy({ number in
                          let value = number.doubleValue
                          return CFGetTypeID(number) != CFBooleanGetTypeID() && value.isFinite &&
                              value > 0 && value <= Double(memoryLimit) && value.rounded(.towardZero) == value
                      }) else {
                    throw Failure.code("invalid-native-memory-metric")
                }
                let rss = rssNumber.uint64Value, footprint = footprintNumber.uint64Value
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

private final class PreviewProbe: @unchecked Sendable {
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

private func verifyInputs() throws -> [JSONObject] {
    #if !arch(arm64)
    throw Failure.code("unsupported-hardware")
    #endif
    try require(ProcessInfo.processInfo.physicalMemory >= 16 * 1024 * 1024 * 1024, "minimum-16GiB-required")
    if #available(macOS 14, *) {} else { throw Failure.code("unsupported-system") }
    var pressure: Int32 = 0, count = MemoryLayout<Int32>.size
    try require(sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &count, nil, 0) == 0 && pressure == 1,
                "normal-memory-pressure-required")
    let receipt = try json(root.appendingPathComponent("evaluation-installation.json"))
    try require(receipt["sdkRevision"] as? String == "8cd731e7b4667eb8f40a153315b9a7125d09a58d" &&
                receipt["ggmlRevision"] as? String == "d25b121ce1d6ae0c7e62ad080460d9fc1e46dd93" &&
                receipt["modelRevision"] as? String == "8a4288a76071f7280aedbdb3253bdb9e9d5d84bb", "installation-revision")
    try require(try hash(root.appendingPathComponent("evaluation-helper-current")) == receipt["helperSHA256"] as? String, "helper-hash")
    // The native configuration ID hashes canonical JSON without its final LF;
    // the pinned installation file includes that LF and has a separate digest.
    try require(try hash(root.appendingPathComponent("unbatched-configuration.json")) ==
                "bfcd90c91223a8076644420943cd9638bca717d81909b99ef39866714ba7514f", "configuration-file-hash")
    try require(try hash(root.appendingPathComponent("fixtures-manifest.json")) == fixtureSHA, "fixture-manifest-hash")
    try require(try hash(root.appendingPathComponent("model-manifest.json")) == "666bdfbe19edd25cdf677b28d53055a19ce0983a0dde0223f35ec3091fc5ae79", "model-manifest-hash")
    let manifest = try json(root.appendingPathComponent("model-manifest.json"))
    for item in manifest["files"] as! [JSONObject] {
        let path = item["installedPath"] as! String
        try require(!path.hasPrefix("/") && !path.split(separator: "/").contains(".."), "model-relative-path")
        let file = root.appendingPathComponent("model").appendingPathComponent(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try require(attributes[.type] as? FileAttributeType == .typeRegular, "model-file-type")
        try require((attributes[.size] as! NSNumber).int64Value == (item["bytes"] as! NSNumber).int64Value, "model-file-size")
        if let expected = item["sha256"] as? String { try require(try hash(file) == expected, "model-weight-hash") }
        else { try require(try hash(file, gitBlob: true) == item["gitBlobSHA1"] as! String, "model-metadata-hash") }
    }
    let fixtures = try json(root.appendingPathComponent("fixtures-manifest.json"))["fixtures"] as! [JSONObject]
    for fixture in fixtures {
        try require(try hash(root.appendingPathComponent(fixture["source"] as! String)) == fixture["sourceFileSHA256"] as! String, "source-hash")
        for mask in fixture["masks"] as! [JSONObject] {
            try require(try hash(root.appendingPathComponent(mask["path"] as! String)) == mask["fileSHA256"] as! String, "mask-hash")
        }
    }
    return fixtures
}

private func benchmark(directory: URL, allFixtures: Bool) throws {
    signal(SIGPIPE, SIG_IGN)
    stopControl.setDeadline(now() + (allFixtures ? 2400 : 1000))
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
    interrupt.setEventHandler { stopControl.request() }; terminate.setEventHandler { stopControl.request() }
    interrupt.resume(); terminate.resume(); defer { interrupt.cancel(); terminate.cancel() }
    let fd = open(root.appendingPathComponent("evaluation.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    try require(fd >= 0, "evaluation-lock-open")
    defer { close(fd) }
    try require(flock(fd, LOCK_EX | LOCK_NB) == 0, "another-evaluation-active")
    defer { flock(fd, LOCK_UN) }
    try require(!FileManager.default.fileExists(atPath: directory.path), "report-directory-must-be-new")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let reportURL = directory.appendingPathComponent("benchmark.json")
    var report: JSONObject = ["schemaVersion": 1, "date": ISO8601DateFormatter().string(from: Date()),
        "decision": "fullNoGo", "qualityStatus": "unverified-manual-review-required", "productCapability": "unavailable",
        "clock": "mach_continuous_time-includes-system-sleep", "noNetworkOrDownload": true,
        "contextColdDefinition": "new helper/model context; operating-system file and shader caches not purged",
        "gates": ["loadSeconds": 45, "generationSeconds": 180, "coldTotalSeconds": 240,
                  "cancelSeconds": 5, "residentAndWorkingBytes": memoryLimit, "previewP95Seconds": 0.25, "previewBaselineMultiplier": 2],
        "operations": [JSONObject](), "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
        "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
        "harnessExecutableSHA256": try hash(URL(fileURLWithPath: CommandLine.arguments[0]))]
    var session: NativeSession?, preview: PreviewProbe?, failure: Error?
    do {
        let fixtures = try verifyInputs()
        report["installation"] = try json(root.appendingPathComponent("evaluation-installation.json"))
        report["allInputAndWeightHashesVerifiedBeforeLoad"] = true
        try writeJSON(report, reportURL)
        let first = fixtures[0], firstMask = (first["masks"] as! [JSONObject])[0]
        var cases: [(String, JSONObject, JSONObject)] = [("cold", first, firstMask)]
        cases += (1...3).map { ("warm-\($0)", first, firstMask) }
        if allFixtures {
            for fixture in fixtures.dropFirst() { for mask in fixture["masks"] as! [JSONObject] {
                cases.append(("\(fixture["id"]!)-\(mask["kind"]!)", fixture, mask))
            } }
        }
        let stamp = UUID().uuidString.lowercased()
        let coldStart = now()
        session = try NativeSession(directory: directory.appendingPathComponent("series-context"))
        let loaded = try session!.operation(["operation": "load", "id": "load", "backend": "metal"], timeout: 45)
        report["load"] = loaded
        try require(loaded["status"] as? String == "success", "load-failed")
        try require(loaded["configurationSHA256"] as? String == configurationSHA, "native-configuration-hash")
        for (index, item) in cases.enumerated() {
            if index == 1 { preview = PreviewProbe(); report["previewBaseline"] = preview!.baseline(); preview!.start() }
            let output = "outputs/\(stamp)-\(item.0).png"
            let request: JSONObject = ["operation": "generate", "id": item.0, "source": item.1["source"]!,
                "mask": item.2["path"]!, "output": output, "prompt": item.1["prompt"]!,
                "negativePrompt": item.1["negativePrompt"]!, "seed": 4281]
            var result = try session!.operation(request, timeout: 180)
            if index == 1 {
                let value = preview!.stop(); report["previewConcurrent"] = value; preview!.release(); preview = nil
                let baseline = report["previewBaseline"] as! JSONObject
                report["previewGatePassed"] = (value["p95Seconds"] as! Double) <= 0.25 &&
                    (value["p95Seconds"] as! Double) <= (baseline["p95Seconds"] as! Double) * 2
            }
            result["request"] = request
            result["fixtureID"] = item.1["id"]!; result["maskKind"] = item.2["kind"]!
            var operations = report["operations"] as! [JSONObject]; operations.append(result); report["operations"] = operations
            try writeJSON(report, reportURL)
            try require(result["status"] as? String == "success", "native-generation-failed")
            let actual = result["nativeConfiguration"] as? JSONObject
            try require(actual?["actualBatchedCFG"] as? Bool == false && actual?["vaeRuntimeBackend"] as? String == "CPU" &&
                actual?["diffusionRuntimeBackend"] as? String == "MTL0", "native-configuration-drift")
            if index == 0 {
                report["coldEndToEndSeconds"] = now() - coldStart
                try require((report["coldEndToEndSeconds"] as! Double) <= 240, "cold-total-gate")
            }
            let caseDirectory = directory.appendingPathComponent("artifacts/\(item.0)")
            try FileManager.default.createDirectory(at: caseDirectory, withIntermediateDirectories: true)
            for (from, to) in [(item.1["source"] as! String, "source.png"), (item.2["path"] as! String, "replace-mask.png"), (output, "raw.png")] {
                try FileManager.default.copyItem(at: root.appendingPathComponent(from), to: caseDirectory.appendingPathComponent(to))
            }
            print("Completed \(index + 1)/\(cases.count): \(item.0); quality requires manual review"); fflush(stdout)
        }
        report["seriesStop"] = session!.stop(); session = nil
        // A fresh process owns cancellation; no canceled context is reused.
        session = try NativeSession(directory: directory.appendingPathComponent("cancel-context"))
        report["cancelLoad"] = try session!.operation(["operation": "load", "id": "load", "backend": "metal"], timeout: 45)
        let cancelOutput = "outputs/\(stamp)-cancel-must-not-publish.png"
        let cancellation = try session!.operation(["operation": "generate", "id": "cancel", "source": first["source"]!,
            "mask": firstMask["path"]!, "output": cancelOutput, "prompt": first["prompt"]!,
            "negativePrompt": first["negativePrompt"]!, "seed": 4281], timeout: 180, cancelAtStep: 2)
        report["cancellation"] = cancellation
        let noOutput = !FileManager.default.fileExists(atPath: root.appendingPathComponent(cancelOutput).path)
        report["cancelNoOutputPublished"] = noOutput
        report["cancelGatePassed"] = noOutput && cancellation["code"] as? String == "cancelled" &&
            (cancellation["cancelLatencyUntilNativeReturnSeconds"] as? Double ?? .infinity) <= 5
        report["cancelStop"] = session!.stop(); session = nil
        try require(report["previewGatePassed"] as? Bool == true, "preview-gate")
        try require(report["cancelGatePassed"] as? Bool == true, "cancel-gate")
        report["status"] = "native-measurements-complete-awaiting-current-compositor-and-visual-review"
    } catch { failure = error; report["status"] = "failed-evidence-retained"; report["failure"] = String(describing: error) }
    if let preview { report["interruptedPreview"] = preview.stop(); preview.release() }
    if let session { report["emergencyStop"] = session.stop() }
    report["allNativeProcessesConfirmedEnded"] = true
    report["inferenceLeaseHeldThroughActualNativeExit"] = true
    report["ownPeakRSSBytes"] = ownPeakRSS()
    try writeJSON(report, reportURL)
    print("REPORT \(reportURL.path)"); fflush(stdout)
    if let failure { throw failure }
}

@main
private struct ImageGenerationEvaluation {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let mode = arguments.first ?? "plan"
        func option(_ name: String) throws -> URL {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--") else { throw Failure.code("missing-\(name)") }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
        }
        switch mode {
        case "plan": print("fullNoGo; fixtures/replay require no models; benchmark requires --run and explicit prior installation")
        case "fixtures":
            let directory = try option("--out")
            let count = try await Task.detached { try ImageGenerationFixtures.write(to: directory).count }.value
            print("Wrote \(count) synthetic contract fixtures without model results")
        case "replay":
            let historical = try option("--historical"), output = try option("--out")
            // Preserve the declared preprocessing when replaying a saved LaMa
            // series. Historical SD-1.5 and LaMa V1 retain their old default.
            var alphaPolicy: ImageGenerationReplay.CandidateAlphaPolicy = .historicalWhiteMatte
            let lamaReport = historical.appendingPathComponent("lama-report.json")
            if FileManager.default.fileExists(atPath: lamaReport.path),
               let version = try json(lamaReport)["preprocessingVersion"] as? Int {
                try require(version == 2, "unsupported-lama-preprocessing-version")
                alphaPolicy = .straightRGB
            }
            _ = try await ImageGenerationReplay.run(historicalRoot: historical, outputRoot: output,
                                                    candidateAlphaPolicy: alphaPolicy)
            print("Current compositor replay: \(output.path)")
        case "lama":
            try require(arguments.contains("--run"), "explicit-run-required")
            let modelRoot = try option("--root"), output = try option("--out")
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let inspect = arguments.contains("--inspect")
            let budget = AIResourceBudget.shared
            let lease = try await budget.acquireLocalInference(residentBytes: Int64(memoryLimit))
            do {
                try await Task.detached { try LaMaEvaluation.run(root: modelRoot, repository: repository, output: output, inspectOnly: inspect) }.value
            } catch { await budget.release(lease); throw error }
            await budget.release(lease)
            if !inspect {
                var report = try json(output.appendingPathComponent("lama-report.json"))
                let ids = (report["runs"] as! [JSONObject]).compactMap { $0["id"] as? String }
                let replay = URL(fileURLWithPath: output.path + "-compositor", isDirectory: true)
                _ = try await ImageGenerationReplay.run(historicalRoot: output, outputRoot: replay, caseIDs: ids,
                                                       candidateAlphaPolicy: .straightRGB)
                report["currentCompositorDirectory"] = replay.lastPathComponent
                report["currentCompositorReportSHA256"] = try hash(replay.appendingPathComponent("current-compositor-report.json"))
                try writeJSON(report, output.appendingPathComponent("lama-report.json"))
            }
        case "benchmark":
            try require(arguments.contains("--run"), "explicit-run-required")
            root = try option("--root")
            let output = try option("--out"), all = arguments.contains("--all-fixtures")
            let budget = AIResourceBudget.shared
            let lease = try await budget.acquireLocalInference(residentBytes: Int64(memoryLimit))
            do { try await Task.detached { try benchmark(directory: output, allFixtures: all) }.value }
            catch { await budget.release(lease); throw error }
            await budget.release(lease)
            // Model timing ends before CPU composition or labeled comparisons.
            // A replay is evidence of preservation, never a second inference.
            var report = try json(output.appendingPathComponent("benchmark.json"))
            let ids = (report["operations"] as! [JSONObject]).compactMap { $0["id"] as? String }
            let replay = URL(fileURLWithPath: output.path + "-compositor", isDirectory: true)
            _ = try await ImageGenerationReplay.run(historicalRoot: output, outputRoot: replay, caseIDs: ids)
            report["currentCompositorDirectory"] = replay.lastPathComponent
            report["currentCompositorReportSHA256"] = try hash(replay.appendingPathComponent("current-compositor-report.json"))
            try writeJSON(report, output.appendingPathComponent("benchmark.json"))
        default: throw Failure.code("unknown-mode")
        }
    }
}
#endif
