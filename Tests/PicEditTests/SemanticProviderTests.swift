import Foundation
import Testing
@testable import PicEdit
import PicEditCore

@Suite("Semantic native provider contracts")
struct SemanticProviderTests {
    @Test func absentInstallationStaysUnloaded() async throws {
        let provider = SemanticLocalProviderFactory.makeProvider(installation: nil)
        #expect(await provider.availability() == .unavailable(.modelNotInstalled))
        await #expect(throws: SemanticEmbeddingError.unavailable(.modelNotInstalled)) {
            try await provider.encodeText("roter Kreis")
        }
        await provider.unload()
    }

    @Test func invalidInputsFailBeforeAnyModelLoad() async throws {
        let provider = SemanticLocalProviderFactory.makeProvider(installation: nil)
        for text in ["", "   \n", String(repeating: "x", count: 4_097)] {
            await #expect(throws: SemanticEmbeddingError.invalidInput) { try await provider.encodeText(text) }
        }
        let bad = SemanticImageInput(values: [.nan], rasterSHA256: "", sourceRevision: "")
        await #expect(throws: SemanticEmbeddingError.invalidInput) { try await provider.encodeImage(bad) }
    }

    @Test func normalizationRejectsInvalidAndKeepsUnitLength() throws {
        for invalid in [[], Array(repeating: Float.zero, count: 768), Array(repeating: Float.nan, count: 768), [1]] {
            #expect(throws: SemanticEmbeddingError.invalidVector) { try SemanticLocalEmbeddingProvider.normalized(invalid) }
        }
        let normalized = try SemanticLocalEmbeddingProvider.normalized((0..<768).map { Float($0 - 384) })
        let norm = normalized.reduce(0.0) { $0 + Double($1) * Double($1) }
        #expect(abs(norm - 1) < 0.000_001)
        #expect(normalized.first! < 0 && normalized.last! > 0)
    }

    @Test func approvedManifestPinsEveryRuntimeInput() throws {
        let manifest = try SemanticPackageManifest.approved()
        try manifest.validate()
        #expect(manifest.descriptor == SemanticLocalProviderFactory.descriptor)
        #expect(manifest.files.count == 14)
        #expect(manifest.files.contains { $0.path == "tokenizer/tokenizer.json" })
        #expect(manifest.files.contains { $0.path == "licenses/MODEL-CARD.md" })
        #expect(!manifest.files.contains { $0.path.contains("safetensors") })
        #expect(manifest.files.reduce(Int64(0)) { $0 + $1.bytes } < SemanticModelInstaller.maximumInstalledBytes)
    }
}
