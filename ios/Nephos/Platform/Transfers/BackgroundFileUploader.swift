import Foundation
import OSLog

// URLSession invokes delegates on its serial queue; session creation is protected by sessionLock.
final class BackgroundFileUploader: NSObject, FileUploadTransport, URLSessionTaskDelegate, @unchecked Sendable {
    let identifier: String
    private let sessionLock = NSLock()
    private var instance: URLSession?
    private let events: FileUploadEventStore
    private let onEvent: @Sendable () -> Void
    private let onFinished: @MainActor @Sendable () -> Void
    private let onError: @Sendable (String) -> Void
    private let logger = Logger(subsystem: "app.nephos.ios", category: "BackgroundUpload")

    init(
        identifier: String, events: FileUploadEventStore, onEvent: @escaping @Sendable () -> Void,
        onFinished: @escaping @MainActor @Sendable () -> Void, onError: @escaping @Sendable (String) -> Void
    ) throws {
        guard !identifier.isEmpty else {
            throw FileUploadError.invalid("A stable background session identifier is required.")
        }
        self.identifier = identifier
        self.events = events
        self.onEvent = onEvent
        self.onFinished = onFinished
        self.onError = onError
    }

    func activate() { _ = session() }

    private func session() -> URLSession {
        sessionLock.withLock {
            if let instance { return instance }
            let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
            configuration.httpMaximumConnectionsPerHost = 4
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            instance = session
            return session
        }
    }

    func active() async -> [FileUploadDescriptor] {
        await session().allTasks.compactMap { task in
            do { return try FileUploadDescriptor.parse(task.taskDescription) } catch {
                task.cancel()
                logger.error(
                    "Cancelled an upload task with invalid identity: \(error.localizedDescription, privacy: .private)")
                onError("A background file upload could not be recovered.")
                return nil
            }
        }
    }

    func enqueue(_ transfer: FileUploadDescriptor, request: URLRequest, file: URL) async throws {
        let description = try transfer.taskDescription()
        let prepared = try FileUploadRequest.prepare(request, upload: transfer, file: file)
        let task = session().uploadTask(with: prepared, fromFile: file)
        task.taskDescription = description
        task.countOfBytesClientExpectsToSend = transfer.byteCount
        task.countOfBytesClientExpectsToReceive = 0
        task.resume()
    }

    func cancel(scope: String?) async {
        for task in await session().allTasks {
            do {
                let transfer = try FileUploadDescriptor.parse(task.taskDescription)
                if scope == nil || transfer.scope == scope { task.cancel() }
            } catch {
                task.cancel()
                logger.warning("Cancelled an unrecoverable upload task")
            }

        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        do {
            let transfer = try FileUploadDescriptor.parse(task.taskDescription)
            Task { await events.update(transfer, bytes: totalBytesSent) }
        } catch { onError(error.localizedDescription) }
    }

    func cancel(ids: Set<UUID>) async {
        for task in await session().allTasks {
            do {
                if ids.contains(try FileUploadDescriptor.parse(task.taskDescription).id) { task.cancel() }
            } catch {
                task.cancel()
                logger.warning("Cancelled an unrecoverable file upload task")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do {
            let transfer = try FileUploadDescriptor.parse(task.taskDescription)
            let response = task.response as? HTTPURLResponse
            let sameOrigin =
                task.originalRequest?.url.flatMap { original in
                    response?.url.map { FileUploadRequest.sameOrigin(original, $0) }
                } ?? false
            let message =
                !sameOrigin && response != nil
                ? "The upload endpoint redirected outside the requested server origin."
                : error?.localizedDescription
            // Persist before URLSession can deliver its finished-events callback.
            try events.record(
                FileUploadReceipt(
                    upload: transfer, status: sameOrigin ? response?.statusCode : nil,
                    error: message, cancelled: (error as? URLError)?.code == .cancelled, completedAt: Date()))
            onEvent()
        } catch {
            logger.error("Unable to persist upload outcome: \(error.localizedDescription, privacy: .private)")
            onError("Could not save an upload result. \(error.localizedDescription)")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in onFinished() }
    }
}
