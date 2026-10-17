import CoreGraphics
import CryptoKit
import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers
import zlib

/// The single native codec slot belongs to the injected resource owner. ImageIO
/// calls are synchronous and keep their slot/memory until their actual return.
internal enum ArtifactPNGCodec {
    static let maximumICC = 1_048_576
    static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    static let colorChunks: Set<String> = ["iCCP", "sRGB", "gAMA", "cHRM", "cICP"]
    struct Shape {
        let size: ArtifactPixelSize; let bits: Int; let channels: ArtifactChannels
        let profile: ArtifactColorProfile?; let icc: Data?
        let nativeBytes: Int64; let gray: Bool
        var canonicalBytes: Int64 { Int64(size.width) * Int64(size.height) * Int64(gray ? 1 : channels == .rgba ? 4 : 3) * Int64(bits / 8) }
    }
    static func shape(_ image: CGImage, gray: Bool = false) throws -> Shape {
        let size = try ArtifactPixelSize(width: image.width, height: image.height)
        guard !image.isMask, !image.bitmapInfo.contains(.floatComponents), image.bytesPerRow > 0,
              image.bytesPerRow <= Int.max / image.height else { throw ArtifactContractError.unsupportedFormat }
        let bytes = Int64(image.bytesPerRow * image.height)
        guard bytes <= 536_870_912 else { throw ArtifactContractError.limitExceeded }
        if gray {
            guard image.bitsPerComponent == 8, image.bitsPerPixel == 8, image.alphaInfo == .none,
                  image.colorSpace?.model == .monochrome else { throw ArtifactContractError.unsupportedFormat }
            return Shape(size: size, bits: 8, channels: .rgb, profile: nil, icc: nil, nativeBytes: bytes, gray: true)
        }
        guard [8, 16].contains(image.bitsPerComponent), image.colorSpace?.model == .rgb,
              ![CGImageAlphaInfo.premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo),
              image.bitsPerPixel % image.bitsPerComponent == 0,
              [3, 4].contains(image.bitsPerPixel / image.bitsPerComponent),
              let icc = image.colorSpace?.copyICCData() as Data?, !icc.isEmpty, icc.count <= maximumICC else { throw ArtifactContractError.unsupportedFormat }
        let channels: ArtifactChannels = [.first, .last].contains(image.alphaInfo) ? .rgba : .rgb
        guard channels != .rgba || image.bitsPerPixel / image.bitsPerComponent == 4 else { throw ArtifactContractError.unsupportedFormat }
        var selected: ArtifactColorProfile?
        for (name, profile) in [(CGColorSpace.sRGB, ArtifactColorProfile.sRGB), (CGColorSpace.displayP3, .displayP3)] {
            if let standard = CGColorSpace(name: name)?.copyICCData(), standard as Data == icc { selected = profile }
        }
        guard let selected else { throw ArtifactContractError.unsupportedFormat }
        return Shape(size: size, bits: image.bitsPerComponent, channels: channels, profile: selected, icc: icc, nativeBytes: bytes, gray: false)
    }
    static func pixelHash(_ image: CGImage, shape: Shape) throws -> ArtifactDigest {
        guard let providerData = image.dataProvider?.data else { throw ArtifactContractError.unsupportedFormat }
        let bytes = providerData as Data
        guard bytes.count >= image.bytesPerRow * image.height else { throw ArtifactContractError.corruptArtifact }
        let components = image.bitsPerPixel / image.bitsPerComponent
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        if shape.bits == 16 { guard order == .byteOrder16Little || order == .byteOrder16Big else { throw ArtifactContractError.unsupportedFormat } }
        if shape.bits == 8 { guard order == [] || order == .byteOrder32Big || (components == 4 && order == .byteOrder32Little) else { throw ArtifactContractError.unsupportedFormat } }
        let indices: [Int]
        if shape.gray { indices = [0] }
        else if image.alphaInfo == .first { indices = [1, 2, 3, 0] }
        else if image.alphaInfo == .noneSkipFirst { indices = [1, 2, 3] }
        else { indices = shape.channels == .rgba ? [0, 1, 2, 3] : [0, 1, 2] }
        guard indices.allSatisfy({ $0 < components }) else { throw ArtifactContractError.unsupportedFormat }
        var hash = SHA256()
        hash.update(data: Data("PicEdit.CanonicalSamples.v1/\(image.width)/\(image.height)/\(shape.bits)/\(shape.gray ? "gray" : shape.channels.rawValue)\n".utf8))
        var block = Data(); block.reserveCapacity(65_536)
        for y in 0..<image.height {
            try Task.checkCancellation()
            for x in 0..<image.width { for logical in indices {
                let channel = shape.bits == 8 && order == .byteOrder32Little ? 3 - logical : logical
                let offset = y * image.bytesPerRow + (x * components + channel) * shape.bits / 8
                if shape.bits == 8 { block.append(bytes[offset]) }
                else if order == .byteOrder16Little { block.append(bytes[offset + 1]); block.append(bytes[offset]) }
                else { block.append(bytes[offset]); block.append(bytes[offset + 1]) }
                if block.count >= 65_536 { hash.update(data: block); block.removeAll(keepingCapacity: true) }
            } }
        }
        if !block.isEmpty { hash.update(data: block) }; return try ArtifactFileIO.digest(hash.finalize())
    }
    /// ImageIO may decode RGB8 into four native lanes (noneSkipLast). Charge
    /// native rows, not only three canonical RGB samples. Metadata is checked
    /// before provider.data forces samples; no held slot grows its reservation.
    static func decodedByteLimit(size: ArtifactPixelSize, bits: Int, gray: Bool) -> Int64 {
        let row = Int64(size.width) * Int64(gray ? 1 : 4) * Int64(bits / 8)
        return ((row + 255) / 256 * 256) * Int64(size.height)
    }
    static func encode(_ image: CGImage, gray: Bool, directory: ArtifactDirectory, name: String,
                       resources: any ArtifactResourceAdmitting, retaining: [ArtifactMemoryReservation]) async throws -> (Shape, ArtifactFileDescriptor) {
        let input = try shape(image, gray: gray)
        let decodedLimit = decodedByteLimit(size: input.size, bits: input.bits, gray: gray)
        let scratch = input.nativeBytes + decodedLimit * 2 + 4_194_304
        let allocation = try await resources.acquire(kind: .retainedMemory, bytes: scratch + 65_536, priority: .interactive, retaining: retaining)
        let memory = try await resources.retain(bytes: scratch + 65_536, from: allocation)
        let kept = retaining + [memory]
        let codec = try await resources.acquire(kind: .codec, bytes: 0, priority: .interactive, retaining: kept)
        let transfer = try await resources.acquire(kind: .transfer, bytes: 0, priority: .interactive, retaining: kept)
        defer { withExtendedLifetime((allocation, memory, transfer, codec, retaining, image)) {} }
        return try autoreleasepool {
            try Task.checkCancellation()
            let originalName = name + ".imageio"
            let native = try ArtifactFileIO.create(directory, originalName)
            defer { ArtifactFileIO.removeOwnedFile(directory, originalName, fd: native) }
            let writer = ArtifactNativeWriter(native)
            let consumer = try writer.consumer()
            guard let destination = CGImageDestinationCreateWithDataConsumer(consumer, UTType.png.identifier as CFString, 1, nil) else { throw ArtifactContractError.unsupportedFormat }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { try writer.check(); throw ArtifactContractError.unsupportedFormat }
            try writer.check(); guard fsync(native.value) == 0 else { throw ArtifactFileIO.failure("PNG synchronisieren") }
            let original = try ArtifactPinnedFile(fd: native, directory: directory, leaf: originalName)
            let final = try ArtifactFileIO.create(directory, name)
            do {
                try rewrite(original, output: final, icc: input.icc)
                guard fsync(final.value) == 0 else { throw ArtifactFileIO.failure("ICC-PNG synchronisieren") }
                let checked = try ArtifactPinnedFile(fd: final, directory: directory, leaf: name)
                let decoded = try decode(checked)
                let output = try shape(decoded, gray: gray)
                guard output.nativeBytes <= decodedLimit else { throw ArtifactContractError.limitExceeded }
                guard output.size == input.size, output.bits == input.bits, output.channels == input.channels,
                      output.icc == input.icc, try pixelHash(image, shape: input) == pixelHash(decoded, shape: output) else { throw ArtifactContractError.corruptArtifact }
                let profile = try inspect(checked)
                guard profile.width == input.size.width, profile.height == input.size.height,
                      profile.bits == input.bits, profile.type == (gray ? 0 : input.channels == .rgba ? 6 : 2), profile.icc == input.icc else { throw ArtifactContractError.corruptArtifact }
                let descriptor = try ArtifactFileDescriptor(sha256: checked.digest(), bytes: checked.stamp.bytes)
                return (input, descriptor)
            } catch { ArtifactFileIO.removeOwnedFile(directory, name, fd: final); throw error }
        }
    }
    static func validate(_ file: ArtifactPinnedFile, raster: RasterDescriptor, resources: any ArtifactResourceAdmitting) async throws {
        try validateFormat(raster.format)
        let raw = decodedByteLimit(size: raster.format.size, bits: raster.format.bitDepth.rawValue, gray: false)
        let allocation = try await resources.acquire(kind: .retainedMemory, bytes: raw * 2 + 4_259_840, priority: .interactive, retaining: [])
        let memory = try await resources.retain(bytes: raw * 2 + 4_259_840, from: allocation)
        let lease = try await resources.acquire(kind: .codec, bytes: 0, priority: .interactive, retaining: [memory])
        let transfer = try await resources.acquire(kind: .transfer, bytes: 0, priority: .interactive, retaining: [memory])
        defer { withExtendedLifetime((allocation, memory, lease, transfer)) {} }
        try autoreleasepool {
            let structure = try inspect(file)
            guard structure.width == raster.format.size.width, structure.height == raster.format.size.height,
                  structure.bits == raster.format.bitDepth.rawValue,
                  structure.type == (raster.format.channels == .rgba ? 6 : 2),
                  let icc = structure.icc, try ArtifactFileIO.digest(icc) == raster.format.iccSHA256 else { throw ArtifactContractError.corruptArtifact }
            let image = try decode(file); let info = try shape(image)
            guard info.nativeBytes <= raw else { throw ArtifactContractError.limitExceeded }
            guard info.size == raster.format.size, info.bits == raster.format.bitDepth.rawValue,
                  info.channels == raster.format.channels, info.profile == raster.format.profile,
                  info.icc == icc else { throw ArtifactContractError.corruptArtifact }
            _ = try pixelHash(image, shape: info) // Force full native decode while the slot/bytes are held.
        }
    }
    static func validateMask(_ file: ArtifactPinnedFile, descriptor: ArtifactMaskDescriptor, resources: any ArtifactResourceAdmitting,
                             binding: GenerationMaskBinding? = nil) async throws {
        let raw = decodedByteLimit(size: descriptor.size, bits: 8, gray: true)
        let peak = raw * (binding == nil ? 2 : 3) + 4_259_840
        let allocation = try await resources.acquire(kind: .retainedMemory, bytes: peak, priority: .background, retaining: [])
        let memory = try await resources.retain(bytes: peak, from: allocation)
        let lease = try await resources.acquire(kind: .codec, bytes: 0, priority: .background, retaining: [memory])
        let transfer = try await resources.acquire(kind: .transfer, bytes: 0, priority: .background, retaining: [memory])
        defer { withExtendedLifetime((allocation, memory, lease, transfer)) {} }
        try autoreleasepool {
            let structure = try inspect(file)
            guard structure.width == descriptor.size.width, structure.height == descriptor.size.height,
                  structure.bits == 8, structure.type == 0, structure.icc == nil else { throw ArtifactContractError.corruptArtifact }
            let image = try decode(file); let info = try shape(image, gray: true)
            guard info.nativeBytes <= raw else { throw ArtifactContractError.limitExceeded }
            guard info.size == descriptor.size else { throw ArtifactContractError.corruptArtifact }
            _ = try pixelHash(image, shape: info)
            if let binding { try MaskPayloadValidation.raster(image, binding: binding) }
        }
    }
    static func validateFormat(_ f: ArtifactRasterFormat) throws {
        guard f.schemaVersion == 1, f.orientation == .up, f.alpha == (f.channels == .rgba ? .straight : .none) else { throw ArtifactContractError.corruptArtifact }
        _ = try ArtifactPixelSize(width: f.size.width, height: f.size.height)
    }
    static func decode(_ file: ArtifactPinnedFile) throws -> CGImage {
        guard let source = CGImageSourceCreateWithDataProvider(try file.provider(), [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw ArtifactContractError.corruptArtifact }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let orientation = properties[kCGImagePropertyOrientation] as? NSNumber, orientation.intValue != 1 {
            throw ArtifactContractError.corruptArtifact
        }
        try file.validate(); return image
    }
    struct PNGInfo { let width: Int; let height: Int; let bits: Int; let type: Int; let icc: Data? }
    static func read(_ file: ArtifactPinnedFile, at offset: Int64, count: Int) throws -> Data {
        guard count >= 0, count <= 2_097_152, Int64(count) <= file.stamp.bytes - offset else { throw ArtifactContractError.corruptArtifact }
        var result = Data(); var cursor = offset
        while result.count < count { let part = try file.read(offset: cursor, count: min(65_536, count - result.count)); guard !part.isEmpty else { throw ArtifactContractError.corruptArtifact }; result.append(part); cursor += Int64(part.count) }; return result
    }
    static func u32(_ data: Data, at i: Int) -> UInt32 { data[i..<i + 4].reduce(0) { ($0 << 8) | UInt32($1) } }
    static func big32(_ value: UInt32) -> Data { Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
    static func checksum(_ bytes: Data, previous: uLong = 0) -> uLong { bytes.withUnsafeBytes { crc32(previous, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)) } }
    static func chunk(_ type: String, _ data: Data) -> Data {
        let name = Data(type.utf8); return big32(UInt32(data.count)) + name + data + big32(UInt32(checksum(data, previous: checksum(name))))
    }
    static func deflate(_ icc: Data) throws -> Data {
        guard !icc.isEmpty, icc.count <= maximumICC else { throw ArtifactContractError.unsupportedFormat }
        var count = compressBound(uLong(icc.count)); guard count <= maximumICC * 2 else { throw ArtifactContractError.limitExceeded }
        var result = Data(count: Int(count))
        let status = result.withUnsafeMutableBytes { target in icc.withUnsafeBytes { input in
            compress2(target.bindMemory(to: Bytef.self).baseAddress!, &count, input.bindMemory(to: Bytef.self).baseAddress!, uLong(icc.count), Z_BEST_COMPRESSION)
        } }
        guard status == Z_OK else { throw ArtifactContractError.unsupportedFormat }; result.count = Int(count); return result
    }
    static func inflate(_ body: Data) throws -> Data {
        guard let nul = body.firstIndex(of: 0), (1...79).contains(nul), nul + 2 < body.count, body[nul + 1] == 0 else { throw ArtifactContractError.corruptArtifact }
        let compressed = body.subdata(in: nul + 2..<body.count)
        var count = uLongf(maximumICC); var result = Data(count: maximumICC)
        let status = result.withUnsafeMutableBytes { target in compressed.withUnsafeBytes { input in
            uncompress(target.bindMemory(to: Bytef.self).baseAddress!, &count, input.bindMemory(to: Bytef.self).baseAddress!, uLong(compressed.count))
        } }
        guard status == Z_OK, count > 0, count <= maximumICC else { throw ArtifactContractError.corruptArtifact }; result.count = Int(count); return result
    }
    static func walk(_ file: ArtifactPinnedFile, visit: (String, Int64, Int) throws -> Void) throws {
        guard try read(file, at: 0, count: 8) == signature else { throw ArtifactContractError.corruptArtifact }
        var offset: Int64 = 8; var count = 0; var ended = false; var dataSeen = false
        while offset < file.stamp.bytes {
            try Task.checkCancellation(); guard !ended, file.stamp.bytes - offset >= 12, count < 65_536 else { throw ArtifactContractError.corruptArtifact }
            let header = try read(file, at: offset, count: 8); let length = Int(u32(header, at: 0))
            guard Int64(length) <= file.stamp.bytes - offset - 12 else { throw ArtifactContractError.corruptArtifact }
            let name = header.subdata(in: 4..<8)
            guard name.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else { throw ArtifactContractError.corruptArtifact }
            let type = String(decoding: name, as: UTF8.self)
            guard (count == 0) == (type == "IHDR") else { throw ArtifactContractError.corruptArtifact }
            var check = checksum(name); var cursor = offset + 8; var left = length
            while left > 0 { let block = try read(file, at: cursor, count: min(left, 65_536)); check = checksum(block, previous: check); cursor += Int64(block.count); left -= block.count }
            guard UInt32(check) == u32(try read(file, at: cursor, count: 4), at: 0) else { throw ArtifactContractError.corruptArtifact }
            if type == "IDAT" { dataSeen = true }
            if type == "IEND" { guard length == 0 && dataSeen else { throw ArtifactContractError.corruptArtifact }; ended = true }
            try visit(type, offset + 8, length); offset += Int64(length) + 12; count += 1
        }
        guard ended else { throw ArtifactContractError.corruptArtifact }; try file.validate()
    }
    static func rewrite(_ file: ArtifactPinnedFile, output: ArtifactNativeFD, icc: Data?) throws {
        try ArtifactFileIO.writeAll(output.value, signature)
        var seenHeader = false
        try walk(file) { type, offset, length in
            if colorChunks.contains(type) { return }
            var cursor = offset - 8; var left = length + 12
            while left > 0 { let part = try read(file, at: cursor, count: min(left, 65_536)); try ArtifactFileIO.writeAll(output.value, part); cursor += Int64(part.count); left -= part.count }
            if type == "IHDR" {
                guard !seenHeader, length == 13 else { throw ArtifactContractError.corruptArtifact }; seenHeader = true
                if let icc { var body = Data("PicEdit ICC".utf8); body.append(0); body.append(0); body.append(try deflate(icc)); try ArtifactFileIO.writeAll(output.value, chunk("iCCP", body)) }
            }
        }
    }
    static func inspect(_ file: ArtifactPinnedFile) throws -> PNGInfo {
        var header: Data?; var icc: Data?; var profileSeen = false; var dataSeen = false; var paletteSeen = false
        try walk(file) { type, offset, length in
            if type == "IHDR" { guard length == 13 else { throw ArtifactContractError.corruptArtifact }; header = try read(file, at: offset, count: length) }
            if type == "PLTE" { paletteSeen = true }
            if type == "IDAT" { dataSeen = true }
            if type == "iCCP" {
                guard !profileSeen, !dataSeen, !paletteSeen, length <= maximumICC * 2 else { throw ArtifactContractError.corruptArtifact }
                profileSeen = true; icc = try inflate(read(file, at: offset, count: length))
            } else if colorChunks.contains(type) { throw ArtifactContractError.corruptArtifact }
        }
        guard let header, header[10] == 0, header[11] == 0, header[12] == 0 else { throw ArtifactContractError.corruptArtifact }
        let width = Int(u32(header, at: 0)); let height = Int(u32(header, at: 4)); _ = try ArtifactPixelSize(width: width, height: height)
        return PNGInfo(width: width, height: height, bits: Int(header[8]), type: Int(header[9]), icc: icc)
    }
}
