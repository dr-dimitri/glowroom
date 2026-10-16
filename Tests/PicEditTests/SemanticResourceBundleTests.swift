import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Packaged semantic resources")
struct SemanticResourceBundleTests {
    @Test func applicationUsesItsOwnResourcesWithoutDevelopmentPathFallback() throws {
        let fixture = try resourceFixture(includeManifest: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(fixture.bundle.bundleURL.pathExtension == "app")
        let manifest = try SemanticPackageManifest.approved(mainBundle: fixture.bundle)
        #expect(manifest.descriptor == SemanticLocalProviderFactory.descriptor)
        #expect(manifest.files.map(\.path) == ["synthetic/app-only.bin"])
    }

    @Test func missingApplicationResourcesRejectInsteadOfUsingTestBuildResources() throws {
        // Bundle.module is present for this test process. The simulated app
        // must still reject a missing signed resource bundle or manifest.
        for includeEmptyBundle in [false, true] {
            let fixture = try resourceFixture(includeManifest: false, includeEmptyBundle: includeEmptyBundle)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            #expect(throws: SemanticEmbeddingError.invalidInstallation) {
                try SemanticPackageManifest.approved(mainBundle: fixture.bundle)
            }
        }
    }

    private func resourceFixture(includeManifest: Bool, includeEmptyBundle: Bool = true) throws -> (root: URL, bundle: Bundle) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-app-resource-" + UUID().uuidString)
        let app = root.appendingPathComponent("PicEdit.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        func info(_ directory: URL, type: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "picedit.synthetic." + UUID().uuidString,
                "CFBundleName": "PicEdit", "CFBundlePackageType": type,
                "CFBundleExecutable": "PicEdit", "CFBundleInfoDictionaryVersion": "6.0"
            ], format: .xml, options: 0)
            try data.write(to: directory.appendingPathComponent("Info.plist"))
        }
        try info(contents, type: "APPL")
        if includeEmptyBundle {
            let bundleContents = resources.appendingPathComponent("PicEdit_PicEdit.bundle/Contents", isDirectory: true)
            let bundleResources = bundleContents.appendingPathComponent("Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: bundleResources, withIntermediateDirectories: true)
            try info(bundleContents, type: "BNDL")
            if includeManifest {
                let manifest = SemanticPackageManifest(schemaVersion: 1, descriptor: SemanticLocalProviderFactory.descriptor,
                    files: [.init(path: "synthetic/app-only.bin", bytes: 1, sha256: String(repeating: "0", count: 64))])
                try SemanticInstallationIO.json(manifest).write(to: bundleResources.appendingPathComponent("SemanticApprovedPackage.json"))
            }
        }
        return (root, try #require(Bundle(url: app)))
    }
}
