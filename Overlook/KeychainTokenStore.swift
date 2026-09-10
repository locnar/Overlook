import Foundation
import Security

/// Stores KVM auth tokens in the login keychain, one generic-password item per host:port.
///
/// A KVM auth token is full keyboard and mouse control of the target machine, so it does not belong
/// in UserDefaults, which any process running as the user can read.
enum KeychainTokenStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "Overlook") + ".kvm-auth-token"

    static func account(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    static func token(host: String, port: Int) -> String? {
        var query = baseQuery(host: host, port: port)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                print("Keychain read failed for \(account(host: host, port: port)): \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Writes or replaces the token. An empty token removes the item.
    @discardableResult
    static func setToken(_ token: String, host: String, port: Int) -> Bool {
        guard !token.isEmpty else {
            return deleteToken(host: host, port: port)
        }

        let data = Data(token.utf8)
        let query = baseQuery(host: host, port: port)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "Overlook KVM token (\(account(host: host, port: port)))"
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        if status != errSecSuccess {
            print("Keychain write failed for \(account(host: host, port: port)): \(status)")
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func deleteToken(host: String, port: Int) -> Bool {
        let status = SecItemDelete(baseQuery(host: host, port: port) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(host: String, port: Int) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host, port: port),
        ]
    }
}
