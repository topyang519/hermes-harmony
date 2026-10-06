import Foundation
import Security
import Darwin

enum KeychainStore {
    private static let service = "ai.hermes.harmony.ios"

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }

        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }
}

struct Credentials {
    var gatewayURL: String
    var appPassword: String
    var cfId: String
    var cfSecret: String

    static let gatewayExample = "wss://your-gateway.example/v2/app"
    static let defaultGateway = ""

    static func load() -> Credentials {
        Credentials(
            gatewayURL: {
                let v = KeychainStore.load(account: "gateway_url")
                return v.isEmpty ? defaultGateway : v
            }(),
            appPassword: KeychainStore.load(account: "app_token"),
            cfId: KeychainStore.load(account: "cf_id"),
            cfSecret: KeychainStore.load(account: "cf_secret")
        )
    }

    func save() -> Bool {
        return [
            KeychainStore.save(gatewayURL, account: "gateway_url"),
            KeychainStore.save(appPassword, account: "app_token"),
            KeychainStore.save(cfId, account: "cf_id"),
            KeychainStore.save(cfSecret, account: "cf_secret")
        ].allSatisfy { $0 }
    }

    func validate() -> String? {
        if gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写网关地址"
        }
        guard let components = URLComponents(string: gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["ws", "wss"].contains(scheme),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.fragment == nil, components.url != nil else {
            return "网关地址必须是有效的 ws:// 或 wss:// 地址"
        }
        if scheme == "ws" && !isLocalWebSocketHost(host) {
            return "明文 ws 仅支持本地或局域网地址；公网网关请使用 wss"
        }
        if appPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写应用密码"
        }
        // Cloudflare Access is Bypass; CF Id/Secret are optional.
        return nil
    }
}

func isLocalWebSocketHost(_ host: String) -> Bool {
    let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    if normalized == "localhost" || normalized.hasSuffix(".localhost") || normalized.hasSuffix(".local") {
        return true
    }

    var ipv4 = in_addr()
    if normalized.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
        let octets = withUnsafeBytes(of: ipv4) { Array($0) }
        return octets[0] == 10
            || octets[0] == 127
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
    }

    guard !normalized.contains("%") else { return false }
    var ipv6 = in6_addr()
    guard normalized.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return false }
    let octets = withUnsafeBytes(of: ipv6) { Array($0) }
    let isLoopback = octets.dropLast().allSatisfy { $0 == 0 } && octets.last == 1
    let isUniqueLocal = (octets[0] & 0xfe) == 0xfc
    let isLinkLocal = octets[0] == 0xfe && (octets[1] & 0xc0) == 0x80
    return isLoopback || isUniqueLocal || isLinkLocal
}
