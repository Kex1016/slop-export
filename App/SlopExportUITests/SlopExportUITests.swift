import XCTest

final class SlopExportUITests: XCTestCase {
    @MainActor
    func testConnectStepShowsAndConnectIsDisabledUntilFilledIn() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-bridge.user", "", "-bridge.certificate", ""]
        app.launch()
        XCTAssertTrue(app.buttons["connect-button"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["connect-button"].isEnabled)
        XCTAssertTrue(app.secureTextFields["bridge-password"].exists)
    }

    @MainActor
    func testCommandNumberSwitchesSteps() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["connect-button"].waitForExistence(timeout: 10))
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.buttons["verify-button"].waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.buttons["connect-button"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testVerifyStepNeedsAnExportFirst() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-export.bookmark", ""]
        app.launch()
        let step = app.descendants(matching: .any)["step-verify"]
        XCTAssertTrue(step.waitForExistence(timeout: 10))
        step.click()
        XCTAssertTrue(app.buttons["verify-button"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["verify-button"].isEnabled)
    }
}
