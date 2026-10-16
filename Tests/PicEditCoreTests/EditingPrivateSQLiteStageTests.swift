import Foundation
import Darwin
import Testing
@testable import PicEditCore

@Suite("Private SQLite stage cleanup has actual native ownership")
struct EditingPrivateSQLiteStageTests {
    @Test func shallowCleanupRemovesOnlyRegisteredSameInodes() throws {
        let stage = try EditingPrivateSQLiteStage(prefix:"PicEdit-Test-Own-Stage-")
        let fd = try stage.createFile("edits.sqlite")
        #expect(write(fd,[UInt8(1),2,3],3) == 3)
        try stage.prepareAbsentWALFiles()
        let path = stage.directory.url
        stage.cleanup()
        #expect(!FileManager.default.fileExists(atPath:path.path))
    }
    @Test func foreignReplacementAndUnknownChildArePreservedWithoutRecursiveDelete() throws {
        let stage = try EditingPrivateSQLiteStage(prefix:"PicEdit-Test-Replaced-Stage-")
        _ = try stage.createFile("edits.sqlite")
        let replacement = Data("foreign replacement".utf8),unknown = Data("unknown must survive".utf8)
        try replacement.write(to:stage.url("edits.sqlite"),options:.atomic)
        try unknown.write(to:stage.url("unknown"))
        stage.cleanup()
        #expect(try Data(contentsOf:stage.url("edits.sqlite")) == replacement)
        #expect(try Data(contentsOf:stage.url("unknown")) == unknown)
        // Tests own these synthetic foreign bytes; production cleanup does not.
        try FileManager.default.removeItem(at:stage.directory.url)
    }
    @Test func exchangedDirectoryCannotRedirectCleanupIntoForeignTree() throws {
        let stage = try EditingPrivateSQLiteStage(prefix:"PicEdit-Test-Stage-Directory-")
        _ = try stage.createFile("edits.sqlite")
        let original = stage.directory.url,moved = original.appendingPathExtension("retained")
        try FileManager.default.moveItem(at:original,to:moved)
        try FileManager.default.createDirectory(at:original,withIntermediateDirectories:false)
        let foreign = Data("foreign directory content".utf8)
        try foreign.write(to:original.appendingPathComponent("edits.sqlite"))
        stage.cleanup()
        #expect(try Data(contentsOf:original.appendingPathComponent("edits.sqlite")) == foreign)
        #expect(FileManager.default.fileExists(atPath:moved.appendingPathComponent("edits.sqlite").path))
        try FileManager.default.removeItem(at:original);try FileManager.default.removeItem(at:moved)
    }
}
