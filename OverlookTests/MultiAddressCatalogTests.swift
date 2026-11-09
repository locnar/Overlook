import Combine
import Foundation
import Testing
@testable import Overlook

/// Devices with several addresses: the move from one record per host:port, saving, scanning,
/// credentials and pins found through any address, and the one-window rule across addresses.
/// Everything runs on scratch defaults, an in-memory credential store and a scratch trust store.
@MainActor
@Suite("Multi-address devices")
struct MultiAddressCatalogTests {
    let scratch = ScratchDefaults()
    let credentials = FakeCredentialStore()

    static let lan = DeviceAddress(host: "192.168.0.131", port: 443)
    static let tailnet = DeviceAddress(host: "mdesktopkvm", port: 443)

    private func makeCatalog(trust: DeviceTrustStore? = nil) -> KVMDeviceManager {
        Fixtures.catalog(scratch, credentials: credentials, trust: trust)
    }

    private func legacy(_ host: String, port: Int = 443, name: String, token: String? = nil) -> StoredDeviceRecord {
        StoredDeviceRecord(
            host: host,
            port: port,
            name: name,
            type: KVMDeviceType.glinetComet.rawValue,
            authToken: token,
            capabilities: [KVMCapability.videoStreaming.rawValue]
        )
    }

    private func pin(_ address: DeviceAddress, _ fingerprint: String) {
        var pins = scratch.defaults.dictionary(forKey: "overlook.trusted_certificates.v1") as? [String: String] ?? [:]
        pins[DeviceTrustStore.key(host: address.host, port: address.port)] = fingerprint
        scratch.defaults.set(pins, forKey: "overlook.trusted_certificates.v1")
    }

    /// The Desk KVM saved with both addresses, LAN first.
    private func saveDesk(in catalog: KVMDeviceManager, token: String = "") -> KVMDevice {
        let saved = catalog.persistDevice(Fixtures.device(nickname: "Desk", host: Self.lan.host, authToken: token))
        return catalog.saveEdits(of: saved, nickname: "Desk", addresses: [Self.lan, Self.tailnet])!
    }

    // MARK: - Migration

    @Test func eachLegacyRecordBecomesADeviceWithOneAddressAndItsOldID() throws {
        try Fixtures.writeLegacyRecords([
            legacy("192.168.0.131", name: "Manual KVM @ 192.168.0.131:443"),
            legacy("192.168.200.1", port: 80, name: "KVM @ 192.168.200.1:80"),
            legacy("10.0.0.7", name: "GLKVM @ 10.0.0.7:443"),
            legacy("kvm.tail1234.ts.net", name: "GLKVM @ kvm.tail1234.ts.net:443 (Tailscale)"),
            legacy("fd00::5", port: 8443, name: "Rack 3"),
        ], to: scratch.defaults)

        let devices = makeCatalog().availableDevices

        #expect(devices.count == 5)
        let byID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        #expect(byID["saved-192.168.0.131-443"]?.nickname == nil)
        #expect(byID["saved-192.168.200.1-80"]?.nickname == nil)
        #expect(byID["saved-10.0.0.7-443"]?.nickname == nil)
        #expect(byID["saved-kvm.tail1234.ts.net-443"]?.nickname == nil)
        #expect(byID["saved-fd00__5-8443"]?.nickname == "Rack 3")
        #expect(byID["saved-fd00__5-8443"]?.addresses == [DeviceAddress(host: "fd00::5", port: 8443)])
        #expect(byID["saved-192.168.0.131-443"]?.displayName == "192.168.0.131")
        #expect(byID["saved-192.168.200.1-80"]?.displayName == "192.168.200.1")

        let records = try Fixtures.readRecords(from: scratch.defaults)
        #expect(records.count == 5)
        #expect(records.allSatisfy { $0.addresses.count == 1 })
        #expect(records.first { $0.id == "saved-fd00__5-8443" }?.nickname == "Rack 3")
    }

