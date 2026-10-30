import AVFoundation
import CoreMedia
import ImageIO
import Photos
import SwiftUI
import UniformTypeIdentifiers

// Separate simulator-only executable: no fixture identity or test bypass is compiled into Nephos.
@main
struct PhotosQualificationApp: App {
    @State private var status = "Running synthetic PhotoKit restore qualification…"
    var body: some Scene {
        WindowGroup {
            ScrollView { Text(status).padding().textSelection(.enabled) }
                .task {
                    let result = await PhotosQualification.run()
                    status = result.joined(separator: "\n")
                }
        }
    }
}

@MainActor
enum PhotosQualification {
    static func run() async -> [String] {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let work = root.appendingPathComponent("SyntheticResources", isDirectory: true)
        var report: [String] = []
        var created: [String] = []
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let photos = PhotosLibrary()
            for (kind, types) in [
                ("single-photo", [PHAssetResourceType.photo]),
                ("single-video", [.video]),
                ("live-photo", [.photo, .pairedVideo]),
                ("raw-jpeg", [.photo, .alternatePhoto]),
            ] {
                report.append(
                    "PhotoKit creation API accepts \(kind) resource types: \(PHAssetCreationRequest.supportsAssetResourceTypes(types.map { NSNumber(value: $0.rawValue) }))"
                )
            }
            if photos.authorization == .notDetermined {
                _ = await photos.requestAccess()
            }
            guard photos.authorization == .authorized else {
                throw ClientError.invalid(
                    "Full Photos access is unavailable (status \(photos.authorization.rawValue)). Grant full access in the simulator's Settings and rerun. No restoration or deletion pass is claimed."
                )
            }
            let pairID = UUID().uuidString
            let still = work.appendingPathComponent("NEPHOS-QUALIFICATION.jpg")
            try makeJPEG(still, identifier: pairID)
            let movie = work.appendingPathComponent("NEPHOS-QUALIFICATION.mov")
            try await makeMovie(movie, identifier: pairID)
            for kind in ["single-photo", "single-video", "live-photo"] {
                let files = kind == "single-photo" ? [still] : (kind == "single-video" ? [movie] : [still, movie])
                let roles =
                    kind == "single-photo"
                    ? ["photo"] : (kind == "single-video" ? ["video"] : ["photo", "pairedVideo"])
                let parts = try files.enumerated().map { index, file in
                    let hash = try Hashing.file(file)
                    return ResourcePart(
                        assetId: UUID(), role: roles[index], sha256: hash.sha256, size: hash.size,
                        fileName: file.lastPathComponent,
                        uniformTypeIdentifier: file.pathExtension == "jpg"
                            ? UTType.jpeg.identifier : UTType.quickTimeMovie.identifier)
                }
                let manifest = ResourceManifest(
                    id: UUID(), libraryId: UUID(), kind: kind == "live-photo" ? kind : "single",
                    sourceRevision: "synthetic-simulator-fixture", primaryAssetId: parts[0].assetId, resources: parts,
                    createdAt: "2020-05-06T12:00:00Z")
                let export = VerifiedExport(
                    directory: work, files: files, manifest: manifest, parts: parts, createdAt: "2020-05-06T12:00:00Z")
                guard export.canRestore else {
                    throw ClientError.invalid("This simulator's PhotoKit rejects \(kind) resource creation.")
                }
                let identifier = try await export.saveToPhotos()
                created.append(identifier)
                guard let asset = photos.asset(identifier) else {
                    throw ClientError.invalid("Restored \(kind) is not accessible.")
                }
                guard kind != "live-photo" || asset.mediaSubtypes.contains(.photoLive) else {
                    throw ClientError.invalid("Live Photo creation lost its paired semantics.")
                }
                let resources = photos.resources(asset)
                guard resources.count == parts.count else {
                    throw ClientError.invalid("\(kind) resource count changed.")
                }
                for (index, resource) in resources.enumerated() {
                    let role = photos.role(resource)
                    guard let part = parts.first(where: { $0.role == role }) else {
                        throw ClientError.invalid("Unexpected restored resource role: \(role)")
                    }
                    let downloaded = work.appendingPathComponent("roundtrip-\(index)")
                    try await photos.export(resource, to: downloaded, maximum: part.size + 1, allowNetwork: false)
                    let actual = try Hashing.file(downloaded)
                    guard actual.sha256 == part.sha256, actual.size == part.size else {
                        throw ClientError.invalid("\(kind) was not restored byte-for-byte.")
                    }
                    try FileManager.default.removeItem(at: downloaded)
                }
                guard photos.revision(asset).cleanupSupported == (kind != "live-photo") else {
                    throw ClientError.invalid("Cleanup eligibility changed unexpectedly for \(kind).")
                }
                report.append(
                    "PASS \(kind): real PhotoKit creation, exact original-resource SHA-256/size round-trip, semantic type and cleanup boundary."
                )
            }
            let types = [PHAssetResourceType.photo, .alternatePhoto].map { NSNumber(value: $0.rawValue) }
            report.append(
                "RAW+JPEG API resource-type support: \(PHAssetCreationRequest.supportsAssetResourceTypes(types)); no synthetic RAW sensor file claimed as a camera fixture."
            )
            report.append(
                "PASS simulator qualification. Synthetic fixture Photos IDs: \(created.joined(separator: ", ")).")
        } catch {
            report.append(
                "FAIL \(error.localizedDescription). Created fixture Photos IDs: \(created.joined(separator: ", ")).")
        }
        try? FileManager.default.removeItem(at: work)
        do {
            try JSONEncoder().encode(report).write(to: root.appendingPathComponent("report.json"), options: .atomic)
        } catch { report.append("FAIL report persistence: \(error.localizedDescription)") }
        return report
    }

    static func makeJPEG(_ url: URL, identifier: String) throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        guard let cgImage = image.cgImage,
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw ClientError.invalid("Cannot create the synthetic JPEG fixture.")
        }
        CGImageDestinationAddImage(
            destination, cgImage,
            [
                kCGImagePropertyMakerAppleDictionary: ["17": identifier],
                kCGImageDestinationLossyCompressionQuality: 0.9,
            ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ClientError.invalid("Cannot finalize JPEG fixture.")
        }
    }

    static func makeMovie(_ url: URL, identifier: String) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let identifierMetadata = AVMutableMetadataItem()
        identifierMetadata.identifier = .quickTimeMetadataContentIdentifier
        identifierMetadata.dataType = kCMMetadataBaseDataType_UTF8 as String
        identifierMetadata.value = identifier as NSString
        writer.metadata = [identifierMetadata]
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
            ])
        writer.add(video)
        var description: CMFormatDescription?
        let result = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [
                [
                    kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                        "mdta/com.apple.quicktime.still-image-time",
                    kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                        "com.apple.metadata.datatype.int8",
                ]
            ] as CFArray, formatDescriptionOut: &description)
        guard result == noErr, let description else {
            throw ClientError.invalid("Cannot create Live Photo timed metadata.")
        }
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        writer.add(metadataInput)
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        guard writer.startWriting() else { throw writer.error ?? ClientError.invalid("Movie writer failed.") }
        writer.startSession(atSourceTime: .zero)
        let stillTime = AVMutableMetadataItem()
        stillTime.key = "com.apple.quicktime.still-image-time" as NSString
        stillTime.keySpace = .quickTimeMetadata
        stillTime.value = NSNumber(value: 0)
        stillTime.dataType = "com.apple.metadata.datatype.int8"
        guard
            metadataAdaptor.append(
                AVTimedMetadataGroup(
                    items: [stillTime], timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 30)))
            )
        else {
            throw writer.error ?? ClientError.invalid("Cannot append Live Photo timed metadata.")
        }
        metadataInput.markAsFinished()
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        guard let pixelBuffer else { throw ClientError.invalid("Cannot create video pixel buffer.") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let memory = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(memory, 96, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        for frame in 0..<30 {
            while !video.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    throw writer.error ?? ClientError.invalid("Video writer stopped.")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? ClientError.invalid("Cannot append video fixture frame.")
            }
        }
        video.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? ClientError.invalid("Cannot finalize video fixture.")
        }
    }
}
