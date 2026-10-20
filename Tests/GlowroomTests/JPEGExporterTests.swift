import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import GlowroomCore
import Testing
import UniformTypeIdentifiers
@testable import Glowroom

@Suite("JPEG export", .serialized)
struct JPEGExporterTests {
    @Test func cropAndClockwiseRotationDetermineExportDimensionsBeforeResizing() async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "crop-source.png", width: 128, height: 96) { x, y in
                (UInt8(x + 30), UInt8(y + 40), 90, 255)
            }
            let before = try Data(contentsOf: source)
            let geometry = DevelopGeometry(crop: try .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5), quarterTurns: 1)
            let settings = EditSettings(exposure: 0.2, developGeometry: geometry)
            for mode in [JPEGExportSizeMode.original, .longEdge] {
                let target = directory.appendingPathComponent("crop-\(mode.rawValue).jpg")
                let result = try await JPEGExporter().export(.init(sourceURL: source, destinationURL: target,
                    settings: settings, options: .init(quality: 100, sizeMode: mode, longEdge: 32)))
                #expect(result.width == (mode == .original ? 48 : 24))
                #expect(result.height == (mode == .original ? 64 : 32))
                let output = try decode(target)
                #expect(output.width == result.width && output.height == result.height)
                if mode == .original {
                    let expected = try pixels(EditRenderer.render(.init(image: decode(source)), settings: settings).image)
                    #expect(meanDifference(expected, try pixels(output)) < 3)
                }
            }
            #expect(try Data(contentsOf: source) == before)
        }
    }

    @Test func heifHDRIsReallyTenBitHLGAndRetainsValuesAboveSDRWhite() async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "hdr-source.png", width: 96, height: 64) { _, _ in (180, 180, 180, 255) }
            let before = try Data(contentsOf: source)
            let target = directory.appendingPathComponent("real-hdr.heic")
            var settings = EditSettings(exposure: 2)
            settings.developColor.hdrEnabled = true
            let result = try await JPEGExporter().export(.init(sourceURL: source, destinationURL: target,
                settings: settings, options: .init(format: .heif10HDR, quality: 100)))
            #expect(result.width == 96 && result.height == 64)
            let metadata = try properties(target)
            #expect((metadata[kCGImagePropertyDepth] as? NSNumber)?.intValue == 10)
            let imageSource = try #require(CGImageSourceCreateWithURL(target as CFURL, nil))
            let ordinary = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            let space = try #require(ordinary.colorSpace)
            #expect(CGColorSpaceUsesITUR_2100TF(space))
            let decodedHDR = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, [
                kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
                kCGImageSourceShouldAllowFloat: true,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary))
            var rgba = [Float](repeating: 0, count: 96 * 64 * 4)
            let linear = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
            rgba.withUnsafeMutableBytes { bytes in
                EditRenderer.maskCompositingContext().render(CIImage(cgImage: decodedHDR), toBitmap: bytes.baseAddress!,
                    rowBytes: 96 * 4 * MemoryLayout<Float>.size, bounds: CGRect(x: 0, y: 0, width: 96, height: 64),
                    format: .RGBAf, colorSpace: linear)
            }
            #expect(rgba[(32 * 96 + 48) * 4] > 1.1, "HDR output must preserve light beyond SDR reference white, rather than only changing its label")
            #expect(try Data(contentsOf: source) == before)
            #expect(try temporaryOutputs(in: directory).isEmpty)
        }
    }

    @Test(arguments: JPEGExportFormat.allCases)
    func everyFormatPreservesOriginalsAndExistingTargetsAfterEncodingFailure(format: JPEGExportFormat) async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "protected.png")
            let sourceBytes = try Data(contentsOf: source)
            let target = directory.appendingPathComponent("keep.\(format.fileExtension)")
            let existing = Data("preserve-existing".utf8)
            try existing.write(to: target)
            let exporter = JPEGExporter(beforePublication: { throw PublicationFailure.injected })
            await #expect(throws: PublicationFailure.injected) {
                try await exporter.export(.init(sourceURL: source, destinationURL: target, settings: .neutral,
                    options: .init(format: format), overwriteExisting: true))
            }
            #expect(try Data(contentsOf: target) == existing)
            #expect(try Data(contentsOf: source) == sourceBytes)
            #expect(try temporaryOutputs(in: directory).isEmpty)
            await #expect(throws: JPEGExportError.protectedOriginal) {
                try await JPEGExporter().export(.init(sourceURL: source, destinationURL: source, settings: .neutral,
                    options: .init(format: format), overwriteExisting: true))
            }
        }
    }

    @Test func fullResolutionBeyondPreviewLimitDeclaresSRGBAndDPI() async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "original.png", width: 5_000, height: 40)
            let before = try Data(contentsOf: source)
            let target = directory.appendingPathComponent("full.jpg")
            let result = try await JPEGExporter().export(.init(sourceURL: source, destinationURL: target,
                settings: EditSettings(exposure: 0.3), options: .init(pixelsPerInch: 144)))
            #expect(result == JPEGExportResult(url: target, width: 5_000, height: 40))
            let output = try decode(target)
            #expect(output.width == 5_000 && output.height == 40)
            #expect(output.colorSpace?.name == CGColorSpace.sRGB)
            let metadata = try properties(target)
            #expect(abs(((metadata[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 0) - 144) < 0.1)
            #expect(abs(((metadata[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 0) - 144) < 0.1)
            let exif = try #require(metadata[kCGImagePropertyExifDictionary] as? [CFString: Any])
            #expect((exif[kCGImagePropertyExifColorSpace] as? NSNumber)?.intValue == 1)
            #expect(try Data(contentsOf: source) == before)
            #expect(try temporaryOutputs(in: directory).isEmpty)
        }
    }

    @Test func orientationIsAppliedOnceAndSizingUsesOrientedDimensions() async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "rotated.jpg", width: 120, height: 80,
                                     orientation: 6, type: .jpeg) { x, _ in
                x < 60 ? (220, 30, 20, 255) : (20, 30, 220, 255)
            }
            let target = directory.appendingPathComponent("upright.jpg")
            let result = try await JPEGExporter().export(.init(sourceURL: source, destinationURL: target,
                settings: .neutral, options: .init(quality: 100, sizeMode: .longEdge, longEdge: 60)))
            #expect(result.width == 40 && result.height == 60)
            let metadata = try properties(target)
            #expect(((metadata[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) == 1)
            let output = try pixels(decode(target))
            let top = (10 * 40 + 20) * 4
            let bottom = (50 * 40 + 20) * 4
            #expect(output[top] > 180 && output[top + 2] < 70)
            #expect(output[bottom] < 70 && output[bottom + 2] > 180)
        }
    }

    @Test func profilesConvertActualPixelsAndTransparencyBecomesWhite() async throws {
        try await withDirectory { directory in
            let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
            let source = try fixture(directory, name: "wide.png", width: 96, height: 48, colorSpace: p3) { x, _ in
                (190, 100, 70, x < 32 ? 0 : 255)
            }
            let original = try decode(source)
            let expectedSRGB = try pixels(original, space: CGColorSpace(name: CGColorSpace.sRGB))
            var encoded: [[UInt8]] = []
            for profile in JPEGExportColorSpace.allCases {
                let target = directory.appendingPathComponent("\(profile.rawValue).jpg")
                _ = try await JPEGExporter().export(.init(sourceURL: source, destinationURL: target,
                    settings: .neutral, options: .init(colorSpace: profile, quality: 100)))
                let output = try decode(target)
                let expectedName = profile == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3
                #expect(output.colorSpace?.name == expectedName)
                if profile == .displayP3 {
                    #expect(try Data(contentsOf: target).range(of: Data("ICC_PROFILE".utf8)) != nil)
                } else {
                    let exif = try #require(properties(target)[kCGImagePropertyExifDictionary] as? [CFString: Any])
                    #expect((exif[kCGImagePropertyExifColorSpace] as? NSNumber)?.intValue == 1)
                }
                let values = try pixels(output)
                let transparent = (24 * 96 + 12) * 4
                #expect(values[transparent] > 250 && values[transparent + 1] > 250 && values[transparent + 2] > 250)
                encoded.append(values)
            }
            let opaque = (24 * 96 + 80) * 4
            let difference = (0..<3).reduce(0) { $0 + abs(Int(encoded[0][opaque + $1]) - Int(encoded[1][opaque + $1])) }
            #expect(difference > 10, "Profile selection must convert channel values, not only relabel the image")
            for channel in 0..<3 {
                #expect(abs(Int(encoded[0][opaque + channel]) - Int(expectedSRGB[opaque + channel])) <= 3)
            }
        }
    }

    @Test func savedEditsUseTheSameGraphAsThePreview() async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "edited.png", width: 128, height: 96)
            let original = try decode(source)
            var settings = EditSettings.neutral
            settings.exposure = 0.7
            settings.autoToneAmount = 30
            settings.texture = 20
            settings.clarity = 15
            settings.colorNoiseReduction = 30
            settings.localAdjustments = [try LocalAdjustment(name: "Local gradient", mask: .init(shape: .linear(
                start: .init(x: 0.15, y: 0.2), end: .init(x: 0.8, y: 0.7))),
                settings: .init(exposure: -0.4, clarity: 25, saturation: -45))]
            let expected = try pixels(EditRenderer.render(PreviewBitmap(image: original), settings: settings).image)
            let target = directory.appendingPathComponent("edited.jpg")
            _ = try await JPEGExporter().export(.init(sourceURL: source, destinationURL: target,
                settings: settings, options: .init(quality: 100)))
            let output = try pixels(decode(target))
            #expect(meanDifference(expected, output) < 3, "JPEG quantization may differ; the underlying edit graph must agree")
            #expect(meanDifference(try pixels(original), output) > 10)
        }
    }

    @Test func localMaskCoordinatesApplyToTheFullResolutionExport() async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "local-original.png", width: 5_000, height: 40) { _, _ in
                (80, 80, 80, 255)
            }
            var settings = EditSettings.neutral
            settings.localAdjustments = [try LocalAdjustment(name: "Left half", mask: .init(shape: .linear(
                start: .init(x: 0.25, y: 0.5), end: .init(x: 0.75, y: 0.5)), feather: 0),
                settings: .init(exposure: 1))]
            let target = directory.appendingPathComponent("local-full.jpg")
            _ = try await JPEGExporter().export(.init(sourceURL: source, destinationURL: target,
                settings: settings, options: .init(quality: 100)))
            let image = try decode(target)
            #expect(image.width == 5_000 && image.height == 40)
            let values = try pixels(image)
            #expect(values[(20 * 5_000 + 100) * 4] > 105)
            #expect(abs(Int(values[(20 * 5_000 + 4_900) * 4]) - 80) <= 2)
        }
    }

    @Test func qualityAffectsCompressionAndPixelError() async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "texture.png", width: 256, height: 192) { x, y in
                let noise = (x * 13 + y * 37) % 61
                return (UInt8((x + noise) % 256), UInt8((y + noise) % 256), UInt8((x + y + noise) % 256), 255)
            }
            let original = try pixels(decode(source))
            var sizes: [Int] = []
            var differences: [Double] = []
            for quality in [10, 100] {
                let target = directory.appendingPathComponent("q\(quality).jpg")
                _ = try await JPEGExporter().export(.init(sourceURL: source, destinationURL: target,
                    settings: .neutral, options: .init(quality: quality)))
                sizes.append(try Data(contentsOf: target).count)
                differences.append(meanDifference(original, try pixels(decode(target))))
            }
            #expect(sizes[1] > sizes[0] * 2)
            #expect(differences[1] < differences[0])
        }
    }

    @Test func naturalBalanceExportMatchesPreviewForBothOutputProfiles() async throws {
        try await withDirectory { directory in
            let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
            let source = try fixture(directory, name: "natural.png", width: 192, height: 128, colorSpace: p3) { x, y in
                let gray = 12 + x * 230 / 191
                return (UInt8(min(250, gray + y / 8)), UInt8(gray), UInt8(max(5, gray - y / 10)), 255)
            }
            let original = try decode(source)
            var settings = EditSettings.neutral
            settings.naturalBalanceAmount = 70
            settings.naturalBalanceColorAmount = 50
            settings.autoToneAmount = 90 // The same precedence rule applies to full-resolution exports.
            settings.exposure = 0.1
            let rendered = try EditRenderer.render(PreviewBitmap(image: original), settings: settings)
            for profile in JPEGExportColorSpace.allCases {
                let space = try #require(CGColorSpace(name: profile == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3))
                let expected = try pixels(rendered.image, space: space)
                let target = directory.appendingPathComponent("natural-\(profile.rawValue).jpg")
                _ = try await JPEGExporter().export(.init(sourceURL: source, destinationURL: target,
                    settings: settings, options: .init(colorSpace: profile, quality: 100)))
                let exported = try decode(target)
                #expect(exported.colorSpace?.name == space.name)
                #expect(meanDifference(expected, try pixels(exported, space: space)) < 3,
                        "Natural balance must use the same graph in preview and JPEG export")
            }
        }
    }

    @Test func overwriteRequiresApprovalAndNeverChangesTheOriginal() async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "original.png")
            let original = try Data(contentsOf: source)
            let target = directory.appendingPathComponent("existing.jpg")
            let existing = Data("existing destination".utf8)
            try existing.write(to: target)
            let exporter = JPEGExporter()
            await #expect(throws: JPEGExportError.destinationExists) {
                try await exporter.export(.init(sourceURL: source, destinationURL: target, settings: .neutral, options: .init()))
            }
            #expect(try Data(contentsOf: target) == existing)
            _ = try await exporter.export(.init(sourceURL: source, destinationURL: target, settings: .neutral,
                                               options: .init(), overwriteExisting: true))
            #expect(try decode(target).width == 64)
            await #expect(throws: JPEGExportError.protectedOriginal) {
                try await exporter.export(.init(sourceURL: source, destinationURL: source, settings: .neutral,
                                                options: .init(), overwriteExisting: true))
            }
            #expect(try Data(contentsOf: source) == original)
            #expect(try temporaryOutputs(in: directory).isEmpty)
        }
    }

    @Test func protectedOriginalsRejectHardlinksSymlinksAndDirectoryAliases() async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "source.png")
            let other = try fixture(directory, name: "other-original.png")
            let before = try Data(contentsOf: other)
            let hardlink = directory.appendingPathComponent("hardlink.jpg")
            try FileManager.default.linkItem(at: other, to: hardlink)
            let symlink = directory.appendingPathComponent("symlink.jpg")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: other)
            let directoryAlias = directory.appendingPathComponent("directory-alias")
            try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: directory)
            for target in [other, hardlink, symlink, directoryAlias.appendingPathComponent(other.lastPathComponent)] {
                await #expect(throws: JPEGExportError.protectedOriginal) {
                    try await JPEGExporter().export(.init(sourceURL: source, destinationURL: target, settings: .neutral,
                        options: .init(), overwriteExisting: true, protectedSourceURLs: [other]))
                }
            }
            #expect(try Data(contentsOf: other) == before)
            #expect(try Data(contentsOf: hardlink) == before)
        }
    }

    @Test func invalidSourceMemoryLimitsAndCancellationLeaveDestinationIntact() async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "source.png")
            let target = directory.appendingPathComponent("existing.jpg")
            let existing = Data("keep existing output".utf8)
            try existing.write(to: target)
            let request = JPEGExportRequest(sourceURL: source, destinationURL: target, settings: .neutral,
                                            options: .init(), overwriteExisting: true)
            await #expect(throws: JPEGExportError.insufficientMemory) {
                try await JPEGExporter(memoryBudget: 1).export(request)
            }
            let corrupt = directory.appendingPathComponent("broken.png")
            try Data("not an image".utf8).write(to: corrupt)
            await #expect(throws: JPEGExportError.unsupportedOrDamaged) {
                try await JPEGExporter().export(.init(sourceURL: corrupt, destinationURL: target,
                    settings: .neutral, options: .init(), overwriteExisting: true))
            }
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await JPEGExporter().export(request)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try Data(contentsOf: target) == existing)
            #expect(try temporaryOutputs(in: directory).isEmpty)
        }
    }

    @Test func stackedLocalSpatialEditsAreBudgetedBeforePublishing() async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "local-budget.png")
            let before = try Data(contentsOf: source)
            let document = try MaskDocument(canvasSize: .init(width: 64, height: 48), strokes: [
                .init(points: [.init(x: 32, y: 24)], radius: 64)
            ])
            var settings = EditSettings.neutral
            settings.localAdjustments = [try LocalAdjustment(name: "Local", mask: .init(shape: .brush(document), feather: 0),
                settings: .init(exposure: 0.5))]
            let exporter = JPEGExporter(memoryBudget: 310_000)
            _ = try await exporter.export(.init(sourceURL: source, destinationURL: directory.appendingPathComponent("tone.jpg"),
                settings: settings, options: .init()))
            settings.localAdjustments[0].settings.texture = 50
            settings.localAdjustments[0].settings.clarity = 30
            let target = directory.appendingPathComponent("protected-output.jpg")
            let existing = Data("keep existing output".utf8)
            try existing.write(to: target)
            await #expect(throws: JPEGExportError.insufficientMemory) {
                try await exporter.export(.init(sourceURL: source, destinationURL: target, settings: settings,
                    options: .init(), overwriteExisting: true))
            }
            #expect(try Data(contentsOf: target) == existing)
            settings.localAdjustments[0].isEnabled = false
            _ = try await exporter.export(.init(sourceURL: source, destinationURL: directory.appendingPathComponent("disabled.jpg"),
                settings: settings, options: .init()))
            #expect(try Data(contentsOf: source) == before)
            #expect(try temporaryOutputs(in: directory).isEmpty)
        }
    }

    @Test func concurrentIndependentExportersCannotClobberAnUnapprovedDestination() async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "source.png", width: 1_200, height: 800)
            let target = directory.appendingPathComponent("shared.jpg")
            let request = JPEGExportRequest(sourceURL: source, destinationURL: target, settings: .neutral, options: .init())
            let tasks = (0..<2).map { _ in Task { () -> Result<JPEGExportResult, Error> in
                do { return .success(try await JPEGExporter().export(request)) }
                catch { return .failure(error) }
            } }
            var successes = 0
            var conflicts = 0
            for task in tasks {
                switch await task.value {
                case .success: successes += 1
                case let .failure(error): if error as? JPEGExportError == .destinationExists { conflicts += 1 }
                }
            }
            #expect(successes == 1 && conflicts == 1)
            #expect(try decode(target).width == 1_200)
            #expect(try temporaryOutputs(in: directory).isEmpty)
        }
    }

    @Test func cancellationAndFailureAfterEncodingPreserveDestinationAndRemoveTemporaryOutput() async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "source.png")
            let target = directory.appendingPathComponent("existing.jpg")
            let existing = Data("existing accepted destination".utf8)
            try existing.write(to: target)
            let request = JPEGExportRequest(sourceURL: source, destinationURL: target, settings: .neutral,
                                            options: .init(), overwriteExisting: true)
            let gate = PublicationGate()
            let exporter = JPEGExporter(beforePublication: { gate.block() })
            let task = Task { try await exporter.export(request) }
            defer { gate.release() }
            let blocked = await gate.waitUntilBlocked()
            #expect(blocked, "Exporter did not reach the encoded temporary-file boundary")
            guard blocked else {
                gate.release()
                _ = try? await task.value
                return
            }
            #expect(try temporaryOutputs(in: directory).count == 1)
            #expect(try Data(contentsOf: target) == existing)
            task.cancel()
            gate.release()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try Data(contentsOf: target) == existing)
            #expect(try temporaryOutputs(in: directory).isEmpty)

            let failing = JPEGExporter(beforePublication: { throw PublicationFailure.injected })
            await #expect(throws: PublicationFailure.injected) { try await failing.export(request) }
            #expect(try Data(contentsOf: target) == existing)
            #expect(try temporaryOutputs(in: directory).isEmpty)
        }
    }

    @Test func refreshedOriginalIdentityRejectsAnAliasCreatedDuringRendering() async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "source.png")
            let protected = try fixture(directory, name: "protected.png")
            let replacement = try fixture(directory, name: "replacement.png") { _, _ in (30, 60, 90, 255) }
            let replacementBytes = try Data(contentsOf: replacement)
            let target = directory.appendingPathComponent("existing.jpg")
            try Data("previous destination".utf8).write(to: target)
            let exporter = JPEGExporter(beforePublication: {
                try FileManager.default.removeItem(at: protected)
                try FileManager.default.moveItem(at: replacement, to: protected)
                try FileManager.default.removeItem(at: target)
                try FileManager.default.linkItem(at: protected, to: target)
            })
            await #expect(throws: JPEGExportError.protectedOriginal) {
                try await exporter.export(.init(sourceURL: source, destinationURL: target, settings: .neutral,
                    options: .init(), overwriteExisting: true, protectedSourceURLs: [protected]))
            }
            #expect(try Data(contentsOf: target) == replacementBytes)
            #expect(try Data(contentsOf: protected) == replacementBytes)
            #expect(try temporaryOutputs(in: directory).isEmpty)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_RAW_EXPORT_TEST_FILE"]?.isEmpty == false))
    func explicitlySuppliedCameraRAWExportsAtFullSizeAndAsEditedP3() async throws {
        guard let path = ProcessInfo.processInfo.environment["GLOWROOM_RAW_EXPORT_TEST_FILE"], !path.isEmpty else { return }
        let source = URL(fileURLWithPath: path)
        let originalHash = try SHA256.hash(data: Data(contentsOf: source))
        let metadata = try properties(source)
        let width = try #require((metadata[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let height = try #require((metadata[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        let orientation = (metadata[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let full = JPEGPixelSize(width: (5...8).contains(orientation) ? height : width,
                                 height: (5...8).contains(orientation) ? width : height)
        try await withDirectory { directory in
            let originalTarget = directory.appendingPathComponent("full.jpg")
            let exporter = JPEGExporter()
            let result = try await exporter.export(.init(sourceURL: source, destinationURL: originalTarget,
                settings: .neutral, options: .init()))
            #expect(result.width == full.width && result.height == full.height)
            #expect(try decode(originalTarget).colorSpace?.name == CGColorSpace.sRGB)
            var edits = EditSettings.neutral
            edits.exposure = 0.4
            edits.autoToneAmount = 20
            edits.texture = 15
            let options = JPEGExportOptions(colorSpace: .displayP3, sizeMode: .longEdge, longEdge: 1_200)
            let target = directory.appendingPathComponent("edited-p3.jpg")
            let resized = try await exporter.export(.init(sourceURL: source, destinationURL: target, settings: edits, options: options))
            let expected = try options.outputSize(sourceWidth: full.width, sourceHeight: full.height)
            #expect(resized.width == expected.width && resized.height == expected.height)
            #expect(try decode(target).colorSpace?.name == CGColorSpace.displayP3)
            #expect(try temporaryOutputs(in: directory).isEmpty)
        }
        #expect(try SHA256.hash(data: Data(contentsOf: source)) == originalHash)
    }

    @MainActor @Test(arguments: [false, true])
    func delayedAcceptedImportProtectsAnOpenDialogAndOverwriteRetry(overwritePrompt: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glowroom-jpeg-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(directory, name: "source.png")
        let importDirectory = directory.appendingPathComponent("Import", isDirectory: true)
        try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        let target = try fixture(importDirectory, name: "source-bearbeitet.jpg", type: .jpeg)
        let before = try Data(contentsOf: target)
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog", isDirectory: true))
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: source)
        try repository.save(LibraryCatalog(folders: [folder], assets: [asset]))
        let scanner = JPEGImportScanner(target: target)
        let library = LibraryModel(repository: repository, folderScanner: { await scanner.scan($0) })
        defer { library.cancelImport(); Task { await scanner.release() } }
        try await waitForLibrary { !library.isLoading && !library.isProjecting }
        let model = JPEGExportModel(preferences: nil)
        model.present(asset: asset, settings: .neutral, protectedSourceURLs: [source],
                      catalogProtection: library.jpegExportProtection)
        model.destinationDirectory = importDirectory
        if overwritePrompt {
            model.startExport()
            try await waitForLibrary { model.needsOverwriteConfirmation }
        }
        library.importFolders([importDirectory])
        // Import acceptance is synchronous; the scanner has not run yet.
        #expect(!library.canExportJPEG)
        if overwritePrompt { model.confirmOverwrite() } else { model.startExport() }
        try await waitForLibrary { !model.isExporting }
        #expect(model.errorMessage == JPEGExportError.catalogBusy.localizedDescription)
        #expect(model.result == nil && !model.needsOverwriteConfirmation)
        try await waitForLibrary { await scanner.started }
        #expect(try Data(contentsOf: target) == before)
        await scanner.release()
        try await waitForLibrary { !library.isImporting && !library.isProjecting }
        #expect(library.assets.contains { $0.fileURL == target })
        model.startExport()
        try await waitForLibrary { !model.isExporting }
        #expect(model.errorMessage == JPEGExportError.protectedOriginal.localizedDescription)
        #expect(model.result == nil && !model.needsOverwriteConfirmation)
        #expect(try Data(contentsOf: target) == before)
        #expect(try temporaryOutputs(in: importDirectory).isEmpty)
    }

    @MainActor @Test
    func importAcceptedAfterEncodingPreventsFinalRenameWhileScanIsPending() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glowroom-jpeg-pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(directory, name: "source.png")
        let target = try fixture(directory, name: "late-original.jpg", type: .jpeg)
        let before = try Data(contentsOf: target)
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog", isDirectory: true))
        try repository.save(LibraryCatalog())
        let scanner = JPEGImportScanner(target: target)
        let library = LibraryModel(repository: repository, folderScanner: { await scanner.scan($0) })
        defer { library.cancelImport(); Task { await scanner.release() } }
        try await waitForLibrary { !library.isLoading && !library.isProjecting }
        let boundary = PublicationGate()
        defer { boundary.release() }
        let exporter = JPEGExporter(beforePublication: { boundary.block() })
        let request = JPEGExportRequest(sourceURL: source, destinationURL: target, settings: .neutral,
            options: .init(), overwriteExisting: true, catalogProtection: library.jpegExportProtection)
        let task = Task { try await exporter.export(request) }
        let reached = await boundary.waitUntilBlocked()
        #expect(reached)
        guard reached else { boundary.release(); _ = try? await task.value; return }
        library.importFolders([directory])
        boundary.release()
        await #expect(throws: JPEGExportError.catalogBusy) { try await task.value }
        #expect(try Data(contentsOf: target) == before)
        #expect(try temporaryOutputs(in: directory).isEmpty)
        try await waitForLibrary { await scanner.started }
        await scanner.release()
        try await waitForLibrary { !library.isImporting }
        await #expect(throws: JPEGExportError.protectedOriginal) { try await JPEGExporter().export(request) }
        #expect(try Data(contentsOf: target) == before)
    }

    @Test(arguments: ["before-start", "after-render", "after-snapshot"], [false, true])
    func currentCatalogProtectsLateOriginalsAndHardlinks(phase: String, hardlink: Bool) async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "source.png")
            let imported = try fixture(directory, name: "late-original.jpg", type: .jpeg)
            let target = hardlink ? directory.appendingPathComponent("alias.jpg") : imported
            if hardlink { try FileManager.default.linkItem(at: imported, to: target) }
            let before = try Data(contentsOf: imported)
            let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog", isDirectory: true))
            let folder = LibraryFolder(url: directory)
            let initial = LibraryCatalog(folders: [folder], assets: [PhotoAsset(folderID: folder.id, fileURL: source)])
            var changed = initial
            changed.assets.append(PhotoAsset(folderID: folder.id, fileURL: imported))
            let importedCatalog = changed
            try repository.save(initial)
            let protection = JPEGExportCatalogProtection(repository: repository)
            let request = JPEGExportRequest(sourceURL: source, destinationURL: target, settings: .neutral,
                options: .init(), overwriteExisting: true, catalogProtection: protection)
            if phase == "before-start" { try repository.save(importedCatalog) }
            let exporter = JPEGExporter(beforePublication: {
                if phase == "after-render" { try repository.save(importedCatalog) }
            }, beforeCatalogPublication: {
                if phase == "after-snapshot" { try repository.save(importedCatalog) }
            })
            let expected: JPEGExportError = phase == "after-snapshot" ? .catalogChanged : .protectedOriginal
            await #expect(throws: expected) { try await exporter.export(request) }
            #expect(try Data(contentsOf: imported) == before)
            #expect(try Data(contentsOf: target) == before)
            #expect(try temporaryOutputs(in: directory).isEmpty)
        }
    }

    @Test func acceptedChangeEpochRejectsFinalPublicationEvenAfterItFinishes() async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "source.png")
            let target = directory.appendingPathComponent("ordinary.jpg")
            let before = Data("ordinary previous output".utf8)
            try before.write(to: target)
            let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog", isDirectory: true))
            try repository.save(LibraryCatalog())
            let protection = JPEGExportCatalogProtection(repository: repository)
            let request = JPEGExportRequest(sourceURL: source, destinationURL: target, settings: .neutral,
                options: .init(), overwriteExisting: true, catalogProtection: protection)
            let exporter = JPEGExporter(beforeCatalogPublication: {
                // Both transitions occur after the final snapshot. A busy-only
                // check would miss this completed/cancelled accepted mutation.
                let admission = protection.acceptCatalogChange()
                withExtendedLifetime(admission) {}
            })
            await #expect(throws: JPEGExportError.catalogChanged) { try await exporter.export(request) }
            #expect(try Data(contentsOf: target) == before)
            #expect(try temporaryOutputs(in: directory).isEmpty)
            _ = try await JPEGExporter().export(request)
            #expect(try decode(target).width == 64)
        }
    }

    @Test(arguments: [false, true])
    func freshRecoveryProtectionAndUnavailableStateStopAnAlreadyRenderingExport(unavailable: Bool) async throws {
        try await withDirectory { directory in
            let source = try fixture(directory, name: "source.png")
            let target = directory.appendingPathComponent("ordinary.jpg")
            let before = Data("preserve recovery source".utf8)
            try before.write(to: target)
            let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog", isDirectory: true))
            try repository.save(LibraryCatalog())
            let protection = JPEGExportCatalogProtection(repository: repository)
            let request = JPEGExportRequest(sourceURL: source, destinationURL: target, settings: .neutral,
                options: .init(), overwriteExisting: true, catalogProtection: protection)
            let exporter = JPEGExporter(beforePublication: {
                if unavailable { protection.setUnavailable(true) }
                else { protection.updateProtectedSources([target]) }
            })
            await #expect(throws: unavailable ? JPEGExportError.catalogUnavailable : .protectedOriginal) {
                try await exporter.export(request)
            }
            #expect(try Data(contentsOf: target) == before)
            #expect(try temporaryOutputs(in: directory).isEmpty)
        }
    }

    private func withDirectory(_ operation: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glowroom-jpeg-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await operation(directory)
    }

    @MainActor private func waitForLibrary(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw PublicationFailure.injected }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func fixture(_ directory: URL, name: String, width: Int = 64, height: Int = 48,
                         colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                         orientation: Int = 1, type: UTType = .png,
                         pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) = { x, y in
                             (UInt8(40 + x % 100), UInt8(60 + y % 100), 100, 255)
                         }) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let index = (y * width + x) * 4
                bytes[index] = UInt8(Int(r) * Int(a) / 255)
                bytes[index + 1] = UInt8(Int(g) * Int(a) / 255)
                bytes[index + 2] = UInt8(Int(b) * Int(a) / 255)
                bytes[index + 3] = a
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = directory.appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func decode(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
    }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func pixels(_ image: CGImage, space: CGColorSpace? = nil) throws -> [UInt8] {
        var values = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try values.withUnsafeMutableBytes { data in
            let context = try #require(CGContext(data: data.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: space ?? image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return values
    }

    private func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
    }

    private func temporaryOutputs(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".glowroom-export-") }
    }

    private enum PublicationFailure: Error, Equatable { case injected }

    private final class PublicationGate: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let proceed = DispatchSemaphore(value: 0)

        func block() { entered.signal(); proceed.wait() }
        func release() { proceed.signal() }
        func waitUntilBlocked() async -> Bool {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: self.entered.wait(timeout: .now() + 20) == .success)
                }
            }
        }
    }
}

private actor JPEGImportScanner {
    let target: URL
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(target: URL) { self.target = target }
    func scan(_ folder: LibraryFolder) async -> ScanResult {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return ScanResult(assets: [PhotoAsset(folderID: folder.id, fileURL: target)], skippedFiles: 0)
    }
    func release() { continuation?.resume(); continuation = nil }
}
