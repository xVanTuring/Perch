import Foundation
import Security

/// 极简 Keychain 封装,只服务 MCP token 的存取(generic password 类)。
/// Perch 未 sandbox,不需要额外的 keychain-access-group entitlement。
enum Keychain {
    private static let service = "tech.xvanturing.Perch.mcp"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            return SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess
        }
        var newItem = query
        newItem[kSecValueData as String] = data
        return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
    }
}
