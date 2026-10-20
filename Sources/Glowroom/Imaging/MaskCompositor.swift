import CoreGraphics
import CoreImage
import Foundation
import GlowroomCore

/// Immutable, oriented inputs use the same whole-pixel canvas as the Gray8 mask.
/// The output is packed, straight RGBA in the base's SDR profile and bit depth.
/// At weight zero its samples equal the base normalized to that output raster,
/// including otherwise invisible RGB in a straight-alpha source.
enum MaskCompositor {
    enum Backend: Sendable { case automatic, cpu, coreImage, softwareCoreImage }
    enum Failure: LocalizedError, Equatable {
        case incompatibleCanvas, unsupportedRaster, backendUnavailable
        var errorDescription: String? {
            switch self {
            case .incompatibleCanvas: "Basis, Ergebnis und Maske müssen denselben orientierten Bildraum verwenden."
            case .unsupportedRaster: "Die Maskenverarbeitung unterstützt SDR-Bilder in sRGB oder Display P3 mit 8 oder 16 Bit."
            case .backendUnavailable: "Die Bildverarbeitung ist auf diesem Gerät momentan nicht verfügbar. Die bisherige Bildquelle bleibt erhalten."
            }
        }
    }

    /// Nonisolated async work runs off MainActor. The shared artifact codec lane
    /// bounds native work; no additional worker pool or per-stroke GPU work exists.
    static func compose(base: ArtifactRasterInput, candidate: ArtifactRasterInput, mask: MaskRaster,
                        resources: any ArtifactResourceAdmitting, backend: Backend = .automatic) async throws -> ArtifactRasterInput {
        try Task.checkCancellation()
        let baseLayout = try Layout(base.image), candidateLayout = try Layout(candidate.image)
        guard baseLayout.size == candidateLayout.size, baseLayout.size == mask.size else { throw Failure.incompatibleCanvas }
        var keeping: [ArtifactMemoryReservation] = []
        var capabilities: [ObjectIdentifier: (memory: ArtifactMemoryReservation, images: [ObjectIdentifier: Int64])] = [:]
        var unowned: Int64 = 0
        for (input, layout) in [(base, baseLayout), (candidate, candidateLayout)] {
            if let memory = input.memoryOwnership {
                let id = ObjectIdentifier(memory)
                var entry = capabilities[id] ?? (memory, [:])
                entry.images[ObjectIdentifier(input.image)] = layout.nativeBytes
                capabilities[id] = entry
            } else { unowned += layout.nativeBytes }
        }
        // One capability can cover a shared immutable image reference once;
        // distinct image allocations need their combined bytes, as in storage.
        for entry in capabilities.values {
            let bytes = entry.images.values.reduce(Int64(0), +)
            try await resources.validate(entry.memory, minimumBytes: bytes)
            keeping.append(entry.memory)
        }
        let pixels = Int64(mask.size.width) * Int64(mask.size.height)
        var useCI: Bool
        switch backend {
        case .cpu: useCI = false
        case .automatic: useCI = pixels >= 65_536
        case .coreImage, .softwareCoreImage: useCI = true
        }
        // Provider reads can materialize native bytes. CI adds a float readback
        // and conservative half/float texture scratch. This bounds owned phase
        // allocations, as in ArtifactPNGCodec; it is not a process/GPU RSS cap.
        let outputBytes = pixels * Int64(4 * baseLayout.bytesPerComponent)
        let cpuPeak = unowned + baseLayout.nativeBytes + candidateLayout.nativeBytes + outputBytes * 2 + pixels + 65_536
        let phase: ArtifactResourceLease
        do {
            phase = try await resources.acquire(kind: .codec, bytes: cpuPeak + (useCI ? pixels * 64 : 0),
                                                priority: .interactive, retaining: keeping)
        } catch ArtifactResourceError.capacityExceeded where backend == .automatic && useCI {
            // Admission precedes native reads: a legal large SDR raster can fit
            // the equivalent CPU path even when CI texture scratch does not.
            useCI = false
            phase = try await resources.acquire(kind: .codec, bytes: cpuPeak, priority: .interactive, retaining: keeping)
        }
        defer { withExtendedLifetime((phase, keeping, base, candidate, mask)) {} }
        let bytes: Data = try autoreleasepool {
            let source = try Samples(base.image, layout: baseLayout)
            let replacement = try Samples(candidate.image, layout: candidateLayout)
            if useCI {
                do {
                    let linear = try linearComposite(base: base.image, candidate: candidate.image, mask: mask,
                                                     software: backend == .softwareCoreImage)
                    return try encode(source: source, replacement: replacement, mask: mask, linear: linear)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    guard backend == .automatic else { throw Failure.backendUnavailable }
                    // A failed native render has returned before the equivalent
                    // CPU path starts, so its buffers never overlap a new job.
                }
            }
            return try encode(source: source, replacement: replacement, mask: mask, linear: nil)
        }
        try Task.checkCancellation()
        let memory = try await resources.retain(bytes: outputBytes, from: phase)
        let image = try makeImage(bytes: bytes, layout: baseLayout, memory: memory, resources: resources)
        try Task.checkCancellation()
        return ArtifactRasterInput(immutableImage: image, memoryOwnership: memory)
    }

