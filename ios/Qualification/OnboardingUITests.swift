import XCTest

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

    func testLegacyServerCertificateFailureReplacementRelaunchAndBrowserCancellation() throws {
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
        XCTAssertTrue(app.buttons["Sign in"].waitForExistence(timeout: 15))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Sign in"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[base + "/realms/nephos"].exists)
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
        XCTAssertTrue(app.buttons["Sign in"].waitForExistence(timeout: 15))
        app.buttons["Sign in"].tap()
        let permission = app.alerts.buttons["Continue"]
        if permission.waitForExistence(timeout: 5) { permission.tap() }
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.webViews.textFields.firstMatch.waitForExistence(timeout: 15))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "real-system-sign-in"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Sign-in was cancelled. You can try again."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Sign in"].isEnabled)
        XCTAssertFalse(app.staticTexts["Certificate not trusted"].exists)
    }

    private func replace(_ field: XCUIElement, with value: String) {
        field.tap()
        let previous = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + value)
    }
}
