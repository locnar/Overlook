import Combine
import Foundation
import Testing
@testable import Overlook

/// The Edit… sheet: its model (the name, adding and removing addresses, which keys do what) and
/// what Save does to the catalog and to a session connected to the device.
@MainActor
@Suite("Edit device")
struct DeviceEditTests {
    let scratch = ScratchDefaults()
    let credentials = FakeCredentialStore()

    static let lan = DeviceAddress(host: "192.168.0.131", port: 443)
    static let tailnet = DeviceAddress(host: "mdesktopkvm", port: 443)

    private func makeCatalog() -> KVMDeviceManager {
        Fixtures.catalog(scratch, credentials: credentials)
    }

    // MARK: - The model

    @Test func startsFromTheDevicesNameAndAddresses() {
        let named = DeviceEditModel(device: Fixtures.device(nickname: "Desk", host: Self.lan.host, addresses: [Self.lan, Self.tailnet]))
        #expect(named.name == "Desk")
        #expect(named.addresses == [Self.lan, Self.tailnet])
        #expect(named.selection == nil)
        #expect(named.isAddingAddress == false)

        let unnamed = DeviceEditModel(device: Fixtures.device(nickname: nil, host: Self.lan.host))
        #expect(unnamed.name == "")
        #expect(unnamed.result.nickname == nil)
    }

    @Test func anEmptyNameSavesAsNoNickname() {
        let model = DeviceEditModel(device: Fixtures.device(nickname: "Desk"))
        model.name = "   "
        #expect(model.result.nickname == nil)
        model.name = "  Rack 3 "
        #expect(model.result.nickname == "Rack 3")
    }

    @Test func plusAddsATypedAddressAndSelectsIt() {
        let model = DeviceEditModel(device: Fixtures.device(host: Self.lan.host))
        model.beginAddingAddress()
        #expect(model.isAddingAddress)
        model.newHost = " mdesktopkvm "

        #expect(model.addAddress())

        #expect(model.addresses == [Self.lan, Self.tailnet])
        #expect(model.selection == Self.tailnet)
        #expect(model.isAddingAddress == false)
        #expect(model.newHost == "")
        #expect(model.problem == nil)
    }

    @Test func aTypedPortOrHostPortIsUsed() {
        let model = DeviceEditModel(device: Fixtures.device(host: Self.lan.host))
        model.beginAddingAddress()
        model.newHost = "kvm.example"
        model.newPort = "8443"
        model.addAddress()
        model.beginAddingAddress()
        model.newHost = "https://other.example:9443/"
        model.addAddress()

        #expect(model.addresses == [Self.lan, DeviceAddress(host: "kvm.example", port: 8443), DeviceAddress(host: "other.example", port: 9443)])
    }

    @Test func badAddressesAreRefusedWithTheReason() {
        let model = DeviceEditModel(device: Fixtures.device(host: Self.lan.host))
        model.beginAddingAddress()

        model.newHost = ""
        #expect(model.addAddress() == false)
        #expect(model.problem == AddressInput.Problem.emptyHost.message)

        model.newHost = "kvm.example"
        model.newPort = "70000"
        #expect(model.addAddress() == false)
        #expect(model.problem == AddressInput.Problem.invalidPort.message)

        model.newHost = "my kvm"
        model.newPort = ""
        #expect(model.addAddress() == false)
        #expect(model.problem == AddressInput.Problem.invalidHost.message)

        #expect(model.addresses == [Self.lan])
        #expect(model.isAddingAddress)
    }

    @Test func anAddressAlreadyListedOrAnotherDevicesIsRefused() {
        let other = Fixtures.device(id: "saved-other", nickname: "Rack 3", host: "192.0.2.50")
        let model = DeviceEditModel(device: Fixtures.device(host: Self.lan.host)) { address in
            address == other.address ? other : nil
        }
        model.beginAddingAddress()

        model.newHost = "192.168.0.131:443"
        #expect(model.addAddress() == false)
        #expect(model.problem == "192.168.0.131:443 is already listed.")

        model.newHost = "192.0.2.50"
        #expect(model.addAddress() == false)
        #expect(model.problem == "192.0.2.50:443 is already an address of Rack 3.")
        #expect(model.addresses == [Self.lan])
    }

    @Test func minusRemovesTheSelectedAddressButNeverTheLast() {
        let model = DeviceEditModel(device: Fixtures.device(host: Self.lan.host, addresses: [Self.lan, Self.tailnet]))
        #expect(model.canRemove == false)

        model.selection = Self.lan
        #expect(model.canRemove)
        model.removeSelected()

        #expect(model.addresses == [Self.tailnet])
        #expect(model.selection == Self.tailnet)
        #expect(model.canRemove == false)
        model.removeSelected()
        #expect(model.addresses == [Self.tailnet])
    }

