import Foundation
import Testing
@testable import Overlook

/// The one connect and disconnect path that the window and the menu-bar agent share. The steps
/// that reach the device are recorded by `RecordingSessionLink` instead of run, so these check the
/// order and the session's own state with no device on the network.
@MainActor
@Suite("Session connect path")
struct SessionConnectTests {
    let scratch = ScratchDefaults()
    let catalog: KVMDeviceManager

    init() {
        catalog = KVMDeviceManager(
            defaults: scratch.defaults,
            credentials: FakeCredentialStore(),
            trustStore: Fixtures.trustStore(scratch)
        )
    }

    private func makeSession(_ link: RecordingSessionLink) -> ConsoleSession {
        ConsoleSession(catalog: catalog, defaults: scratch.defaults, link: link, connectionLog: .inMemory())
    }

    // MARK: - Connecting

    @Test func aConnectSignsInThenStartsInputThenTheStream() async {
        let link = RecordingSessionLink()
        let session = makeSession(link)
        var stepsWhenSignedIn: [RecordingSessionLink.Step] = []

        let outcome = await session.connect(to: Fixtures.device(host: "192.0.2.50")) { _ in
            stepsWhenSignedIn = link.steps
        }

        guard case .connected(let device, let streamError) = outcome else {
            Issue.record("Expected a connection, got \(outcome)")
            return
        }
        #expect(device.id == "saved-192.0.2.50-443")
        #expect(streamError == nil)
        // The window closes its Connections panel here, before the stream has come up.
        #expect(stepsWhenSignedIn == [.signIn(host: "192.0.2.50", password: nil)])
        #expect(link.steps == [
            .signIn(host: "192.0.2.50", password: nil),
            .startInput,
            .startStream(host: "192.0.2.50"),
        ])
        #expect(session.connection.connectedDevice?.host == "192.0.2.50")
        #expect(session.panels.isSessionActive)
    }

    @Test func aTypedPasswordReachesTheSignIn() async {
        let link = RecordingSessionLink()
        let session = makeSession(link)

        _ = await session.connect(to: Fixtures.device(host: "192.0.2.51"), password: "hunter2", savePassword: true)

        #expect(link.steps.first == .signIn(host: "192.0.2.51", password: "hunter2"))
    }

    @Test func aRefusedSignInAsksForAPasswordAndStartsNothing() async {
        let link = RecordingSessionLink()
        link.signInError = KVMError.authenticationFailed
        let session = makeSession(link)
        var signedIn = false

        let outcome = await session.connect(to: Fixtures.device()) { _ in signedIn = true }

        guard case .needsPassword = outcome else {
            Issue.record("Expected a password prompt, got \(outcome)")
            return
        }
        #expect(signedIn == false)
        #expect(link.steps == [.signIn(host: "192.0.2.10", password: nil)])
        #expect(session.connection.connectedDevice == nil)
    }

    @Test func aChangedCertificateIsReportedWithItsFingerprint() async {
        let link = RecordingSessionLink()
        link.signInError = KVMError.certificateChanged(host: "192.0.2.52", port: 8443, fingerprint: "AB:CD")
        let session = makeSession(link)

        let outcome = await session.connect(to: Fixtures.device(host: "192.0.2.52", port: 8443))

        guard case .certificateChanged(let host, let port, let fingerprint) = outcome else {
            Issue.record("Expected a certificate question, got \(outcome)")
            return
        }
        #expect(host == "192.0.2.52")
        #expect(port == 8443)
        #expect(fingerprint == "AB:CD")
        #expect(link.steps.count == 1)
    }

    @Test func anyOtherFailureIsReportedAndStartsNothing() async {
        let link = RecordingSessionLink()
        link.signInError = TestError(name: "unreachable")
        let session = makeSession(link)

        let outcome = await session.connect(to: Fixtures.device())

        guard case .failed(let error) = outcome else {
            Issue.record("Expected a failure, got \(outcome)")
            return
        }
        #expect(error as? TestError == TestError(name: "unreachable"))
        #expect(link.steps.count == 1)
        #expect(session.panels.isSessionActive == false)
    }

    @Test func aStreamThatFailsLeavesTheSessionConnected() async {
        let link = RecordingSessionLink()
        link.streamError = TestError(name: "no video")
        let session = makeSession(link)

        let outcome = await session.connect(to: Fixtures.device())

        guard case .connected(_, let streamError) = outcome else {
            Issue.record("Expected a connection, got \(outcome)")
            return
        }
        #expect(streamError as? TestError == TestError(name: "no video"))
        #expect(session.connection.connectedDevice != nil)
        #expect(session.panels.isSessionActive)
    }

    // MARK: - Disconnecting

    @Test func aDisconnectHangsUpWhileTheDeviceIsStillKnownThenLetsGoOfInput() async {
        let link = RecordingSessionLink()
        let session = makeSession(link)
        _ = await session.connect(to: Fixtures.device(host: "192.0.2.53"))

        session.disconnect()

        #expect(Array(link.steps.suffix(2)) == [.hangUp, .stopInput])
        // The hang-up tells the device the console has gone, so it needs the client still there.
        #expect(link.entries.first { $0.step == .hangUp }?.device?.host == "192.0.2.53")
        #expect(link.entries.last?.device == nil)
        #expect(session.connection.connectedDevice == nil)
        #expect(session.connection.glkvmClient == nil)
        #expect(session.panels.isSessionActive == false)
    }

    @Test func quittingShutsTheSessionDown() async {
        let link = RecordingSessionLink()
        let session = makeSession(link)
        _ = await session.connect(to: Fixtures.device())

        await session.shutDownForTermination()

        #expect(link.steps.last == .shutDown)
    }
}

