import XCTest

final class LocalGalleryUITests: XCTestCase {
    private var app: XCUIApplication!
    private var allowPhotos = true
    private var handledPhotosPrompt = false
    private var photosMonitor: NSObjectProtocol?

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "app.nephos.ui-qualification")
        app.launchEnvironment = ["NEPHOS_UI_SCREEN": "local-gallery"]
        photosMonitor = addUIInterruptionMonitor(withDescription: "Photos access") { [weak self] alert in
            guard let self,
                alert.label.localizedCaseInsensitiveContains("Photo Library")
            else { return false }
            let button = alert.buttons.matching(NSPredicate(format: photosPermissionPredicate)).firstMatch
            guard button.exists else { return false }
            button.tap()
            handledPhotosPrompt = true
            return true
        }
    }

    override func tearDownWithError() throws {
        app.terminate()
        if let photosMonitor { removeUIInterruptionMonitor(photosMonitor) }
        XCUIDevice.shared.orientation = .portrait
    }

    func testDeniedAccessShowsSettingsWithoutPretendingTheLibraryIsEmpty() {
        allowPhotos = false
        app.resetAuthorizationStatus(for: .photos)
        app.launch()
        XCTAssertTrue(app.buttons["gallery.allowAccess"].waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["gallery.allowAccess"].tap()
        respondToPhotosPermission()
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(media.firstMatch.exists)
    }

    func testFiltersFitOnOneRowWithoutHorizontalScrolling() {
        app.launch()
        assertFiltersFit()
        let all = app.buttons["gallery.filter.All"]
        for title in ["Photos", "Videos", "Shared"] {
            XCTAssertEqual(app.buttons["gallery.filter.\(title)"].frame.minY, all.frame.minY, accuracy: 1)
        }
    }

    func testFiltersWrapAtAccessibilityTextSizes() {
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        assertFiltersFit()
        XCTAssertGreaterThan(
            app.buttons["gallery.filter.Shared"].frame.minY, app.buttons["gallery.filter.All"].frame.minY)
        attach("gallery-wrapped-filters")
    }

    func testPhotoViewerHasNativeShareAndCancelableLocalOnlyDeletion() {
        openLibrary()
        app.buttons["gallery.filter.Photos"].tap()
        XCTAssertTrue(media.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        fixture("qualification.photoID").tap()
        XCTAssertTrue(app.buttons["viewer.options"].waitForExistence(timeout: 10))
        app.buttons["viewer.options"].tap()
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.alerts.buttons["Delete from Photos"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.alerts.buttons["Delete everywhere"].exists)
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["viewer.share"].exists)
        app.buttons["viewer.share"].tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 20), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "native-media-share"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Close"].tap()
        app.buttons["viewer.back"].tap()
        XCTAssertTrue(app.buttons["gallery.filter.Photos"].exists)
    }

    func testVideoPlaysSeeksMutesAndEntersFullscreen() {
        openLibrary()
        app.buttons["gallery.filter.Videos"].tap()
        XCTAssertTrue(media.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        fixture("qualification.videoID").tap()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20), app.debugDescription)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: play)
        wait(for: [ready], timeout: 20)
        play.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Pause"].tap()
        app.sliders["Playback position"].adjust(toNormalizedSliderPosition: 0.5)
        let position = app.sliders["Playback position"].value as? String
        app.buttons["Unmute"].tap()
        XCTAssertTrue(app.buttons["Mute"].exists)
        app.buttons["Full screen"].tap()
        XCTAssertTrue(app.buttons["Close full screen"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Close full screen"].tap()
        XCTAssertTrue(app.buttons["viewer.back"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.sliders["Playback position"].value as? String, position)
        XCTAssertTrue(app.buttons["Mute"].exists)
        app.buttons["viewer.back"].tap()
        XCTAssertTrue(app.buttons["gallery.filter.Videos"].exists)
    }

    func testConfirmedDeletionRemovesThePhotosAsset() {
        openLibrary()
        app.buttons["gallery.filter.Photos"].tap()
        XCTAssertTrue(media.firstMatch.waitForExistence(timeout: 20))
        let photo = fixture("qualification.photoID")
        let deletedID = photo.identifier
        photo.tap()
        app.buttons["viewer.options"].tap()
        app.buttons["Delete"].tap()
        app.alerts.buttons["Delete from Photos"].tap()
        let confirm = permissionButton("label BEGINSWITH 'Delete'")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), permissionDescription)
        confirm.tap()
        if app.buttons["viewer.back"].waitForExistence(timeout: 5) { app.buttons["viewer.back"].tap() }
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons[deletedID])
        wait(for: [gone], timeout: 10)
    }

    func testLightDarkAndLargeTextLayouts() {
        for theme in ["light", "dark"] {
            app.launchEnvironment["NEPHOS_UI_THEME"] = theme
            openLibrary()
            attach("gallery-\(theme)")
            app.buttons["gallery.filter.Photos"].tap()
            XCTAssertTrue(media.firstMatch.waitForExistence(timeout: 10))
            fixture("qualification.photoID").tap()
            attach("photo-viewer-\(theme)")
            app.terminate()
        }
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        openLibrary()
        XCTAssertTrue(app.buttons["gallery.options"].isHittable)
        attach("gallery-large-text")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["gallery.options"].waitForExistence(timeout: 10))
        attach("gallery-large-text-landscape")
    }

    private var media: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'gallery.item.'"))
    }

    private func assertFiltersFit() {
        for title in ["All", "Photos", "Videos", "Shared"] {
            let button = app.buttons["gallery.filter.\(title)"]
            XCTAssertTrue(button.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX + 15)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX - 15)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
    }

    private func openLibrary() {
        app.launch()
        if app.buttons["gallery.allowAccess"].waitForExistence(timeout: 3) {
            app.buttons["gallery.allowAccess"].tap()
            respondToPhotosPermission()
        }
        if app.buttons["Open Settings"].exists, !media.firstMatch.exists {
            app.terminate()
            app.resetAuthorizationStatus(for: .photos)
            app.launch()
            handledPhotosPrompt = false
            app.buttons["gallery.allowAccess"].tap()
            respondToPhotosPermission()
        }
        XCTAssertTrue(media.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(
            app.staticTexts["qualification.uploadInventory"].waitForExistence(timeout: 20), app.debugDescription)
    }

    private func permissionButton(_ predicate: String) -> XCUIElement {
        XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons.matching(NSPredicate(format: predicate))
            .firstMatch
    }

    private var photosPermissionPredicate: String {
        allowPhotos
            ? "label CONTAINS[c] 'Full Access' OR label CONTAINS[c] 'All Photos'"
            : "label CONTAINS[c] 'Allow' AND (label CONTAINS[c] 'Don' OR label CONTAINS[c] 'Not')"
    }

    private func respondToPhotosPermission() {
        guard !handledPhotosPrompt else { return }
        let button = permissionButton(photosPermissionPredicate)
        XCTAssertTrue(button.waitForExistence(timeout: 10), permissionDescription)
        button.tap()
        handledPhotosPrompt = true
    }

    private var permissionDescription: String {
        XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription + app.debugDescription
    }

    private func fixture(_ identifier: String) -> XCUIElement {
        let marker = app.staticTexts[identifier]
        XCTAssertTrue(marker.waitForExistence(timeout: 20), app.debugDescription)
        let item = app.buttons["gallery.item.\(marker.label)"]
        XCTAssertTrue(item.waitForExistence(timeout: 10), app.debugDescription)
        return item
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
