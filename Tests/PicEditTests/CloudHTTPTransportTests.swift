import Foundation
import Testing
@testable import PicEdit

@Suite("Bounded Cloud HTTP", .serialized, .timeLimit(.minutes(1)))
struct CloudHTTPTransportTests {
    @Test func actuallySentBytesPassThroughIsolatedURLProtocol() async throws {
        let payload = Data("synthetic-text-body".utf8)
        let route = CloudProtocolStub.configure { request, client, source in
            #expect(cloudProtocolBody(request) == payload)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-only")
            client.urlProtocol(source, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(source, didLoad: Data("ok".utf8))
            client.urlProtocolDidFinishLoading(source)
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"; request.httpBody = payload
        request.setValue("Bearer fake-only", forHTTPHeaderField: "Authorization")
        let operation = BoundedCloudHTTPOperation(stubRequest: request, limit: 8, route: route)
        operation.resume()
        let result = try await operation.value()
        #expect(result.statusCode == 200 && result.data == Data("ok".utf8))
        #expect(CloudProtocolStub.count(route) == 1)
    }
    @Test func fullProviderBodyObservedAtURLSessionHasNoPhotoMetadata() async throws {
        let route = CloudProtocolStub.configure { request, client, source in
            let body = cloudProtocolBody(request) ?? Data()
            let text = String(decoding: body, as: UTF8.self)
            #expect(!body.isEmpty && body.count <= CloudAIProvider.maximumRequestBytes)
            for forbidden in ["synthetic-asset-id", "/private/synthetic-catalog", "private-photo.RAW", "GPSLatitude", "Exif", "base64"] { #expect(!text.contains(forbidden)) }
            #expect(text.contains("claude-haiku-5-5") && text.contains("userText"))
            client.urlProtocol(source, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(source, didLoad: cloudEnvelope())
            client.urlProtocolDidFinishLoading(source)
        }
        let f = try CloudFixture()
        let provider = CloudAIProvider(keychain: f.keychain, usage: f.usage, transport: ProtocolCloudTransport(route: route))
        await provider.updateConfiguration(enabled: true, requestLimit: 1, monthlyBudgetNanodollars: 1_000_000_000)
        let consent = try await provider.prepareConsent(for: f.request)
        try await provider.grant(consent)
        _ = try await provider.proposal(for: f.request)
        #expect(CloudProtocolStub.count(route) == 1)
    }
    @Test(arguments: [true,false]) func oversizedContentLengthOrChunksAreRejected(_ header: Bool) async throws {
        let route = CloudProtocolStub.configure { request, client, source in
            client.urlProtocol(source, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: header ? ["Content-Length":"1000"] : nil)!, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(source, didLoad: Data(repeating: 65, count: 9))
            client.urlProtocolDidFinishLoading(source)
        }
        let operation = BoundedCloudHTTPOperation(stubRequest: URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!), limit: 8, route: route)
        operation.resume()
        await expectCloud(.responseTooLarge) { _ = try await operation.value() }
        #expect(CloudProtocolStub.count(route) == 1)
    }
    @Test func timeoutIsSanitizedAndNoRetry() async throws {
        let route = CloudProtocolStub.configure { _, client, source in client.urlProtocol(source, didFailWithError: URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey:"private-server-body"])) }
        let operation = BoundedCloudHTTPOperation(stubRequest: URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!), limit: 8, route: route)
        operation.resume()
        await expectCloud(.timeout) { _ = try await operation.value() }
        #expect(CloudProtocolStub.count(route) == 1)
    }
    @Test func cancellationFinishesWaitingTransport() async throws {
        let route = CloudProtocolStub.configure { _,_,_ in }
        let operation = BoundedCloudHTTPOperation(stubRequest: URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!), limit: 8, route: route)
        operation.resume()
        let task = Task { try await operation.value() }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch { #expect(error is CancellationError) }
    }
    @Test func redirectIsRejectedWithoutCredentialForwarding() async throws {
        let route = CloudProtocolStub.configure { request, client, source in
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location":"https://example.invalid/credential-sink"])!
            client.urlProtocol(source, wasRedirectedTo: URLRequest(url: URL(string: "https://example.invalid/credential-sink")!), redirectResponse: response)
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.setValue("Bearer fake-only", forHTTPHeaderField: "Authorization")
        let operation = BoundedCloudHTTPOperation(stubRequest: request, limit: 8, route: route)
        operation.resume()
        await expectCloud(.redirect) { _ = try await operation.value() }
        #expect(CloudProtocolStub.count(route) == 1)
    }
}
final class CloudProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, any URLProtocolClient, URLProtocol) -> Void
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]
    private static var requests: [String: Int] = [:]
    static func count(_ route: String) -> Int { lock.withLock { requests[route, default: 0] } }
    static func configure(_ handler: @escaping Handler) -> String {
        let route = UUID().uuidString
        lock.withLock { handlers[route] = handler; requests[route] = 0 }
        return route
    }
    static func routed(_ request: URLRequest, route: String) -> URLRequest {
        var copy = request; copy.setValue(route, forHTTPHeaderField: "X-PicEdit-Synthetic-Route"); return copy
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let route = request.value(forHTTPHeaderField: "X-PicEdit-Synthetic-Route") ?? ""
        let callback = Self.lock.withLock { Self.requests[route, default: 0] += 1; return Self.handlers[route] }
        if let client { callback?(request, client, self) }
    }
    override func stopLoading() {}
}

private func cloudProtocolBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open(); defer { stream.close() }
    var output = Data(), buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0, output.count + count <= CloudAIProvider.maximumRequestBytes else { return nil }
        if count == 0 { break }
        output.append(contentsOf: buffer.prefix(count))
    }
    return output
}

private struct ProtocolCloudTransport: CloudHTTPTransport {
    let route: String
    func operation(for request: URLRequest) -> any CloudHTTPOperation {
        BoundedCloudHTTPOperation(stubRequest: request, limit: BoundedCloudHTTPTransport.maximumResponseBytes, route: route)
    }
}

private extension BoundedCloudHTTPOperation {
    convenience init(stubRequest: URLRequest, limit: Int, route: String) {
        self.init(request: CloudProtocolStub.routed(stubRequest, route: route), limit: limit, protocolClasses: [CloudProtocolStub.self])
    }
}
