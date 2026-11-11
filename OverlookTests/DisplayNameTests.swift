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

    /// A bare MagicDNS name and the full `.ts.net` name are different addresses, and can be
    /// different devices; every place that names a device by its address keeps them apart.
    @Test func aBareAndAFullTailscaleNameAreShownApart() {
        let bare = DeviceAddress(host: "mdesktopkvm", port: 443)
        let full = DeviceAddress(host: "mdesktopkvm.tail1234.ts.net", port: 443)

        #expect(bare.label == "mdesktopkvm")
        #expect(full.label == "mdesktopkvm.tail1234.ts.net")
        #expect(bare.label != full.label)
        #expect(bare.labelWithTag != full.labelWithTag)

        // The device pop-up, for devices saved without a nickname.
        let bareDevice = Fixtures.device(id: "saved-bare", nickname: nil, host: bare.host)
        let fullDevice = Fixtures.device(id: "saved-full", nickname: nil, host: full.host)
        #expect(DeviceMenuTitle(bareDevice).name == "mdesktopkvm")
        #expect(DeviceMenuTitle(fullDevice).name == "mdesktopkvm.tail1234.ts.net")
        // And after a nickname, as the address.
        #expect(DeviceMenuTitle(Fixtures.device(nickname: "Desk", host: full.host)).address == "mdesktopkvm.tail1234.ts.net")

        // The Connect menu of a device that has both.
        let both = Fixtures.device(id: "saved-x", nickname: "Desk", host: bare.host, addresses: [bare, full])
        let titles = ConnectVia.items(for: both).map(\.title)
        #expect(titles.count == 2)
        #expect(Set(titles).count == 2)
        #expect(titles.contains { $0.hasPrefix("mdesktopkvm.tail1234.ts.net") })

        // The status line and the log's device tag.
        #expect(ConnectVia.statusText(connectedThrough: bare) != ConnectVia.statusText(connectedThrough: full))
        #expect(SessionLog.label(host: bare.host, port: bare.port) != SessionLog.label(host: full.host, port: full.port))
    }

    @Test func aFullTailscaleNameStaysWholeInAFileName() {
        #expect(CaptureManager.fileNameComponent("mdesktopkvm.tail1234.ts.net") == "mdesktopkvm.tail1234.ts.net")
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
        #expect(DeviceMenuTitle(device).address == "mdesktopkvm.tail1234.ts.net")
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

    @Test func theAddressesSitAgainstTheRightEdgeOfAWideButton() throws {
        let button = DevicePopUpButton.DevicePopUpNSButton(frame: NSRect(x: 0, y: 0, width: 340, height: 22), pullsDown: false)
        button.addItems(withTitles: [DevicePopUpButton.placeholder, "Desk", "x"])
        button.titles = [DeviceMenuTitle(name: "Desk", address: "192.168.0.131"), DeviceMenuTitle(name: "192.0.2.1", address: nil)]

        let paragraph = try #require(button.item(at: 1)?.attributedTitle?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.tabStops.first?.location == 340 - DevicePopUpButton.DevicePopUpNSButton.trailingInset)
        #expect(button.item(at: 2)?.attributedTitle?.string == "192.0.2.1")

        button.setFrameSize(NSSize(width: 400, height: 22))
        let wider = try #require(button.item(at: 1)?.attributedTitle?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(wider.tabStops.first?.location == 400 - DevicePopUpButton.DevicePopUpNSButton.trailingInset)
    }

    @Test func theClosedPopUpPutsTheAddressAgainstTheRightEdge() {
        let frame = NSRect(x: 8, y: 2, width: 300, height: 16)
        let layout = DeviceMenuTitle.closedLayout(in: frame, addressWidth: 80.4)
        #expect(layout.address.maxX == frame.maxX)
        #expect(layout.address.width == 81)
        #expect(layout.name.minX == frame.minX)
        #expect(layout.name.maxX == layout.address.minX - 12)
        #expect(layout.name.minY == frame.minY && layout.address.height == frame.height)

        // A frame too narrow for both: the address keeps the right edge, the name gets nothing.
        let narrow = DeviceMenuTitle.closedLayout(in: NSRect(x: 0, y: 0, width: 60, height: 16), addressWidth: 80)
        #expect(narrow.address.maxX == 60)
        #expect(narrow.name.width == 0)
    }

    @Test func theClosedTitleRunsFromTheMeasuredTitleToTheArrows() {
        // What the cell hands over: a rect only as wide as the title it measured.
        let measured = NSRect(x: 12, y: 3, width: 172.5, height: 16)
        let bounds = NSRect(x: 0, y: 0, width: 340, height: 22)
        let area = DevicePopUpCell.titleArea(from: measured, bounds: bounds)
        #expect(area.minX == 12)
        #expect(area.maxX == 340 - DevicePopUpCell.arrowsWidth)
        #expect(area.minY == 3 && area.height == 16)
        // Never narrower than what was measured.
        #expect(DevicePopUpCell.titleArea(from: measured, bounds: NSRect(x: 0, y: 0, width: 150, height: 22)).maxX == measured.maxX)
    }

    @Test func theDevicePopUpDrawsWithItsOwnCell() throws {
        let button = DevicePopUpButton.DevicePopUpNSButton(frame: NSRect(x: 0, y: 0, width: 340, height: 22), pullsDown: false)
        button.addItems(withTitles: [DevicePopUpButton.placeholder, "Desk"])
        let titles = [DeviceMenuTitle(name: "Desk", address: "192.168.0.131")]
        button.titles = titles
        let cell = try #require(button.cell as? DevicePopUpCell)
        #expect(cell.titles == titles)
        // The cell's menu is the button's: rows added to it are the ones the cell selects.
        button.selectItem(at: 1)
        #expect(cell.indexOfSelectedItem == 1)
    }

    // MARK: - Window title and the recording question

    @Test func theWindowTitleUsesTheNicknameOrTheAddress() {
        let named = Fixtures.device(nickname: "Desk", host: "192.168.0.131")
        let unnamed = Fixtures.device(nickname: nil, host: "192.168.0.131")
        #expect(ContentView.windowTitlePrefix(connectedDevice: named, selectedDevice: nil, isConnected: true) == "Overlook - Desk / Connected")
        #expect(ContentView.windowTitlePrefix(connectedDevice: unnamed, selectedDevice: nil, isConnected: true) == "Overlook - 192.168.0.131 / Connected")
        #expect(ContentView.windowTitlePrefix(connectedDevice: named.via(Self.tailnet), selectedDevice: nil, isConnected: true) == "Overlook - Desk / Connected")
        #expect(ContentView.windowTitlePrefix(connectedDevice: nil, selectedDevice: named, isConnected: false) == "Overlook - Desk / Disconnected")
        #expect(ContentView.windowTitlePrefix(connectedDevice: nil, selectedDevice: unnamed, isConnected: false) == "Overlook - 192.168.0.131 / Disconnected")
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
