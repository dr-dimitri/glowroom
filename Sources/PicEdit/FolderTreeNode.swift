import Foundation
import PicEditCore

/// A catalog projection: subfolders are browseable without importing them a second time.
struct FolderTreeNode: Identifiable {
    let relativePath: String
    let name: String
    let photoCount: Int
    let children: [FolderTreeNode]
    var id: String { relativePath }

    func contains(relativePath path: String) -> Bool {
        relativePath == path || children.contains { $0.contains(relativePath: path) }
    }

    static func make(folder: LibraryFolder, assets: [PhotoAsset]) -> FolderTreeNode {
        final class Branch {
            var children: [String: Branch] = [:]
            var photoCount = 0

            func add(_ components: [String], countingPhoto: Bool) {
                var branch = self
                if countingPhoto { branch.photoCount += 1 }
                for name in components {
                    if branch.children[name] == nil { branch.children[name] = Branch() }
                    branch = branch.children[name]!
                    if countingPhoto { branch.photoCount += 1 }
                }
            }
            func node(name: String, path: String) -> FolderTreeNode {
                let names = children.keys.sorted {
                    let order = $0.localizedStandardCompare($1)
                    return order == .orderedSame ? $0 < $1 : order == .orderedAscending
                }
                return FolderTreeNode(relativePath: path, name: name, photoCount: photoCount, children: names.map {
                    children[$0]!.node(name: $0, path: path.isEmpty ? $0 : path + "/" + $0)
                })
            }
        }

        let root = Branch()
        for path in folder.subdirectoryPaths {
            let parts = path.split(separator: "/").map(String.init)
            guard !path.hasPrefix("/"), !parts.contains(".."), !parts.contains(".") else { continue }
            root.add(parts, countingPhoto: false)
        }
        let rootPath = folder.url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for asset in assets where asset.fileURL.path.hasPrefix(prefix) {
            let relative = String(asset.fileURL.path.dropFirst(prefix.count))
            // Also reconstruct ancestors in catalogs written before folder trees were stored.
            root.add(relative.split(separator: "/").dropLast().map(String.init), countingPhoto: true)
        }
        return root.node(name: folder.name, path: "")
    }
}