/// Where `SessionConnection.connectToDevice` keeps a typed password: in the catalog's credential
/// store (memory here, the login keychain in the app), never the keychain directly. The TCP check
/// is answered here and the device's API by a stub, so nothing reaches the network.
@MainActor
@Suite("Connect passwords")
struct ConnectPasswordTests {
    let scratch = ScratchDefaults()
    let credentials = FakeCredentialStore()
    let catalog: KVMDeviceManager

    init() {
        catalog = Fixtures.catalog(scratch, credentials: credentials)
    }

    /// kvmd's answer to a request without a valid token.
    nonisolated static let unauthorized = StubDevice.Response(status: 401, body: Data("""
    {"ok": false, "result": {"error": "UnauthorizedError", "error_msg": "Unauthorized"}}
    """.utf8))

    /// A device whose token has expired, and that signs in with `password` alone.
    nonisolated static func device(acceptingPassword password: String) -> StubDevice {
        StubDevice { request in
            switch request.path {
            case "/api/auth/check":
                return Self.unauthorized
            case "/api/auth/login":
                guard request.bodyText.contains("\r\n\(password)\r\n") else { return Self.unauthorized }
                return .ok(.object(["token": .string("fresh-token")]))
            default:
                return .ok()
            }
        }
    }

    func makeConnection(to stub: StubDevice) -> SessionConnection {
        SessionConnection(
            catalog: catalog,
            reach: { _ in true },
            makeClient: { device, log in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [StubURLProtocol.self]
                return try GLKVMClient(
                    host: device.host,
                    port: device.port,
                    authToken: device.authToken.isEmpty ? nil : device.authToken,
                    log: log,
                    sessionConfiguration: configuration
                )
            }
        )
    }

    @Test func aTypedPasswordIsSavedThroughTheCatalogsStore() async throws {
        let stub = Self.device(acceptingPassword: "hunter2")
        let connection = makeConnection(to: stub)
        let key = FakeCredentialStore.key(host: stub.host, port: 443)

        let connected = try await connection.connectToDevice(
            Fixtures.device(host: stub.host),
            password: "hunter2",
            savePassword: true
        )

        #expect(credentials.savedPasswords == [key])
        #expect(credentials.passwords[key] == "hunter2")
        #expect(connected.authToken == "fresh-token")
        #expect(stub.requests(to: "/api/auth/login").count == 1)
    }

    @Test func aTypedPasswordIsNotSavedUnlessAsked() async throws {
        let stub = Self.device(acceptingPassword: "hunter2")
        _ = try await makeConnection(to: stub).connectToDevice(Fixtures.device(host: stub.host), password: "hunter2")
        #expect(credentials.savedPasswords.isEmpty)
        #expect(credentials.passwords.isEmpty)
    }

    @Test func aSavedPasswordTheDeviceRejectsIsDeletedThroughTheCatalogsStore() async {
        let stub = Self.device(acceptingPassword: "the-new-one")
        let key = FakeCredentialStore.key(host: stub.host, port: 443)
        credentials.passwords[key] = "stale"

        await #expect(throws: KVMError.authenticationFailed) {
            try await makeConnection(to: stub).connectToDevice(Fixtures.device(host: stub.host))
        }

        #expect(credentials.deletedPasswords == [key])
        #expect(credentials.passwords[key] == nil)
        #expect(credentials.savedPasswords.isEmpty)
    }

    @Test func aWrongTypedPasswordLeavesASavedOneAlone() async {
        let stub = Self.device(acceptingPassword: "right")
        let key = FakeCredentialStore.key(host: stub.host, port: 443)
        credentials.passwords[key] = "right"

        await #expect(throws: KVMError.authenticationFailed) {
            try await makeConnection(to: stub).connectToDevice(
                Fixtures.device(host: stub.host),
                password: "wrong",
                savePassword: true
            )
        }

        #expect(credentials.deletedPasswords.isEmpty)
        #expect(credentials.savedPasswords.isEmpty)
        #expect(credentials.passwords[key] == "right")
    }

    @Test func anUnreachableDeviceIsNotAskedAnything() async {
        let stub = Self.device(acceptingPassword: "hunter2")
        let connection = SessionConnection(catalog: catalog, reach: { _ in false })
        await #expect(throws: KVMError.connectionFailed) {
            try await connection.connectToDevice(Fixtures.device(host: stub.host), password: "hunter2", savePassword: true)
        }
        #expect(stub.requests.isEmpty)
        #expect(credentials.savedPasswords.isEmpty)
    }
}
