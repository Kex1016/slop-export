import Crypto
import Foundation

public enum SlopVersion {
    public static let current = "0.1.0"
}

enum Hashing {
    static func sha256Hex<D: DataProtocol>(_ data: D) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