    @Test func migrationLeavesTheLegacyRecordsAndCopiesThemAside() throws {
        let original = [legacy("192.168.0.131", name: "Rack 3"), legacy("10.0.0.7", name: "KVM @ 10.0.0.7:443")]
        try Fixtures.writeLegacyRecords(original, to: scratch.defaults)
        let before = scratch.defaults.data(forKey: Fixtures.legacySavedDevicesKey)

        _ = makeCatalog()

        #expect(scratch.defaults.data(forKey: Fixtures.legacySavedDevicesKey) == before)
        #expect(scratch.defaults.data(forKey: Fixtures.legacyBackupKey) == before)
        #expect(try Fixtures.readLegacyRecords(from: scratch.defaults) == original)
    }

    @Test func migrationLosesNoTokenOrPin() throws {
        try Fixtures.writeLegacyRecords([
            legacy("192.168.0.131", name: "Rack 3"),
            legacy("10.0.0.7", name: "KVM @ 10.0.0.7:443", token: "legacy-token"),
        ], to: scratch.defaults)
        credentials.tokens[FakeCredentialStore.key(host: "192.168.0.131", port: 443)] = "tok-131"
        credentials.passwords[FakeCredentialStore.key(host: "192.168.0.131", port: 443)] = "pw-131"
        pin(Self.lan, "aa")
        pin(DeviceAddress(host: "10.0.0.7", port: 443), "bb")
        let trust = Fixtures.trustStore(scratch)

        let devices = makeCatalog(trust: trust).availableDevices

        #expect(credentials.deletedTokens.isEmpty)
        #expect(credentials.deletedPasswords.isEmpty)
        #expect(credentials.tokens[FakeCredentialStore.key(host: "192.168.0.131", port: 443)] == "tok-131")
        #expect(credentials.passwords[FakeCredentialStore.key(host: "192.168.0.131", port: 443)] == "pw-131")
        // The token that was still in the legacy record is moved to the store, as before.
        #expect(credentials.tokens[FakeCredentialStore.key(host: "10.0.0.7", port: 443)] == "legacy-token")
        #expect(devices.first { $0.host == "192.168.0.131" }?.authToken == "tok-131")
        #expect(devices.first { $0.host == "10.0.0.7" }?.authToken == "legacy-token")
        #expect(trust.pinnedFingerprint(host: "192.168.0.131", port: 443) == "aa")
        #expect(trust.pinnedFingerprint(host: "10.0.0.7", port: 443) == "bb")
        #expect(Fixtures.trustStore(scratch).pinnedFingerprint(host: "10.0.0.7", port: 443) == "bb")
    }

    @Test func aTokenTheKeychainRefusesHoldsTheMigrationBackUntilItMoves() throws {
        try Fixtures.writeLegacyRecords([legacy("192.168.0.131", name: "Rack 3", token: "legacy")], to: scratch.defaults)
        credentials.refusesWrites = true

        #expect(makeCatalog().availableDevices.first?.authToken == "legacy")
        #expect(scratch.defaults.object(forKey: Fixtures.savedDevicesKey) == nil)

        credentials.refusesWrites = false
        let catalog = makeCatalog()

        #expect(catalog.availableDevices.first?.authToken == "legacy")
        #expect(credentials.tokens[FakeCredentialStore.key(host: "192.168.0.131", port: 443)] == "legacy")
        #expect(try Fixtures.readRecords(from: scratch.defaults).map(\.nickname) == ["Rack 3"])
    }

