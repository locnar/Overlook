import Foundation
import Security
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

// MARK: - The KVM's video mode

/// A KVM in the WebRTC (Native) video mode stops Janus, which Overlook streams through. A connect
/// that fails at Janus reads the mode and says so; one to a device already known to be in that
/// mode is refused before Janus is tried. The device is a stub; nothing reaches the network.
@MainActor
@Suite("KVM video mode")
struct VideoModeTests {
    let scratch = ScratchDefaults()

    static let expectedMessage = "This KVM is set to the WebRTC (Native) video mode, which Overlook can't use. "
        + "In the KVM's web page, change Video › Mode to another mode, then connect again."

    private func device(mode: String?) -> StubDevice {
        var file: GLKVMJSONObject = ["stream_quality": .int(1), "language": .string("en")]
        if let mode {
            file["video_mode"] = .string(mode)
        }
        return StubDevice(config: FakeUserConfig(file))
    }

    private func isSignalingLost(_ error: Error) -> Bool {
        if case WebRTCError.signalingConnectionLost = error { return true }
        return false
    }

    private func messages(in log: SessionLog, containing text: String) async -> [String] {
        let marker = "flush-\(UUID().uuidString)"
        log.debug(.lifecycle, marker)
        await waitUntil { log.store.events(in: .allDevices).contains { $0.message.contains(marker) } }
        return log.store.events(in: .allDevices).map(\.message).filter { $0.contains(text) }
    }

    @Test func theMessageIsTheOneAskedFor() {
        #expect(NativeWebRTCVideoModeError.message == Self.expectedMessage)
        #expect(NativeWebRTCVideoModeError().localizedDescription == Self.expectedMessage)
        #expect(String(describing: NativeWebRTCVideoModeError()) == Self.expectedMessage)
    }

    @Test func theSystemConfigCarriesTheVideoMode() async throws {
        let stub = device(mode: "gl_webrtc")
        let client = try stub.makeClient()
        #expect(try await client.getSystemConfig().videoMode == "gl_webrtc")
        #expect(await client.readVideoMode() == "gl_webrtc")
        // Also keeps the stub alive until here: a request to a stub that has gone fails.
        #expect(stub.requests(to: "/api/system/get_config").count == 2)
    }

    @Test func aJanusFailureInNativeModeGetsTheMessage() async throws {
        let stub = device(mode: "gl_webrtc")
        let client = try stub.makeClient()

        let result = await GLKVMVideoMode.explain(WebRTCError.signalingConnectionLost) { await client.readVideoMode() }

        #expect(result.error is NativeWebRTCVideoModeError)
        #expect(result.error.localizedDescription == Self.expectedMessage)
        #expect(result.mode == "gl_webrtc")
        #expect(stub.requests(to: "/api/system/get_config").count == 1)
        // Only read: nothing is written to the device.
        #expect(stub.requests(to: "/api/system/set_config").isEmpty)
    }

    @Test(arguments: ["webrtc", "direct_h264", "flex_fec"])
    func aJanusFailureInAnyOtherModeIsReportedAsBefore(_ mode: String) async throws {
        let stub = device(mode: mode)
        let client = try stub.makeClient()

        let result = await GLKVMVideoMode.explain(WebRTCError.signalingConnectionLost) { await client.readVideoMode() }

        #expect(isSignalingLost(result.error))
        #expect(result.mode == mode)
        #expect(stub.requests(to: "/api/system/get_config").count == 1)
    }

