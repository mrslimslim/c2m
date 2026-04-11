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
    public static let defaultServiceName = "com.ctunnel.saved-connections"
    public static let legacyServiceNames = ["com.codepilot.saved-connections"]

    private let service: String
    private let legacyServices: [String]
    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    private let accessibility: CFString
    #endif

    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    public init(
        service: String = KeychainSecretStore.defaultServiceName,
        legacyServices: [String] = KeychainSecretStore.legacyServiceNames,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) {
        self.service = service
        self.legacyServices = legacyServices.filter { $0 != service }
        self.accessibility = accessibility
    }
    #else
    public init(
        service: String = KeychainSecretStore.defaultServiceName,
        legacyServices: [String] = KeychainSecretStore.legacyServiceNames
    ) {
        self.service = service
        self.legacyServices = legacyServices.filter { $0 != service }
    }
    #endif

    public func setSecret(_ secret: String, for account: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw KeychainSecretStoreError.invalidSecretEncoding
        }

        let status = SecItemAdd(
            addQuery(account: account, service: service, valueData: data) as CFDictionary,
            nil
        )

        if status == errSecSuccess {
            return
        }

        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(account: account, service: service) as CFDictionary,
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
        if let current = try secret(for: account, service: service) {
            return current
        }

        for legacyService in legacyServices {
            if let legacy = try secret(for: account, service: legacyService) {
                return legacy
            }
        }

        return nil
    }

    public func removeSecret(for account: String) throws {
        try removeSecret(for: account, service: service)
        for legacyService in legacyServices {
            try removeSecret(for: account, service: legacyService)
        }
    }

    private func secret(for account: String, service: String) throws -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            readQuery(account: account, service: service) as CFDictionary,
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

    private func removeSecret(for account: String, service: String) throws {
        let status = SecItemDelete(baseQuery(account: account, service: service) as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess {
            return
        }
        throw KeychainSecretStoreError.unexpectedStatus(status)
    }

    private func addQuery(account: String, service: String, valueData: Data) -> [String: Any] {
        var query = baseQuery(account: account, service: service)
        query[kSecValueData as String] = valueData
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        query[kSecAttrAccessible as String] = accessibility
        #endif
        return query
    }

    private func readQuery(account: String, service: String) -> [String: Any] {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    private func baseQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

extension KeychainSecretStore: SecretStoring {}