    private enum Profile { case sRGB, displayP3 }
    private struct Layout {
        let size: ArtifactPixelSize
        let bits: Int, components: Int, rowBytes: Int
        let profile: Profile
        let alpha: CGImageAlphaInfo
        let byteOrder: CGBitmapInfo
        let colorSpace: CGColorSpace
        var bytesPerComponent: Int { bits / 8 }
        var maximum: Double { bits == 8 ? 255 : 65_535 }
        var nativeBytes: Int64 { Int64(rowBytes) * Int64(size.height) }
        init(_ image: CGImage) throws {
            size = try ArtifactPixelSize(width: image.width, height: image.height)
            bits = image.bitsPerComponent; alpha = image.alphaInfo
            byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
            guard !image.isMask, !image.bitmapInfo.contains(.floatComponents), image.decode == nil,
                  [8, 16].contains(bits), image.bitsPerPixel % bits == 0,
                  let space = image.colorSpace, space.model == .rgb,
                  let icc = space.copyICCData() else { throw Failure.unsupportedRaster }
            colorSpace = space
            if icc == CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() { profile = .sRGB }
            else if icc == CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() { profile = .displayP3 }
            else { throw Failure.unsupportedRaster }
            components = image.bitsPerPixel / bits; rowBytes = image.bytesPerRow
            guard [3, 4].contains(components), rowBytes >= size.width * components * (bits / 8),
                  rowBytes <= 536_870_912 / size.height,
                  [.none, .noneSkipFirst, .noneSkipLast, .first, .last, .premultipliedFirst, .premultipliedLast].contains(alpha),
                  components == 4 || alpha == .none else { throw Failure.unsupportedRaster }
            if bits == 16 {
                guard byteOrder == .byteOrder16Little || byteOrder == .byteOrder16Big else { throw Failure.unsupportedRaster }
            } else {
                guard byteOrder == [] || byteOrder == .byteOrder32Big || (components == 4 && byteOrder == .byteOrder32Little) else {
                    throw Failure.unsupportedRaster
                }
            }
        }
    }
    private struct Samples {
        let layout: Layout
        let data: CFData
        let pointer: UnsafePointer<UInt8>
        init(_ image: CGImage, layout: Layout) throws {
            guard let data = image.dataProvider?.data, CFDataGetLength(data) >= layout.rowBytes * layout.size.height,
                  let pointer = CFDataGetBytePtr(data) else { throw Failure.unsupportedRaster }
            self.layout = layout; self.data = data; self.pointer = pointer
        }
        func straight(x: Int, y: Int) -> SIMD4<Double> {
            let l = layout, start = y * l.rowBytes + x * l.components * l.bytesPerComponent
            func sample(_ logical: Int) -> Double {
                let channel = l.bits == 8 && l.byteOrder == .byteOrder32Little ? 3 - logical : logical
                let index = start + channel * l.bytesPerComponent
                if l.bits == 8 { return Double(pointer[index]) / l.maximum }
                let value = l.byteOrder == .byteOrder16Little
                    ? UInt16(pointer[index]) | UInt16(pointer[index + 1]) << 8
                    : UInt16(pointer[index]) << 8 | UInt16(pointer[index + 1])
                return Double(value) / l.maximum
            }
            let first = [.first, .premultipliedFirst, .noneSkipFirst].contains(l.alpha)
            let hasAlpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(l.alpha)
            let alpha = hasAlpha ? sample(first ? 0 : 3) : 1
            let index = first ? 1 : 0
            var value = SIMD4(sample(index), sample(index + 1), sample(index + 2), alpha)
            if [.premultipliedFirst, .premultipliedLast].contains(l.alpha) {
                // The fixed straight-alpha output is also the comparison raster
                // for premultiplied input. Hidden premultiplied RGB is undefined.
                for c in 0..<3 { value[c] = alpha > 0 ? min(1, value[c] / alpha) : 0 }
            }
            return value
        }
    }

