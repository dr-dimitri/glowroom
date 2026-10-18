import PicEditCore
import Testing

struct JPEGExportOptionsTests {
    @Test func outputFormatDefaultsToJPEGAndHDRHasItsOwnExtensions() throws {
        #expect(JPEGExportOptions().format == .jpeg)
        #expect(JPEGExportFormat.jpeg.acceptedExtensions == ["jpg", "jpeg"])
        #expect(JPEGExportFormat.heif10HDR.acceptedExtensions == ["heic", "heif"])
        let hdr = JPEGExportOptions(format: .heif10HDR, sizeMode: .longEdge, longEdge: 800)
        try hdr.validate()
        #expect(try hdr.outputSize(sourceWidth: 1200, sourceHeight: 800) == .init(width: 800, height: 533))
    }

    @Test func originalRetainsFullResolutionAndPrintDensityDoesNotResize() throws {
        var options = JPEGExportOptions()
        #expect(try options.outputSize(sourceWidth: 6_000, sourceHeight: 4_000) == JPEGPixelSize(width: 6_000, height: 4_000))
        options.pixelsPerInch = 72
        #expect(try options.outputSize(sourceWidth: 6_000, sourceHeight: 4_000) == JPEGPixelSize(width: 6_000, height: 4_000))
    }

    @Test func longEdgeHandlesBothOrientationsAndUpscaling() throws {
        var options = JPEGExportOptions(sizeMode: .longEdge, longEdge: 2_400)
        #expect(try options.outputSize(sourceWidth: 6_000, sourceHeight: 4_000) == JPEGPixelSize(width: 2_400, height: 1_600))
        #expect(try options.outputSize(sourceWidth: 4_000, sourceHeight: 6_000) == JPEGPixelSize(width: 1_600, height: 2_400))
        #expect(try options.outputSize(sourceWidth: 600, sourceHeight: 400) == JPEGPixelSize(width: 600, height: 400))
        options.allowUpscaling = true
        #expect(try options.outputSize(sourceWidth: 600, sourceHeight: 400) == JPEGPixelSize(width: 2_400, height: 1_600))
    }

    @Test func fitIsAnAspectPreservingBoundingBoxWithRoundedPixels() throws {
        let options = JPEGExportOptions(sizeMode: .fit, width: 1_000, height: 700)
        #expect(try options.outputSize(sourceWidth: 6_000, sourceHeight: 4_000) == JPEGPixelSize(width: 1_000, height: 667))
        #expect(try options.outputSize(sourceWidth: 4_000, sourceHeight: 6_000) == JPEGPixelSize(width: 467, height: 700))
        #expect(try options.outputSize(sourceWidth: 60_000, sourceHeight: 1) == JPEGPixelSize(width: 1_000, height: 1))
    }

    @Test func invalidValuesAndArithmeticOverflowThrow() {
        #expect(throws: JPEGExportOptionsError.invalidQuality) { try JPEGExportOptions(quality: -1).validate() }
        #expect(throws: JPEGExportOptionsError.invalidQuality) { try JPEGExportOptions(quality: 101).validate() }
        #expect(throws: JPEGExportOptionsError.invalidResolution) { try JPEGExportOptions(width: 0).validate() }
        #expect(throws: JPEGExportOptionsError.invalidResolution) { try JPEGExportOptions(longEdge: Int.max).validate() }
        #expect(throws: JPEGExportOptionsError.invalidPixelsPerInch) { try JPEGExportOptions(pixelsPerInch: 0).validate() }
        #expect(throws: JPEGExportOptionsError.invalidSourceSize) { try JPEGExportOptions().outputSize(sourceWidth: 0, sourceHeight: 5) }
        #expect(throws: JPEGExportOptionsError.invalidSourceSize) { try JPEGExportOptions().outputSize(sourceWidth: Int.max, sourceHeight: 2) }
        #expect(throws: JPEGExportOptionsError.dimensionsTooLarge) { try JPEGExportOptions().outputSize(sourceWidth: 65_536, sourceHeight: 1) }
    }

    @Test func jpegBoundariesAndLargeSourceDownscalingAreAccepted() throws {
        try JPEGExportOptions(quality: 0, pixelsPerInch: 1).validate()
        try JPEGExportOptions(quality: 100, pixelsPerInch: 1_200).validate()
        #expect(try JPEGExportOptions().outputSize(sourceWidth: 65_535, sourceHeight: 1) == JPEGPixelSize(width: 65_535, height: 1))
        #expect(try JPEGExportOptions(sizeMode: .longEdge, longEdge: 2_400).outputSize(sourceWidth: 100_000, sourceHeight: 50_000) == JPEGPixelSize(width: 2_400, height: 1_200))
    }
}