    @Test func noModeOrNoAnswerIsReportedAsBefore() async throws {
        // Firmware without the key.
        let olderStub = device(mode: nil)
        let older = try olderStub.makeClient()
        let olderResult = await GLKVMVideoMode.explain(WebRTCError.signalingConnectionLost) { await older.readVideoMode() }
        #expect(isSignalingLost(olderResult.error))
        #expect(olderResult.mode == "")
        #expect(olderStub.requests(to: "/api/system/get_config").count == 1)

        // A device that does not answer the config read.
        let failing = StubDevice { _ in StubDevice.Response(status: 500, body: Data()) }
        let client = try failing.makeClient()
        let result = await GLKVMVideoMode.explain(WebRTCError.signalingConnectionLost) { await client.readVideoMode() }
        #expect(isSignalingLost(result.error))
        #expect(result.mode == nil)
        #expect(failing.requests(to: "/api/system/get_config").count == 1)

        // No reader at all.
        #expect(isSignalingLost(await GLKVMVideoMode.explain(WebRTCError.signalingConnectionLost, readMode: nil).error))
    }

    @Test func aDeviceKnownToBeInNativeModeIsRefusedBeforeJanus() async throws {
        let stub = device(mode: "gl_webrtc")
        let client = try stub.makeClient()
        let log = SessionLog(destination: .inMemory())
        let manager = WebRTCManager(
            audioPreferences: AudioPreferences(defaults: scratch.defaults),
            networkPreferences: NetworkPreferences(defaults: scratch.defaults),
            log: log
        )
        // Getting as far as the media route would mean Janus was about to be tried.
        manager.resolveHost = { host in
            Issue.record("The connect went on to resolve \(host)")
            return []
        }
        manager.localInterfaces = { [] }
        manager.readVideoMode = { await client.readVideoMode() }
        let kvm = Fixtures.device(host: "192.0.2.77")
        manager.noteVideoMode("gl_webrtc", for: kvm.address)

        await #expect(throws: NativeWebRTCVideoModeError.self) {
            try await manager.connect(to: kvm)
        }

        #expect(manager.lastDisconnectReason == Self.expectedMessage)
        #expect(manager.hasEverConnectedToStream, "the overlay shows the message")
        #expect(!manager.isConnecting)
        #expect(!manager.isConnected)
        // The known mode is read again before refusing, so a mode changed since is picked up.
        #expect(stub.requests(to: "/api/system/get_config").count == 1)
        #expect(stub.requests(to: "/api/system/set_config").isEmpty)
        // Logged once, and not again as a generic connect failure.
        #expect(await messages(in: log, containing: "WebRTC (Native)").count == 1)
        #expect(await messages(in: log, containing: "Connect failed").isEmpty)
    }

    @Test func theSessionReadsTheModeThroughItsOwnClient() async throws {
        let stub = device(mode: "gl_webrtc")
        let session = ConsoleSession(
            catalog: Fixtures.catalog(scratch),
            defaults: scratch.defaults,
            link: RecordingSessionLink(),
            connectionLog: .inMemory()
        )
        let reader = try #require(session.webRTCManager.readVideoMode)
        #expect(await reader() == nil, "no client yet")

        session.connection.glkvmClient = try stub.makeClient()
        #expect(await reader() == "gl_webrtc")
        #expect(stub.requests(to: "/api/system/get_config").count == 1)
    }
}

// MARK: - Certificate pins

/// `SessionConnection` keeps certificate pins in its catalog's trust store, as it keeps passwords
/// in the catalog's credential store, so a test's connection uses the test's own store and never
/// the app's.
@MainActor
@Suite("Connection trust store")
struct ConnectionTrustStoreTests {
    let scratch = ScratchDefaults()

    /// Hands a value that is not `Sendable` to a stub's handler.
    final class Carried<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    /// A self-signed certificate made for these tests (CN overlook-test.invalid); no system trusts it.
    nonisolated static let certificateDER = Data(base64Encoded: """
        MIIBlzCCAT2gAwIBAgIUbXObFBwfJ0n3Vmib10k4Br64nW8wCgYIKoZIzj0EAwIwIDEeMBwGA1UEAwwVb3Zlcmxvb2stdGVzdC5p\
        bnZhbGlkMCAXDTI2MTExMTAwNTUwOVoYDzIxMjYxMDE4MDA1NTA5WjAgMR4wHAYDVQQDDBVvdmVybG9vay10ZXN0LmludmFsaWQw\
        WTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQjMObOx8Cye8YYgDmGlRcKmlSK9BD6Ha8wCz6oGxAe3MO6jYf/m6YEZaLJuoWSAszT\
        z5DGAMy7amvMpKQxjC13o1MwUTAdBgNVHQ4EFgQUCNNOf6qcxUqd1ZPjpWOt61FkyKkwHwYDVR0jBBgwFoAUCNNOf6qcxUqd1ZPj\
        pWOt61FkyKkwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEAyHOm1i8CqlQh5AKfGEqYzs7Dpn0o/xsQsXI24WPc\
        6VoCIDDbKdfyn6ftXVW7ycceoiXzEswtnWnyQaOxC+X9Tdtw
        """)!

