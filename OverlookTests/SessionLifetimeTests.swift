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
        _ = await session.connect(to: Fixtures.device(name: "Rack \(host)", host: host))
        #expect(session.panels.isSessionActive)
        #expect(menu.model.connected.contains { $0.deviceName == "Rack \(host)" })
        let watched = Watched(session)

        session.windowWillClose()
        registry.remove(session)
        return watched
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
        _ = await other.connect(to: Fixtures.device(name: "Rack other", host: "192.0.2.32"))

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
