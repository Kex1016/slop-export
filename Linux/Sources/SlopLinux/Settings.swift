import Foundation

/// Everything the Linux app remembers between runs, except passwords (those are in the keyring).
/// Mirrors what the macOS app keeps in UserDefaults. The certificate is kept as DER bytes, like
/// the macOS app (D-008), so moving or deleting cert.pem later does not break the connection.
public struct AppSettings: Codable, Equatable, Sendable {
    public var host = "127.0.0.1"
    public var port = 1143
    public var user = ""
    public var certificateDER: Data?
    public var certificateName: String?
    public var exportFolder: String?
    public var icloudUser = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        // Every field is optional on disk, so a settings file from an older version still loads.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? d.user
        certificateDER = try c.decodeIfPresent(Data.self, forKey: .certificateDER)
        certificateName = try c.decodeIfPresent(String.self, forKey: .certificateName)
        exportFolder = try c.decodeIfPresent(String.self, forKey: .exportFolder)
        icloudUser = try c.decodeIfPresent(String.self, forKey: .icloudUser) ?? d.icloudUser
    }
}

/// `$XDG_CONFIG_HOME/slop-export/settings.json` (normally `~/.config/slop-export/settings.json`),
/// readable by the user only.
public struct SettingsFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> SettingsFile {
        let base: URL
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        }
        return SettingsFile(url: base.appendingPathComponent("slop-export/settings.json"))
    }

    /// The saved settings, or defaults. A file that exists but cannot be read is moved aside
    /// (to `settings.json.damaged`) rather than overwritten by the next save, and `problem` says so.
    public func load() -> (settings: AppSettings, problem: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (AppSettings(), nil) }
        do {
            return (try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url)), nil)
        } catch {
            let aside = url.appendingPathExtension("damaged")
            try? FileManager.default.removeItem(at: aside)
            let moved = (try? FileManager.default.moveItem(at: url, to: aside)) != nil
            return (AppSettings(), "Could not read the saved settings (\(url.path)), so the defaults are shown. "
                    + (moved ? "The old file was kept as \(aside.lastPathComponent)." : ""))
        }
    }

    public func save(_ settings: AppSettings) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Created as 0600 from the start, then renamed over the old file, so it is never readable
        // by others, not even for a moment.
        let temporary = dir.appendingPathComponent(".settings-\(UUID().uuidString).json")
        guard fm.createFile(atPath: temporary.path, contents: try encoder.encode(settings),
                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