    /// The test certificate as a server would present it, evaluated without the network.
    private static func presented() throws -> (trust: SecTrust, fingerprint: String) {
        let certificate = try #require(SecCertificateCreateWithData(nil, certificateDER as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let made = try #require(trust)
        SecTrustSetNetworkFetchAllowed(made, false)
        return (made, DeviceTrustStore.fingerprint(of: certificate))
    }

    /// A stub device, pinned under another certificate in a trust store of the test's own, and a
    /// catalog with that store.
    private func pinnedDevice() -> (StubDevice, DeviceTrustStore, KVMDeviceManager) {
        let stub = StubDevice()
        scratch.defaults.set([DeviceTrustStore.key(host: stub.host, port: 443): "aa"], forKey: "overlook.trusted_certificates.v1")
        let trust = DeviceTrustStore(defaults: scratch.defaults)
        return (stub, trust, Fixtures.catalog(scratch, trust: trust))
    }

    private func makeConnection(catalog: KVMDeviceManager) -> SessionConnection {
        SessionConnection(
            catalog: catalog,
            reach: { _ in true },
            makeClient: { device, log in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [StubURLProtocol.self]
                return try GLKVMClient(host: device.host, port: device.port, log: log, sessionConfiguration: configuration)
            }
        )
    }

    @Test func aChangedCertificateIsFoundInTheCatalogsStore() async throws {
        let (stub, trust, catalog) = pinnedDevice()
        #expect(trust.pinnedFingerprint(host: stub.host, port: 443) == "aa")
        let presented = try Self.presented()
        let carried = Carried((trust, presented.trust))
        let host = stub.host
        // At sign-in the device presents another certificate. The stub records the mismatch where
        // the client's TLS check would, in the catalog's store, and the request fails.
        stub.setHandler { _ in
            _ = carried.value.0.evaluate(carried.value.1, host: host, port: 443)
            return StubDevice.Response(status: 502, body: Data())
        }

        await #expect(throws: KVMError.certificateChanged(host: host, port: 443, fingerprint: presented.fingerprint)) {
            try await makeConnection(catalog: catalog).connectToDevice(Fixtures.device(host: host))
        }

        #expect(trust.pendingMismatch(host: host, port: 443)?.actual == presented.fingerprint)
        // The app's store was never asked.
        #expect(DeviceTrustStore.shared.pendingMismatch(host: host, port: 443) == nil)
        #expect(DeviceTrustStore.shared.pinnedFingerprint(host: host, port: 443) == nil)
    }

    @Test func aConnectClearsAStaleMismatchInTheCatalogsStore() async throws {
        let (stub, trust, catalog) = pinnedDevice()
        let presented = try Self.presented()
        _ = trust.evaluate(presented.trust, host: stub.host, port: 443)
        #expect(trust.pendingMismatch(host: stub.host, port: 443) != nil)
        stub.setHandler { _ in .ok() }

        let connected = try await makeConnection(catalog: catalog).connectToDevice(Fixtures.device(host: stub.host))

        #expect(connected.host == stub.host)
        #expect(trust.pendingMismatch(host: stub.host, port: 443) == nil)
        #expect(trust.pinnedFingerprint(host: stub.host, port: 443) == "aa")
        #expect(stub.requests(to: "/api/auth/check").count == 1)
    }
}
