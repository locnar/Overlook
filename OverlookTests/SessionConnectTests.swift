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
        ConsoleSession(catalog: catalog, defaults: scratch.defaults, link: link)
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
