import AppKit
import Foundation
import Testing
@testable import Overlook

/// Settings › General › "Wake the target's display when connecting": one Shift tap through the
/// HID socket each time it comes up, on HID sockets answered in the test. Nothing here reaches a
/// device.
@MainActor
@Suite("Waking the target's display")
struct WakeDisplayTests {
    let scratch = ScratchDefaults()
    let sockets = FakeHIDSockets()
    let preferences: ConnectionPreferences
    let log = SessionLog(destination: .inMemory())
    let input: InputManager
    /// The device's config, with Keyboard Control on unless a test turns it off.
    let config = FakeUserConfig(["keyboard_control": .bool(true)])
    let device: StubDevice

    init() {
        preferences = ConnectionPreferences(defaults: scratch.defaults)
        device = StubDevice(config: config)
        input = InputManager(defaults: scratch.defaults, connectionPreferences: preferences, log: log)
    }

    private func connect() throws {
        let client = try device.makeClient()
        client.hidSocketTiming = .testing()
        let sockets = self.sockets
        client.makeHIDSocket = { _ in sockets.make() }
        input.setGLKVMClient(client)
    }

    /// Waits for socket `index` to be made and for the keyboard resync that follows its greeting.
    private func openedSocket(_ index: Int) async throws -> FakeHIDSocket {
        #expect(await waitUntil(timeout: .seconds(5)) {
            sockets.count > index && sockets.all[index].frames.contains(where: \.clearsKeyboard)
        })
        return try #require(sockets.all.count > index ? sockets.all[index] : nil)
    }

    private func shiftFrames(on socket: FakeHIDSocket) -> [String] {
        socket.keyFrames.compactMap(\.keyText).filter { $0.hasPrefix("Shift") }
    }

    private func wakesLogged() -> Int {
        log.store.events(in: .allDevices).filter { $0.message == "Woke the target's display (sent Shift)" }.count
    }

    // MARK: - The setting

    @Test func theSettingIsOffByDefault() {
        #expect(ConnectionPreferences.Keys.wakeDisplayOnConnect == "overlook.connection.wakeDisplayOnConnect")
        #expect(ConnectionPreferences(defaults: scratch.defaults).wakeDisplayOnConnect == false)
        // The app's own object, on the test host's throwaway defaults.
        #expect(ConnectionPreferences.shared.defaults === AppEnvironment.defaults)
        #expect(ConnectionPreferences.shared.wakeDisplayOnConnect == false)
        #expect(AppEnvironment.defaults.object(forKey: "overlook.connection.wakeDisplayOnConnect") == nil)
    }

    @Test func theSettingIsStoredUnderItsKey() {
        preferences.wakeDisplayOnConnect = true
        #expect(scratch.defaults.bool(forKey: "overlook.connection.wakeDisplayOnConnect"))
        #expect(ConnectionPreferences(defaults: scratch.defaults).wakeDisplayOnConnect)
    }

    @Test func everySessionGetsTheSettingItWasHanded() {
        let catalog = Fixtures.catalog(scratch)
        let session = ConsoleSession(
            catalog: catalog,
            defaults: scratch.defaults,
            link: RecordingSessionLink(),
            audioPreferences: AudioPreferences(defaults: scratch.defaults),
            connectionPreferences: preferences,
            connectionLog: .inMemory()
        )
        #expect(session.inputManager.connectionPreferences === preferences)
    }

    // MARK: - Connecting

    @Test func offSendsNothing() async throws {
        try connect()
        let socket = try await openedSocket(0)
        try await Task.sleep(for: .milliseconds(400))

        #expect(shiftFrames(on: socket).isEmpty)
        #expect(socket.keyFrames.isEmpty)
        #expect(wakesLogged() == 0)
        await input.shutdown()
    }

    @Test func onSendsOneShiftTapAfterTheSocketComesUp() async throws {
        preferences.wakeDisplayOnConnect = true
        try connect()
        let socket = try await openedSocket(0)

        #expect(await waitUntil { shiftFrames(on: socket).count == 2 })
        #expect(shiftFrames(on: socket) == ["ShiftLeft down", "ShiftLeft up"])
        // After the keyboard resync, in the HID queue's order.
        let frames = socket.frames
        let clearIndex = frames.firstIndex(where: \.clearsKeyboard)
        let downIndex = frames.firstIndex(where: { $0.keyText == "ShiftLeft down" })
        let clear = try #require(clearIndex)
        let down = try #require(downIndex)
        #expect(clear < down)
        #expect(await waitUntil { wakesLogged() == 1 })

        // Once per connect: nothing more while the socket stays up.
        try await Task.sleep(for: .milliseconds(400))
        #expect(shiftFrames(on: socket).count == 2)
        #expect(wakesLogged() == 1)
        await input.shutdown()
    }

    @Test func anAutomaticReconnectSendsOneMoreTap() async throws {
        preferences.wakeDisplayOnConnect = true
        try connect()
        let first = try await openedSocket(0)
        #expect(await waitUntil { shiftFrames(on: first).count == 2 })

        // The socket drops on its own; the HID link reconnects with a new one.
        first.abort()
        let second = try await openedSocket(1)

        #expect(await waitUntil { shiftFrames(on: second).count == 2 })
        #expect(shiftFrames(on: second) == ["ShiftLeft down", "ShiftLeft up"])
        #expect(shiftFrames(on: first).count == 2)
        #expect(await waitUntil { wakesLogged() == 2 })
        await input.shutdown()
    }

    @Test func aConnectThatEndsBeforeTheHIDLinkIsUpSendsNothing() async throws {
        preferences.wakeDisplayOnConnect = true
        sockets.greet = false
        try connect()
        #expect(await waitUntil { sockets.count == 1 })
        try await Task.sleep(for: .milliseconds(200))

        // The connect is abandoned (a disconnect, or the stream failing) before the device answered.
        input.setGLKVMClient(nil)
        try await Task.sleep(for: .milliseconds(400))

        for socket in sockets.all {
            #expect(shiftFrames(on: socket).isEmpty)
        }
        #expect(wakesLogged() == 0)
        await input.shutdown()
    }

    @Test func keyboardControlOffOnTheDeviceSendsNothing() async throws {
        preferences.wakeDisplayOnConnect = true
        config.stored = ["keyboard_control": .bool(false)]
        try connect()
        let socket = try await openedSocket(0)

        #expect(await waitUntil {
            log.store.events(in: .allDevices).contains { $0.message.contains("Keyboard Control is off") }
        })
        #expect(shiftFrames(on: socket).isEmpty)
        #expect(wakesLogged() == 0)
        await input.shutdown()
    }

    @Test func turningItOffBeforeTheSocketComesUpSendsNothing() async throws {
        preferences.wakeDisplayOnConnect = true
        preferences.wakeDisplayOnConnect = false
        try connect()
        let socket = try await openedSocket(0)
        try await Task.sleep(for: .milliseconds(400))
        #expect(shiftFrames(on: socket).isEmpty)
        await input.shutdown()
    }
}
