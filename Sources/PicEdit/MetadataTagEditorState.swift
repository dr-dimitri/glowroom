import Foundation
import PicEditCore

/// UI text and normalized persisted tags have different lifetimes: a Return at
/// the end of a line is useful editing state even though it adds no DTO tag.
struct MetadataTagEditorState {
    private(set) var text = ""
    private var submitted: [String] = []

    mutating func edit(_ text: String) -> [String] {
        self.text = text
        submitted = Self.parse(text)
        return submitted
    }

    mutating func synchronize(_ tags: [String]) {
        if tags == submitted { return }
        // Own saves can trim/deduplicate tags. Preserve the raw editing text
        // when that normalization is the only difference, including final LF.
        if let normalized = try? PhotoTextNormalization.normalize(PhotoTextFields(tags: submitted)), normalized.tags == tags {
            submitted = tags
            return
        }
        submitted = tags
        text = tags.joined(separator: "\n")
    }

    static func parse(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
