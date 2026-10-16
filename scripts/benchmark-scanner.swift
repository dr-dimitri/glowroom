import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Compiled with FolderScanner and LibraryModels by benchmark-scanner.sh.
/// Run the shell wrapper: it creates and cleans up the private fixture directory.
@main
struct ScannerBenchmark {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4, let count = Int(arguments[3]), (1...240).contains(count) else {
            throw failure("Use scripts/benchmark-scanner.sh [IMAGE_COUNT] [PASSES].")
        }
        let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
        if arguments[1] == "prepare", arguments.count == 4 {
            try prepare(root: root, count: count)
            return
        }
        guard arguments[1] == "scan", arguments.count == 6,
              let readers = Int(arguments[4]), [1, 4].contains(readers),
              let passes = Int(arguments[5]), (2...10).contains(passes) else {
            throw failure("Use scripts/benchmark-scanner.sh [IMAGE_COUNT] [PASSES].")
        }
        print("\nRequested readers: \(readers) (scanner CPU/memory caps apply)")
        let scanner = FolderScanner(maximumConcurrentMetadataReads: readers)
        let folder = LibraryFolder(url: root)
        var reference: [PhotoAsset]?
        var durations: [Double] = []
        for index in 0..<passes {
            let start = ContinuousClock.now
            let result = try await scanner.scan(folder: folder)
            let elapsed = start.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            guard result.assets.count == count, result.skippedFiles == 0,
                  result.assets.allSatisfy({ $0.pixelWidth == 6000 && $0.pixelHeight == 4000 }) else {
                throw failure("Scan returned unexpected image count or dimensions.")
            }
            if let reference {
                guard reference == result.assets else { throw failure("Repeated scans returned different metadata.") }
            } else { reference = result.assets }
            durations.append(seconds)
            print("pass \(index + 1)\(index == 0 ? " (first)" : " (warm)"): \(formatted(seconds)) s")
        }
        let warm = durations.dropFirst().sorted()
        let middle = warm.count / 2
        let median = warm.count.isMultiple(of: 2) ? (warm[middle - 1] + warm[middle]) / 2 : warm[middle]
        print("warm median: \(formatted(median)) s; throughput: \(formatted(Double(count) / median)) images/s")
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            print("peak RSS: \(usage.ru_maxrss) bytes (\(formatted(Double(usage.ru_maxrss) / 1_048_576)) MiB)")
        } else {
            print("peak RSS: unavailable")
        }
    }

    private static func prepare(root: URL, count: Int) throws {
        // Refuse existing directories; a directly invoked binary cannot overwrite
        // a user's image collection. The wrapper owns this new temporary directory.
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw failure("Fixture directory must not already exist.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        guard let context = CGContext(data: nil, width: 6000, height: 4000, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw failure("Could not allocate the synthetic image.")
        }
        for row in 0..<400 {
            context.setFillColor(CGColor(red: Double(row % 27) / 27, green: Double(row % 13) / 13,
                                         blue: Double(row % 19) / 19, alpha: 1))
            context.fill(CGRect(x: 0, y: row * 10, width: 6000, height: 10))
        }
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw failure("Could not create the synthetic JPEG.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw failure("JPEG encoding failed.") }
        // Fixture generation is not timed. Reusing one encoded image bounds its
        // memory and CPU cost while each scan still reads independent files.
        for index in 0..<count { try (data as Data).write(to: root.appendingPathComponent("photo\(index).jpg"), options: .withoutOverwriting) }
        print("Prepared \(count) synthetic 6000×4000 JPEGs, \(data.length) bytes each.")
        print("First scans use fresh processes; OS file caches are not flushed. No RAW files are measured.")
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ScannerBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
