import Foundation
import Darwin

public struct MCPConnection: Codable, Sendable {
    public let socketPath: String
    public let session: String
    public let secret: String
}

/// Unix sockets keep the catalog in the running app. The dedicated serial IO
/// queue bounds peers to one; render work still uses the existing app budgets.
public final class MCPLocalServer: @unchecked Sendable {
    public typealias Handler = @Sendable (String, MCPJSON) async -> MCPJSON
    public let connectionURL: URL
    private let connection: MCPConnection
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var peer: Int32 = -1
    private var stopped = false
    private let directory: URL

    public init(handler: @escaping Handler) throws {
        directory = URL(fileURLWithPath: "/private/tmp/glowroom-mcp-\(getuid())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        connectionURL = directory.appendingPathComponent("connection.json")
        connection = MCPConnection(socketPath: directory.appendingPathComponent("ipc").path, session: UUID().uuidString, secret: UUID().uuidString + UUID().uuidString)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: directory); throw MCPFailure("transport", "Cannot create IPC socket.") }
        listener = fd
        do {
            try MCPSocket.withAddress(connection.socketPath) { address, length in
                guard Darwin.bind(fd, address, length) == 0, chmod(connection.socketPath, 0o600) == 0, Darwin.listen(fd, 1) == 0 else { throw MCPFailure("transport", "Cannot bind IPC socket.") }
            }
            try JSONEncoder().encode(connection).write(to: connectionURL, options: .atomic)
            guard chmod(connectionURL.path, 0o600) == 0 else { throw MCPFailure("transport", "Cannot protect connection file.") }
        } catch { Darwin.close(fd); listener = -1; try? FileManager.default.removeItem(at: directory); throw error }
        DispatchQueue(label: "Glowroom.MCP.IPC", qos: .userInitiated).async { [weak self] in self?.serve(handler) }
    }

    public func stop() {
        lock.lock()
        stopped = true
        let listener = self.listener, peer = self.peer
        self.listener = -1
        if listener >= 0 { Darwin.shutdown(listener, SHUT_RDWR); Darwin.close(listener) }
        if peer >= 0 { Darwin.shutdown(peer, SHUT_RDWR) }
        lock.unlock()
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { stop() }

    private func serve(_ handler: @escaping Handler) {
        while true {
            lock.lock(); let fd = listener, finished = stopped; lock.unlock()
            if finished || fd < 0 { return }
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 { return }
            lock.lock()
            if stopped { lock.unlock(); Darwin.close(client); return }
            peer = client; lock.unlock()
            deferPeer(client, handler)
        }
    }

    private func deferPeer(_ client: Int32, _ handler: @escaping Handler) {
        defer { lock.lock(); peer = -1; Darwin.close(client); lock.unlock() }
        MCPSocket.configure(client)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        do {
            let request = try MCPContract.decodeMessage(MCPSocket.readLine(client, maximum: MCPContract.maximumRequestBytes))
            guard let fields = request.object, Set(fields.keys) == Set(["session", "secret", "tool", "arguments"]),
                  request["session"].string == connection.session, request["secret"].string == connection.secret,
                  let name = request["tool"].string else { throw MCPFailure("access_denied", "Session access was revoked or is invalid.") }
            _ = try MCPContract.validate(tool: name, arguments: request["arguments"])
            let completed = DispatchSemaphore(value: 0)
            let box = MCPResponseBox()
            // The serial IO thread waits; the cooperative executor and MainActor
            // remain available for user edits and bounded rendering.
            Task { box.value = await handler(name, request["arguments"]); completed.signal() }
            completed.wait()
            lock.lock(); let revoked = stopped; lock.unlock()
            guard !revoked else { return }
            try MCPSocket.writeLine(client, data: JSONEncoder().encode(box.value), maximum: MCPContract.maximumResponseBytes)
        } catch {
            let failure = error as? MCPFailure ?? MCPFailure("transport", "IPC request failed.")
            try? MCPSocket.writeLine(client, data: JSONEncoder().encode(MCPContract.textResult(failure.json, isError: true)), maximum: MCPContract.maximumResponseBytes)
        }
    }

    public static func call(connectionURL: URL, tool: String, arguments: MCPJSON) throws -> MCPJSON {
        let connectionFD = Darwin.open(connectionURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard connectionFD >= 0 else { throw MCPFailure("access_denied", "Connection file is absent or unavailable.") }
        defer { Darwin.close(connectionFD) }
        var info = stat()
        guard fstat(connectionFD, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 16_384 else { throw MCPFailure("access_denied", "Connection file must be a private regular file owned by this user.") }
        var connectionData = Data(), connectionBuffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(connectionFD, &connectionBuffer, connectionBuffer.count)
            guard count >= 0 else { throw MCPFailure("access_denied", "Cannot read connection file.") }
            if count == 0 { break }
            guard connectionData.count + count <= 16_384 else { throw MCPFailure("access_denied", "Connection file exceeds its size limit.") }
            connectionData.append(contentsOf: connectionBuffer.prefix(count))
        }
        let connection = try JSONDecoder().decode(MCPConnection.self, from: connectionData)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPFailure("transport", "Cannot create connection.") }
        defer { Darwin.close(fd) }
        MCPSocket.configure(fd)
        try MCPSocket.withAddress(connection.socketPath) { address, length in
            guard Darwin.connect(fd, address, length) == 0 else { throw MCPFailure("access_denied", "Glowroom is not running or sharing has ended.") }
        }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw MCPFailure("access_denied", "IPC peer belongs to another user.") }
        let request: MCPJSON = .object(["session": .string(connection.session), "secret": .string(connection.secret), "tool": .string(tool), "arguments": arguments])
        try MCPSocket.writeLine(fd, data: JSONEncoder().encode(request), maximum: MCPContract.maximumRequestBytes)
        return try JSONDecoder().decode(MCPJSON.self, from: MCPSocket.readLine(fd, maximum: MCPContract.maximumResponseBytes))
    }
}

private final class MCPResponseBox: @unchecked Sendable { var value = MCPJSON.null }

private enum MCPSocket {
    static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: 120, tv_usec: 0), yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw MCPFailure("transport", "IPC path too long.") }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        return try withUnsafePointer(to: &address) { try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) } }
    }
    static func readLine(_ fd: Int32, maximum: Int) throws -> Data {
        var data = Data(), bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { throw MCPFailure("outcome_unknown", "Connection ended. Query the request ID before retrying.") }
            if let end = bytes.prefix(count).firstIndex(of: 10) {
                guard data.count + end <= maximum, end == count - 1 else { throw MCPFailure("message_too_large", "Invalid or oversized message.") }
                data.append(contentsOf: bytes[..<end]); return data
            }
            guard data.count + count <= maximum else { throw MCPFailure("message_too_large", "Message limit exceeded.") }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
    static func writeLine(_ fd: Int32, data: Data, maximum: Int) throws {
        guard data.count <= maximum else { throw MCPFailure("message_too_large", "Message limit exceeded.") }
        var line = data; line.append(10)
        try line.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                guard count > 0 else { throw MCPFailure("outcome_unknown", "Connection ended. Query the request ID before retrying.") }
                written += count
            }
        }
    }
}
