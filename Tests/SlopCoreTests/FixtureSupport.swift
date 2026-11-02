import Foundation
import XCTest
@testable import SlopCore

struct FixtureMissing: Error, CustomStringConvertible {
    var description: String { "SLOP_REQUIRE_FIXTURES=1 but SLOP_FIXTURE_DIR is not set" }
}

/// Connection details written by `Fixtures/slopfixture.py up --dir $SLOP_FIXTURE_DIR`.
struct FixtureServer: Decodable {
    var host: String
    var port: Int
    var security: String
    var user: String
    var password: String
    var cert: String

    static func load(_ kind: String) throws -> FixtureServer {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SLOP_FIXTURE_DIR"], !dir.isEmpty else {
            if env["SLOP_REQUIRE_FIXTURES"] == "1" {
                throw FixtureMissing()
            }
            throw XCTSkip("SLOP_FIXTURE_DIR not set; start the fixture servers with Fixtures/slopfixture.py")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("\(kind).json"))
        return try JSONDecoder().decode(FixtureServer.self, from: data)
    }

    var bridgeSettings: BridgeSettings {
        BridgeSettings(host: host, port: port, user: user, tls: TLSMode(rawValue: security) ?? .startTLS, certificatePath: cert)
    }
}
