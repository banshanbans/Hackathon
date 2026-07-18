import Foundation
import Security

actor KeychainStore {
    private let service: String

    init(service: String = "ai.soloshot.app.handoff") {
        self.service = service
    }

    func clientInstanceID() throws -> String {
        if let existing = try value(account: "client-instance-id") {
            return existing
        }
        let value = "ios_\(UUID().uuidString.lowercased())"
        try set(value, account: "client-instance-id")
        return value
    }

    func saveClaimToken(_ token: String, code: String) throws {
        try set(token, account: "claim-token-\(code)")
    }

    func claimToken(code: String) throws -> String? {
        try value(account: "claim-token-\(code)")
    }

    func removeClaimToken(code: String) throws {
        let status = SecItemDelete(query(account: "claim-token-\(code)") as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HandoffClientError.invalidToken
        }
    }

    private func value(account: String) throws -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw HandoffClientError.invalidToken
        }
        return value
    }

    private func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let base = query(account: account)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                throw HandoffClientError.invalidToken
            }
        } else if status != errSecSuccess {
            throw HandoffClientError.invalidToken
        }
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
