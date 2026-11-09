import AppKit
import Foundation
import Testing
@testable import Overlook

/// Where a device is named: the Connections panel's menu, the window title, the question asked
/// before closing a recording window. Everywhere it is the nickname, or the address without one.
@MainActor
@Suite("Display names")
struct DisplayNameTests {
    static let lan = DeviceAddress(host: "192.168.0.131", port: 443)
    static let tailnet = DeviceAddress(host: "mdesktopkvm.tail1234.ts.net", port: 443)

    // MARK: - The Connections panel's device menu

    @Test func aNicknamedDeviceShowsItsAddressAfterTheName() {
        let title = DeviceMenuTitle(Fixtures.device(nickname: "Desk", host: "192.168.0.131"))
        #expect(title == DeviceMenuTitle(name: "Desk", address: "192.168.0.131"))
    }

    @Test func aDeviceWithoutANicknameShowsItsAddressAlone() {
        #expect(DeviceMenuTitle(Fixtures.device(nickname: nil, host: "192.168.0.131")) == DeviceMenuTitle(name: "192.168.0.131", address: nil))
        #expect(DeviceMenuTitle(Fixtures.device(nickname: nil, host: "kvm.example", port: 8443)) == DeviceMenuTitle(name: "kvm.example:8443", address: nil))
    }

    @Test func noGeneratedPrefixIsShown() {
        let manual = KVMDeviceManager.mergeListed([
            Fixtures.device(id: "manual-1", nickname: nil, host: "192.0.2.5"),
            Fixtures.device(id: "scanned-192.0.2.6-443", nickname: nil, host: "192.0.2.6"),
        ])
        let names = manual.map { DeviceMenuTitle($0).name }
        #expect(names == ["192.0.2.5", "192.0.2.6"])
        #expect(names.allSatisfy { !$0.contains("@") })
    }

    @Test func theAddressShownIsTheOnePlainConnectUses() {
        var device = Fixtures.device(id: "saved-x", nickname: "Desk", host: Self.lan.host, addresses: [Self.lan, Self.tailnet])
        device.lastUsedAddress = Self.tailnet
        device = device.via(device.preferredAddress)
        #expect(DeviceMenuTitle(device).address == "mdesktopkvm")
    }

    @Test func theAddressIsATabAwayInASecondaryMonospacedFont() throws {
        let title = DeviceMenuTitle(name: "Desk", address: "192.168.0.131")
        let column = DeviceMenuTitle.column(for: [title])

        let text = title.attributed(column: column)

        #expect(text.string == "Desk\t192.168.0.131")
        let addressStart = (text.string as NSString).range(of: "192").location
        let font = try #require(text.attribute(.font, at: addressStart, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
        #expect(text.attribute(.foregroundColor, at: addressStart, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
        let paragraph = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.tabStops.map(\.alignment) == [.right])
        #expect(paragraph.tabStops.first?.location == column)
        #expect(DeviceMenuTitle(name: "192.168.0.131", address: nil).attributed(column: column).string == "192.168.0.131")
    }

    @Test func theAddressColumnClearsTheLongestName() {
        let short = DeviceMenuTitle.column(for: [DeviceMenuTitle(name: "A", address: "10.0.0.1")])
        let long = DeviceMenuTitle.column(for: [
            DeviceMenuTitle(name: "A", address: "10.0.0.1"),
            DeviceMenuTitle(name: "A much longer nickname for a KVM", address: "10.0.0.1"),
        ])
        #expect(short > 0)
        #expect(long > short)
    }

    @Test func choosingARowSelectsThatDevice() {
        let devices = [Fixtures.device(id: "a", host: "192.0.2.1"), Fixtures.device(id: "b", host: "192.0.2.2")]
        var chosen: [String?] = []
        let coordinator = DevicePopUpButton.Coordinator { chosen.append($0?.id) }
        coordinator.devices = devices
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: [DevicePopUpButton.placeholder, "a", "b"])

        button.selectItem(at: 2)
        coordinator.chose(button)
        button.selectItem(at: 0)
        coordinator.chose(button)

        #expect(chosen == ["b", nil])
    }

    // MARK: - Window title and the recording question

    @Test func theWindowTitleUsesTheNicknameOrTheAddress() {
        let named = Fixtures.device(nickname: "Desk", host: "192.168.0.131")
        let unnamed = Fixtures.device(nickname: nil, host: "192.168.0.131")
        #expect(ContentView.windowTitlePrefix(device: named, isConnected: true) == "Overlook - Desk / Connected")
        #expect(ContentView.windowTitlePrefix(device: unnamed, isConnected: true) == "Overlook - 192.168.0.131 / Connected")
        #expect(ContentView.windowTitlePrefix(device: named.via(Self.tailnet), isConnected: true) == "Overlook - Desk / Connected")
    }

    @Test func theRecordingQuestionNamesTheDeviceTheSameWay() {
        let named = ConsoleSession.closeDecision(device: Fixtures.device(nickname: "Desk"), isConnecting: false, isRecording: true)
        let unnamed = ConsoleSession.closeDecision(device: Fixtures.device(nickname: nil, host: "192.168.0.131"), isConnecting: false, isRecording: true)
        #expect(named == .confirmStopRecording(deviceName: "Desk"))
        #expect(unnamed == .confirmStopRecording(deviceName: "192.168.0.131"))
        #expect(StopRecordingQuestion.messageText(deviceName: "Desk") == "Desk is recording")
        #expect(StopRecordingQuestion.informativeText(deviceName: "192.168.0.131").contains("disconnects from 192.168.0.131."))
    }

    // MARK: - Capture file names

    @Test(arguments: [
        ("Desk", "Desk"),
        (" Rack/3: Lab ", "Rack-3- Lab"),
        ("a\\b*c?d\"e<f>g|h", "a-b-c-d-e-f-g-h"),
        ("line\nbreak\ttab", "line-break-tab"),
        ("..hidden", "hidden"),
        ("[fd00::5]:8443", "[fd00--5]-8443"),
        ("Café KVM ☕", "Café KVM ☕"),
        ("   ", ""),
    ])
    func deviceNamesAreMadeSafeForFileNames(name: String, expected: String) {
        #expect(CaptureManager.fileNameComponent(name) == expected)
    }

    @Test func longNamesAreShortened() {
        let name = String(repeating: "x", count: 200)
        #expect(CaptureManager.fileNameComponent(name).count == 80)
    }
}
