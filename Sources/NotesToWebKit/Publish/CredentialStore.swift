import Foundation
import Security

public enum CredentialStoreError: Error, LocalizedError, Equatable {
    case couldNotRead(OSStatus)
    case couldNotWrite(OSStatus)
    case couldNotDelete(OSStatus)
    case notText

    public var errorDescription: String? {
        switch self {
        case .couldNotRead(let status):
            "The keychain would not hand back the saved token (\(Self.reason(status))). Enter it again."
        case .couldNotWrite(let status):
            "The keychain refused to save the token (\(Self.reason(status))). Unlock your login keychain and try again."
        case .couldNotDelete(let status):
            "The keychain refused to remove the saved token (\(Self.reason(status)))."
        case .notText:
            "The saved token is damaged. Remove it and enter the token again."
        }
    }

    private static func reason(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
    }
}

/// Login-keychain storage for provider credentials.
///
/// One item per provider: service is the app's bundle identifier, account is the
/// provider ID. Secrets never appear in error text or logs — a leaked token in a
/// crash report is the whole threat model here.
public struct CredentialStore: Sendable {
    public static let defaultService = "com.alecf.notes-to-web"

    public let service: String

    public init(service: String = CredentialStore.defaultService) {
        self.service = service
    }

    /// Returns `nil` when nothing is stored. Only real keychain failures throw.
    public func read(provider: String) throws -> String? {
        var query = baseQuery(provider: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw CredentialStoreError.notText
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.couldNotRead(status)
        }
    }

    public func write(_ secret: String, provider: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(provider: provider)

        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.couldNotWrite(updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.couldNotWrite(addStatus)
        }
    }

    /// Deleting something that is not there is success, not an error.
    public func delete(provider: String) throws {
        let status = SecItemDelete(baseQuery(provider: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.couldNotDelete(status)
        }
    }

    private func baseQuery(provider: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
        ]
    }
}
