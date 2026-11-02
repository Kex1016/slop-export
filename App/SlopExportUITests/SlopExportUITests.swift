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
}
