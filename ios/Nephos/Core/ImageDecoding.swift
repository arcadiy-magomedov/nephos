import CoreGraphics
import Foundation
import ImageIO

enum ImageDecoding {
    static func thumbnail(_ bytes: Data, maximumPixels: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard maximumPixels > 0, maximumPixels <= 4096,
            let source = CGImageSourceCreateWithData(
                bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { throw ClientError.invalid("Preview format or dimensions are unsupported.") }
        try Task.checkCancellation()
        return image
    }

    static func crop(_ image: CGImage, rect: CGRect) throws -> CGImage {
        try Task.checkCancellation()
        guard let result = image.cropping(to: rect) else {
            throw ClientError.invalid("The face crop is unavailable.")
        }
        try Task.checkCancellation()
        return result
    }
}
