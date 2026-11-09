import AppKit
import SwiftUI
import Testing
@testable import Overlook

/// A closed window's session is let go: the session itself and what it owns, panels included, are
/// released once its window has closed, and neither the registry, the menu bar's menu, the audio
/// routing nor a hosted view that published the session's focused objects keeps any of it alive.
@MainActor
@Suite("Session lifetime")
struct SessionLifetimeTests {
    let scratch = ScratchDefaults()
    let catalog: KVMDeviceManager
    let registry: SessionRegistry
    let preferences: AudioPreferences
    let menu: StatusMenuState
    let router: SessionAudioRouter

    init() {
        let catalog = KVMDeviceManager(
            defaults: scratch.defaults,
            credentials: FakeCredentialStore(),
            trustStore: Fixtures.trustStore(scratch)
        )
        self.catalog = catalog
        let scratch = self.scratch
        let preferences = AudioPreferences(defaults: scratch.defaults)
        self.preferences = preferences
        let registry = SessionRegistry(catalog: catalog) { catalog in
            ConsoleSession(
                catalog: catalog,
                defaults: scratch.defaults,
                link: RecordingSessionLink(catalog: catalog),
                audioPreferences: preferences,
                connectionLog: .inMemory()
            )
        }
        self.registry = registry
        menu = StatusMenuState(registry: registry)
        router = SessionAudioRouter(registry: registry, preferences: preferences)
    }

    /// Weak references to a session and the objects it owns.
    @MainActor
    struct Watched {
        weak var session: ConsoleSession?
        weak var panels: PanelPresentation?
        weak var connection: SessionConnection?
        weak var webRTCManager: WebRTCManager?
        weak var inputManager: InputManager?
        weak var captureManager: CaptureManager?
        weak var ocrManager: OCRManager?

        init(_ session: ConsoleSession) {
            self.session = session
            panels = session.panels
            connection = session.connection
            webRTCManager = session.webRTCManager
            inputManager = session.inputManager
            captureManager = session.captureManager
            ocrManager = session.ocrManager
        }

        var released: Bool {
            session == nil && panels == nil && connection == nil && webRTCManager == nil
                && inputManager == nil && captureManager == nil && ocrManager == nil
        }

        var stillAlive: [String] {
            [
                session == nil ? nil : "session",
                panels == nil ? nil : "panels",
                connection == nil ? nil : "connection",
                webRTCManager == nil ? nil : "webRTCManager",
                inputManager == nil ? nil : "inputManager",
                captureManager == nil ? nil : "captureManager",
                ocrManager == nil ? nil : "ocrManager",
            ].compactMap { $0 }
        }
    }

