import Foundation
import Testing
@testable import Overlook

/// The registry of console sessions: which are listed, which is active, the one-window-per-device
/// rule, where a menu-bar connect goes, and quitting. Windows are stood in for by calling what
/// their attachment calls (`add`, `sessionDidBecomeKey`, `remove`); every session's outside steps
/// are recorded, not run.
@MainActor
@Suite("Session registry")
struct SessionRegistryTests {
    let scratch = ScratchDefaults()
    let catalog: KVMDeviceManager
    let registry: SessionRegistry
    /// Each session's recording link, in the order the sessions were made.
    private let links = LinkBox()

    final class LinkBox {
        var all: [RecordingSessionLink] = []
    }

    init() {
        let catalog = KVMDeviceManager(
            defaults: scratch.defaults,
            credentials: FakeCredentialStore(),
            trustStore: Fixtures.trustStore(scratch)
        )
        self.catalog = catalog
        let scratch = self.scratch
        let links = self.links
        registry = SessionRegistry(catalog: catalog) { catalog in
            let link = RecordingSessionLink(catalog: catalog)
            links.all.append(link)
            return ConsoleSession(catalog: catalog, defaults: scratch.defaults, link: link)
        }
    }

    /// A session whose window has appeared.
    private func openWindow() -> ConsoleSession {
        let session = registry.sessionForNewWindow()
        registry.add(session)
        return session
    }

    // MARK: - Listing

    @Test func aWindowsSessionIsListedUntilTheWindowCloses() {
        let a = openWindow()
        let b = openWindow()
        #expect(registry.sessions.map { ObjectIdentifier($0) } == [ObjectIdentifier(a), ObjectIdentifier(b)])
        #expect(a.registry === registry)

        registry.remove(a)
        #expect(registry.sessions.map { ObjectIdentifier($0) } == [ObjectIdentifier(b)])

        // Adding twice lists once.
        registry.add(b)
        #expect(registry.sessions.count == 1)
    }

    @Test func theFirstWindowIsActiveBeforeAnyWindowIsReportedKey() {
        let a = openWindow()
        _ = openWindow()
        #expect(registry.activeSession === a)
    }

    // MARK: - The active session

    @Test func theKeyWindowsSessionIsActive() {
        let a = openWindow()
        let b = openWindow()

        registry.sessionDidBecomeKey(b)
        #expect(registry.activeSession === b)

        registry.sessionDidBecomeKey(a)
        #expect(registry.activeSession === a)
    }

    @Test func theLastKeySessionStaysActiveWhileTheAppIsInactive() {
        let a = openWindow()
        let b = openWindow()
        registry.sessionDidBecomeKey(a)
        registry.sessionDidBecomeKey(b)

        // Overlook goes to the background: windows stop being key, which the registry is not told
        // about, and no window becomes key. A new window appearing in the background does not
        // take over either.
        _ = openWindow()

        #expect(registry.activeSession === b)
    }

    @Test func closingTheActiveWindowHandsOverToTheOneUsedBeforeIt() {
        let a = openWindow()
        let b = openWindow()
        let c = openWindow()
        registry.sessionDidBecomeKey(a)
        registry.sessionDidBecomeKey(c)
        registry.sessionDidBecomeKey(b)

        registry.remove(b)
        #expect(registry.activeSession === c)
        registry.remove(c)
        #expect(registry.activeSession === a)
        registry.remove(a)
        #expect(registry.activeSession == nil)
    }

    @Test func closingAnotherWindowLeavesTheActiveOneAlone() {
        let a = openWindow()
        let b = openWindow()
        registry.sessionDidBecomeKey(b)

        registry.remove(a)

        #expect(registry.activeSession === b)
    }

    @Test func aSessionNotListedCannotBecomeActive() {
        let a = openWindow()
        let stray = ConsoleSession(catalog: catalog, defaults: scratch.defaults, link: RecordingSessionLink())

        registry.sessionDidBecomeKey(stray)

        #expect(registry.activeSession === a)
    }

    // MARK: - Opening windows

    @Test func aWindowAskedForGetsTheSessionMadeForIt() {
        var opened = 0
        #expect(registry.openWindow() == nil)

        registry.openWindowAction = { opened += 1 }
        let asked = registry.openWindow()

        #expect(opened == 1)
        #expect(asked != nil)
        // Listed for quitting before its window appears, but not as a window yet.
        #expect(registry.allSessions.contains { $0 === asked })
        #expect(registry.sessions.isEmpty)

        let appearing = registry.sessionForNewWindow()
        #expect(appearing === asked)
        registry.add(appearing)
        #expect(registry.sessions.count == 1)
        #expect(registry.allSessions.count == 1)

        // File › New Window, with nothing asked for: a session of its own.
        #expect(registry.sessionForNewWindow() !== asked)
    }

    // MARK: - One window per device

