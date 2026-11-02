import Foundation

enum Headers {
    /// The Message-ID from a header block (unfolded, case-insensitive), angle brackets kept.
    /// Works on bytes: in Swift strings "\r\n" is one character, so splitting text on "\n" fails.
    static func messageID(in header: [UInt8]) -> String? {
        var unfolded: [[UInt8]] = []
        for var line in header.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map(Array.init) {
            if line.last == UInt8(ascii: "\r") { line.removeLast() }
            if line.isEmpty {
                if unfolded.isEmpty { continue }
                break  // end of headers
            }
            if line[0] == UInt8(ascii: " ") || line[0] == UInt8(ascii: "\t"), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += [UInt8(ascii: " ")] + line
            } else {
                unfolded.append(line)
            }
        }
        for line in unfolded {
            guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else { continue }
            let name = String(decoding: line[..<colon], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare("Message-ID") == .orderedSame else { continue }
            let value = String(decoding: line[(colon + 1)...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
