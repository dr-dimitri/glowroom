import Foundation
import SwiftUI
import PicEditCore

/// Uses catalog values only; displaying the header never reads or decodes a photo.
enum DevelopCaptureSummary {
    static func text(for asset: PhotoAsset, timeZone: TimeZone = .current) -> String? {
        func compact(_ value: String?) -> String? {
            guard let value else { return nil }
            let compact = value.filter { !$0.isWhitespace }
            return compact.isEmpty ? nil : compact.replacingOccurrences(of: ".", with: ",")
        }

        let values = [
            compact(asset.shutterSpeed),
            compact(asset.aperture)?.replacingOccurrences(of: "ƒ/", with: "f")
                .replacingOccurrences(of: "f/", with: "f"),
            compact(asset.iso).map { "ISO \($0)" },
            compact(asset.focalLength),
            asset.captureDate.map {
                $0.formatted(Date.VerbatimFormatStyle(
                    format: "\(day: .twoDigits).\(month: .twoDigits).\(year: .defaultDigits)",
                    timeZone: timeZone, calendar: Calendar(identifier: .gregorian)))
            }
        ].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }
}

struct DevelopPhotoHeader: View {
    let asset: PhotoAsset
    let previewLabel: String

    var body: some View {
        let summary = DevelopCaptureSummary.text(for: asset)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                filename
                if let summary { captureText(summary) }
                sourceLabel
                Spacer(minLength: 0)
            }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    filename
                    sourceLabel
                    Spacer(minLength: 0)
                }
                if let summary {
                    captureText(summary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 18).padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background(Theme.chrome)
    }

    private var filename: some View {
        Text(asset.fileName).fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(asset.fileName)
    }

    private var sourceLabel: some View {
        Text(previewLabel).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
    }

    private func captureText(_ summary: String) -> some View {
        Text(summary).foregroundStyle(Theme.muted).help(summary)
            .accessibilityLabel("Aufnahmedaten: \(summary)")
    }
}
