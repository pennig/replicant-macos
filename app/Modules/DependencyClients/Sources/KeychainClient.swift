//
//  KeychainClient.swift
//  Replicant
//
//  A small, controllable dependency that stores the API key securely in the
//  macOS Keychain. Exposed to features via `@Dependency(\.keychain)`.
//

import ComposableArchitecture
import Foundation
import Security

/// Securely stores small string secrets (the API key) in the Keychain.
public struct KeychainClient: Sendable {
    /// Save (or overwrite) the value for the given account key.
    public var save: @Sendable (_ value: String, _ account: String) throws -> Void
    /// Load the value for the given account key, or `nil` if absent.
    public var load: @Sendable (_ account: String) -> String?
    /// Remove the value for the given account key.
    public var delete: @Sendable (_ account: String) throws -> Void
}

public extension KeychainClient {
    /// The account key under which the API key is stored.
    nonisolated static let apiKeyAccount = "api-key"

    enum Failure: Error { case unexpectedStatus(OSStatus) }
}

// MARK: - Live implementation

extension KeychainClient: DependencyKey {
    public static let liveValue: KeychainClient = {
        let service = "name.pennig.Replicant"

        @Sendable func query(_ account: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
        }

        return KeychainClient(
            save: { value, account in
                let data = Data(value.utf8)
                // Remove any existing item, then add fresh — simplest correct upsert.
                SecItemDelete(query(account) as CFDictionary)
                var attributes = query(account)
                attributes[kSecValueData as String] = data
                let status = SecItemAdd(attributes as CFDictionary, nil)
                guard status == errSecSuccess else { throw Failure.unexpectedStatus(status) }
            },
            load: { account in
                var attributes = query(account)
                attributes[kSecReturnData as String] = true
                attributes[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = SecItemCopyMatching(attributes as CFDictionary, &result)
                guard status == errSecSuccess, let data = result as? Data else { return nil }
                return String(decoding: data, as: UTF8.self)
            },
            delete: { account in
                let status = SecItemDelete(query(account) as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw Failure.unexpectedStatus(status)
                }
            }
        )
    }()
}

// MARK: - Test / preview implementation

extension KeychainClient: TestDependencyKey {
    /// An in-memory stand-in so previews and tests never touch the real Keychain.
    public static var testValue: KeychainClient {
        let storage = LockIsolated<[String: String]>([:])
        return KeychainClient(
            save: { value, account in storage.withValue { $0[account] = value } },
            load: { account in storage.value[account] },
            delete: { account in storage.withValue { $0[account] = nil } }
        )
    }

    public static let previewValue = testValue
}

extension DependencyValues {
    public var keychain: KeychainClient {
        get { self[KeychainClient.self] }
        set { self[KeychainClient.self] = newValue }
    }
}
