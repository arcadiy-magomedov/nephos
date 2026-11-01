import AVKit
import Foundation
import Network
import UIKit

@MainActor @Observable
final class NetworkPolicy {
    static let shared = NetworkPolicy()
    private let monitor = NWPathMonitor()
    private(set) var isExpensive = true
    private(set) var isConstrained = false
    private(set) var isConnected = false
    #if UI_QUALIFICATION
        func qualificationNetwork(constrained: Bool = false) {
            precondition(Bundle.main.bundleIdentifier == "app.nephos.ui-qualification")
            monitor.cancel()
            monitor.pathUpdateHandler = nil
            isConnected = true
            isExpensive = false
            isConstrained = constrained
        }
    #endif
    func allowsBackup(cellular: Bool) -> Bool {
        isConnected && !isConstrained && (cellular || !isExpensive)
    }
    func backupWaitReason(cellular: Bool) -> String? {
        if !isConnected { return "Waiting for a connection" }
        if isConstrained { return "Backup is waiting for Low Data Mode to be turned off." }
        if isExpensive && !cellular { return "Waiting for Wi-Fi. Cellular backup is off." }
        return nil
    }
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isExpensive = path.isExpensive
                self?.isConstrained = path.isConstrained
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.nephos.network"))
    }
}

@MainActor
final class MediaCache {
    static let shared = MediaCache()
    private let images = NSCache<NSString, UIImage>()
    private var generation = UUID()
    init() {
        images.totalCostLimit = LedgerStore.previewBudget
        images.countLimit = 100
    }
    func clear() {
        generation = UUID()
        images.removeAllObjects()
    }
    func preview(
        _ asset: Asset, api: API, account: String, size: PreviewSize = .thumbnail, trash: Bool = false
    ) async throws -> UIImage {
        let key = "\(account)/\(asset.libraryId)/\(asset.id)/\(size.rawValue)/\(trash)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        let boundary = generation
        let request =
            try await
            (trash
            ? api.trashPreviewRequest(asset.id, size: size)
            : api.previewRequest(asset.id, size: size))
        let bytes = try await api.data(request, maximum: 8 * 1024 * 1024)
        try Task.checkCancellation()
        guard boundary == generation else { throw CancellationError() }
        let worker = Task.detached(priority: .userInitiated) {
            try ImageDecoding.thumbnail(bytes, maximumPixels: size.rawValue)
        }
        let image = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        guard boundary == generation else { throw CancellationError() }
        let result = UIImage(cgImage: image)
        images.setObject(result, forKey: key, cost: image.bytesPerRow * image.height)
        return result
    }
    static func original(_ asset: Asset, api: API, directory: URL, maximum: Int64 = LedgerStore.viewerBudget)
        async throws -> URL
    {
        let request = try await UploadClient(api: api).originalRequest(asset.id)
        let session = api.session
        let worker = Task.detached(priority: .utility) {
            try await downloadOriginal(
                asset, request: request, session: session, directory: directory, maximum: maximum)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
    private nonisolated static func downloadOriginal(
        _ asset: Asset, request: URLRequest, session: URLSession, directory: URL, maximum: Int64
    ) async throws -> URL {
        try Task.checkCancellation()
        guard asset.size > 0, asset.size <= maximum else {
            throw ClientError.invalid(
                "This original exceeds the image viewer budget. Use Export all originals to save its exact bytes to Files."
            )
        }
        let free =
            try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard free > asset.size + 64 * 1024 * 1024 else {
            throw ClientError.invalid("Not enough free space to view this original.")
        }
        let ext = asset.isVideo ? (asset.mediaType == "video/quicktime" ? "mov" : "mp4") : "image"
        let file = directory.appendingPathComponent("\(UUID()).\(ext)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw ClientError.invalid("Cannot create a viewer cache file.")
        }
        let handle = try FileHandle(forWritingTo: file)
        do {
            let (stream, response) = try await session.bytes(for: request)
            try HTTP.check(response)
            guard response.expectedContentLength < 0 || response.expectedContentLength == asset.size else {
                throw ClientError.invalid("Original size differs from the committed gallery metadata.")
            }
            var buffer = Data()
            var written: Int64 = 0
            for try await byte in stream {
                buffer.append(byte)
                if buffer.count == 65_536 {
                    try Task.checkCancellation()
                    guard written + Int64(buffer.count) <= asset.size else {
                        throw ClientError.invalid("Original exceeds its declared size.")
                    }
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            guard written + Int64(buffer.count) == asset.size else {
                throw ClientError.invalid("The original download was incomplete.")
            }
            try handle.write(contentsOf: buffer)
            try handle.close()
            let hash = try Hashing.file(file)
            guard hash.sha256 == asset.sha256 else {
                throw ClientError.invalid("Downloaded original failed its SHA-256 integrity check.")
            }
            try Task.checkCancellation()
            return file
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}
