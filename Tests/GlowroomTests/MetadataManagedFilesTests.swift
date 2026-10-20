import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Metadata managed-file protection")
struct MetadataManagedFilesTests {
    @Test func fixedPathsAliasesAndLateOwnedFamiliesAreProtected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-protection-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("photo-metadata.sqlite")
        let bytes = Data("metadata-must-survive".utf8); try bytes.write(to: database)
        let alias = root.appendingPathComponent("foreign-name.sqlite")
        try FileManager.default.linkItem(at: database, to: alias)
        #expect(ManagedFileProtection.protects(database, directory: root))
        #expect(ManagedFileProtection.protects(alias, directory: root))
        let capturedFamilies = ManagedFileProtection.managedFamilies(in: root)
        let quarantine = root.appendingPathComponent("photo-metadata-quarantine-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let target = quarantine.appendingPathComponent("foreign.jpg")
        #expect(capturedFamilies.contains { ManagedFileProtection.containsDestination(target, in: $0) })
        #expect(!ManagedFileProtection.protects(root.appendingPathComponent("backup.sqlite"), directory: root))
        #expect(try Data(contentsOf: database) == bytes)
    }

    @Test func containmentAtFilesystemRootAndMissingParentsTerminates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-parent-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("Managed", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("target.jpg")
        #expect(ManagedFileProtection.containsDestination(target, in: URL(fileURLWithPath: "/", isDirectory: true)))
        #expect(!ManagedFileProtection.containsDestination(target, in: inside))
        #expect(!ManagedFileProtection.containsDestination(target, in: ManagedDirectoryFamily(parent: inside, childNamePrefix: "metadata-")))
        let missing = root.appendingPathComponent("Missing/Deeper/target.jpg")
        #expect(!ManagedFileProtection.containsDestination(missing, in: inside))
        #expect(!ManagedFileProtection.containsDestination(missing, in: ManagedDirectoryFamily(parent: root, childNamePrefix: "metadata-")))
    }

    @Test func jpegCannotPublishIntoCatalogStagingOrMetadataQuarantine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-jpeg-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for leaf in ["MetadataCatalogStaging", "photo-metadata-quarantine-" + UUID().uuidString,
                     ".catalog-coordination-root-" + UUID().uuidString.lowercased() + ".stage"] {
            let parent = root.appendingPathComponent(leaf, isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let target = parent.appendingPathComponent("protected.jpg"), bytes = Data("foreign-payload".utf8)
            try bytes.write(to: target)
            let request = JPEGExportRequest(sourceURL: root.appendingPathComponent("not-an-image.raw"), destinationURL: target,
                settings: .neutral, options: .init(), overwriteExisting: true,
                protectedSourceURLs: ManagedFileProtection.managedFiles(in: root) + ManagedFileProtection.managedDirectories(in: root),
                protectedDirectoryFamilies: ManagedFileProtection.managedFamilies(in: root))
            await #expect(throws: JPEGExportError.protectedOriginal) { _ = try await JPEGExporter.shared.export(request) }
            #expect(try Data(contentsOf: target) == bytes)
        }
    }

    @Test @MainActor func editBackupCannotReplaceMetadataOrWriteInsideCatalogStage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-backup-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("photo-metadata.sqlite"), bytes = Data("synthetic-metadata".utf8)
        try bytes.write(to: target)
        let editor = EditingModel(directory: root)
        for _ in 0..<2_000 { if !editor.isLoading { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(editor.canBackUp)
        #expect(await editor.createBackup(exportTo: target) == nil)
        #expect(try Data(contentsOf: target) == bytes)
        let stage = root.appendingPathComponent("MetadataCatalogStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        #expect(await editor.createBackup(exportTo: stage.appendingPathComponent("backup.sqlite")) == nil)
        #expect(!FileManager.default.fileExists(atPath: stage.appendingPathComponent("backup.sqlite").path))
    }
}