    @Test func migrationRunsOnceAndTheNewRecordsWinAfterThat() throws {
        try Fixtures.writeLegacyRecords([legacy("192.168.0.131", name: "Rack 3")], to: scratch.defaults)
        let first = makeCatalog()
        let migrated = try #require(first.availableDevices.first)
        first.saveEdits(of: migrated, nickname: "Desk", addresses: [Self.lan, Self.tailnet])

        // An earlier build run in between writes the legacy key again; it is not read twice.
        try Fixtures.writeLegacyRecords([legacy("192.168.0.131", name: "Old"), legacy("10.0.0.9", name: "New")], to: scratch.defaults)
        let second = makeCatalog()

        #expect(second.availableDevices.map(\.displayName) == ["Desk"])
        #expect(second.availableDevices.first?.addresses == [Self.lan, Self.tailnet])
        #expect(second.availableDevices.first?.id == migrated.id)
    }

    @Test func forgettingEveryDeviceDoesNotBringTheLegacyOnesBack() throws {
        try Fixtures.writeLegacyRecords([legacy("192.168.0.131", name: "Rack 3")], to: scratch.defaults)
        let first = makeCatalog()
        first.forgetDevice(try #require(first.availableDevices.first))

        #expect(makeCatalog().availableDevices.isEmpty)
    }

    // MARK: - Saving

    @Test func connectingThroughASecondAddressKeepsTheDeviceAndRecordsLastUsed() throws {
        let catalog = makeCatalog()
        let desk = saveDesk(in: catalog)
        #expect(desk.lastUsedAddress == Self.lan)

        let saved = catalog.persistDevice(desk.via(Self.tailnet))

        #expect(saved.id == desk.id)
        #expect(saved.address == Self.tailnet)
        #expect(saved.nickname == "Desk")
        #expect(catalog.availableDevices.count == 1)
        let entry = try #require(catalog.availableDevices.first)
        #expect(entry.lastUsedAddress == Self.tailnet)
        // The list shows the device at the address a plain Connect will use.
        #expect(entry.address == Self.tailnet)
        let record = try #require(try Fixtures.readRecords(from: scratch.defaults).first)
        #expect(record.addresses.map(\.host) == ["192.168.0.131", "mdesktopkvm"])
        #expect(record.lastUsed?.host == "mdesktopkvm")
    }

    @Test func aManualEntryForAKnownAddressSavesIntoThatDevice() throws {
        let catalog = makeCatalog()
        let desk = saveDesk(in: catalog)
        let manual = catalog.addManualDevice(host: "MDesktopKVM", port: 443, type: .glinetComet)

        let saved = catalog.persistDevice(manual)

        #expect(saved.id == desk.id)
        #expect(saved.nickname == "Desk")
        #expect(catalog.availableDevices.map(\.id) == [desk.id])
        #expect(try Fixtures.readRecords(from: scratch.defaults).count == 1)
    }

    @Test func pickingAnAddressRecordsItAsLastUsedAtOnce() throws {
        let catalog = makeCatalog()
        let desk = saveDesk(in: catalog)

        catalog.setLastUsedAddress(Self.tailnet, for: desk)

        #expect(catalog.availableDevices.first?.lastUsedAddress == Self.tailnet)
        #expect(catalog.availableDevices.first?.address == Self.tailnet)
        #expect(makeCatalog().availableDevices.first?.preferredAddress == Self.tailnet)
        // An address the device does not have is not recorded.
        catalog.setLastUsedAddress(DeviceAddress(host: "elsewhere", port: 443), for: desk)
        #expect(catalog.availableDevices.first?.lastUsedAddress == Self.tailnet)
    }

    // MARK: - Scanning

    @Test func aScannedAddressOfASavedDeviceIsShownAsThatDevice() {
        let saved = Fixtures.device(id: "saved-192.168.0.131-443", nickname: "Desk", host: Self.lan.host, addresses: [Self.lan, Self.tailnet])
        let scannedSecond = Fixtures.device(id: "scanned-mdesktopkvm-443", nickname: nil, host: "mdesktopkvm")
        let scannedFirst = Fixtures.device(id: "scanned-192.168.0.131-443", nickname: nil, host: Self.lan.host)
        let other = Fixtures.device(id: "scanned-192.168.0.140-443", nickname: nil, host: "192.168.0.140")
        let manualDuplicate = Fixtures.device(id: "manual-x", nickname: nil, host: Self.lan.host)

        let listed = KVMDeviceManager.mergeListed([scannedSecond, manualDuplicate, other, scannedFirst, saved])

        #expect(listed.count == 2)
        #expect(Set(listed.map(\.id)) == ["saved-192.168.0.131-443", "scanned-192.168.0.140-443"])
    }

    @Test func theListIsSortedByTheNameShown() {
        let listed = KVMDeviceManager.mergeListed([
            Fixtures.device(id: "saved-b", nickname: "zeta", host: "192.0.2.1"),
            Fixtures.device(id: "scanned-a", nickname: nil, host: "192.0.2.2"),
            Fixtures.device(id: "saved-c", nickname: "Alpha", host: "192.0.2.3"),
        ])
        #expect(listed.map(\.displayName) == ["192.0.2.2", "Alpha", "zeta"])
    }

    @Test func findingAnEntryByAnyOfItsAddresses() {
        let catalog = makeCatalog()
        let desk = saveDesk(in: catalog)

        #expect(catalog.device(at: Self.lan)?.id == desk.id)
        #expect(catalog.device(at: Self.tailnet)?.id == desk.id)
        #expect(catalog.savedDevice(containing: DeviceAddress(host: "MDESKTOPKVM", port: 443))?.id == desk.id)
        #expect(catalog.device(at: DeviceAddress(host: "mdesktopkvm", port: 8443)) == nil)
    }

    // MARK: - Credentials and pins across addresses

    @Test func aTokenSavedUnderAnyAddressIsTheDevicesTheLastUsedOneFirst() throws {
        try Fixtures.writeRecords([
            StoredDeviceRecordV2(
                id: "saved-192.168.0.131-443",
                nickname: "Desk",
                addresses: [.init(host: "192.168.0.131", port: 443), .init(host: "mdesktopkvm", port: 443)],
                lastUsed: .init(host: "mdesktopkvm", port: 443),
                type: "glinet_comet",
                capabilities: ["video_streaming"]
            ),
        ], to: scratch.defaults)
        credentials.tokens[FakeCredentialStore.key(host: "192.168.0.131", port: 443)] = "lan-token"

        #expect(makeCatalog().availableDevices.first?.authToken == "lan-token")

        credentials.tokens[FakeCredentialStore.key(host: "mdesktopkvm", port: 443)] = "tailnet-token"
        #expect(makeCatalog().availableDevices.first?.authToken == "tailnet-token")
    }

    @Test func aSavedPasswordUnderAnyAddressIsFoundThroughTheOneInUseFirst() {
        let catalog = makeCatalog()
        let desk = saveDesk(in: catalog)
        credentials.passwords[FakeCredentialStore.key(host: "192.168.0.131", port: 443)] = "lan-pw"

        let viaTailnet = catalog.savedPassword(for: desk.via(Self.tailnet))
        #expect(viaTailnet?.password == "lan-pw")
        #expect(viaTailnet?.address == Self.lan)

        credentials.passwords[FakeCredentialStore.key(host: "mdesktopkvm", port: 443)] = "tailnet-pw"
        #expect(catalog.savedPassword(for: desk.via(Self.tailnet))?.password == "tailnet-pw")
        #expect(catalog.savedPassword(for: desk.via(Self.lan))?.password == "lan-pw")
        #expect(catalog.savedPassword(for: Fixtures.device(host: "192.0.2.1")) == nil)
    }

    @Test func anAddedAddressGetsTheDevicesTokenUnlessItHasOne() {
        let catalog = makeCatalog()
        let saved = catalog.persistDevice(Fixtures.device(nickname: "Desk", host: Self.lan.host, authToken: "desk-token"))
        let other = DeviceAddress(host: "kvm.example", port: 443)
        credentials.tokens[FakeCredentialStore.key(host: "kvm.example", port: 443)] = "its-own"

        catalog.saveEdits(of: saved, nickname: "Desk", addresses: [Self.lan, Self.tailnet, other])

        #expect(credentials.tokens[FakeCredentialStore.key(host: "mdesktopkvm", port: 443)] == "desk-token")
        #expect(credentials.tokens[FakeCredentialStore.key(host: "kvm.example", port: 443)] == "its-own")
        #expect(credentials.tokens[FakeCredentialStore.key(host: "192.168.0.131", port: 443)] == "desk-token")
    }

    @Test func removingAnAddressDeletesNothingStoredForIt() {
        pin(Self.tailnet, "aa")
        let trust = Fixtures.trustStore(scratch)
        let catalog = makeCatalog(trust: trust)
        let desk = saveDesk(in: catalog, token: "desk-token")

        catalog.saveEdits(of: desk, nickname: "Desk", addresses: [Self.lan])

        #expect(credentials.deletedTokens.isEmpty)
        #expect(credentials.tokens[FakeCredentialStore.key(host: "mdesktopkvm", port: 443)] == "desk-token")
        #expect(trust.pinnedFingerprint(host: "mdesktopkvm", port: 443) == "aa")
        #expect(catalog.availableDevices.first?.addresses == [Self.lan])
    }

    @Test func forgettingADeviceClearsEveryAddress() {
        pin(Self.lan, "aa")
        pin(Self.tailnet, "aa")
        pin(DeviceAddress(host: "192.0.2.200", port: 443), "cc")
        let trust = Fixtures.trustStore(scratch)
        let catalog = makeCatalog(trust: trust)
        let desk = saveDesk(in: catalog, token: "desk-token")
        _ = catalog.persistDevice(Fixtures.device(nickname: "Other", host: "192.0.2.200", authToken: "other"))
        var heard: [KVMDeviceRemoval] = []
        let watch = catalog.deviceRemovals.sink { heard.append($0) }
        defer { watch.cancel() }

        catalog.forgetDevice(desk)

        #expect(Set(credentials.deletedTokens) == ["192.168.0.131:443", "mdesktopkvm:443"])
        #expect(Set(credentials.deletedPasswords) == ["192.168.0.131:443", "mdesktopkvm:443"])
        #expect(trust.pinnedFingerprint(host: "192.168.0.131", port: 443) == nil)
        #expect(trust.pinnedFingerprint(host: "mdesktopkvm", port: 443) == nil)
        #expect(trust.pinnedFingerprint(host: "192.0.2.200", port: 443) == "cc")
        #expect(credentials.tokens[FakeCredentialStore.key(host: "192.0.2.200", port: 443)] == "other")
        #expect(catalog.availableDevices.map(\.displayName) == ["Other"])
        #expect(heard == [.forgotten(id: desk.id, addresses: [Self.lan, Self.tailnet])])
    }

    // MARK: - Sessions

    @Test func aConnectionThroughAnotherAddressIsClearedWhenTheDeviceIsForgotten() throws {
        let catalog = makeCatalog()
        let desk = saveDesk(in: catalog)
        let connection = SessionConnection(catalog: catalog)
        connection.connectedDevice = desk.via(Self.tailnet)
        connection.glkvmClient = try GLKVMClient(device: desk.via(Self.tailnet))

        catalog.forgetDevice(catalog.availableDevices[0])

        #expect(connection.connectedDevice == nil)
        #expect(connection.glkvmClient == nil)
    }

    @Test func aRenameReachesTheConnectedSessionWhichKeepsItsAddress() {
        let catalog = makeCatalog()
        let desk = saveDesk(in: catalog)
        let connection = SessionConnection(catalog: catalog)
        var connected = desk.via(Self.tailnet)
        connected.authToken = "session-token"
        connection.connectedDevice = connected
        let bystander = SessionConnection(catalog: catalog)
        bystander.connectedDevice = Fixtures.device(id: "saved-other", nickname: "Other", host: "192.0.2.9")

        catalog.saveEdits(of: desk, nickname: "Desk 2", addresses: [Self.lan, Self.tailnet])

        #expect(connection.connectedDevice?.nickname == "Desk 2")
        #expect(connection.connectedDevice?.address == Self.tailnet)
        #expect(connection.connectedDevice?.authToken == "session-token")
        #expect(bystander.connectedDevice?.nickname == "Other")
    }

    @Test func aDeviceOpenThroughOneAddressIsFoundThroughTheOther() async {
        let catalog = makeCatalog()
        let desk = saveDesk(in: catalog)
        let defaults = scratch.defaults
        let registry = SessionRegistry(catalog: catalog) { catalog in
            let link = RecordingSessionLink(catalog: catalog)
            return ConsoleSession(catalog: catalog, defaults: defaults, link: link, connectionLog: .inMemory())
        }
        let first = registry.sessionForNewWindow()
        registry.add(first)
        _ = await first.connect(to: desk.via(Self.lan))
        let second = registry.sessionForNewWindow()
        registry.add(second)

        let outcome = await second.connect(to: desk.via(Self.tailnet))

        guard case .openElsewhere(let other) = outcome else {
            Issue.record("Expected the open window, got \(outcome)")
            return
        }
        #expect(other === first)
        #expect(second.connection.connectedDevice == nil)
        #expect(registry.session(showing: Self.tailnet) === first)
        guard case .bringForward(let open) = registry.connectTarget(for: catalog.availableDevices[0]) else {
            Issue.record("Expected bring forward")
            return
        }
        #expect(open === first)
    }

    // MARK: - Menu bar and Quick Connect

    @Test func aTypedAddressOfASavedDeviceConnectsAsThatDevice() {
        let catalog = makeCatalog()
        let desk = saveDesk(in: catalog)

        let typed = catalog.device(forTyped: DeviceAddress(host: "MDesktopKVM", port: 443))

        #expect(typed.id == desk.id)
        #expect(typed.nickname == "Desk")
        #expect(typed.address == Self.tailnet)
        // No manual entry was added for it.
        #expect(catalog.availableDevices.map(\.id) == [desk.id])
    }

    @Test func anUnknownTypedAddressGetsAManualEntry() {
        let catalog = makeCatalog()
        _ = saveDesk(in: catalog)

        let typed = catalog.device(forTyped: DeviceAddress(host: "192.0.2.77", port: 8443))

        #expect(typed.id.hasPrefix("manual-"))
        #expect(typed.nickname == nil)
        #expect(catalog.availableDevices.count == 2)
    }

    @Test func theMenuBarConnectsThroughTheLastUsedAddressAndFindsTheOpenWindow() async {
        let catalog = makeCatalog()
        let desk = saveDesk(in: catalog)
        catalog.setLastUsedAddress(Self.tailnet, for: desk)
        let defaults = scratch.defaults
        var links: [RecordingSessionLink] = []
        let registry = SessionRegistry(catalog: catalog) { catalog in
            let link = RecordingSessionLink(catalog: catalog)
            links.append(link)
            return ConsoleSession(catalog: catalog, defaults: defaults, link: link, connectionLog: .inMemory())
        }
        let active = registry.sessionForNewWindow()
        registry.add(active)

        // What the Devices menu and the popover do with the listed entry.
        let entry = catalog.availableDevices[0]
        guard case .connect(let target) = registry.connectTarget(for: ConnectVia.plainConnect(entry)) else {
            Issue.record("Expected the free active window")
            return
        }
        _ = await target.connect(to: ConnectVia.plainConnect(entry))
        #expect(links.first?.steps.first == .signIn(host: "mdesktopkvm", password: nil))

        // Quick Connect to the device's other address finds that window.
        let typed = catalog.device(forTyped: Self.lan)
        guard case .bringForward(let open) = registry.connectTarget(for: typed) else {
            Issue.record("Expected the open window")
            return
        }
        #expect(open === active)
    }
}
