import Foundation
import Security

enum Keychain {
    private static let service = "Legend Remake"

    private static func query(_ user: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: user.lowercased()]
    }

    static func ticket(for user: String) -> String? {
        var q = query(user)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func store(_ ticket: String, for user: String) {
        let data = Data(ticket.utf8)
        let status = SecItemUpdate(query(user) as CFDictionary, [kSecValueData: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var q = query(user)
        q[kSecValueData] = data
        q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrLabel] = "Legend Remake (\(user))"
        SecItemAdd(q as CFDictionary, nil)
    }

    static func remove(for user: String) {
        SecItemDelete(query(user) as CFDictionary)
    }
}
