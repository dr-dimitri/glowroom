import SwiftUI

/// Creation stays in the inspector even before the first mask exists. The
/// canvas palette is reserved for existing masks and their local history.
@MainActor
struct InlineMaskCreator: View {
    @ObservedObject var workspace: InlineMaskWorkspace
    @ViewState private var showsPeople = true
    @ViewState private var showsSkySetup = false
    @ViewState private var showsSubjectSetup = false

    private var canCreate: Bool {
        workspace.isCurrent && workspace.canvasSize != nil && workspace.model?.isGenerating == false
            && (workspace.model?.settings.localAdjustments.count ?? 0) < 16
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Neue Maske hinzufügen:").font(.system(size: 12, weight: .medium))
            HStack(alignment: .top, spacing: 8) {
                tile(.subject, title: "Motiv")
                tile(.sky, title: "Himmel")
                tile(.background, title: "Hintergrund")
            }.padding(.vertical, 3)
            Divider().overlay(Theme.line)
            VStack(spacing: 2) {
                unavailableRow("Landschaft", symbol: "mountain.2", id: "landscape")
                unavailableRow("Objekte", symbol: "viewfinder", id: "object")
                toolRow(.brush, title: "Pinsel")
                toolRow(.linear, title: "Linearer Verlauf")
                toolRow(.radial, title: "Radialverlauf")
            }
            Divider().overlay(Theme.line)
            DisclosureGroup(isExpanded: $showsPeople) {
                Text("Personenauswahl noch nicht verfügbar.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
            } label: {
                Text("Personen").font(.system(size: 12))
            }.tint(Theme.muted)
            Button("Himmelsmodell einrichten …") { showsSkySetup = true }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.muted)
                .accessibilityIdentifier("local-mask.sky-setup")
            Button("Motivmodell einrichten …") { showsSubjectSetup = true }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.muted)
                .accessibilityIdentifier("local-mask.subject-setup")
            if (workspace.model?.settings.localAdjustments.count ?? 0) >= 16 {
                Text("Maximal 16 Masken pro Bild.").font(.caption).foregroundStyle(Theme.muted)
            }
        }.foregroundStyle(Theme.text)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("local-mask.creator")
            .sheet(isPresented: $showsSkySetup) { SkyMaskModelSetupView() }
            .sheet(isPresented: $showsSubjectSetup) { SubjectMattingModelSetupView() }
    }

    private func tile(_ kind: LocalMaskCreation, title: String) -> some View {
        Button { create(kind) } label: {
            VStack(spacing: 5) {
                Image(systemName: kind.symbol).font(.system(size: 21, weight: .light))
                    .frame(width: 48, height: 48)
                    .overlay { Rectangle().strokeBorder(Theme.muted, lineWidth: 1.5) }
                Text(title).font(.system(size: 11)).lineLimit(1)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!canCreate)
            .help(kind.title).accessibilityLabel(kind.title)
            .accessibilityIdentifier("local-mask.create.\(kind.rawValue)")
    }

    private func toolRow(_ kind: LocalMaskCreation, title: String) -> some View {
        Button { create(kind) } label: { rowLabel(title, symbol: kind.symbol) }
            .buttonStyle(.plain).disabled(!canCreate)
            .accessibilityLabel(title)
            .accessibilityIdentifier("local-mask.create.\(kind.rawValue)")
    }

    private func unavailableRow(_ title: String, symbol: String, id: String) -> some View {
        Button {} label: { rowLabel(title, symbol: symbol).foregroundStyle(Theme.muted.opacity(0.55)) }
            .buttonStyle(.plain).disabled(true)
            .help("\(title): noch nicht verfügbar")
            .accessibilityLabel("\(title): noch nicht verfügbar")
            .accessibilityIdentifier("local-mask.unavailable.\(id)")
    }

    private func rowLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 17, weight: .light)).frame(width: 22)
            Text(title).font(.system(size: 12))
            Spacer(minLength: 0)
        }.frame(height: 25).contentShape(Rectangle())
    }

    private func create(_ kind: LocalMaskCreation) {
        workspace.finishGesture()
        workspace.model?.add(kind)
    }
}
