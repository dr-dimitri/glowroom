import SwiftUI
import PicEditCore

struct ArtifactVariantsSection: View {
    let assetID: String
    @EnvironmentObject private var editor: EditingModel
    var body: some View {
        if let library = editor.library {
            ArtifactVariantsContent(assetID: assetID, editor: editor, library: library)
        }
    }
}

private struct ArtifactVariantsContent: View {
    let assetID: String
    @ObservedObject var editor: EditingModel
    @ObservedObject var library: LibraryModel
    @ViewState<Bool> private var expanded = false
    @ViewState<Int> private var offset = 0
    private var currentVariants: [EditingVariant] { editor.variants.filter { $0.assetID == assetID } }
    private var page: [EditingVariant] { Array(currentVariants.reversed().dropFirst(offset).prefix(100)) }
    private var loadIdentity: ArtifactVariantsLoadIdentity { editor.variantsLoadIdentity(assetID: assetID, expanded: expanded) }
    var body: some View {
        DisclosureGroup("Gespeicherte Bildstände", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Der Wechsel ist rückgängig machbar. Er startet keine Generierung.").font(.caption)
                if !loadIdentity.isReady || editor.isLoadingVariants { ProgressView() }
                else if currentVariants.isEmpty { Text("Keine früheren Bildstände gespeichert.").font(.caption) }
                else {
                    ForEach(page, id: \.id) { variant in
                        Button {
                            Task { await editor.selectVariant(variant) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(variant.snapshot.source == .original ? "Original mit Reglern" : "Generierter Bildstand")
                                Text(variant.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2)
                            }
                        }.disabled(!editor.canEdit)
                    }
                    HStack {
                        if offset > 0 { Button("Neuere") { offset = max(0, offset - 100) } }
                        if offset + 100 < currentVariants.count { Button("Ältere") { offset += 100 } }
                    }
                }
            }.padding(.top, 8)
        }.font(.system(size: 11))
            .task(id: loadIdentity) {
                let identity = loadIdentity
                offset = 0
                if identity.expanded && identity.isReady { await editor.loadVariants(identity) }
            }
    }
}
