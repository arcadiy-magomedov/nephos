import UIKit
import XCTest

final class BackupUITests: XCTestCase {
    func testPeopleRenameAndMergeRefreshTheParentListAndKeepTheName() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.nephos.ui-qualification")
        app.launchEnvironment = ["NEPHOS_UI_SCREEN": "backup-people"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Source person"].waitForExistence(timeout: 15), app.debugDescription)
        app.staticTexts["Source person"].tap()
        XCTAssertTrue(app.buttons["Edit name"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Edit name"].tap()
        let name = app.textFields["Unnamed person"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), app.debugDescription)
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        name.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Source person".count) + "Edited person")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Edited person"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.buttons["People"].tap()
        XCTAssertTrue(app.staticTexts["Edited person"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Source person"].exists, app.debugDescription)
        app.staticTexts["Unnamed person"].tap()
        XCTAssertTrue(app.buttons["Merge…"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Merge…"].tap()
        XCTAssertTrue(app.staticTexts["Edited person"].waitForExistence(timeout: 10), app.debugDescription)
        app.staticTexts["Edited person"].tap()
        XCTAssertTrue(app.buttons["Merge groups"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Merge groups"].tap()
        XCTAssertTrue(app.staticTexts["Edited person"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.buttons["People"].tap()
        XCTAssertTrue(app.staticTexts["Edited person"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Unnamed person"].exists, app.debugDescription)
    }

    func testActualQueueOverlapsThreeRequestsAndFinishesAllSixUploads() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.nephos.ui-qualification")
        app.launchEnvironment = ["NEPHOS_UI_SCREEN": "backup-parallel"]
        app.launch()
        startBackup(app)
        let complete = app.staticTexts["Backup complete"]
        XCTAssertTrue(complete.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "backup.progress").firstMatch.label,
            "6 of 6 files saved")
    }

    func testStoppedItemExplainsCauseAndRetryDoesNotUnblockOtherItems() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.nephos.ui-qualification")
        app.launchEnvironment = ["NEPHOS_UI_SCREEN": "backup-attention"]
        app.launch()
        let rejected = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "backup.item.", "Server rejected"))
        XCTAssertTrue(rejected.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let itemID = rejected.firstMatch.identifier
        rejected.firstMatch.tap()
        let explanation = app.staticTexts.matching(
            identifier: "The server rejected this item. Update Nephos and the server, then retry.")
        XCTAssertTrue(explanation.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Server returned")).count, 0)
        let retry = app.buttons.matching(NSPredicate(format: "label == %@", "Retry this item")).firstMatch
        reveal(retry, in: app)
        retry.tap()
        let saved = app.staticTexts["Saved"]
        XCTAssertTrue(saved.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["Retry this item"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons[itemID].label.contains("Saved"))
        XCTAssertEqual(rejected.count, 1)
    }

    private func start() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.nephos.ui-qualification")
        app.launchEnvironment = ["NEPHOS_UI_SCREEN": "backup-retry"]
        app.launch()
        startBackup(app)
        let waiting = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "backup.item.", "Waiting to retry")
        ).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 10), app.debugDescription)
        return app
    }

    func testManualQueueRetriesWithoutAnotherTriggerAndDetailsAreCollapsed() {
        let app = start()
        let rawError = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Server returned 503"))
        XCTAssertEqual(rawError.count, 0)
        XCTAssertEqual(app.alerts.count, 0)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "backup.item.")).firstMatch.tap()
        let details = app.buttons["Technical details"]
        reveal(details, in: app)
        details.tap()
        reveal(rawError.firstMatch, in: app)
        XCTAssertTrue(rawError.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        reveal(details, in: app, upwards: false)
        details.tap()
        XCTAssertEqual(rawError.count, 0)
        let saved = app.staticTexts["Saved"]
        XCTAssertTrue(saved.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertEqual(app.alerts.count, 0)
        app.buttons["Done"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "backup-retry-completed"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testPauseCancelsDeadlineAndResumePreservesTheQueue() {
        let app = start()
        let pause = app.buttons["Pause backup"]
        pause.tap()
        XCTAssertTrue(app.staticTexts["Backup paused"].waitForExistence(timeout: 5))
        let progress = app.descendants(matching: .any).matching(identifier: "backup.progress").firstMatch
        let premature = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "1 of 1 files saved"), object: progress)
        premature.isInverted = true
        wait(for: [premature], timeout: 35)
        XCTAssertEqual(progress.label, "0 of 1 files saved")
        app.buttons["Resume backup"].tap()
        XCTAssertTrue(app.staticTexts["Backup complete"].waitForExistence(timeout: 15), app.debugDescription)
    }

    func testCancelDuringStartupCanResume() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.nephos.ui-qualification")
        app.launchEnvironment = ["NEPHOS_UI_SCREEN": "backup-startup"]
        app.launch()
        XCTAssertTrue(app.buttons["Resume backup"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["Resume backup"].tap()
        XCTAssertTrue(app.staticTexts["Backup complete"].waitForExistence(timeout: 15), app.debugDescription)
    }

    func testVerifiedPhotoPublishesEvenWhenLowDataModeBlocksOtherUploads() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.nephos.ui-qualification")
        app.launchEnvironment = ["NEPHOS_UI_SCREEN": "backup-publication"]
        app.launch()
        startBackup(app)
        let saved = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "backup.item.", "Saved"))
        XCTAssertTrue(saved.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "backup.item.", "Queued")
            ).count, 1)
        XCTAssertTrue(app.staticTexts["Backup is waiting for Low Data Mode to be turned off."].exists)
    }

