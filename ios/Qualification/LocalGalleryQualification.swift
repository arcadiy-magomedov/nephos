import AVFoundation
import Photos
import SwiftUI
import os

struct LocalGalleryQualification: View {
    @State private var library = LocalMediaLibrary()
    @State private var session = SignInModel()
    @State private var error: String?
    @State private var uploadInventoryVerified = false
    @State private var photoIdentifiers = UserDefaults.standard.stringArray(forKey: "gallery-photo-identifiers") ?? []
    @State private var videoIdentifier = UserDefaults.standard.string(forKey: "gallery-video-identifier")

    var body: some View {
        LocalGalleryView(session: session, library: library, signOut: {})
            .task(id: library.authorization) {
                guard library.authorization == .authorized else { return }
                do {
                    if !UserDefaults.standard.bool(forKey: "gallery-fixtures") {
                        try await seed()
                        UserDefaults.standard.set(true, forKey: "gallery-fixtures")
                        library.refresh()
                    }
                    try await checkUploadInventory()
                    uploadInventoryVerified = true
                } catch {
                    self.error = error.localizedDescription
                }
            }
            .overlay {
                if let error { Text("Gallery fixture failed: \(error)").padding().background(.regularMaterial) }
            }
            .overlay(alignment: .topLeading) {
                VStack {
                    if uploadInventoryVerified {
                        Text("Upload source checks passed").accessibilityIdentifier("qualification.uploadInventory")
                    }
                    if let photo = library.items.first(where: { photoIdentifiers.contains($0.id) }) {
                        Text(photo.id).accessibilityIdentifier("qualification.photoID")
                    }
                    if let videoIdentifier {
                        Text(videoIdentifier).accessibilityIdentifier("qualification.videoID")
                    }
                }
                .font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1).clipped()
            }
    }

    private func seed() async throws {
        guard Bundle.main.bundleIdentifier == "app.nephos.ui-qualification" else {
            throw ClientError.invalid("Gallery fixtures require the isolated qualification application.")
        }
        let images = (0..<4).map { index in
            UIGraphicsImageRenderer(size: CGSize(width: 720, height: 480)).image { context in
                UIColor(hue: CGFloat(index) / 4, saturation: 0.65, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 720, height: 480))
                ("Nephos photo \(index + 1)" as NSString).draw(
                    at: CGPoint(x: 40, y: 200),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 44), .foregroundColor: UIColor.white])
            }
        }
        let video = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { LocalMediaExport.remove(video) }
        let writer = try AVAssetWriter(outputURL: video, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 480, AVVideoHeightKey: 320])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 480, kCVPixelBufferHeightKey as String: 320,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? LocalMediaError.exportUnavailable }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<12 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(20))
                if writer.status == .failed { throw writer.error ?? LocalMediaError.exportUnavailable }
            }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
                let buffer
            else { throw LocalMediaError.exportUnavailable }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let bytes = CVPixelBufferGetBaseAddress(buffer) {
                memset(bytes, Int32(40 + index * 10), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 4)) else {
                throw writer.error ?? LocalMediaError.exportUnavailable
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 3, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? LocalMediaError.exportUnavailable }
        let photos = OSAllocatedUnfairLock(initialState: [String]())
        let videoID = OSAllocatedUnfairLock<String?>(initialState: nil)
        try await PHPhotoLibrary.shared().performChanges {
            for (index, image) in images.enumerated() {
                let request = PHAssetChangeRequest.creationRequestForAsset(from: image)
                request.creationDate = Date().addingTimeInterval(-Double(index) * 86_400)
                if let id = request.placeholderForCreatedAsset?.localIdentifier { photos.withLock { $0.append(id) } }
            }
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: video)
            videoID.withLock { $0 = request?.placeholderForCreatedAsset?.localIdentifier }
        }
        photoIdentifiers = photos.withLock { $0 }
        videoIdentifier = videoID.withLock { $0 }
        guard photoIdentifiers.count == images.count, videoIdentifier != nil else {
            throw ClientError.invalid("Photos did not return the qualification fixture identifiers.")
        }
        UserDefaults.standard.set(photoIdentifiers, forKey: "gallery-photo-identifiers")
        UserDefaults.standard.set(videoIdentifier, forKey: "gallery-video-identifier")
    }

    private func checkUploadInventory() async throws {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue)
        let expected = PHAsset.fetchAssets(with: options).count
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { LocalMediaExport.remove(directory) }
        let source = UploadPhotoLibrary()
        let scope = "native-fixture-inventory"
        let first = try SQLiteUploadRepository(url: directory.appendingPathComponent("first.sqlite"))
        try await first.setPolicy(.allNetworks, scope: scope)
        try await source.discover(repository: first, scope: scope)
        let initial = try await first.snapshot(scope: scope, limit: expected)
        guard initial.batch?.total == expected, initial.failedCount == 0 else {
            throw ClientError.invalid(
                "Native upload discovery expected \(expected) items, found \(initial.batch?.total ?? 0), with \(initial.failedCount) failures."
            )
        }
        let second = try SQLiteUploadRepository(url: directory.appendingPathComponent("second.sqlite"))
        try await second.setPolicy(.allNetworks, scope: scope)
        try await source.discover(repository: second, scope: scope)
        let rebuilt = try await second.snapshot(scope: scope, limit: expected)
        guard Set(initial.pending.map(\.resourceSetID)) == Set(rebuilt.pending.map(\.resourceSetID)) else {
            throw ClientError.invalid("Photos source identity was not stable across upload database reconstruction.")
        }
    }
}
