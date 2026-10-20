import Foundation
import Security

/// 极简 Keychain 封装,只服务 MCP token 的存取(generic password 类)。
/// Perch 未 sandbox,不需要额外的 keychain-access-group entitlement。
enum Keychain {
    private static let service = "tech.xvanturing.Perch.mcp"

    static func read(account: String) -> String? {
        if case .found(let value) = lookup(account: account) { return value }
        return nil
    }

    /// 读的结果分三种:有、确实没有、读失败(钥匙串锁着 / 访问被拒…)。调用方要分清后两种 ——
    /// 把「读失败」当「没有」去生成新值写回,会覆盖掉一个其实还在的值。
    enum Lookup {
        case found(String)
        case missing
        case failed(OSStatus)
    }

    static func lookup(account: String) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return .missing }
            return .found(value)
        case errSecItemNotFound:
            return .missing
        default:
            return .failed(status)
        }
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
