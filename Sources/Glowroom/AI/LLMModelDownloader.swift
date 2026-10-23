import Foundation

/// URLSession streams multi-gigabyte weights to disk; no Data-sized copy enters
/// the app heap. A generous transfer deadline supports slower connections while
/// request inactivity and explicit cancellation still terminate promptly.
final class LLMModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let maximumBytes: Int64
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var cancelled = false

    init(destination: URL, maximumBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination; self.maximumBytes = maximumBytes; self.progress = progress
    }

    func download(_ url: URL) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 6 * 60 * 60
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: url)
                lock.lock()
                self.continuation = continuation; self.session = session; self.task = task
                let wasCancelled = cancelled
                lock.unlock()
                task.resume()
                if wasCancelled { task.cancel() }
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= maximumBytes, totalBytesExpectedToWrite <= maximumBytes else {
            result = .failure(LLMModelError.invalidDownload); downloadTask.cancel(); return
        }
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200,
                  let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size == maximumBytes else { throw LLMModelError.invalidDownload }
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(())
        } catch { result = .failure(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation; self.continuation = nil
        let wasCancelled = cancelled; self.task = nil; self.session = nil
        lock.unlock()
        let completed: Result<Void, Error> = wasCancelled ? .failure(CancellationError()) : result ?? error.map { .failure($0) } ?? .failure(LLMModelError.invalidDownload)
        continuation?.resume(with: completed)
        session.finishTasksAndInvalidate()
    }
}
