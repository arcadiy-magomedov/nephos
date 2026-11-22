import Foundation

extension UploadItem {
    var feedback: String {
        switch phase {
        case .failed: "Failed"
        case .succeeded: "Uploaded"
        case .queued: "Scheduled"
        case .preparing: "Preparing"
        case .verifying: "Verifying"
        case .uploading, .scheduled:
            if let progress, progress >= 1 {
                "Verifying"
            } else if let progress, receivedBytes > 0 {
                "Uploading \(Int(progress * 100))%"
            } else {
                "Scheduled"
            }
        }
    }

    var localPreview: LocalMediaItem {
        LocalMediaItem(
            id: localIdentifier,
            kind: primaryResource?.descriptor.mediaType.hasPrefix("video/") == true ? .video : .photo,
            capturedAt: capturedAt, modifiedAt: nil, duration: 0, pixelWidth: 1, pixelHeight: 1,
            isLivePhoto: resources.contains {
                ["pairedVideo", "fullSizePairedVideo", "adjustmentBasePairedVideo"].contains($0.descriptor.role)
            })
    }
}
