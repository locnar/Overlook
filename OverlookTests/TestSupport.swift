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

// MARK: - A device's HTTP API, answered in the test

/// Stands in for a device's HTTP API. A client from `makeClient()` sends its requests here rather
/// than to the network: `StubURLProtocol` hands each one to `handler` and records it.
///
/// Each stub has a host of its own, so tests running in parallel never answer each other's
/// requests, and the host is under `.invalid`, so a request that got past the stub could not
/// reach anything either.
final class StubDevice: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data

        var bodyText: String { String(decoding: body, as: UTF8.self) }
        var bodyJSON: JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: body) }
    }

    struct Response: Sendable {
        var status = 200
        var body: Data

        /// kvmd's success envelope: `{"ok": true, "result": …}`.
        static func ok(_ result: JSONValue = .object([:])) -> Response {
            let envelope = JSONValue.object(["ok": .bool(true), "result": result])
            return Response(body: (try? JSONEncoder().encode(envelope)) ?? Data())
        }
    }

    typealias Handler = @Sendable (Request) async throws -> Response

    let host = "stub-\(UUID().uuidString.lowercased()).invalid"

    private let lock = NSLock()
    private var handler: Handler
    private var received: [Request] = []
    private var cancelled: [Request] = []

    init(handler: @escaping Handler = { _ in .ok() }) {
        self.handler = handler
        StubURLProtocol.register(self)
    }

    deinit {
        StubURLProtocol.unregister(host: host)
    }

    /// Every request that reached the stub, in the order they arrived.
    var requests: [Request] { lock.withLock { received } }
    /// Requests the client gave up on (its task was cancelled) before they were answered.
    var cancelledRequests: [Request] { lock.withLock { cancelled } }

    func requests(to path: String) -> [Request] {
        requests.filter { $0.path == path }
    }

    func setHandler(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    func makeClient(log: SessionLog? = nil) throws -> GLKVMClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return try GLKVMClient(host: host, port: 443, log: log, sessionConfiguration: configuration)
    }

    fileprivate func handle(_ request: Request) async throws -> Response {
        let handler = lock.withLock {
            received.append(request)
            return self.handler
        }
        return try await handler(request)
    }

    fileprivate func noteCancelled(_ request: Request) {
        lock.withLock { cancelled.append(request) }
    }
}

/// Answers requests for the hosts of live `StubDevice`s; any other request is refused.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private final class WeakDevice {
        weak var device: StubDevice?
        init(_ device: StubDevice) { self.device = device }
    }

    private static let registryLock = NSLock()
    private static var devices: [String: WeakDevice] = [:]

    static func register(_ device: StubDevice) {
        registryLock.withLock { devices[device.host] = WeakDevice(device) }
    }

    static func unregister(host: String) {
        registryLock.withLock { devices[host] = nil }
    }

    private static func device(for host: String) -> StubDevice? {
        registryLock.withLock { devices[host]?.device }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        // Claims every request of a session configured with it, so none can go to the network;
        // one for an unknown host fails in `startLoading`.
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    private let stateLock = NSLock()
    private var work: Task<Void, Never>?
    private var isDone = false
    private var recorded: StubDevice.Request?
    private weak var device: StubDevice?

    override func startLoading() {
        guard let url = request.url, let host = url.host, let device = Self.device(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let recorded = StubDevice.Request(
            method: request.httpMethod ?? "GET",
            path: url.path,
            query: query,
            body: Self.body(of: request)
        )
        stateLock.withLock {
            self.recorded = recorded
            self.device = device
        }
        let task = Task {
            do {
                let response = try await device.handle(recorded)
                self.finish(with: response, url: url)
            } catch {
                self.finish(with: error)
            }
        }
        stateLock.withLock { work = task }
    }

    override func stopLoading() {
        let (task, wasDone, recorded, device) = stateLock.withLock {
            let wasDone = isDone
            isDone = true
            return (work, wasDone, self.recorded, self.device)
        }
        task?.cancel()
        if !wasDone, let recorded {
            device?.noteCancelled(recorded)
        }
    }

    /// True once, for whichever of an answer and a cancellation comes first.
    private func markDone() -> Bool {
        stateLock.withLock {
            guard !isDone else { return false }
            isDone = true
            return true
        }
    }

    private func finish(with response: StubDevice.Response, url: URL) {
        guard markDone() else { return }
        let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func finish(with error: Error) {
        guard markDone() else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }

    /// URLSession hands a protocol the body as a stream, not as `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Holds whoever waits on it until it is opened; for keeping a stubbed request unanswered.
actor Latch {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let resumed = waiting
        waiting.removeAll()
        resumed.forEach { $0.resume() }
    }
}

/// Polls `condition` until it holds or `timeout` passes; returns whether it held.
@MainActor
@discardableResult
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

/// The device's user config as kvmd keeps it: `get_config` returns the file, and `set_config`
/// replaces the whole file with the request body (`_write_user_config` opens it with "w").
final class FakeUserConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var file: GLKVMJSONObject
    /// Held before each `get_config` answer, when set, so a test can make two writes overlap.
    var readDelay: Duration?
    /// Waited on before each `set_config` answer, when set, so a test can hold a write open.
    var writeLatch: Latch?

    init(_ file: GLKVMJSONObject) {
        self.file = file
    }

    var stored: GLKVMJSONObject {
        get { lock.withLock { file } }
        set { lock.withLock { file = newValue } }
    }

    func handle(_ request: StubDevice.Request) async throws -> StubDevice.Response {
        switch request.path {
        case "/api/system/get_config":
            if let readDelay {
                try await Task.sleep(for: readDelay)
            }
            return .ok(.object(["success": .bool(true), "config": .object(stored)]))
        case "/api/system/set_config":
            guard case .object(let written)? = request.bodyJSON else {
                return StubDevice.Response(status: 400, body: Data())
            }
            if let writeLatch {
                await writeLatch.wait()
            }
            stored = written
            return .ok(.object(["success": .bool(true), "config": .object(written)]))
        default:
            return .ok()
        }
    }
}

extension StubDevice {
    convenience init(config: FakeUserConfig) {
        self.init { request in try await config.handle(request) }
    }
}

/// A settings panel's behaviour wired to a stubbed device, with nothing else of a window around it.
@MainActor
struct SettingsPanelFixture {
    let scratch = ScratchDefaults()
    let device: StubDevice
    let model = WebUISettingsPanelModel()
    let connection: SessionConnection
    let input: InputManager
    let actions: WebUISettingsActions

    init(device: StubDevice, config: GLKVMJSONObject) throws {
        self.device = device
        let catalog = KVMDeviceManager(
            defaults: scratch.defaults,
            credentials: FakeCredentialStore(),
            trustStore: Fixtures.trustStore(scratch)
        )
        connection = SessionConnection(catalog: catalog)
        connection.glkvmClient = try device.makeClient()
        input = InputManager(defaults: scratch.defaults, log: SessionLog(destination: .inMemory()))
        actions = WebUISettingsActions(
            model: model,
            webRTCManager: WebRTCManager(),
            inputManager: input,
            connection: connection
        )
        model.config = try JSONDecoder().decode(GLKVMSystemConfig.self, from: JSONEncoder().encode(config))
    }
}