    private static let blendKernel = CIColorKernel(source: """
        kernel vec4 glowroomMaskBlend(__sample base, __sample candidate, __sample mask) {
            return mix(base, candidate, mask.r);
        }
        """)

    private static func linearComposite(base: CGImage, candidate: CGImage, mask: MaskRaster, software: Bool) throws -> [Float] {
        try Task.checkCancellation()
        guard let kernel = blendKernel,
              let provider = CGDataProvider(data: mask.bytes as CFData),
              let maskImage = CGImage(width: mask.size.width, height: mask.size.height, bitsPerComponent: 8,
                  bitsPerPixel: 8, bytesPerRow: mask.size.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.backendUnavailable }
        let extent = CGRect(x: 0, y: 0, width: mask.size.width, height: mask.size.height)
        // Masks are scalar data: disabling their color space prevents ICC/gamma
        // conversion of weights. CGImage applies the same top-row convention to
        // all three inputs; the one CI y-axis boundary is the flipped readback.
        let weights = CIImage(cgImage: maskImage, options: [.colorSpace: NSNull()])
        guard let graph = kernel.apply(extent: extent, arguments: [CIImage(cgImage: base), CIImage(cgImage: candidate), weights]) else {
            throw Failure.backendUnavailable
        }
        var result = [Float](repeating: .nan, count: mask.size.width * mask.size.height * 4)
        try result.withUnsafeMutableBytes { buffer in
            let destination = CIRenderDestination(bitmapData: buffer.baseAddress!, width: mask.size.width,
                height: mask.size.height, bytesPerRow: mask.size.width * 16, format: .RGBAf)
            destination.colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            destination.alphaMode = .premultiplied
            destination.isFlipped = true
            destination.isDithered = false
            destination.isClamped = false
            let task = try EditRenderer.maskCompositingContext(softwareRenderer: software)
                .startTask(toRender: graph, from: extent, to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
        }
        try Task.checkCancellation()
        guard result.allSatisfy(\.isFinite) else { throw Failure.backendUnavailable }
        return result
    }

    private static func encode(source: Samples, replacement: Samples, mask: MaskRaster, linear: [Float]?) throws -> Data {
        let l = source.layout
        var result = Data(count: l.size.width * l.size.height * 4 * l.bytesPerComponent)
        try result.withUnsafeMutableBytes { output in
            let target = output.bindMemory(to: UInt8.self)
            for y in 0..<l.size.height {
                try Task.checkCancellation()
                for x in 0..<l.size.width {
                    let pixel = y * l.size.width + x, weight = mask.bytes[pixel]
                    let base = source.straight(x: x, y: y)
                    var value: SIMD4<Double>
                    if weight == 0 { value = base }
                    else {
                        let candidate = replacement.straight(x: x, y: y)
                        if weight == 255, replacement.layout.profile == l.profile { value = candidate }
                        else {
                            let amount = Double(weight) / 255
                            var blended: SIMD4<Double>
                            // The shared CI context uses half-float working
                            // samples. Near-transparent 16-bit colors lose
                            // precision before unpremultiplication; correct only
                            // those pixels with the numerical linear reference.
                            // No extra decode, image copy or GPU readback occurs.
                            let exactAlpha = base.w * (1 - amount) + candidate.w * amount
                            if let linear, exactAlpha >= 1.0 / 1_024 {
                                blended = SIMD4(Double(linear[pixel * 4]), Double(linear[pixel * 4 + 1]),
                                                Double(linear[pixel * 4 + 2]), Double(linear[pixel * 4 + 3]))
                            } else {
                                let a = working(base, profile: l.profile)
                                let b = working(candidate, profile: replacement.layout.profile)
                                blended = a * (1 - amount) + b * amount
                            }
                            if blended.w > 0 { for c in 0..<3 { blended[c] /= blended.w } }
                            else {
                                // Fully transparent interpolation has no visible
                                // color. Retain a defined unassociated color,
                                // avoiding an arbitrary black/white matte.
                                let unassociatedBase = working(SIMD4(base.x, base.y, base.z, 1), profile: l.profile)
                                let unassociatedCandidate = working(SIMD4(candidate.x, candidate.y, candidate.z, 1),
                                                                    profile: replacement.layout.profile)
                                for c in 0..<3 { blended[c] = unassociatedBase[c] * (1 - amount) + unassociatedCandidate[c] * amount }
                            }
                            value = encoded(blended, profile: l.profile)
                        }
                    }
                    for channel in 0..<4 {
                        let sample = UInt16((min(1, max(0, value[channel])) * l.maximum).rounded())
                        let index = (pixel * 4 + channel) * l.bytesPerComponent
                        if l.bits == 8 { target[index] = UInt8(sample) }
                        else { target[index] = UInt8(truncatingIfNeeded: sample >> 8); target[index + 1] = UInt8(truncatingIfNeeded: sample) }
                    }
                }
            }
        }
        return result
    }

    /// IEC 61966-2-1 transfer; Display P3 uses the same transfer curve. Matrices
    /// below are D65 linear-sRGB <-> linear-Display-P3 (CSS Color 4 primaries).
    private static func decode(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    private static func encode(_ x: Double) -> Double { x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
    private static func working(_ value: SIMD4<Double>, profile: Profile) -> SIMD4<Double> {
        var rgb = SIMD3(decode(value.x), decode(value.y), decode(value.z))
        if profile == .displayP3 {
            rgb = SIMD3(1.2249401762805598 * rgb.x - 0.2249401762805598 * rgb.y,
                        -0.0420569547096882 * rgb.x + 1.0420569547096882 * rgb.y,
                        -0.0196375545903344 * rgb.x - 0.0786360455506319 * rgb.y + 1.0982736001409663 * rgb.z)
        }
        return SIMD4(rgb.x * value.w, rgb.y * value.w, rgb.z * value.w, value.w)
    }
    private static func encoded(_ value: SIMD4<Double>, profile: Profile) -> SIMD4<Double> {
        var rgb = SIMD3(value.x, value.y, value.z)
        if profile == .displayP3 {
            rgb = SIMD3(0.8224619687143623 * rgb.x + 0.1775380312856377 * rgb.y,
                        0.0331941988509616 * rgb.x + 0.9668058011490384 * rgb.y,
                        0.0170826307211200 * rgb.x + 0.0723974406639634 * rgb.y + 0.9105199286149166 * rgb.z)
        }
        return SIMD4(encode(rgb.x), encode(rgb.y), encode(rgb.z), value.w)
    }

    private final class OutputOwner {
        let bytes: CFData
        let memory: ArtifactMemoryReservation
        let resources: any ArtifactResourceAdmitting
        init(_ bytes: CFData, _ memory: ArtifactMemoryReservation, _ resources: any ArtifactResourceAdmitting) {
            self.bytes = bytes; self.memory = memory; self.resources = resources
        }
    }
    private static func makeImage(bytes: Data, layout: Layout, memory: ArtifactMemoryReservation,
                                  resources: any ArtifactResourceAdmitting) throws -> CGImage {
        let data = bytes as CFData
        guard let pointer = CFDataGetBytePtr(data) else { throw Failure.unsupportedRaster }
        let owner = Unmanaged.passRetained(OutputOwner(data, memory, resources)).toOpaque()
        guard let provider = CGDataProvider(dataInfo: owner, data: pointer, size: CFDataGetLength(data), releaseData: { context, _, _ in
            if let context { Unmanaged<OutputOwner>.fromOpaque(context).release() }
        }) else {
            Unmanaged<OutputOwner>.fromOpaque(owner).release(); throw Failure.unsupportedRaster
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
            .union(layout.bits == 16 ? .byteOrder16Big : [])
        guard let image = CGImage(width: layout.size.width, height: layout.size.height, bitsPerComponent: layout.bits,
            bitsPerPixel: layout.bits * 4, bytesPerRow: layout.size.width * 4 * layout.bytesPerComponent,
            space: layout.colorSpace, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent) else { throw Failure.unsupportedRaster }
        return image
    }
}
