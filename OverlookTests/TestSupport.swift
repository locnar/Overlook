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

/// Stands in for the parts of a connect that reach outside the app (`LiveSessionLink`). Each step
/// is recorded with what the session looked like at that moment, and signing in points the
/// session's connection at the device the way `SessionConnection.connectToDevice` does — saved
/// in the catalog under its `saved-` id when one is given — with no network involved.
@MainActor
final class RecordingSessionLink: ConsoleSessionLink {
    enum Step: Equatable {
        case signIn(host: String, password: String?)
        case startInput
        case startStream(host: String)
        case hangUp
        case stopInput
        case shutDown
    }

    struct Entry {
        let step: Step
        /// Whether the session was recording when the step ran.
        let wasRecording: Bool
        /// The device the session's connection held when the step ran.
        let device: KVMDevice?
    }

    private(set) var entries: [Entry] = []
    var steps: [Step] { entries.map(\.step) }

    /// Saves a signed-in device here, as a real connect does, when set.
    var catalog: KVMDeviceManager?
    /// Thrown from `signIn` instead of signing in.
    var signInError: Error?
    /// Thrown from `startStream`.
    var streamError: Error?
    /// Runs inside `signIn`, before it returns or throws: while the connect is under way.
    var duringSignIn: (@MainActor (ConsoleSession) async -> Void)?

    init(catalog: KVMDeviceManager? = nil) {
        self.catalog = catalog
    }

    private func record(_ step: Step, _ session: ConsoleSession) {
        entries.append(Entry(
            step: step,
            wasRecording: session.captureManager.isRecording,
            device: session.connection.connectedDevice
        ))
    }

    func signIn(_ session: ConsoleSession, to device: KVMDevice, password: String?, savePassword: Bool) async throws -> KVMDevice {
        record(.signIn(host: device.host, password: password), session)
        await duringSignIn?(session)
        if let signInError { throw signInError }

        var saved = device
        if let catalog {
            saved = catalog.persistDevice(device)
        } else {
            saved.id = "saved-\(device.host)-\(device.port)"
        }
        session.connection.connectedDevice = saved
        session.connection.glkvmClient = try GLKVMClient(device: saved)
        return saved
    }

    func startInput(_ session: ConsoleSession) async {
        record(.startInput, session)
    }

    func startStream(_ session: ConsoleSession, to device: KVMDevice) async throws {
        record(.startStream(host: device.host), session)
        if let streamError { throw streamError }
    }

    func hangUp(_ session: ConsoleSession) {
        record(.hangUp, session)
    }

    func stopInput(_ session: ConsoleSession) {
        record(.stopInput, session)
    }

    func shutDown(_ session: ConsoleSession) async {
        record(.shutDown, session)
    }
}

struct TestError: Error, Equatable {
    let name: String
}
