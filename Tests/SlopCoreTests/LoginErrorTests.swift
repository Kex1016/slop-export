import NIOIMAP
import XCTest
@testable import SlopCore

/// Which refused LOGINs count as wrong credentials. Only those should tell the user to
/// check their user name and password.
final class LoginErrorTests: XCTestCase {
    func testCredentialCodesAndNoCodeMeanWrongCredentials() {
        XCTAssertTrue(IMAPClient.isCredentialRefusal(ResponseText(code: nil, text: "no such user")))
        XCTAssertTrue(IMAPClient.isCredentialRefusal(ResponseText(code: .authenticationFailed, text: "x")))
        XCTAssertTrue(IMAPClient.isCredentialRefusal(ResponseText(code: .authorizationFailed, text: "x")))
    }

    func testOtherCodesAreNotReportedAsWrongCredentials() {
        for code: ResponseTextCode in [.unavailable, .limit, .contactAdmin, .privacyRequired, .expired] {
            XCTAssertFalse(IMAPClient.isCredentialRefusal(ResponseText(code: code, text: "x")), "\(code)")
        }
    }

    func testRenderKeepsTheCode() {
        XCTAssertEqual(IMAPClient.render(ResponseText(code: .unavailable, text: "try later")), "[UNAVAILABLE] try later")
        XCTAssertEqual(IMAPClient.render(ResponseText(code: nil, text: "plain")), "plain")
    }

    func testCredentialsCleaning() {
        XCTAssertEqual(Credentials.clean(" \u{FEFF}user@example.test\u{200B}\r\n"), "user@example.test")
        XCTAssertEqual(Credentials.clean("pa ss"), "pa ss")
    }
}