    func testGalleryRefreshesWithoutGestureAndWithBackupPausedAndReadOnlyLibrary() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.nephos.ui-qualification")
        app.launchEnvironment = ["NEPHOS_UI_SCREEN": "backup-gallery"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 20), app.debugDescription)
        let added = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "new-photo.jpg"))
            .firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 25), app.debugDescription)
        XCUIDevice.shared.press(.home)
        app.activate()
        let returned = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "returned-photo.jpg")
        ).firstMatch
        XCTAssertTrue(returned.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.alerts.count, 0)
    }

    private func startBackup(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Backup options"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["Backup options"].tap()
        app.buttons["Back up now"].tap()
    }

    func testAutomaticGalleryRefreshDoesNotSnapVisibleCellToTop() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.nephos.ui-qualification")
        app.launchEnvironment = ["NEPHOS_UI_SCREEN": "backup-gallery", "NEPHOS_UI_SCROLL_REGRESSION": "1"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 20), app.debugDescription)
        app.swipeUp()
        let cells = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "gallery.item."))
        let cell = try XCTUnwrap(
            cells.allElementsBoundByIndex.first {
                $0.isHittable && $0.frame.minY > 220 && $0.frame.maxY < app.frame.height - 180
            })
        let identifier = cell.identifier
        let before = cell.frame.minY
        let newItem = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "new-photo.jpg")
        ).firstMatch
        XCTAssertTrue(newItem.waitForExistence(timeout: 25), app.debugDescription)
        let retained = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(retained.exists, app.debugDescription)
        XCTAssertEqual(retained.frame.minY, before, accuracy: 4, app.debugDescription)
    }

    func testLocalThumbnailDoesNotBlinkOrMoveDuringRefreshAndPublication() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.nephos.ui-qualification")
        app.launchEnvironment = ["NEPHOS_UI_SCREEN": "backup-gallery", "NEPHOS_UI_PREVIEW_REGRESSION": "1"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 20), app.debugDescription)
        let cell = app.descendants(matching: .any).matching(identifier: "gallery.item.local:fixture-0").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), app.debugDescription)
        func thumbnailPixels() throws -> Data {
            let image = try XCTUnwrap(cell.screenshot().image.cgImage)
            let center = CGRect(x: image.width / 2 - 5, y: image.height / 2 - 5, width: 10, height: 10)
            return try XCTUnwrap(UIImage(cgImage: XCTUnwrap(image.cropping(to: center))).pngData())
        }
        let before = cell.frame.minY
        let pixels = try thumbnailPixels()
        app.buttons["Refresh previews"].tap()
        for _ in 0..<5 {
            XCTAssertEqual(try thumbnailPixels(), pixels, "The displayed preview was cleared while refreshing.")
        }
        let published = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "new-photo.jpg"), object: cell)
        wait(for: [published], timeout: 25)
        XCTAssertEqual(cell.frame.minY, before, accuracy: 4, app.debugDescription)
        XCTAssertEqual(try thumbnailPixels(), pixels, "Publication replaced the local thumbnail with a placeholder.")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, upwards: Bool = true) {
        for _ in 0..<6 {
            if element.exists, element.isHittable, element.frame.minY > 140,
                element.frame.maxY < app.frame.height - 80
            {
                return
            }
            if upwards { app.swipeUp() } else { app.swipeDown() }
        }
    }
}

@MainActor
final class OnboardingUITests: XCTestCase {
    func testLegacyConnectionDoesNotExposeManualDiscoveryOrPIN() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.nephos.ui-qualification")
        app.launchEnvironment = ["NEPHOS_UI_SCREEN": "onboarding-flow", "NEPHOS_UI_SEED_LEGACY": "1"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.scanQR"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["onboarding.importQR"].exists)
        XCTAssertFalse(app.textFields["onboarding.serverURL"].exists)
        XCTAssertFalse(app.textFields["onboarding.email"].exists)
        XCTAssertFalse(app.textFields["onboarding.pin"].exists)
        app.terminate()
        app.launchEnvironment["NEPHOS_UI_SEED_LEGACY"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.scanQR"].waitForExistence(timeout: 20), app.debugDescription)
    }
}
