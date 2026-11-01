import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import NephosCore

final class ImageDecodingTests: XCTestCase {
    private func fixture() throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 128, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 64))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    @MainActor
    func testDecodeAndCropAreBoundedAndRunOffMainThread() async throws {
        let bytes = try fixture()
        let worker = Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            let image = try ImageDecoding.thumbnail(bytes, maximumPixels: 32)
            XCTAssertEqual(image.width, 32)
            XCTAssertEqual(image.height, 16)
            let crop = try ImageDecoding.crop(image, rect: CGRect(x: 0, y: 0, width: 8, height: 8))
            XCTAssertEqual(crop.width, 8)
            return image.width
        }
        let result = try await worker.value
        XCTAssertEqual(result, 32)
    }
    func testInvalidImagesAndUnboundedDimensionsFailExplicitly() throws {
        XCTAssertThrowsError(try ImageDecoding.thumbnail(Data(), maximumPixels: 32))
        XCTAssertThrowsError(try ImageDecoding.thumbnail(fixture(), maximumPixels: 0))
        XCTAssertThrowsError(try ImageDecoding.thumbnail(fixture(), maximumPixels: 4097))
    }
    func testCancelledDecodeThrows() async throws {
        let bytes = try fixture()
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ImageDecoding.thumbnail(bytes, maximumPixels: 32)
        }
        do {
            _ = try await worker.value
            XCTFail("Cancelled decoding must not return an image.")
        } catch is CancellationError {}
    }
}