    @Test func connectingToADeviceOpenInAnotherWindowLeavesThisOneDisconnected() async {
        let a = openWindow()
        let b = openWindow()
        let manual = catalog.addManualDevice(host: "192.0.2.60", port: 443, type: .glinetComet)
        _ = await a.connect(to: manual)
        let linkB = links.all[1]

        // The entry b picked before a connected has the old id; the address still matches.
        let outcome = await b.connect(to: manual)

        guard case .openElsewhere(let other) = outcome else {
            Issue.record("Expected the device to be open elsewhere, got \(outcome)")
            return
        }
        #expect(other === a)
        #expect(linkB.steps.isEmpty)
        #expect(b.connection.connectedDevice == nil)
        #expect(b.isIdle)
    }

    @Test func aDeviceStillSigningInCountsAsOpen() async {
        let a = openWindow()
        let b = openWindow()
        let device = Fixtures.device(host: "192.0.2.61")
        var outcomeInB: ConsoleSession.ConnectOutcome?
        links.all[0].duringSignIn = { _ in
            outcomeInB = await b.connect(to: device)
        }

        _ = await a.connect(to: device)

        guard case .openElsewhere(let other)? = outcomeInB else {
            Issue.record("Expected the device to be open elsewhere, got \(String(describing: outcomeInB))")
            return
        }
        #expect(other === a)
        #expect(links.all[1].steps.isEmpty)
    }

    @Test func anotherPortOnTheSameHostIsAnotherDevice() async {
        let a = openWindow()
        let b = openWindow()
        _ = await a.connect(to: Fixtures.device(host: "192.0.2.62", port: 443))

        let outcome = await b.connect(to: Fixtures.device(host: "192.0.2.62", port: 8443))

        guard case .connected = outcome else {
            Issue.record("Expected a connection, got \(outcome)")
            return
        }
    }

    @Test func aWindowThatHasNotAppearedYetCountsToo() async {
        let a = openWindow()
        registry.openWindowAction = {}
        let pending = registry.openWindow()!
        _ = await pending.connect(to: Fixtures.device(host: "192.0.2.63"))

        let outcome = await a.connect(to: Fixtures.device(host: "192.0.2.63"))

        guard case .openElsewhere(let other) = outcome else {
            Issue.record("Expected the device to be open elsewhere, got \(outcome)")
            return
        }
        #expect(other === pending)
    }

    @Test func anotherWindowsSelectionFollowsTheDeviceThroughItsSave() async {
        let a = openWindow()
        let manual = catalog.addManualDevice(host: "192.0.2.64", port: 443, type: .glinetComet)
        // Window b has it selected, by address.
        let selectionInB = manual.address

        _ = await a.connect(to: manual)

        #expect(catalog.device(at: selectionInB)?.id == "saved-192.0.2.64-443")
    }

    // MARK: - Where a menu-bar connect goes

    @Test func aMenuBarConnectBringsAnOpenDevicesWindowForward() async {
        let a = openWindow()
        let b = openWindow()
        registry.sessionDidBecomeKey(b)
        _ = await a.connect(to: Fixtures.device(host: "192.0.2.65"))

        guard case .bringForward(let open) = registry.connectTarget(for: DeviceAddress(host: "192.0.2.65", port: 443)) else {
            Issue.record("Expected the open window to come forward")
            return
        }
        #expect(open === a)
    }

    @Test func aMenuBarConnectUsesTheActiveSessionWhenItIsFree() {
        _ = openWindow()
        let b = openWindow()
        registry.sessionDidBecomeKey(b)

        guard case .connect(let session) = registry.connectTarget(for: DeviceAddress(host: "192.0.2.66", port: 443)) else {
            Issue.record("Expected the active session")
            return
        }
        #expect(session === b)
    }

    @Test func aMenuBarConnectOpensAWindowWhenTheActiveSessionIsBusy() async {
        let a = openWindow()
        _ = openWindow()
        registry.sessionDidBecomeKey(a)
        _ = await a.connect(to: Fixtures.device(host: "192.0.2.67"))

        guard case .newWindow = registry.connectTarget(for: DeviceAddress(host: "192.0.2.68", port: 443)) else {
            Issue.record("Expected a new window")
            return
        }
    }

    @Test func aMenuBarConnectOpensAWindowWhenNoneIsOpen() {
        guard case .newWindow = registry.connectTarget(for: DeviceAddress(host: "192.0.2.69", port: 443)) else {
            Issue.record("Expected a new window")
            return
        }
    }

    @Test func theMenuBarsShortcutsReachOnlyTheActiveSession() {
        let a = openWindow()
        let b = openWindow()
        registry.sessionDidBecomeKey(b)

        // What the agent's Save Screenshot item does.
        registry.activeSession?.perform(.saveScreenshot)

        #expect(b.captureManager.notice?.title == "No video to capture")
        #expect(a.captureManager.notice == nil)
    }

    // MARK: - Quitting

    @Test func quittingShutsDownEverySessionIncludingOnesStillOpening() async {
        let a = openWindow()
        let b = openWindow()
        registry.openWindowAction = {}
        _ = registry.openWindow()
        _ = await a.connect(to: Fixtures.device(host: "192.0.2.70"))
        registry.remove(b)

        await registry.shutDownAll()

        // a and the window still opening; b's window had closed, so it is no longer the app's.
        #expect(links.all[0].steps.last == .shutDown)
        #expect(links.all[1].steps.contains(.shutDown) == false)
        #expect(links.all[2].steps == [.shutDown])
    }
}