    /// Gives pending main-actor work and autorelease pools a chance to let go, for up to a second.
    private func waitForRelease(_ watched: Watched) async {
        for _ in 0..<100 where !watched.released {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Opens a window's session, connects it, makes it active, then closes the window the way its
    /// attachment does. Only weak references survive this call.
    private func openUseAndClose(host: String) async -> Watched {
        let session = registry.sessionForNewWindow()
        registry.add(session)
        registry.sessionDidBecomeKey(session)
        _ = await session.connect(to: Fixtures.device(nickname: "Rack \(host)", host: host))
        #expect(session.panels.isSessionActive)
        #expect(menu.model.connected.contains { $0.deviceName == "Rack \(host)" })
        let watched = Watched(session)

        session.windowWillClose()
        registry.remove(session)
        return watched
    }

    // MARK: - The device client and its URLSession

    /// Weak references to a device client, the URLSession it signs in with, and that session's
    /// certificate-pinning delegate. The session keeps itself and its delegate alive until it is
    /// invalidated, so the delegate going away is what shows the session was invalidated.
    @MainActor
    struct WatchedClient {
        weak var client: GLKVMClient?
        weak var holder: GLKVMURLSession?
        weak var urlSession: URLSession?
        weak var delegate: URLSessionDelegate?
        // The long-timeout session paste requests use, and its delegate.
        weak var printHolder: GLKVMURLSession?
        weak var printSession: URLSession?
        weak var printDelegate: URLSessionDelegate?

        init(_ client: GLKVMClient) {
            self.client = client
            autoreleasepool {
                holder = client.urlSession
                urlSession = client.urlSession.session
                delegate = client.urlSession.session.delegate
                printHolder = client.printURLSession
                printSession = client.printURLSession.session
                printDelegate = client.printURLSession.session.delegate
            }
        }

        var stillAlive: [String] {
            [
                client == nil ? nil : "client",
                holder == nil ? nil : "holder",
                urlSession == nil ? nil : "urlSession",
                delegate == nil ? nil : "delegate",
                printHolder == nil ? nil : "printHolder",
                printSession == nil ? nil : "printSession",
                printDelegate == nil ? nil : "printDelegate",
            ].compactMap { $0 }
        }
    }

    /// Invalidation lets go of the delegate on the session's own queue; waits up to two seconds.
    private func waitForRelease(_ watched: WatchedClient) async {
        for _ in 0..<200 where !watched.stillAlive.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// A connected window's session, made active, with its client watched.
    private func connectedSession(host: String) async throws -> (ConsoleSession, WatchedClient) {
        let session = registry.sessionForNewWindow()
        registry.add(session)
        registry.sessionDidBecomeKey(session)
        _ = await session.connect(to: Fixtures.device(nickname: "Rack \(host)", host: host))
        let client = try #require(session.connection.glkvmClient)
        let watched = WatchedClient(client)
        #expect(watched.delegate != nil)
        #expect(watched.printDelegate != nil)
        return (session, watched)
    }

    @Test func aDisconnectedSessionsClientAndItsDelegateAreReleased() async throws {
        let (session, watched) = try await connectedSession(host: "192.0.2.34")

        session.disconnect()
        await waitForRelease(watched)

        #expect(watched.stillAlive == [])
        // The window is still open: the client went with the disconnect, not with the session.
        #expect(registry.sessions.contains { $0 === session })
    }

    @Test func aClosedWindowsClientAndItsDelegateAreReleased() async throws {
        var watched: WatchedClient?
        do {
            let (session, client) = try await connectedSession(host: "192.0.2.35")
            watched = client
            session.windowWillClose()
            registry.remove(session)
        }
        guard let watched else { return }
        await waitForRelease(watched)
        #expect(watched.stillAlive == [])
    }

    @Test func aClientIsReleasedWhenTheWindowClosesAfterQuitting() async throws {
        let (session, watched) = try await connectedSession(host: "192.0.2.36")

        await registry.shutDownAll()
        session.windowWillClose()
        await waitForRelease(watched)

        #expect(watched.stillAlive == [])
    }

    @Test func aSocketKeepsItsClientsSessionUntilItIsGone() async throws {
        var client: GLKVMClient? = try GLKVMClient(host: "192.0.2.37")
        // Never connected, so nothing goes out on the network.
        var socket: GLKVMClient.WebSocketClient? = try client?.makeWebSocketClient()
        let watched = WatchedClient(try #require(client))

        // The client is done, but the HID socket made from it may still be releasing keys.
        client = nil
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(watched.client == nil)
        #expect(watched.holder != nil)
        #expect(watched.delegate != nil)
        // No socket uses the paste session, so it goes with the client.
        for _ in 0..<200 where watched.printDelegate != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(watched.printHolder == nil)
        #expect(watched.printDelegate == nil)

        _ = socket
        socket = nil
        await waitForRelease(watched)
        #expect(watched.stillAlive == [])
    }

    @Test func aClosedWindowsSessionAndItsPanelsAreReleased() async {
        let watched = await openUseAndClose(host: "192.0.2.31")
        await waitForRelease(watched)
        #expect(watched.stillAlive == [])
        #expect(registry.sessions.isEmpty)
        #expect(registry.activeSession == nil)
        #expect(menu.model.connected.isEmpty)
    }

    @Test func anotherWindowStayingOpenDoesNotKeepTheClosedOneAlive() async {
        let other = registry.sessionForNewWindow()
        registry.add(other)
        _ = await other.connect(to: Fixtures.device(nickname: "Rack other", host: "192.0.2.32"))

        let watched = await openUseAndClose(host: "192.0.2.33")
        await waitForRelease(watched)
        #expect(watched.stillAlive == [])
        #expect(registry.activeSession === other)
        #expect(menu.model.connected.map(\.deviceName) == ["Rack other"])
        #expect(other.webRTCManager.audioRoute.playsAudio)
    }

    @Test func aHostedViewThatPublishedTheSessionLetsItGo() async {
        var watched: Watched?
        do {
            let session = registry.sessionForNewWindow()
            registry.add(session)
            watched = Watched(session)

            // The window's environment objects and the focused objects the menus read.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: Color.clear.consoleSession(session))
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            session.windowWillClose()
            registry.remove(session)
            window.contentView = nil
            window.close()
        }
        guard let watched else { return }
        await waitForRelease(watched)
        #expect(watched.stillAlive == [])
    }
}