    @Test func cancellingTheNewAddressRowLeavesTheList() {
        let model = DeviceEditModel(device: Fixtures.device(host: Self.lan.host))
        model.beginAddingAddress()
        model.newHost = "mdesktopkvm"

        model.cancelAddingAddress()

        #expect(model.addresses == [Self.lan])
        #expect(model.isAddingAddress == false)
        #expect(model.newHost == "")
    }

    @Test func returnSavesAndEscapeCancelsUnlessAnAddressIsBeingTyped() {
        let model = DeviceEditModel(device: Fixtures.device())
        #expect(model.returnAction == .save)
        #expect(model.escapeAction == .cancel)
        #expect(model.canSave)

        model.beginAddingAddress()
        #expect(model.returnAction == .addAddress)
        #expect(model.escapeAction == .cancelAddingAddress)
        #expect(model.canSave == false)

        model.cancelAddingAddress()
        #expect(model.returnAction == .save)
        #expect(model.escapeAction == .cancel)
    }

    // MARK: - Save

    @Test func savingAnUnsavedDeviceSavesIt() throws {
        let catalog = makeCatalog()
        let manual = catalog.addManualDevice(host: Self.lan.host, port: 443, type: .glinetComet)
        var heard: [KVMDeviceUpdate] = []
        let watch = catalog.deviceUpdates.sink { heard.append($0) }
        defer { watch.cancel() }

        let saved = try #require(catalog.saveEdits(of: manual, nickname: "Desk", addresses: [Self.lan, Self.tailnet]))

        #expect(saved.id == "saved-192.168.0.131-443")
        #expect(saved.nickname == "Desk")
        #expect(saved.addresses == [Self.lan, Self.tailnet])
        #expect(catalog.availableDevices.map(\.id) == [saved.id])
        let record = try #require(try Fixtures.readRecords(from: scratch.defaults).first)
        #expect(record.nickname == "Desk")
        #expect(record.addresses.map(\.host) == ["192.168.0.131", "mdesktopkvm"])
        #expect(heard.map(\.replacedIDs) == [[manual.id]])
    }

    @Test func savingAScannedDeviceSavesIt() throws {
        let catalog = makeCatalog()
        let scanned = Fixtures.device(id: "scanned-192.168.0.131-443", nickname: nil, host: Self.lan.host)

        let saved = try #require(catalog.saveEdits(of: scanned, nickname: nil, addresses: [Self.lan]))

        #expect(saved.isSaved)
        #expect(saved.displayName == "192.168.0.131")
        #expect(makeCatalog().availableDevices.map(\.id) == [saved.id])
    }

    @Test func savingWithNoAddressesDoesNothing() {
        let catalog = makeCatalog()
        let saved = catalog.persistDevice(Fixtures.device(nickname: "Desk", host: Self.lan.host))

        #expect(catalog.saveEdits(of: saved, nickname: "Other", addresses: []) == nil)
        #expect(catalog.availableDevices.first?.nickname == "Desk")
    }

    @Test func removingTheLastUsedAddressFallsBackToTheFirst() throws {
        let catalog = makeCatalog()
        let saved = catalog.persistDevice(Fixtures.device(nickname: "Desk", host: Self.lan.host))
        let both = try #require(catalog.saveEdits(of: saved, nickname: "Desk", addresses: [Self.tailnet, Self.lan]))
        #expect(both.lastUsedAddress == Self.lan)
        #expect(both.address == Self.lan)

        let trimmed = try #require(catalog.saveEdits(of: both, nickname: "Desk", addresses: [Self.tailnet]))

        #expect(trimmed.lastUsedAddress == nil)
        #expect(trimmed.address == Self.tailnet)
    }

    @Test func editingWhileConnectedLeavesTheConnectionAlone() async throws {
        let catalog = makeCatalog()
        let link = RecordingSessionLink(catalog: catalog)
        let session = ConsoleSession(catalog: catalog, defaults: scratch.defaults, link: link, connectionLog: .inMemory())
        _ = await session.connect(to: Fixtures.device(nickname: "Desk", host: Self.lan.host))
        let connected = try #require(session.connection.connectedDevice)
        let client = session.connection.glkvmClient
        let stepsBefore = link.steps

        // Add the Tailscale name, then remove the LAN address the session is using.
        catalog.saveEdits(of: connected, nickname: "Desk", addresses: [Self.lan, Self.tailnet])
        catalog.saveEdits(of: catalog.availableDevices[0], nickname: "Desk 2", addresses: [Self.tailnet])

        #expect(link.steps == stepsBefore)
        #expect(session.connection.glkvmClient === client)
        #expect(session.connection.connectedDevice?.address == Self.lan)
        #expect(session.connection.connectedDevice?.nickname == "Desk 2")
        #expect(session.connection.connectedDevice?.addresses == [Self.tailnet])
        #expect(session.panels.isSessionActive)
        // Still one window for the device, through its remaining address.
        #expect(session.isShowing(catalog.availableDevices[0]))
    }
}
