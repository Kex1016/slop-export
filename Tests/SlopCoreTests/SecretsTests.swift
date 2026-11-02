import XCTest
@testable import SlopCore

final class SecretsTests: XCTestCase {
    func testEnvironmentSecrets() throws {
        let env = EnvironmentSecrets(environment: ["SLOP_BRIDGE_PASSWORD": "abc", "SLOP_ICLOUD_PASSWORD": ""])
        XCTAssertEqual(try env.password(.bridge, account: "x"), "abc")
        XCTAssertNil(try env.password(.icloud, account: "x"), "empty counts as unset")
    }

    func testKeychainServiceNames() {
        XCTAssertEqual(SecretKind.bridge.service, "slop-export.bridge")
        XCTAssertEqual(SecretKind.icloud.environmentVariable, "SLOP_ICLOUD_PASSWORD")
    }
}
