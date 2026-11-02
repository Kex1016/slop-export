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

/// Text from mail servers and senders (folder names, Message-IDs, server messages) can hold
/// terminal escape sequences. The CLI passes everything it prints through this.
public enum TerminalText {
    public static func safe(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || $0.properties.generalCategory != .control
        }))
    }
}
