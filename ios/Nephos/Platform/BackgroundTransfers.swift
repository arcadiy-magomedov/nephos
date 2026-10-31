import Foundation
import UIKit

@MainActor
final class BackgroundTransfers: NSObject, URLSessionTaskDelegate, URLSessionDelegate {
    static let shared = BackgroundTransfers()
    static let identifier = "app.nephos.ios.uploads.v1"
    var finishedEvents: (() -> Void)?
    var onOrphanCompletion: (() -> Void)?
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = BackupQueue.concurrency
        config.timeoutIntervalForResource = 60 * 60
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    func upload(request: URLRequest, file: URL, identity: String, cellular: Bool) async throws {
        var request = request
        request.allowsCellularAccess = cellular
        request.allowsExpensiveNetworkAccess = cellular
        request.allowsConstrainedNetworkAccess = false
        try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = identity
            continuations[task.taskIdentifier] = continuation
            task.resume()
        }
    }
    func activeTasks() async -> [URLSessionTask] { await session.allTasks }
    func cancelAll() async {
        for task in await activeTasks() { task.cancel() }
    }
    func cancelOutside(account: String) async {
        for task in await activeTasks() where task.taskDescription?.hasPrefix(account + "/") != true { task.cancel() }
    }
    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let identifier = task.taskIdentifier
        let status = (task.response as? HTTPURLResponse)?.statusCode
        Task { @MainActor in
            let continuation = self.continuations.removeValue(forKey: identifier)
            if let error {
                continuation?.resume(throwing: error)
            } else if status == 204 {
                continuation?.resume()
            } else if status == 401 {
                continuation?.resume(throwing: ClientError.signedOut)
            } else {
                continuation?.resume(
                    throwing: ClientError.http(
                        status ?? 0, "Upload part failed; resume will reconcile with the server."))
            }
            if continuation == nil { self.onOrphanCompletion?() }
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.finishedEvents?()
            self.finishedEvents = nil
        }
    }
}
