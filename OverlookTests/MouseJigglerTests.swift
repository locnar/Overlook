import Foundation
import Testing
@testable import Overlook

/// kvmd's HID state with a jiggler object, as `GET /api/hid` and `hid` events carry it.
func kvmdHIDState(jigglerActive: Bool, available: Bool = true) -> JSONValue {
    .object([
        "online": .bool(true),
        "connected": .bool(true),
        "mouse": .object(["absolute": .bool(true)]),
        "jiggler": .object([
            "enabled": .bool(available),
            "active": .bool(jigglerActive),
            "interval": .int(20),
            "schedule": .array([]),
        ]),
    ])
}

/// A device whose jiggler follows `hid/set_params?jiggler=`, as kvmd's does.
final class FakeJiggler: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    var isActive: Bool {
        get { lock.withLock { active } }
        set { lock.withLock { active = newValue } }
    }

    func handle(_ request: StubDevice.Request) -> StubDevice.Response? {
        switch request.path {
        case "/api/hid/set_params":
            if let value = request.query["jiggler"] {
                isActive = value == "true"
            }
            return .ok()
        case "/api/hid":
            return .ok(kvmdHIDState(jigglerActive: isActive))
        default:
            return nil
        }
    }
}

@Suite("Mouse jiggler state")
struct MouseJigglerStateTests {
    @Test func readsTheJigglerFromKvmdsHIDState() {
        let state = GLKVMJigglerState(hidState: kvmdHIDState(jigglerActive: true))
        #expect(state == GLKVMJigglerState(isAvailable: true, isActive: true, interval: 20))
        #expect(GLKVMJigglerState(hidState: kvmdHIDState(jigglerActive: false, available: false))?.isAvailable == false)
    }

    @Test func aStateWithoutAJigglerReadsAsNone() {
        #expect(GLKVMJigglerState(hidState: .object(["online": .bool(true)])) == nil)
        #expect(GLKVMJigglerState(hidState: nil) == nil)
    }

    @Test func switchingPostsHIDSetParams() async throws {
        let device = StubDevice()
        let client = try device.makeClient()

        try await client.setMouseJiggler(true)
        try await client.setMouseJiggler(false)

        let requests = device.requests
        #expect(requests.map(\.method) == ["POST", "POST"])
        #expect(requests.map(\.path) == ["/api/hid/set_params", "/api/hid/set_params"])
        #expect(requests.map(\.query) == [["jiggler": "true"], ["jiggler": "false"]])
    }
}

@MainActor
@Suite("Mouse jiggler toggle")
struct MouseJigglerToggleTests {
    let config = FakeUserConfig([
        "mouse_jiggle": .bool(false),
        "theme_mode": .string("0"),
        "language": .string("de"),
    ])
    let jiggler = FakeJiggler()
    let fixture: SettingsPanelFixture

    init() throws {
        let config = self.config
        let jiggler = self.jiggler
        let device = StubDevice { request in
            if let answer = jiggler.handle(request) { return answer }
            return try await config.handle(request)
        }
        fixture = try SettingsPanelFixture(device: device, config: config.stored)
    }

    private var input: InputManager { fixture.input }
    private var actions: WebUISettingsActions { fixture.actions }

    private func hidEvent(jigglerActive: Bool) -> GLKVMWebSocketEvent {
        GLKVMWebSocketEvent(eventType: "hid", event: kvmdHIDState(jigglerActive: jigglerActive))
    }

    @Test func theToggleShowsWhatTheDeviceReports() {
        #expect(input.deviceJiggler == nil)
        #expect(actions.mouseJigglerBinding.wrappedValue == false)

        input.handleDeviceEvent(hidEvent(jigglerActive: true))
        #expect(actions.mouseJigglerBinding.wrappedValue == true)

        // A partial event without the jiggler leaves it as it was.
        input.handleDeviceEvent(GLKVMWebSocketEvent(eventType: "hid", event: .object(["connected": .bool(true)])))
        #expect(actions.mouseJigglerBinding.wrappedValue == true)

        input.handleDeviceEvent(hidEvent(jigglerActive: false))
        #expect(actions.mouseJigglerBinding.wrappedValue == false)
    }

    @Test func anotherDeviceStartsUnknown() {
        input.transportMode = .webRTC
        input.handleDeviceEvent(hidEvent(jigglerActive: true))
        input.setGLKVMClient(nil)
        #expect(input.deviceJiggler == nil)
    }

    @Test func switchingOnDrivesTheDeviceAndShowsItsAnswer() async {
        actions.mouseJigglerBinding.wrappedValue = true

        #expect(await waitUntil { input.deviceJiggler?.isActive == true && !fixture.model.isApplyingJiggler })
        #expect(jiggler.isActive)
        let setParams = fixture.device.requests(to: "/api/hid/set_params")
        #expect(setParams.map(\.query) == [["jiggler": "true"]])
        #expect(actions.mouseJigglerBinding.wrappedValue == true)

        // The web UI's record of its switch follows, and nothing else in the config changes.
        #expect(await waitUntil { config.stored["mouse_jiggle"] == .bool(true) && !fixture.model.isApplying })
        #expect(config.stored["language"] == .string("de"))
        #expect(config.stored["theme_mode"] == .string("0"))
        #expect(fixture.model.errorHistory.isEmpty)
    }

    @Test func theToggleFollowsTheDeviceNotTheConfig() async {
        // The config says on; the device says off. The device wins.
        jiggler.isActive = false
        fixture.model.config?.mouseJiggle = true
        input.handleDeviceEvent(hidEvent(jigglerActive: false))
        #expect(actions.mouseJigglerBinding.wrappedValue == false)

        actions.mouseJigglerBinding.wrappedValue = true
        #expect(await waitUntil { input.deviceJiggler?.isActive == true })
        actions.mouseJigglerBinding.wrappedValue = false
        #expect(await waitUntil { input.deviceJiggler?.isActive == false && !fixture.model.isApplyingJiggler })
        #expect(!jiggler.isActive)
    }
}
