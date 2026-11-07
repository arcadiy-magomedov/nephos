import XCTest

final class QREnrollmentUITests: XCTestCase {
    private func app(screen: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.nephos.ui-qualification")
        app.launchEnvironment = ["NEPHOS_UI_SCREEN": screen]
        return app
    }
    func testNativeKeychainMigrationAtomicCommitAndRecovery() {
        let app = app(screen: "qr-native-checks")
        app.launch()
        XCTAssertTrue(app.staticTexts["QR native checks passed"].waitForExistence(timeout: 30), app.debugDescription)
    }
    func testPrimaryLoginHasCameraAndPhotosWithoutManualDiscoveryOrPIN() {
        let app = app(screen: "onboarding-flow")
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.scanQR"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["onboarding.importQR"].exists)
        XCTAssertFalse(app.textFields["onboarding.serverURL"].exists)
        XCTAssertFalse(app.textFields["onboarding.email"].exists)
        XCTAssertFalse(app.textFields["onboarding.pin"].exists)
        app.buttons["onboarding.scanQR"].tap()
        if app.alerts.buttons["Don’t Allow"].waitForExistence(timeout: 5) { app.alerts.buttons["Don’t Allow"].tap() }
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "onboarding.qrError").firstMatch
                .waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["onboarding.importQR"].waitForExistence(timeout: 10))
    }
    func testRealImageEnrollmentCrashLostResponseAndColdRestore() throws {
        let image = ProcessInfo.processInfo.environment["NEPHOS_QR_IMAGE"] ?? ""
        guard !image.isEmpty else {
            throw XCTSkip("Run qr_qualification.py --qr-image against the real trusted HTTPS fixture.")
        }
        let app = app(screen: "qr-real-login")
        app.launchEnvironment["NEPHOS_QR_IMAGE"] = image
        app.launchEnvironment["NEPHOS_QR_PHASE"] = "prepare"
        app.launch()
        require(app.staticTexts["QR request persisted"], in: app, stage: "prepare", timeout: 60)
        app.terminate()
        app.launchEnvironment["NEPHOS_QR_PHASE"] = "discard-response"
        app.launch()
        require(app.staticTexts["QR response deliberately lost"], in: app, stage: "discard-response", timeout: 60)
        app.terminate()
        app.launchEnvironment["NEPHOS_QR_PHASE"] = "restore"
        app.launch()
        require(app.buttons["Browse only"], in: app, stage: "recover", timeout: 60)
        app.buttons["Browse only"].tap()
        require(app.buttons["Open library"], in: app, stage: "setup", timeout: 15)
        app.buttons["Open library"].tap()
        require(app.navigationBars["Library"], in: app, stage: "gallery", timeout: 60)
        app.terminate()
        app.launchEnvironment["NEPHOS_QR_PHASE"] = "refresh"
        app.launch()
        let loginFlash = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"), object: app.buttons["onboarding.scanQR"])
        loginFlash.isInverted = true
        wait(for: [loginFlash], timeout: 2)
        require(app.navigationBars["Library"], in: app, stage: "refresh-restore", timeout: 60)
        XCTAssertFalse(app.buttons["onboarding.scanQR"].exists)
    }
    private func require(_ element: XCUIElement, in app: XCUIApplication, stage: String, timeout: TimeInterval) {
        guard element.waitForExistence(timeout: timeout) else {
            let error = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "QR_ERROR=")).firstMatch
            XCTFail("QR_STAGE=\(stage) \(error.exists ? error.label : "QR_ERROR=no-safe-diagnostic")")
            return
        }
    }
}
