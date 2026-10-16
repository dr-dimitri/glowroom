import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Semantic managed-file destination protection", .timeLimit(.minutes(1)))
struct SemanticManagedFilesTests {
    @Test func directoryIdentityRejectsNestedAndAliasedTargetsWithoutPrefixFalsePositives() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-paths-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("SemanticModels", isDirectory: true)
        let nested = root.appendingPathComponent("generation", isDirectory: true)
        let outside = directory.appendingPathComponent("SemanticModels-other", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("nested-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
        #expect(ManagedFileProtection.containsDestination(root.appendingPathComponent("a.jpg"), in: root))
        #expect(ManagedFileProtection.containsDestination(nested.appendingPathComponent("a.jpg"), in: root))
        #expect(ManagedFileProtection.containsDestination(alias.appendingPathComponent("a.jpg"), in: root))
        #expect(!ManagedFileProtection.containsDestination(outside.appendingPathComponent("a.jpg"), in: root))
    }

    @Test func quarantineFamilyProtectsLateDirectoriesAndAliasesWithoutBlockingOtherParents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-family-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let family = ManagedDirectoryFamily(parent: directory, childNamePrefix: "semantic-index-quarantine-")
        let quarantine = directory.appendingPathComponent("semantic-index-quarantine-" + UUID().uuidString, isDirectory: true)
        let nested = quarantine.appendingPathComponent("nested", isDirectory: true)
        let outside = directory.appendingPathComponent("export", isDirectory: true)
        let sameNameElsewhere = outside.appendingPathComponent(quarantine.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sameNameElsewhere, withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("quarantine-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
        #expect(ManagedFileProtection.containsDestination(nested.appendingPathComponent("foreign.sqlite"), in: family))
        #expect(ManagedFileProtection.containsDestination(alias.appendingPathComponent("foreign.sqlite"), in: family))
        #expect(!ManagedFileProtection.containsDestination(sameNameElsewhere.appendingPathComponent("backup.sqlite"), in: family))
        #expect(!ManagedFileProtection.containsDestination(outside.appendingPathComponent("backup.sqlite"), in: family))
    }

    @Test func jpegRejectsQuarantineFamilyBeforeDecodeAndPreservesExistingPayload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-quarantine-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let family = ManagedDirectoryFamily(parent: directory, childNamePrefix: "semantic-index-quarantine-")
        let quarantine = directory.appendingPathComponent("semantic-index-quarantine-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let target = quarantine.appendingPathComponent("foreign-payload.jpg")
        let payload = Data("quarantined-foreign-test-bytes".utf8)
        try payload.write(to: target)
        let request = JPEGExportRequest(sourceURL: directory.appendingPathComponent("unreadable-source.png"),
            destinationURL: target, settings: .neutral, options: JPEGExportOptions(),
            overwriteExisting: true, protectedDirectoryFamilies: [family])
        await #expect(throws: JPEGExportError.protectedOriginal) { _ = try await JPEGExporter.shared.export(request) }
        #expect(try Data(contentsOf: target) == payload)
    }

    @Test func jpegRejectsModelDirectoryBeforeDecodeAndPreservesExistingPayload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("SemanticModels", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("synthetic-payload.jpg")
        let payload = Data("immutable-model-test-bytes".utf8)
        try payload.write(to: target)
        let request = JPEGExportRequest(sourceURL: directory.appendingPathComponent("unreadable-source.png"),
            destinationURL: target, settings: .neutral, options: JPEGExportOptions(),
            overwriteExisting: true, protectedSourceURLs: [root])
        await #expect(throws: JPEGExportError.protectedOriginal) { _ = try await JPEGExporter.shared.export(request) }
        #expect(try Data(contentsOf: target) == payload)
    }

    @Test @MainActor func backupCannotReplaceIndexOrWriteIntoInstalledModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-backup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("SemanticModels", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = directory.appendingPathComponent("semantic-index.sqlite")
        let payload = Data("synthetic-semantic-index-marker".utf8)
        try payload.write(to: index)
        let editor = EditingModel(directory: directory)
        for _ in 0..<1_000 {
            if !editor.isLoading { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(editor.canBackUp)
        #expect(await editor.createBackup(exportTo: index) == nil)
        #expect(try Data(contentsOf: index) == payload)
        let inside = root.appendingPathComponent("backup.sqlite")
        #expect(await editor.createBackup(exportTo: inside) == nil)
        #expect(!FileManager.default.fileExists(atPath: inside.path))
        let quarantine = directory.appendingPathComponent("semantic-index-quarantine-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let foreign = quarantine.appendingPathComponent("semantic-index.sqlite")
        try payload.write(to: foreign)
        let alias = directory.appendingPathComponent("quarantine-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: quarantine)
        #expect(await editor.createBackup(exportTo: alias.appendingPathComponent(foreign.lastPathComponent)) == nil)
        #expect(try Data(contentsOf: foreign) == payload)

    }
}
