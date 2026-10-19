import CoreGraphics
import CoreVideo
import Foundation
import PicEditCore
import Vision

enum DevelopRepairDetectionKind: String, CaseIterable, Identifiable, Sendable {
    case people, dust
    var id: String { rawValue }
}

/// A suggestion, never an applied edit. Masks cover the complete, uncropped
/// source in top-left coordinates and remain small enough for stored strokes.
struct DevelopRepairCandidate: Identifiable, Hashable, Sendable {
    let id: UUID
    let label: String
    let mask: LocalMaskRaster
    let center: LocalMaskPoint
    /// Fraction of the source's shorter edge, matching DevelopRetouchStroke.
    let radius: Double
}

enum DevelopRepairAnalysisError: Error, LocalizedError, Equatable, Sendable {
    case invalidSelection, noSafeSource, noObject, noPeople, noDust, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidSelection: return "Wähle einen gültigen Bereich im Bild aus."
        case .noSafeSource: return "Für diesen Bereich wurde keine ausreichend große, freie Quelle gefunden. Wähle eine Quelle manuell oder verkleinere die Auswahl."
        case .noObject: return "An dieser Stelle wurde kein eindeutiger Gegenstand erkannt. Markiere ihn mit dem Pinsel."
        case .noPeople: return "Es wurden keine Personen erkannt."
        case .noDust: return "Es wurden keine sicheren Staubkandidaten gefunden."
        case .unavailable: return "Die lokale Bilderkennung ist für dieses Bild oder auf diesem Mac nicht verfügbar."
        }
    }
}

/// One bounded worker reuses the already decoded source. Vision uses the shared
/// inference lease until native work actually returns. Small <=512 px analysis
/// stays serial: another pool would compete with Vision and interactive renders.
actor DevelopRepairAnalyzer {
    static let shared = DevelopRepairAnalyzer()
    private let budget: AIResourceBudget
    private var cached: DevelopRepairPixels?

    init(budget: AIResourceBudget = .shared) { self.budget = budget }

    /// Returns an absolute source point for the first point in `path`. The
    /// complete translated selection must fit and avoid every selected pixel.
    func source(for bitmap: PreviewBitmap, path: [LocalMaskPoint], radius: Double,
                mask: LocalMaskRaster? = nil) throws -> LocalMaskPoint {
        try pixels(bitmap).source(path: path, radius: radius, mask: mask)
    }

    func object(in bitmap: PreviewBitmap, at target: LocalMaskPoint,
                path: [LocalMaskPoint] = []) async throws -> DevelopRepairCandidate {
        let pixels = try pixels(bitmap)
        let lease = try await budget.acquireLocalInference(priority: .interactive, residentBytes: 384 * 1_024 * 1_024)
        let cancellation = DevelopRepairVisionCancellation()
        do {
            let result = try await withTaskCancellationHandler {
                try object(pixels, at: target, path: path, cancellation: cancellation)
            } onCancel: { cancellation.cancel() }
            try Task.checkCancellation()
            await budget.release(lease)
            return result
        } catch {
            await budget.release(lease)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw (error as? DevelopRepairAnalysisError) ?? .unavailable
        }
    }

    func candidates(in bitmap: PreviewBitmap, kind: DevelopRepairDetectionKind,
                    sensitivity: Double = 0.5) async throws -> [DevelopRepairCandidate] {
        let pixels = try pixels(bitmap)
        if kind == .dust { return try pixels.dust(sensitivity: sensitivity) }
        let lease = try await budget.acquireLocalInference(priority: .interactive, residentBytes: 384 * 1_024 * 1_024)
        let cancellation = DevelopRepairVisionCancellation()
        do {
            let result = try await withTaskCancellationHandler {
                try people(pixels, cancellation: cancellation)
            } onCancel: { cancellation.cancel() }
            try Task.checkCancellation()
            await budget.release(lease)
            return result
        } catch {
            await budget.release(lease)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw (error as? DevelopRepairAnalysisError) ?? .unavailable
        }
    }

    private func pixels(_ bitmap: PreviewBitmap) throws -> DevelopRepairPixels {
        try Task.checkCancellation()
        if let cached, cached.original.image === bitmap.image { return cached }
        let value = try DevelopRepairPixels(bitmap)
        cached = value
        return value
    }

    private func object(_ pixels: DevelopRepairPixels, at target: LocalMaskPoint, path: [LocalMaskPoint],
                        cancellation: DevelopRepairVisionCancellation) throws -> DevelopRepairCandidate {
        let request = VNGenerateForegroundInstanceMaskRequest()
        request.revision = VNGenerateForegroundInstanceMaskRequestRevision1
        request.preferBackgroundProcessing = true
        try cancellation.register(request)
        let handler = VNImageRequestHandler(cgImage: pixels.image, orientation: .up, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()
        guard let observation = request.results?.first else { throw DevelopRepairAnalysisError.noObject }
        let labels = try Self.instanceLabels(observation.instanceMask)
        guard let instance = DevelopRepairPixels.selectedInstance(labels: labels.bytes, width: labels.width,
            height: labels.height, target: target, path: path), observation.allInstances.contains(instance) else {
            throw DevelopRepairAnalysisError.noObject
        }
        // Request precisely the tapped instance, never all foreground objects.
        let buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler)
        let mask = try Self.smallMask(buffer)
        return try DevelopRepairPixels.candidate(mask: mask, label: "Objekt")
    }

    private func people(_ pixels: DevelopRepairPixels, cancellation: DevelopRepairVisionCancellation) throws -> [DevelopRepairCandidate] {
        let request = VNGeneratePersonInstanceMaskRequest()
        request.revision = VNGeneratePersonInstanceMaskRequestRevision1
        request.preferBackgroundProcessing = true
        try cancellation.register(request)
        let handler = VNImageRequestHandler(cgImage: pixels.image, orientation: .up, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()
        guard let observation = request.results?.first else { throw DevelopRepairAnalysisError.noPeople }
        var result: [DevelopRepairCandidate] = []
        for instance in observation.allInstances.prefix(16) {
            try Task.checkCancellation()
            let buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler)
            let mask = try Self.smallMask(buffer)
            if let candidate = try? DevelopRepairPixels.candidate(mask: mask, label: "Person \(result.count + 1)") {
                result.append(candidate)
            }
        }
        guard !result.isEmpty else { throw DevelopRepairAnalysisError.noPeople }
        return result
    }

    private static func smallMask(_ buffer: CVPixelBuffer) throws -> LocalMaskRaster {
        let raster = try AutomaticMaskRasterConverter.raster(buffer)
        return try DevelopRepairPixels.resizedMask(raster, maximumDimension: 256)
    }

    private static func instanceLabels(_ buffer: CVPixelBuffer) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, width <= 2_048, height <= 2_048,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw DevelopRepairAnalysisError.unavailable
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard stride >= width, let base = CVPixelBufferGetBaseAddress(buffer) else { throw DevelopRepairAnalysisError.unavailable }
        var values = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            if y.isMultiple(of: 16) { try Task.checkCancellation() }
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width { values[y * width + x] = row[x] }
        }
        return (values, width, height)
    }
}

