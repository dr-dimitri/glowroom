import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Develop capture metadata header")
struct DevelopCaptureSummaryTests {
    @Test func catalogMetadataUsesCompactGermanCameraNotationAndCaptureDate() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 12)))
        let asset = PhotoAsset(folderID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/header.jpg"),
            captureDate: date, focalLength: "56 mm", aperture: "ƒ/5.6", shutterSpeed: "1/300 s", iso: "200")
        #expect(DevelopCaptureSummary.text(for: asset, timeZone: zone)
            == "1/300s, f5,6, ISO 200, 56mm, 12.04.2026")
    }

    @Test func missingMetadataIsOmittedWithoutInventingAnExposureOrCaptureDate() {
        var asset = PhotoAsset(folderID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/no-exif.jpg"),
            createdAt: .now, modifiedAt: .now)
        #expect(DevelopCaptureSummary.text(for: asset) == nil)
        asset.aperture = " \n "
        asset.shutterSpeed = ""
        asset.focalLength = " 35.5 mm "
        #expect(DevelopCaptureSummary.text(for: asset) == "35,5mm")
    }

    @Test func longExposuresAndPartialMetadataRetainTheirUnits() {
        let asset = PhotoAsset(folderID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/long-exposure.jpg"),
            aperture: "ƒ/8", shutterSpeed: "2.5 s", iso: " 100 ")
        #expect(DevelopCaptureSummary.text(for: asset) == "2,5s, f8, ISO 100")
    }
}
