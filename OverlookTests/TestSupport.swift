import Foundation
@testable import Overlook

/// A `UserDefaults` suite of its own for one test, removed again when the test lets go of it.
/// Nothing under test may read or write the app's own defaults: the test host *is* the app, so
/// `.standard` is the operator's real settings.
final class ScratchDefaults {
    let suiteName = "OverlookTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create a defaults suite named \(suiteName)")
        }
        self.defaults = defaults
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// An in-memory stand-in for the keychain, so catalog tests never touch the login keychain.
final class FakeCredentialStore: DeviceCredentialStore {
    var tokens: [String: String] = [:]
    var passwords: [String: String] = [:]
    /// Set to make `setToken` fail, as a keychain that refuses the write would.
    var refusesWrites = false
    private(set) var deletedTokens: [String] = []
    private(set) var deletedPasswords: [String] = []

    static func key(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    func token(host: String, port: Int) -> String? {
        tokens[Self.key(host: host, port: port)]
    }

    @discardableResult
    func setToken(_ token: String, host: String, port: Int) -> Bool {
        guard !refusesWrites else { return false }
        let key = Self.key(host: host, port: port)
        if token.isEmpty {
            tokens.removeValue(forKey: key)
        } else {
            tokens[key] = token
        }
        return true
    }

    func deleteToken(host: String, port: Int) {
        let key = Self.key(host: host, port: port)
        tokens.removeValue(forKey: key)
        deletedTokens.append(key)
    }

    func deletePassword(host: String, port: Int) {
        let key = Self.key(host: host, port: port)
        passwords.removeValue(forKey: key)
        deletedPasswords.append(key)
    }
}

/// The record format `KVMDeviceManager` writes under `overlook.saved_devices.v1`, spelled out
/// here rather than borrowed from the app, so a change to the stored format fails a test instead
/// of silently changing with it.
struct StoredDeviceRecord: Codable, Equatable {
    var host: String
    var port: Int
    var name: String
    var type: String
    var authToken: String?
    var capabilities: [String]
}

enum Fixtures {
    static let savedDevicesKey = "overlook.saved_devices.v1"

    static func device(
        id: String = "manual-test",
        name: String = "Test KVM",
        host: String = "192.0.2.10",
        port: Int = 443,
        type: KVMDeviceType = .glinetComet,
        authToken: String = ""
    ) -> KVMDevice {
        KVMDevice(
            id: id,
            name: name,
            host: host,
            port: port,
            type: type,
            authToken: authToken,
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput]
        )
    }

    static func writeRecords(_ records: [StoredDeviceRecord], to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(records), forKey: savedDevicesKey)
    }

    static func readRecords(from defaults: UserDefaults) throws -> [StoredDeviceRecord] {
        guard let data = defaults.data(forKey: savedDevicesKey) else { return [] }
        return try JSONDecoder().decode([StoredDeviceRecord].self, from: data)
    }

    /// A trust store backed by its own scratch suite, so `forgetDevice` cannot drop a real pin.
    static func trustStore(_ scratch: ScratchDefaults) -> DeviceTrustStore {
        DeviceTrustStore(defaults: scratch.defaults)
    }
}
