import Foundation
import OSLog
import Photos

// PhotoKit calls back on arbitrary queues; the lock owns the file, request and one-shot continuation.
final class PhotoResourceExport: @unchecked Sendable {
    private let lock = NSLock()
    private var file: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var request: PHAssetResourceDataRequestID?
    private var cancelled = false
    private var finished = false
    private var writeError: Error?

    func write(_ resource: PHAssetResource, to url: URL) async throws {
        guard
            FileManager.default.createFile(
                atPath: url.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        else { throw ClientError.invalid("Unable to stage the original. Check available device storage.") }
        let output = try FileHandle(forWritingTo: url)
        lock.withLock { file = output }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let shouldStart = lock.withLock {
                    self.continuation = continuation
                    return !cancelled
                }
                guard shouldStart else {
                    complete(CancellationError())
                    return
                }
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                let id = PHAssetResourceManager.default().requestData(
                    for: resource, options: options,
                    dataReceivedHandler: { [self] data in append(data) },
                    completionHandler: { [self] error in complete(error) })
                let stop = lock.withLock {
                    request = id
                    return cancelled || writeError != nil
                }
                if stop { PHAssetResourceManager.default().cancelDataRequest(id) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func append(_ data: Data) {
        let stop: PHAssetResourceDataRequestID? = lock.withLock {
            guard !finished, !cancelled, writeError == nil else { return nil }
            do {
                try file?.write(contentsOf: data)
                return nil
            } catch {
                writeError = error
                return request
            }
        }
        if let stop { PHAssetResourceManager.default().cancelDataRequest(stop) }
    }

    private func complete(_ error: Error?) {
        let result: (CheckedContinuation<Void, Error>?, Error?) = lock.withLock {
            guard !finished else { return (nil, nil) }
            finished = true
            var failure: Error? = cancelled ? CancellationError() : writeError ?? error
            do {
                try file?.synchronize()
                try file?.close()
            } catch { failure = failure ?? error }
            file = nil
            let saved = continuation
            continuation = nil
            return (saved, failure)
        }
        if let error = result.1 { result.0?.resume(throwing: error) } else { result.0?.resume() }
    }

    private func cancel() {
        let id = lock.withLock {
            cancelled = true
            return request
        }
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
}
