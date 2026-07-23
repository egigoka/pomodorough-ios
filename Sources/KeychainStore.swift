import Foundation
import Security

protocol TokenStoring: Sendable {
    func load() throws -> TokenPair?
    func save(_ tokens: TokenPair) throws
    func delete() throws
}

struct KeychainStore: TokenStoring {
    private let service = "me.egigoka.pomodorough.native-auth"
    private let account = "token-pair"

    func load() throws -> TokenPair? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(operation: "load", status: status)
        }
        return try JSONDecoder.api.decode(TokenPair.self, from: data)
    }

    func save(_ tokens: TokenPair) throws {
        let data = try JSONEncoder.api.encode(tokens)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError(operation: "save (add)", status: addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError(operation: "save (update)", status: status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: "delete", status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }
}

private struct KeychainError: LocalizedError {
    let operation: String
    let status: OSStatus
    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
        return "Keychain \(operation) failed (OSStatus \(status)): \(message)"
    }
}
