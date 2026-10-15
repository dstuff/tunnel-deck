import Foundation
import Security
import TunnelCore

protocol ProfileSecretStorage {
    func load(_ id: UUID) -> ProfileSecrets?
    func save(_ secrets: ProfileSecrets, id: UUID) throws
    func delete(_ id: UUID) throws
}

struct SecretStore: ProfileSecretStorage {
    private static let service = "local.TunnelDeck.profiles"
    func load(_ id: UUID) -> ProfileSecrets? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service, kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ProfileSecrets.self, from: data)
    }
    func save(_ secrets: ProfileSecrets, id: UUID) throws {
        let data = try JSONEncoder().encode(secrets)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service, kSecAttrAccount as String: id.uuidString]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw VPNError("Не удалось сохранить секреты в Связке ключей.") }
        } else if status != errSecSuccess { throw VPNError("Связка ключей отклонила сохранение.") }
    }
    func delete(_ id: UUID) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                       kSecAttrAccount as String: id.uuidString] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VPNError("Не удалось удалить секреты из Связки ключей.")
        }
    }
}
