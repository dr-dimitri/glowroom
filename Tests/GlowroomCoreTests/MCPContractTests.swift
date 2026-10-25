import Foundation
import Testing
import Darwin
@testable import GlowroomCore

@Suite("MCP schemas and local IPC", .timeLimit(.minutes(2)))
struct MCPContractTests {
    @Test func duplicateEscapedKeysDeepNestingAndMessageLimitsFailClosed() throws {
        for text in ["{\"values\":{\"exposure\":1,\"exposure\":2}}", "{\"exposure\":1,\"expos\\u0075re\":2}",
                     String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)] {
            #expect(throws: MCPFailure.self) { try MCPContract.decodeMessage(Data(text.utf8)) }
        }
        #expect(throws: MCPFailure.self) { try MCPContract.decodeMessage(Data(repeating: 32, count: MCPContract.maximumRequestBytes + 1)) }
        #expect(try MCPContract.decodeMessage(Data("{\"values\":{\"exposure\":1},\"id\":\"a\\\"b\"}".utf8))["id"].string == "a\"b")
    }
    @Test func everyToolRejectsUnknownFieldsAndSchemasAreClosed() throws {
        guard case .array(let tools) = MCPContract.toolSchemas else { Issue.record("Missing tools"); return }
        #expect(tools.count == 8)
        for tool in tools {
            #expect(tool["inputSchema"]["additionalProperties"] == .bool(false))
            #expect(tool["annotations"]["openWorldHint"] == .bool(false))
            #expect(throws: MCPFailure.self) {
                try MCPContract.validate(tool: tool["name"].string!, arguments: .object(["unexpected": .number(1)]))
            }
        }
        #expect(tools.first { $0["name"].string == "proposal_create" }?["inputSchema"]["properties"]["values"]["additionalProperties"] == .bool(false))
    }

    @Test func numericControlsReuseTheTypedCatalogAndRejectUnsupportedTargets() throws {
        let patch = try MCPContract.patch(.object(["exposure": .number(1)]))
        #expect(try patch.applying(to: .neutral).exposure == 1)
        let invalid: [MCPJSON] = [.object(["temperature": .number(6500)]), .object(["mask_id": .string("x")]),
                               .object(["exposure": .number(100)]), .object(["exposure": .string("1")]), .object([:])]
        for value in invalid {
            #expect(throws: MCPFailure.self) { try MCPContract.patch(value) }
        }
        for value in [-1.0, 101, 1.5, Double.greatestFiniteMagnitude] {
            #expect(throws: MCPFailure.self) { try MCPContract.validate(tool: "photos_query", arguments: .object(["limit": .number(value)])) }
        }
        #expect(throws: MCPFailure.self) { try MCPContract.validate(tool: "preview_render", arguments: .object(["photo_id": .string("x"), "snapshot_id": .string("y"), "maximum_size": .number(2049)])) }
    }

    @Test func privateIPCRespondsAndRevocationClosesTheSession() async throws {
        let server = try MCPLocalServer { name, _ in MCPContract.textResult(.object(["tool": .string(name)])) }
        defer { server.stop() }
        let url = server.connectionURL
        var fileInfo = stat(), directoryInfo = stat()
        #expect(lstat(url.path, &fileInfo) == 0 && fileInfo.st_uid == getuid() && fileInfo.st_mode & 0o777 == 0o600)
        #expect(lstat(url.deletingLastPathComponent().path, &directoryInfo) == 0 && directoryInfo.st_mode & 0o777 == 0o700)
        let response = try await Task.detached {
            try MCPLocalServer.call(connectionURL: url, tool: "session_inspect", arguments: .object([:]))
        }.value
        #expect(response["isError"] == .bool(false))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(throws: MCPFailure.self) { try MCPLocalServer.call(connectionURL: url, tool: "session_inspect", arguments: .object([:])) }
    }

    @Test func connectionFileWithBroadPermissionsIsRejected() async throws {
        let server = try MCPLocalServer { _, _ in MCPContract.textResult(.null) }
        defer { server.stop() }
        #expect(chmod(server.connectionURL.path, 0o644) == 0)
        #expect(throws: MCPFailure.self) { try MCPLocalServer.call(connectionURL: server.connectionURL, tool: "session_inspect", arguments: .object([:])) }
        let alias = server.connectionURL.deletingLastPathComponent().appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: server.connectionURL)
        #expect(throws: MCPFailure.self) { try MCPLocalServer.call(connectionURL: alias, tool: "session_inspect", arguments: .object([:])) }
    }

    @Test func realStdioAdapterUsesOnlyProtocolOutputAndHonorsSessionRevocation() async throws {
        let server = try MCPLocalServer { name, _ in MCPContract.textResult(.object(["tool": .string(name)])) }
        defer { server.stop() }
        // CLT Swift Testing launches a separate swiftpm-testing-helper, so
        // argv[0] belongs to the toolchain rather than this scratch directory.
        var directory = Bundle(for: MCPTestBundleAnchor.self).bundleURL
        var executable: URL?
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("GlowroomMCP")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { executable = candidate; break }
            directory.deleteLastPathComponent()
        }
        if executable == nil, let scratch = ProcessInfo.processInfo.environment["GLOWROOM_TEST_BUILD_PATH"] {
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let root = scratch.hasPrefix("/") ? URL(fileURLWithPath: scratch) : repository.appendingPathComponent(scratch)
            let candidate = root.appendingPathComponent("debug/GlowroomMCP")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { executable = candidate }
        }
        let adapter = try #require(executable, "swift test must build the GlowroomMCP product")
        let url = server.connectionURL
        func run() async throws -> [MCPJSON] {
            try await Task.detached {
                let child = Process(), input = Pipe(), output = Pipe(), diagnostic = Pipe()
                child.executableURL = adapter; child.arguments = ["--connection", url.path]
                child.standardInput = input; child.standardOutput = output; child.standardError = diagnostic
                try child.run()
                let lines = [
                    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2099-01-01\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}",
                    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
                    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
                    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"session_inspect\",\"arguments\":{}}}",
                    "{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"ping\"}"
                ]
                input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
                try input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                child.waitUntilExit()
                guard child.terminationStatus == 0, diagnostic.fileHandleForReading.readDataToEndOfFile().isEmpty else { throw MCPFailure("test", "Adapter failed or wrote unexpected diagnostics.") }
                return try data.split(separator: 10).map { try JSONDecoder().decode(MCPJSON.self, from: Data($0)) }
            }.value
        }
        let active = try await run()
        #expect(active.count == 4)
        #expect(active[0]["result"]["protocolVersion"].string == MCPContract.protocolVersion)
        #expect(active[2]["result"]["isError"] == .bool(false))
        #expect(active[3]["id"] == .null && active[3]["error"]["code"] == .number(-32600))
        server.stop()
        let revoked = try await run()
        #expect(revoked[2]["result"]["isError"] == .bool(true))
    }
}

private final class MCPTestBundleAnchor: NSObject {}
