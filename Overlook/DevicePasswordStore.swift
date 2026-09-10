import Foundation
import Security

/// Keychain-backed storage for saved device passwords, keyed by host:port.
///
/// A saved password is used only to answer a genuine auth rejection from the device (an expired or
/// invalid token). One the device rejects is deleted, so the operator is re-prompted instead of
/// looping on a stale value.
enum DevicePasswordStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "Overlook") + ".kvm-password"

    private static func account(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    private static func baseQuery(host: String, port: Int) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host, port: port),
        ]
    }

    static func save(_ password: String, host: String, port: Int) {
        let data = Data(password.utf8)
        let query = baseQuery(host: host, port: port)
        let update: [String: Any] = [kSecValueData as String: data]

        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "Overlook KVM password (\(account(host: host, port: port)))"
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        if status != errSecSuccess {
            print("Keychain password write failed for \(account(host: host, port: port)): \(status)")
        }
    }

    static func load(host: String, port: Int) -> String? {
        var query = baseQuery(host: host, port: port)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(host: String, port: Int) {
        SecItemDelete(baseQuery(host: host, port: port) as CFDictionary)
    }
}