private final class DevelopRepairVisionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var cancelled = false
    func register(_ request: VNRequest) throws {
        lock.lock(); self.request = request; let stopped = cancelled; lock.unlock()
        if stopped { request.cancel(); throw CancellationError() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let request = request; lock.unlock()
        request?.cancel()
    }
}

/// Pure, bounded pixel algorithms are separately testable without model files.
struct DevelopRepairPixels {
    let original: PreviewBitmap
    let image: CGImage
    let width: Int
    let height: Int
    let rgba: [UInt8]
    let luma: [Double]

    init(_ bitmap: PreviewBitmap) throws {
        let source = bitmap.image
        let size = AutomaticMaskRasterConverter.outputSize(width: source.width, height: source.height, maximumDimension: 512)
        let width = size.width, height = size.height
        self.width = width; self.height = height; original = bitmap
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let proxy: CGImage? = bytes.withUnsafeMutableBytes { storage in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.setBlendMode(.copy)
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        guard let proxy else { throw DevelopRepairAnalysisError.unavailable }
        try Task.checkCancellation()
        image = proxy; rgba = bytes
        luma = stride(from: 0, to: bytes.count, by: 4).map { i in
            let alpha = max(1, Double(bytes[i + 3]))
            return (0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])) / alpha
        }
    }

    func source(path: [LocalMaskPoint], radius: Double, mask: LocalMaskRaster?) throws -> LocalMaskPoint {
        try Task.checkCancellation()
        guard let first = path.first, path.count <= 4_096, radius.isFinite, (0.000_001...0.5).contains(radius) else {
            throw DevelopRepairAnalysisError.invalidSelection
        }
        let selected = try selection(path: path, radius: radius, mask: mask)
        let footprint = selected.indices.filter { selected[$0] }
        guard !footprint.isEmpty else { throw DevelopRepairAnalysisError.invalidSelection }
        let xs = footprint.map { $0 % width }, ys = footprint.map { $0 / width }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            throw DevelopRepairAnalysisError.invalidSelection
        }
        // A sampled exterior ring compares structure without the unwanted pixels.
        var ring: [Int] = []
        let margin = max(1, Int((Double(min(width, height)) * radius * 0.4).rounded()))
        let step = max(1, Int(sqrt(Double(footprint.count) / 256)))
        for i in footprint where (i % width).isMultiple(of: step) && (i / width).isMultiple(of: step) {
            let x = i % width, y = i / width
            for (dx, dy) in [(margin, 0), (-margin, 0), (0, margin), (0, -margin)] {
                let xx = x + dx, yy = y + dy
                if xx >= 0, xx < width, yy >= 0, yy < height, !selected[yy * width + xx] { ring.append(yy * width + xx) }
            }
        }
        ring = Array(Set(ring)).sorted()
        if ring.count > 256 { ring = stride(from: 0, to: ring.count, by: (ring.count + 255) / 256).map { ring[$0] } }
        guard !ring.isEmpty else { throw DevelopRepairAnalysisError.noSafeSource }
        let referenceLuma = ring.reduce(0.0) { $0 + sqrt(max(0, luma[$1])) } / Double(ring.count)
        let sourceSamples = stride(from: 0, to: footprint.count, by: max(1, (footprint.count + 127) / 128)).map { footprint[$0] }
        let halfSpan = Double(max(maxX - minX + 1, maxY - minY + 1)) * 0.5
        // A mask candidate's overlay radius may enclose its diagonal; search
        // from its actual footprint rather than overshooting nearby sources.
        let extent = mask == nil ? max(halfSpan, radius * Double(min(width, height))) : halfSpan
        var offsets = Set<PixelOffset>()
        // Elongated masks can have a safe source beside their narrow side even
        // when circular rings around the longer side overshoot the image.
        for shift in [maxX - minX + 1 + 2 * margin, maxX - minX + 1 + margin] {
            offsets.insert(PixelOffset(x: shift, y: 0)); offsets.insert(PixelOffset(x: -shift, y: 0))
        }
        for shift in [maxY - minY + 1 + 2 * margin, maxY - minY + 1 + margin] {
            offsets.insert(PixelOffset(x: 0, y: shift)); offsets.insert(PixelOffset(x: 0, y: -shift))
        }
        for distance in [2.2, 3.0, 4.2] {
            for direction in 0..<24 {
                let a = Double(direction) * .pi / 12
                offsets.insert(PixelOffset(x: Int((cos(a) * extent * distance).rounded()), y: Int((sin(a) * extent * distance).rounded())))
            }
        }
        var best: (cost: Double, offset: PixelOffset)?
        // Sorted offsets and strict comparison give stable ties across runs.
        for offset in offsets.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            try Task.checkCancellation()
            guard minX + offset.x >= 0, maxX + offset.x < width, minY + offset.y >= 0, maxY + offset.y < height else { continue }
            let sourceX = first.x + Double(offset.x) / Double(width), sourceY = first.y + Double(offset.y) / Double(height)
            guard (0...1).contains(sourceX), (0...1).contains(sourceY) else { continue }
            let delta = offset.y * width + offset.x
            guard footprint.allSatisfy({ !selected[$0 + delta] && rgba[($0 + delta) * 4 + 3] >= 250 }) else { continue }
            var cost = 0.0, samples = 0
            for i in ring {
                let x = i % width + offset.x, y = i / width + offset.y
                guard x >= 0, x < width, y >= 0, y < height, !selected[y * width + x] else { continue }
                let j = y * width + x
                for channel in 0..<3 {
                    let a = sqrt(Double(rgba[i * 4 + channel]) / 255), b = sqrt(Double(rgba[j * 4 + channel]) / 255)
                    cost += (a - b) * (a - b)
                }
                samples += 1
            }
            guard samples >= max(4, ring.count * 3 / 4) else { continue }
            cost /= Double(samples)
            // A matching boundary alone could copy another blemish into the
            // hole. Penalize incompatible detail inside the proposed source.
            cost += sourceSamples.reduce(0.0) { total, i in
                let difference = sqrt(max(0, luma[i + delta])) - referenceLuma
                return total + difference * difference
            } / Double(sourceSamples.count) * 0.5
            if cost < (best?.cost ?? .infinity) { best = (cost, offset) }
        }
        guard let best else { throw DevelopRepairAnalysisError.noSafeSource }
        return try LocalMaskPoint(x: first.x + Double(best.offset.x) / Double(width), y: first.y + Double(best.offset.y) / Double(height))
    }

    private struct PixelOffset: Hashable { let x: Int; let y: Int }

    private func selection(path: [LocalMaskPoint], radius: Double, mask: LocalMaskRaster?) throws -> [Bool] {
        if let mask {
            let bytes = [UInt8](mask.bytes)
            return (0..<width * height).map { i in
                let x = min(mask.width - 1, (i % width) * mask.width / width)
                let y = min(mask.height - 1, (i / width) * mask.height / height)
                return bytes[y * mask.width + x] > 8
            }
        }
        var result = [Bool](repeating: false, count: width * height)
        let r = max(1, radius * Double(min(width, height)))
        for index in path.indices {
            if index.isMultiple(of: 16) { try Task.checkCancellation() }
            let a = path[max(0, index - 1)], b = path[index]
            let ax = a.x * Double(width), ay = a.y * Double(height), bx = b.x * Double(width), by = b.y * Double(height)
            let x0 = max(0, Int(floor(min(ax, bx) - r))), x1 = min(width - 1, Int(ceil(max(ax, bx) + r)))
            let y0 = max(0, Int(floor(min(ay, by) - r))), y1 = min(height - 1, Int(ceil(max(ay, by) + r)))
            guard x0 <= x1, y0 <= y1 else { continue }
            let dx = bx - ax, dy = by - ay, length = dx * dx + dy * dy
            for y in y0...y1 {
                for x in x0...x1 {
                    if result[y * width + x] { continue }
                    let px = Double(x) + 0.5, py = Double(y) + 0.5
                    let t = length > 0 ? min(1, max(0, ((px - ax) * dx + (py - ay) * dy) / length)) : 0
                    if hypot(px - ax - t * dx, py - ay - t * dy) <= r { result[y * width + x] = true }
                }
            }
        }
        return result
    }

    static func selectedInstance(labels: [UInt8], width: Int, height: Int,
                                 target: LocalMaskPoint, path: [LocalMaskPoint]) -> Int? {
        guard width > 0, height > 0, width <= 2_048, height <= 2_048, labels.count == width * height else { return nil }
        func value(_ point: LocalMaskPoint) -> Int {
            Int(labels[min(height - 1, Int(point.y * Double(height))) * width + min(width - 1, Int(point.x * Double(width)))])
        }
        let tapped = value(target)
        if tapped != 0 { return tapped }
        var votes: [Int: Int] = [:]
        for point in path.prefix(4_096) { let label = value(point); if label != 0 { votes[label, default: 0] += 1 } }
        return votes.keys.sorted().max { a, b in votes[a, default: 0] < votes[b, default: 0] }
    }

    static func resizedMask(_ mask: LocalMaskRaster, maximumDimension: Int = 256) throws -> LocalMaskRaster {
        let size = AutomaticMaskRasterConverter.outputSize(width: mask.width, height: mask.height, maximumDimension: min(256, max(1, maximumDimension)))
        let input = [UInt8](mask.bytes)
        var bytes = Data(count: size.width * size.height)
        for y in 0..<size.height {
            if y.isMultiple(of: 16) { try Task.checkCancellation() }
            for x in 0..<size.width {
                bytes[y * size.width + x] = input[min(mask.height - 1, y * mask.height / size.height) * mask.width + min(mask.width - 1, x * mask.width / size.width)]
            }
        }
        return try LocalMaskRaster(width: size.width, height: size.height, bytes: bytes)
    }

    static func candidate(mask: LocalMaskRaster, label: String) throws -> DevelopRepairCandidate {
        let mask = try resizedMask(mask)
        let bytes = [UInt8](mask.bytes), indices = mask.bytes.indices.filter { bytes[$0] >= 32 }
        guard !indices.isEmpty else { throw DevelopRepairAnalysisError.noObject }
        let xs = indices.map { $0 % mask.width }, ys = indices.map { $0 / mask.width }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { throw DevelopRepairAnalysisError.noObject }
        let x = Double(xs.reduce(0, +)) / Double(indices.count) + 0.5
        let y = Double(ys.reduce(0, +)) / Double(indices.count) + 0.5
        let center = try LocalMaskPoint(x: x / Double(mask.width), y: y / Double(mask.height))
        let radius = min(0.5, max(0.000_001, hypot(Double(x1 - x0 + 1), Double(y1 - y0 + 1)) / Double(min(mask.width, mask.height)) * 0.5))
        return DevelopRepairCandidate(id: UUID(), label: label, mask: mask, center: center, radius: radius)
    }

    func dust(sensitivity: Double) throws -> [DevelopRepairCandidate] {
        try Task.checkCancellation()
        guard sensitivity.isFinite else { throw DevelopRepairAnalysisError.invalidSelection }
        guard width >= 32, height >= 32 else { throw DevelopRepairAnalysisError.noDust }
        let long = Double(max(width, height))
        let around = try Self.boxBlur(luma, width: width, height: height, radius: max(2, Int(long * 0.012)))
        let detail = zip(luma, around).map { abs($0 - $1) }
        let texture = try Self.boxBlur(detail, width: width, height: height, radius: max(3, Int(long * 0.02)))
        let threshold = 0.03 - 0.022 * min(1, max(0, sensitivity))
        let dark = zip(around, luma).map { max(0, $0 - $1) }
        let flags = (0..<width * height).map { dark[$0] > threshold && dark[$0] > 3 * texture[$0] && luma[$0] > 0.08 && rgba[$0 * 4 + 3] >= 250 }
        var visited = [Bool](repeating: false, count: flags.count)
        var found: [(center: LocalMaskPoint, radius: Double, strength: Double)] = []
        for start in flags.indices where flags[start] && !visited[start] {
            try Task.checkCancellation()
            var stack = [start], members: [Int] = []
            visited[start] = true
            var strength = 0.0
            while let i = stack.popLast() {
                members.append(i); strength = max(strength, dark[i])
                let x = i % width, y = i / width
                for (xx, yy) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where xx >= 0 && xx < width && yy >= 0 && yy < height {
                    let j = yy * width + xx
                    if flags[j], !visited[j] { visited[j] = true; stack.append(j) }
                }
            }
            let xs = members.map { $0 % width }, ys = members.map { $0 / width }
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { continue }
            let bw = Double(x1 - x0 + 1), bh = Double(y1 - y0 + 1), r = max(bw, bh) / 2
            guard r >= 0.0015 * long, r <= 0.02 * long, max(bw, bh) / min(bw, bh) <= 1.8,
                  Double(members.count) >= 0.45 * bw * bh, x0 > 0, y0 > 0, x1 < width - 1, y1 < height - 1 else { continue }
            let cx = (Double(xs.reduce(0, +)) / Double(members.count) + 0.5) / Double(width)
            let cy = (Double(ys.reduce(0, +)) / Double(members.count) + 0.5) / Double(height)
            found.append((try LocalMaskPoint(x: cx, y: cy), r * 1.6 / Double(min(width, height)), strength))
        }
        found.sort { a, b in a.strength == b.strength ? (a.center.y, a.center.x) < (b.center.y, b.center.x) : a.strength > b.strength }
        var candidates: [DevelopRepairCandidate] = []
        let size = AutomaticMaskRasterConverter.outputSize(width: width, height: height, maximumDimension: 256)
        for spot in found.prefix(16) {
            var bytes = Data(count: size.width * size.height)
            let r = spot.radius * Double(min(size.width, size.height))
            for y in 0..<size.height {
                if y.isMultiple(of: 16) { try Task.checkCancellation() }
                for x in 0..<size.width where hypot(Double(x) + 0.5 - spot.center.x * Double(size.width), Double(y) + 0.5 - spot.center.y * Double(size.height)) <= max(1, r) {
                    bytes[y * size.width + x] = 255
                }
            }
            let mask = try LocalMaskRaster(width: size.width, height: size.height, bytes: bytes)
            candidates.append(DevelopRepairCandidate(id: UUID(), label: "Staub \(candidates.count + 1)", mask: mask, center: spot.center, radius: min(0.5, spot.radius)))
        }
        guard !candidates.isEmpty else { throw DevelopRepairAnalysisError.noDust }
        return candidates
    }

    private static func boxBlur(_ input: [Double], width: Int, height: Int, radius: Int) throws -> [Double] {
        var table = [Double](repeating: 0, count: (width + 1) * (height + 1))
        let stride = width + 1
        for y in 0..<height {
            if y.isMultiple(of: 16) { try Task.checkCancellation() }
            var sum = 0.0
            for x in 0..<width { sum += input[y * width + x]; table[(y + 1) * stride + x + 1] = table[y * stride + x + 1] + sum }
        }
        var result = [Double](repeating: 0, count: input.count)
        for y in 0..<height {
            if y.isMultiple(of: 16) { try Task.checkCancellation() }
            let y0 = max(0, y - radius), y1 = min(height, y + radius + 1)
            for x in 0..<width {
                let x0 = max(0, x - radius), x1 = min(width, x + radius + 1)
                result[y * width + x] = (table[y1 * stride + x1] - table[y0 * stride + x1] - table[y1 * stride + x0] + table[y0 * stride + x0]) / Double((x1 - x0) * (y1 - y0))
            }
        }
        return result
    }
}
