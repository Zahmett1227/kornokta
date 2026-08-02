import Foundation
#if canImport(Security)
import Security
#endif

/// Where the device token lives (ANA-PLAN §7.3: "Token Keychain'de tutulur").
///
/// Not `UserDefaults`: that is a plist inside the app container, readable from
/// a file-system backup and not protected when the device is locked. The
/// Keychain is, and this token is the only thing standing between a stranger
/// who finds the backend URL and a Google bill.
public protocol DeviceTokenStoring: Sendable {
    func read() -> String?
    func write(_ token: String) throws
    func clear() throws
}

public enum DeviceTokenError: Error, Sendable, Equatable {
    case keychainFailed(OSStatusValue)
    case empty
}

/// `OSStatus` is `Int32`; wrapped so the error type stays portable to
/// platforms without Security.framework.
public typealias OSStatusValue = Int32

#if canImport(Security)

public struct KeychainDeviceTokenStore: DeviceTokenStoring {
    private let service: String
    private let account: String

    public init(service: String = "app.cizgi.backend", account: String = "deviceToken") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DeviceTokenError.empty }
        guard let data = trimmed.data(using: .utf8) else { throw DeviceTokenError.empty }

        // Delete first rather than branching on add-vs-update: SecItemUpdate
        // fails when nothing is stored yet, and the branch is one more thing
        // to get wrong for no benefit.
        SecItemDelete(baseQuery as CFDictionary)

        var query = baseQuery
        query[kSecValueData as String] = data
        // Readable only while the device is unlocked, and never restored to a
        // different device: a token copied out of a backup would let another
        // phone spend against this project's quota.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DeviceTokenError.keychainFailed(status)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        // Deleting something that is not there is the outcome we wanted.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceTokenError.keychainFailed(status)
        }
    }
}

#endif

/// In-memory store for tests and for platforms without a Keychain.
///
/// Deliberately not a fallback the app silently uses: writing a token here on
/// a real device would drop it at the next launch, and the failure would look
/// like a server problem rather than a storage one.
public final class InMemoryDeviceTokenStore: DeviceTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    public func write(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DeviceTokenError.empty }
        lock.lock()
        defer { lock.unlock() }
        self.token = trimmed
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        token = nil
    }
}
