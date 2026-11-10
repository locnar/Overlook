import Foundation

/// Whether this process is hosting the unit tests, and where the app's own objects keep what they
/// save.
///
/// The test bundle is loaded into the app, so Product › Test launches Overlook like any other run:
/// the app delegate builds the device catalog, the audio settings, the certificate pins and the
/// connection log before the first test starts. Under the test host those objects get stores that
/// lead nowhere: a defaults suite of their own, emptied at launch, credentials kept in memory, and
/// a log with no file. A test run then never reads or changes the operator's saved devices,
/// settings, pins, keychain items or log. A normal launch gets `.standard`, the login keychain and
/// the log file, as it always has.
enum AppEnvironment {
    /// Environment variables Xcode sets on the app when it launches it to host a test bundle,
    /// Swift Testing as much as XCTest. Read from the environment rather than by looking for a
    /// loaded test framework: the app delegate's `init` runs before the bundle is loaded.
    static let testHostVariables = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]

    /// True when this process is hosting the unit tests.
    static let isHostingTests = isTestHost(environment: ProcessInfo.processInfo.environment)

    static func isTestHost(environment: [String: String]) -> Bool {
        testHostVariables.contains { environment[$0] != nil }
    }

    /// The suite the test host's objects use in place of `.standard`.
    static let testHostSuiteName = "Overlook.TestHost"

    /// The defaults the app's own objects read and write: `.standard`, or under the test host a
    /// suite of its own, emptied as the app starts so nothing carries over from an earlier run.
    static let defaults: UserDefaults = {
        guard isHostingTests else { return .standard }
        guard let suite = UserDefaults(suiteName: testHostSuiteName) else {
            fatalError("Could not create a defaults suite named \(testHostSuiteName)")
        }
        suite.removePersistentDomain(forName: testHostSuiteName)
        return suite
    }()

    /// Where the device catalog keeps tokens and passwords: the login keychain, or under the test
    /// host a store in memory.
    static func makeCredentialStore() -> DeviceCredentialStore {
        isHostingTests ? InMemoryDeviceCredentials() : KeychainDeviceCredentials()
    }
}

/// Tokens and passwords kept in memory only, for the test host's device catalog.
final class InMemoryDeviceCredentials: DeviceCredentialStore {
    private var tokens: [String: String] = [:]
    private var passwords: [String: String] = [:]

    private static func key(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    func token(host: String, port: Int) -> String? {
        tokens[Self.key(host: host, port: port)]
    }

    @discardableResult
    func setToken(_ token: String, host: String, port: Int) -> Bool {
        let key = Self.key(host: host, port: port)
        if token.isEmpty {
            tokens.removeValue(forKey: key)
        } else {
            tokens[key] = token
        }
        return true
    }

    func deleteToken(host: String, port: Int) {
        tokens.removeValue(forKey: Self.key(host: host, port: port))
    }

    func password(host: String, port: Int) -> String? {
        passwords[Self.key(host: host, port: port)]
    }

    func deletePassword(host: String, port: Int) {
        passwords.removeValue(forKey: Self.key(host: host, port: port))
    }
}
