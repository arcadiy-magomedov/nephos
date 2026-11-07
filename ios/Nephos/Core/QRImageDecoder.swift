import CoreImage
import Foundation
import ImageIO

enum QRImageDecoder {
    static func payload(_ data: Data) throws -> String {
        guard data.count <= 32 * 1024 * 1024,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary),
            let detector = CIDetector(
                ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else { throw QREnrollmentError.invalidQR }
        let codes = detector.features(in: CIImage(cgImage: image)).compactMap {
            ($0 as? CIQRCodeFeature)?.messageString
        }
        // Ambiguous images never silently select a credential.
        guard codes.count == 1, let payload = codes.first else { throw QREnrollmentError.invalidQR }
        _ = try EnrollmentQR.parse(payload)
        return payload
    }
}
