import Foundation

struct CloudHTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
}
protocol CloudHTTPOperation: Sendable {
    func resume()
    func cancel()
    func value() async throws -> CloudHTTPResponse
}
protocol CloudHTTPTransport: Sendable {
    func operation(for request: URLRequest) throws -> any CloudHTTPOperation
}

struct BoundedCloudHTTPTransport: CloudHTTPTransport {
    static let maximumResponseBytes = 256 * 1_024
    func operation(for request: URLRequest) throws -> any CloudHTTPOperation {
        guard request.url?.absoluteString == "https://api.anthropic.com/v1/messages",
              request.httpMethod == "POST" else { throw AICloudError.network }
        return BoundedCloudHTTPOperation(request: request, limit: Self.maximumResponseBytes)
    }
}

/// A delegate checks every received chunk before retaining it. No data(for:)
/// unbounded buffer, redirect, cookie store, credential store, or response cache.
final class BoundedCloudHTTPOperation: NSObject, CloudHTTPOperation, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var status: Int?
    private var result: Result<CloudHTTPResponse, Error>?
    private var continuation: CheckedContinuation<CloudHTTPResponse, Error>?
    private var started = false
    private var terminalError: Error?
    private var task: URLSessionDataTask!
    private var session: URLSession!

    init(request: URLRequest, limit: Int, protocolClasses: [AnyClass]? = nil) {
        self.limit = limit
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.protocolClasses = protocolClasses
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        task = session.dataTask(with: request)
    }
    func resume() {
        lock.lock()
        let shouldResume = !started && result == nil
        started = true
        lock.unlock()
        if shouldResume { task.resume() }
    }
    func cancel() {
        lock.lock()
        let wasStarted = started
        if terminalError == nil { terminalError = CancellationError() }
        lock.unlock()
        // An active operation keeps its lease until URLSession confirms actual
        // completion. Cancellation must not admit a second in-flight upload.
        if !wasStarted { finish(.failure(CancellationError())) }
        task.cancel()
        session.invalidateAndCancel()
    }
    private func fail(_ error: Error) {
        lock.lock()
        if terminalError == nil { terminalError = error }
        lock.unlock()
        task.cancel()
    }
    func value() async throws -> CloudHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(with: result) }
                else { self.continuation = continuation; lock.unlock() }
            }
        } onCancel: { self.cancel() }
    }
    private func finish(_ value: Result<CloudHTTPResponse, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume(with: value)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            fail(AICloudError.network); completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            fail(AICloudError.responseTooLarge); completionHandler(.cancel); return
        }
        lock.lock(); status = http.statusCode; lock.unlock()
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        let fits = result == nil && chunk.count <= limit - data.count
        if fits { data.append(chunk) }
        lock.unlock()
        if !fits { fail(AICloudError.responseTooLarge) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        fail(AICloudError.redirect)
        completionHandler(nil)
        task.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let terminalError = terminalError; lock.unlock()
        if let terminalError { finish(.failure(terminalError)) }
        else if let error = error as? URLError {
            let mapped: Error = error.code == .cancelled ? CancellationError() : error.code == .timedOut ? AICloudError.timeout : AICloudError.network
            finish(.failure(mapped))
        } else if error != nil { finish(.failure(AICloudError.network)) }
        else {
            lock.lock(); let response = status.map { CloudHTTPResponse(statusCode: $0, data: data) }; lock.unlock()
            if let response { finish(.success(response)) } else { finish(.failure(AICloudError.network)) }
        }
        session.finishTasksAndInvalidate()
    }
}
