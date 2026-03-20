import Foundation
import Security

public protocol SecretStoring: Sendable {
    func setSecret(_ secret: String, for account: String) throws
    func secret(for account: String) throws -> String?
    func removeSecret(for account: String) throws
}

public enum KeychainSecretStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidSecretEncoding
}

public final class KeychainSecretStore: @unchecked Sendable {
    private let service: String
    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    private let accessibility: CFString
    #endif

    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    public init(
        service: String = "com.codepilot.saved-connections",
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) {
        self.service = service
        self.accessibility = accessibility
    }
    #else
    public init(service: String = "com.codepilot.saved-connections") {
        self.service = service
    }
    #endif

    public func setSecret(_ secret: String, for account: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw KeychainSecretStoreError.invalidSecretEncoding
        }

        let status = SecItemAdd(
            addQuery(account: account, valueData: data) as CFDictionary,
            nil
        )

        if status == errSecSuccess {
            return
        }

        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(account: account) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainSecretStoreError.unexpectedStatus(updateStatus)
            }
            return
        }

        throw KeychainSecretStoreError.unexpectedStatus(status)
    }

    public func secret(for account: String) throws -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            readQuery(account: account) as CFDictionary,
            &item
        )

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainSecretStoreError.unexpectedStatus(status)
        }

        guard
            let data = item as? Data,
            let secret = String(data: data, encoding: .utf8)
        else {
            throw KeychainSecretStoreError.invalidSecretEncoding
        }

        return secret
    }

    public func removeSecret(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess {
            return
        }
        throw KeychainSecretStoreError.unexpectedStatus(status)
    }

    private func addQuery(account: String, valueData: Data) -> [String: Any] {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = valueData
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        query[kSecAttrAccessible as String] = accessibility
        #endif
        return query
    }

    private func readQuery(account: String) -> [String: Any] {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

extension KeychainSecretStore: SecretStoring {}
