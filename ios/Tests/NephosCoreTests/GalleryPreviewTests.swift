import Foundation
import XCTest

@testable import NephosCore

final class GalleryPreviewTests: XCTestCase {
    func testRefreshKeepsDisplayedImageUntilReplacementArrives() {
        var preview = GalleryPreview<String>()
        let epoch = UUID()
        let generation = UUID()
        preview.beginRefresh(epoch: epoch, generation: generation, source: "local:photo")
        XCTAssertNil(preview.value)
        preview.value = "original thumbnail"
        for _ in 0..<10 {
            preview.beginRefresh(epoch: epoch, generation: generation, source: "local:photo")
            XCTAssertEqual(preview.value, "original thumbnail")
        }
        preview.value = "refreshed thumbnail"
        XCTAssertEqual(preview.value, "refreshed thumbnail")
    }

    func testAccountLibraryAndSourceChangesClearPreviousImage() {
        var preview = GalleryPreview<String>()
        var epoch = UUID()
        var generation = UUID()
        preview.beginRefresh(epoch: epoch, generation: generation, source: "local:photo")
        preview.value = "private thumbnail"
        epoch = UUID()
        preview.beginRefresh(epoch: epoch, generation: generation, source: "local:photo")
        XCTAssertNil(preview.value)
        preview.value = "another account thumbnail"
        generation = UUID()
        preview.beginRefresh(epoch: epoch, generation: generation, source: "local:photo")
        XCTAssertNil(preview.value)
        preview.value = "another library thumbnail"
        preview.beginRefresh(epoch: epoch, generation: generation, source: "asset:another-photo")
        XCTAssertNil(preview.value)
    }
}
