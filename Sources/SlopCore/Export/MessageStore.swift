import Foundation
import NIO

/// Content-addressed raw message store: `store/<first two hex chars>/<sha256>.eml`.
/// Identical bytes are stored once, however many mailboxes they appear in.
public struct MessageStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func url(for hash: String) -> URL {
        root.appendingPathComponent(String(hash.prefix(2)), isDirectory: true).appendingPathComponent("\(hash).eml")
    }

    public func contains(_ hash: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: hash).path)
    }

    /// Writes the message if it is not there yet and returns its SHA-256. The file appears
    /// atomically (temp file, then rename), so a crash never leaves a half-written message.
    @discardableResult
    public func put(_ bytes: ByteBuffer) throws -> String {
        let data = Data(bytes.readableBytesView)
        let hash = Hashing.sha256Hex(data)
        let target = url(for: hash)
        if FileManager.default.fileExists(atPath: target.path) { return hash }
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".\(hash).\(UUID().uuidString).tmp")
        try data.write(to: temp)
        do {
            try FileManager.default.moveItem(at: temp, to: target)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            // Another writer won the race with the same content: fine.
            if !FileManager.default.fileExists(atPath: target.path) { throw error }
        }
        return hash
    }

    public func read(_ hash: String) throws -> Data {
        try Data(contentsOf: url(for: hash))
    }
}
