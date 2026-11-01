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
    func testBonjourSelectionStillRequiresExplicitTrust() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NEPHOS_UI_DISCOVERY"] == "1" else {
            throw XCTSkip("Enable --discovery with a real LAN advertisement to exercise Bonjour.")
        }
        continueAfterFailure = false
        let base = try XCTUnwrap(environment["NEPHOS_UI_BASE_URL"])
        let app = XCUIApplication(bundleIdentifier: "app.nephos.ui-qualification")
        app.launchEnvironment = ["NEPHOS_UI_SCREEN": "onboarding-flow", "NEPHOS_UI_SEED_LEGACY": "1"]
        app.launch()
        let search = app.buttons["onboarding.findServers"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription)
        search.tap()
        let permission = app.alerts.buttons["Allow"]
        if permission.waitForExistence(timeout: 3) { permission.tap() }
        let server = app.buttons["onboarding.discovered." + base]
        XCTAssertTrue(server.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(app.textFields["onboarding.serverURL"].value as? String, "http://192.168.1.10:18080")
        XCTAssertFalse(app.buttons["Trust and continue"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "real-bonjour-discovery"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        search.tap()
        XCTAssertFalse(server.exists)
        search.tap()
        XCTAssertTrue(server.waitForExistence(timeout: 30))
        server.tap()
        XCTAssertTrue(app.buttons["Trust and continue"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts[base + "/realms/nephos"].exists)
        XCTAssertFalse(app.buttons["Sign in"].exists)
        app.buttons["Back"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        XCTAssertFalse(server.exists)
    }

    func testLegacyServerCertificateReplacementAndEmailFirstPINRequest() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let base = try XCTUnwrap(environment["NEPHOS_UI_BASE_URL"])
        let badCertificate = try XCTUnwrap(environment["NEPHOS_UI_BAD_CERT_URL"])
        let app = XCUIApplication(bundleIdentifier: "app.nephos.ui-qualification")
        app.launchEnvironment = [
            "NEPHOS_UI_SCREEN": "onboarding-flow",
            "NEPHOS_UI_SEED_LEGACY": "1",
        ]
        app.launch()
        let field = app.textFields["onboarding.serverURL"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(field.value as? String, "http://192.168.1.10:18080")
        app.launchEnvironment["NEPHOS_UI_SEED_LEGACY"] = "0"

        replace(field, with: badCertificate)
        app.buttons["Check server"].tap()
        XCTAssertTrue(app.staticTexts["Certificate not trusted"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts[badCertificate].exists)
        XCTAssertFalse(app.staticTexts["http://localhost:18081/realms/nephos"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        XCTAssertEqual(field.value as? String, badCertificate)
        app.buttons["Check server"].tap()
        XCTAssertTrue(app.staticTexts["Certificate not trusted"].waitForExistence(timeout: 30))
        app.buttons["Change server"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        replace(field, with: base)
        app.buttons["Check server"].tap()
        XCTAssertTrue(app.buttons["Trust and continue"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Trust and continue"].isEnabled)
        XCTAssertTrue(app.staticTexts[base + "/realms/nephos"].exists)
        app.buttons["Trust and continue"].tap()
        XCTAssertTrue(app.textFields["onboarding.email"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.textFields["onboarding.pin"].exists)
        XCTAssertFalse(app.buttons["onboarding.requestPin"].isEnabled)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["onboarding.email"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.textFields["onboarding.pin"].exists)
        app.buttons["Change server"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        app.terminate()
        app.launch()
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        XCTAssertEqual(field.value as? String, base)
        XCTAssertFalse(app.buttons["Sign in"].exists)
        app.buttons["Check server"].tap()
        XCTAssertTrue(app.buttons["Trust and continue"].waitForExistence(timeout: 30))
        app.buttons["Trust and continue"].tap()
        let email = app.textFields["onboarding.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 15))
        replace(email, with: "not-an-email")
        XCTAssertFalse(app.buttons["onboarding.requestPin"].isEnabled)
        replace(email, with: "unknown-onboarding@example.invalid")
        app.buttons["onboarding.requestPin"].tap()
        XCTAssertTrue(
            app.staticTexts["This email is not an enabled known account. Contact your administrator."]
                .waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.textFields["onboarding.pin"].exists)
        app.buttons["Edit email"].tap()
        let knownEmail = try XCTUnwrap(environment["NEPHOS_UI_SIGNIN_EMAIL"])
        replace(email, with: knownEmail)
        XCTAssertEqual(email.value as? String, knownEmail, app.debugDescription)
        app.buttons["onboarding.requestPin"].tap()
        let pin = app.textFields["onboarding.pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(email.exists)
        XCTAssertFalse(app.buttons["onboarding.submitPin"].isEnabled)
        XCTAssertEqual(app.webViews.count, 0)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "email-validated-pin-entry"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // Immediate retries must reuse the pending PIN, not replace the entry screen with a cooldown failure.
        app.buttons["Request PIN again"].tap()
        XCTAssertTrue(app.buttons["onboarding.submitPin"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Sign-in could not continue"].exists, app.debugDescription)
        app.terminate()
        app.launch()
        XCTAssertTrue(pin.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(email.exists)
        XCTAssertFalse(app.buttons["onboarding.submitPin"].isEnabled)
        // Discarded local state must also be recoverable within the issuance cooldown.
        app.buttons["Different email"].tap()
        XCTAssertTrue(email.waitForExistence(timeout: 15))
        replace(email, with: knownEmail)
        XCTAssertEqual(email.value as? String, knownEmail)
        app.buttons["onboarding.requestPin"].tap()
        XCTAssertTrue(pin.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Sign-in could not continue"].exists, app.debugDescription)
        if let suppliedPIN = environment["NEPHOS_UI_SIGNIN_PIN"], !suppliedPIN.isEmpty {
            // Exhaust the real IP budget, then verify that a retry cannot strand an accepted user.
            pin.tap()
            pin.typeText(String(suppliedPIN.prefix(4)))
            for _ in 0..<11 {
                var request = URLRequest(url: URL(string: base + "/realms/nephos/nephos-admin/request-pin")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(
                    withJSONObject: ["email": knownEmail, "clientId": "nephos-ios"])
                let (_, response) = try await URLSession.shared.data(for: request)
                XCTAssertTrue([200, 429].contains((response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            app.buttons["Request PIN again"].tap()
            let cooldown = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Request again in"))
            XCTAssertTrue(cooldown.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertTrue(pin.exists)
            XCTAssertEqual(pin.value as? String, String(suppliedPIN.prefix(4)))
            XCTAssertFalse(app.buttons["Request PIN again"].isEnabled)
            XCTAssertFalse(app.staticTexts["Sign-in could not continue"].exists)
            pin.tap()
            pin.typeText(String(suppliedPIN.suffix(4)))
            app.buttons["onboarding.submitPin"].tap()
            XCTAssertTrue(app.buttons["Set up backup"].waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertTrue(app.buttons["Browse only"].isEnabled, app.debugDescription)
            XCTAssertFalse(app.staticTexts["No library is available yet"].exists, app.debugDescription)
            XCTAssertFalse(app.staticTexts["Sign-in could not continue"].exists, app.debugDescription)
            app.buttons["Browse only"].tap()
            XCTAssertTrue(app.buttons["Open library"].waitForExistence(timeout: 15))
            app.buttons["Open library"].tap()
            XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 30), app.debugDescription)
            let bridge = URL(fileURLWithPath: try XCTUnwrap(environment["NEPHOS_UI_REAUTH_BRIDGE"]))
            try Data().write(to: bridge.appendingPathExtension("revoke"))
            try await waitForFixture(bridge.appendingPathExtension("revoked"))
            XCUIDevice.shared.press(.home)
            app.activate()
            if app.buttons["Library actions"].exists {
                app.buttons["Library actions"].tap()
                app.buttons["Newest"].tap()
            }
            if app.alerts.buttons["OK"].waitForExistence(timeout: 10) { app.alerts.buttons["OK"].tap() }
            XCTAssertTrue(email.waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertFalse(pin.exists, "A consumed request must not resume after the session is revoked.")
            replace(email, with: knownEmail)
            let canRequest = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true"), object: app.buttons["onboarding.requestPin"])
            await fulfillment(of: [canRequest], timeout: 65)
            app.buttons["onboarding.requestPin"].tap()
            XCTAssertTrue(pin.waitForExistence(timeout: 30), app.debugDescription)
            try await waitForFixture(bridge.appendingPathExtension("pin"))
            let replacementPIN = try String(contentsOf: bridge.appendingPathExtension("pin"), encoding: .utf8)
            XCTAssertEqual(replacementPIN.count, 8)
            pin.tap()
            pin.typeText(replacementPIN)
            app.buttons["onboarding.submitPin"].tap()
            XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertFalse(email.exists)
            app.terminate()
            app.launchEnvironment["NEPHOS_UI_RESTORE_DELAY"] = "1"
            app.launch()
            XCTAssertTrue(
                app.descendants(matching: .any).matching(identifier: "startup.restoring").firstMatch
                    .waitForExistence(timeout: 3), app.debugDescription)
            let loginFlash = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: email)
            loginFlash.isInverted = true
            await fulfillment(of: [loginFlash], timeout: 2)
            XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 30), app.debugDescription)
            return
        }
        app.buttons["Different email"].tap()
        XCTAssertTrue(email.waitForExistence(timeout: 15))
        XCTAssertFalse(pin.exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(email.waitForExistence(timeout: 15))
        XCTAssertFalse(pin.exists)
        XCTAssertFalse(app.staticTexts["Certificate not trusted"].exists)
    }

    private func waitForFixture(_ url: URL) async throws {
        for _ in 0..<30 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .seconds(1))
        }
        XCTFail("The private fixture did not complete: \(url.pathExtension)")
    }

    private func replace(_ field: XCUIElement, with value: String) {
        if field.value as? String == value { return }
        field.tap()
        let previous = field.value as? String ?? ""
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + value)
    }
}
