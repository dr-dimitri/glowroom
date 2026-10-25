import Foundation
import GlowroomCore
import Darwin

// MCP 2025-06-18 stdio: newline-delimited JSON-RPC only on stdout.
// No SDK is required for this restricted tools-only transport.
let arguments = ProcessInfo.processInfo.arguments
guard arguments.count == 3, arguments[1] == "--connection" else {
    FileHandle.standardError.write(Data("Usage: GlowroomMCP --connection <connection.json from Glowroom>\n".utf8))
    exit(64)
}
let connection = URL(fileURLWithPath: arguments[2])
var initialized = false
var buffer = Data()
var oversize = false

func response(_ request: MCPJSON) -> MCPJSON? {
    let id = request["id"]
    let validID: Bool
    switch id {
    case .null: validID = true
    case .string(let value): validID = value.utf8.count <= 128
    case .number(let value): validID = value.isFinite && value.rounded() == value && abs(value) <= 9_007_199_254_740_991
    default: validID = false
    }
    func error(_ code: Int, _ message: String) -> MCPJSON { .object(["jsonrpc": .string("2.0"), "id": validID ? id : .null, "error": .object(["code": .number(Double(code)), "message": .string(message)])]) }
    guard validID, request["jsonrpc"].string == "2.0", let method = request["method"].string else { return error(-32600, "Invalid request") }
    if id == .null { return nil }
    let result: MCPJSON
    switch method {
    case "initialize":
        guard !initialized, request["params"]["protocolVersion"].string != nil,
              request["params"]["capabilities"].object != nil,
              request["params"]["clientInfo"]["name"].string != nil,
              request["params"]["clientInfo"]["version"].string != nil else { return error(-32602, "Invalid initialization") }
        // A client may offer a newer revision. MCP negotiation returns the
        // supported version; the client decides whether it can continue.
        initialized = true
        result = .object(["protocolVersion": .string(MCPContract.protocolVersion), "capabilities": .object(["tools": .object([:])]), "serverInfo": .object(["name": .string("GlowroomMCP"), "version": .string("1.0.0")])])
    case "ping": result = .object([:])
    case "tools/list":
        guard initialized else { return error(-32000, "Initialize first") }
        result = .object(["tools": MCPContract.toolSchemas])
    case "tools/call":
        guard initialized else { return error(-32000, "Initialize first") }
        do {
            guard let params = request["params"].object, Set(params.keys).isSubset(of: ["name", "arguments", "_meta"]), let name = params["name"]?.string else { throw MCPFailure("invalid_arguments", "Invalid tool call.") }
            let args = params["arguments"] ?? .object([:])
            _ = try MCPContract.validate(tool: name, arguments: args)
            result = try MCPLocalServer.call(connectionURL: connection, tool: name, arguments: args)
        } catch {
            result = MCPContract.textResult((error as? MCPFailure ?? MCPFailure("transport", "Cannot contact Glowroom.")).json, isError: true)
        }
    default: return error(-32601, "Method not found")
    }
    return .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
}

func emit(_ json: MCPJSON) {
    guard let data = try? JSONEncoder().encode(json), data.count <= MCPContract.maximumResponseBytes else { return }
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
}

// Read bounded chunks instead of readLine(), which would allocate an arbitrarily
// large client-controlled line before checking the product's 1 MiB limit.
var chunk = [UInt8](repeating: 0, count: 16_384)
while true {
    let count = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
    if count <= 0 { break }
    for byte in chunk.prefix(count) {
        if byte == 10 {
            if oversize {
                emit(.object(["jsonrpc": .string("2.0"), "id": .null, "error": .object(["code": .number(-32600), "message": .string("Message exceeds 1 MiB")])]))
            } else if let request = try? MCPContract.decodeMessage(buffer) {
                if let result = response(request) { emit(result) }
            } else {
                emit(.object(["jsonrpc": .string("2.0"), "id": .null, "error": .object(["code": .number(-32700), "message": .string("Parse error")])]))
            }
            buffer.removeAll(keepingCapacity: true); oversize = false
        } else if !oversize {
            if buffer.count == MCPContract.maximumRequestBytes { buffer.removeAll(keepingCapacity: true); oversize = true }
            else { buffer.append(byte) }
        }
    }
}
