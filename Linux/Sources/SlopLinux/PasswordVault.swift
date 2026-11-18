import CSecret
import Foundation
import SlopCore

/// Where the Linux app keeps the Bridge and iCloud passwords. The macOS app uses the Keychain;
/// on Linux this is the desktop keyring through the Secret Service (GNOME Keyring on Ubuntu and
/// Linux Mint), D-016. Passwords never go to the settings file, logs or arguments.
public protocol PasswordVault: Sendable {
    func password(_ kind: SecretKind, account: String) throws -> String?
    func setPassword(_ password: String, _ kind: SecretKind, account: String) throws
    func deletePassword(_ kind: SecretKind, account: String) throws
}

public struct VaultError: Error, CustomStringConvertible {
    public var message: String
    public var description: String {
        "The keyring refused: \(message). Is a keyring (GNOME Keyring or KWallet's Secret Service) running and unlocked?"
    }
}

/// Items in the default keyring, with attributes service = `slop-export.<kind>` and account =
/// the user name, the same names the macOS Keychain items use.
public struct SecretServiceVault: PasswordVault {
    public init() {}

    public func password(_ kind: SecretKind, account: String) throws -> String? {
        var error: UnsafeMutablePointer<GError>?
        let value = slop_secret_lookup(kind.service, account, &error)
        try Self.check(error)
        guard let value else { return nil }
        defer { secret_password_free(value) }
        return String(cString: value)
    }

    public func setPassword(_ password: String, _ kind: SecretKind, account: String) throws {
        var error: UnsafeMutablePointer<GError>?
        let label = "slop-export \(kind.rawValue) password (\(account))"
        _ = slop_secret_store(kind.service, account, label, password, &error)
        try Self.check(error)
    }

    public func deletePassword(_ kind: SecretKind, account: String) throws {
        var error: UnsafeMutablePointer<GError>?
        _ = slop_secret_clear(kind.service, account, &error)
        try Self.check(error)
    }

    private static func check(_ error: UnsafeMutablePointer<GError>?) throws {
        guard let error else { return }
        defer { g_error_free(error) }
        throw VaultError(message: error.pointee.message.map { String(cString: $0) } ?? "unknown error")
    }
}

/// Environment variables first (CI and tests, the same `SLOP_*_PASSWORD` names the CLI reads),
/// then the wrapped vault. Writes always go to the wrapped vault.
public struct EnvironmentFirstVault: PasswordVault {
    let base: PasswordVault
    let environment: EnvironmentSecrets

    public init(_ base: PasswordVault, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.base = base
        self.environment = EnvironmentSecrets(environment: environment)
    }

    public func password(_ kind: SecretKind, account: String) throws -> String? {
        if let value = try environment.password(kind, account: account) { return value }
        return try base.password(kind, account: account)
    }

    public func setPassword(_ password: String, _ kind: SecretKind, account: String) throws {
        try base.setPassword(password, kind, account: account)
    }

    public func deletePassword(_ kind: SecretKind, account: String) throws {
        try base.deletePassword(kind, account: account)
    }
}

/// For tests: a vault that lives in memory only.
public final class MemoryVault: PasswordVault, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    public init() {}

    private func key(_ kind: SecretKind, _ account: String) -> String { "\(kind.service)\u{0}\(account)" }

    public func password(_ kind: SecretKind, account: String) throws -> String? {
        lock.withLock { items[key(kind, account)] }
    }

    public func setPassword(_ password: String, _ kind: SecretKind, account: String) throws {
        lock.withLock { items[key(kind, account)] = password }
    }

    public func deletePassword(_ kind: SecretKind, account: String) throws {
        _ = lock.withLock { items.removeValue(forKey: key(kind, account)) }
    }
}
