import SwiftUI
import GlowroomCore

struct FolderTreeRow: View {
    @ObservedObject var model: LibraryModel
    let folder: LibraryFolder
    let node: FolderTreeNode
    let depth: Int
    let remove: (LibraryFolder) -> Void
    @ViewState<Bool> private var expanded: Bool

    init(model: LibraryModel, folder: LibraryFolder, node: FolderTreeNode, depth: Int = 0, remove: @escaping (LibraryFolder) -> Void) {
        self.model = model
        self.folder = folder
        self.node = node
        self.depth = depth
        self.remove = remove
        _expanded = ViewState(initialValue: depth == 0)
    }

    private var active: Bool {
        model.selection == (node.relativePath.isEmpty ? .folder(folder.id) : .subfolder(folder.id, node.relativePath))
    }
    private var url: URL { node.relativePath.isEmpty ? folder.url : folder.url.appendingPathComponent(node.relativePath) }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
                        .frame(width: 17, height: 33).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(node.children.isEmpty ? 0 : 1)
                .disabled(node.children.isEmpty)
                .accessibilityHidden(node.children.isEmpty)
                .accessibilityLabel("\(node.name): Unterordner \(expanded ? "zuklappen" : "aufklappen")")
                .help(expanded ? "Unterordner zuklappen" : "Unterordner aufklappen")

                Button { model.selectFolder(folder, relativePath: node.relativePath) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: expanded && !node.children.isEmpty ? "folder.fill" : "folder").font(.system(size: 12)).frame(width: 16)
                        Text(node.name).font(.system(size: 11, weight: active ? .medium : .regular)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 2)
                        Text(node.photoCount.formatted()).font(.system(size: 9, design: .monospaced)).foregroundStyle(active ? Theme.accent : Theme.muted)
                    }.foregroundStyle(active ? Theme.accent : Color.white.opacity(0.68))
                        .frame(height: 33).contentShape(Rectangle())
                }.buttonStyle(.plain).help(url.path).accessibilityLabel("\(node.name), \(node.photoCount) Fotos")
            }
            .padding(.leading, 4 + CGFloat(min(depth, 7)) * 11).padding(.trailing, 10)
            .background(active ? Theme.accent.opacity(0.085) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10)
            .contextMenu {
                Button("Ordner aktualisieren") {
                    model.selectFolder(folder, relativePath: node.relativePath)
                    model.refreshCurrentFolder()
                }.disabled(model.isImporting || !model.canModify)
                Button("Im Finder öffnen") { NSWorkspace.shared.open(url) }
                if node.relativePath.isEmpty {
                    Divider()
                    Button("Aus Bibliothek entfernen …", role: .destructive) { remove(folder) }.disabled(model.isImporting || !model.canModify)
                }
            }
            if expanded {
                ForEach(node.children) { child in
                    FolderTreeRow(model: model, folder: folder, node: child, depth: depth + 1, remove: remove)
                }
            }
        }
        .onChange(of: model.selection) { _, selection in
            if case .subfolder(let id, let path) = selection, id == folder.id,
               node.relativePath.isEmpty || path.hasPrefix(node.relativePath + "/") { expanded = true }
        }
    }
}
