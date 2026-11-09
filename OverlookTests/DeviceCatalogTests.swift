import Combine
import Foundation
import Testing
@testable import Overlook

/// The saved-device catalog: what it loads, what it writes, and what forgetting a device clears.
/// Every catalog here runs on a scratch defaults suite, an in-memory credential store and a trust
/// store of its own.
@MainActor
@Suite("Device catalog")
struct DeviceCatalogTests {
    let scratch = ScratchDefaults()
    let credentials = FakeCredentialStore()

    private func makeCatalog() -> KVMDeviceManager {
        KVMDeviceManager(
            defaults: scratch.defaults,
            credentials: credentials,
            trustStore: Fixtures.trustStore(scratch)
        )
    }

    private func record(
        host: String,
        port: Int = 443,
        name: String,
        authToken: String? = nil
    ) -> StoredDeviceRecord {
        StoredDeviceRecord(
            host: host,
            port: port,
            name: name,
            type: KVMDeviceType.glinetComet.rawValue,
            authToken: authToken,
            capabilities: [KVMCapability.videoStreaming.rawValue, KVMCapability.keyboardInput.rawValue]
        )
    }

    // MARK: - Loading

    @Test func startsEmptyWithNothingSaved() {
        let catalog = makeCatalog()
        #expect(catalog.availableDevices.isEmpty)
        #expect(catalog.isScanning == false)
    }

    @Test func loadsSavedDevicesSortedByNameWithStableIDs() throws {
        try Fixtures.writeLegacyRecords([
            record(host: "192.0.2.20", name: "Bravo"),
            record(host: "fd00::5", port: 8443, name: "Alpha"),
        ], to: scratch.defaults)
        credentials.tokens[FakeCredentialStore.key(host: "192.0.2.20", port: 443)] = "bravo-token"

        let devices = makeCatalog().availableDevices

        #expect(devices.map(\.displayName) == ["Alpha", "Bravo"])
        // Colons in an IPv6 host are replaced so the id stays one token.
        #expect(devices.map(\.id) == ["saved-fd00__5-8443", "saved-192.0.2.20-443"])
        #expect(devices[0].authToken == "")
        #expect(devices[1].authToken == "bravo-token")
        #expect(devices[1].type == .glinetComet)
        #expect(devices[1].capabilities == [.videoStreaming, .keyboardInput])
    }

    @Test func collapsesRecordsForTheSameHostAndPort() throws {
        try Fixtures.writeLegacyRecords([
            record(host: "192.0.2.20", name: "First"),
            record(host: "192.0.2.20", name: "Second"),
        ], to: scratch.defaults)

        let devices = makeCatalog().availableDevices

        #expect(devices.map(\.displayName) == ["First"])
    }

    @Test func ignoresUnreadableSavedData() {
        scratch.defaults.set(Data("not json".utf8), forKey: Fixtures.legacySavedDevicesKey)
        #expect(makeCatalog().availableDevices.isEmpty)
        scratch.defaults.set(Data("not json".utf8), forKey: Fixtures.savedDevicesKey)
        #expect(makeCatalog().availableDevices.isEmpty)
    }

    // MARK: - Legacy token migration

    @Test func movesALegacyTokenIntoTheCredentialStore() throws {
        try Fixtures.writeLegacyRecords([record(host: "192.0.2.20", name: "Old", authToken: "legacy")], to: scratch.defaults)

        let devices = makeCatalog().availableDevices

        #expect(devices.first?.authToken == "legacy")
        #expect(credentials.tokens[FakeCredentialStore.key(host: "192.0.2.20", port: 443)] == "legacy")
        let rewritten = try Fixtures.readLegacyRecords(from: scratch.defaults)
        #expect(rewritten.count == 1)
        #expect(rewritten.first?.authToken == nil)
    }

    @Test func prefersTheKeychainTokenOverALegacyOne() throws {
        try Fixtures.writeLegacyRecords([record(host: "192.0.2.20", name: "Old", authToken: "legacy")], to: scratch.defaults)
        credentials.tokens[FakeCredentialStore.key(host: "192.0.2.20", port: 443)] = "current"

        let devices = makeCatalog().availableDevices

        #expect(devices.first?.authToken == "current")
        #expect(credentials.tokens[FakeCredentialStore.key(host: "192.0.2.20", port: 443)] == "current")
        #expect(try Fixtures.readLegacyRecords(from: scratch.defaults).first?.authToken == nil)
    }

    @Test func keepsTheLegacyTokenWhenTheKeychainRefusesIt() throws {
        try Fixtures.writeLegacyRecords([record(host: "192.0.2.20", name: "Old", authToken: "legacy")], to: scratch.defaults)
        credentials.refusesWrites = true

        let devices = makeCatalog().availableDevices

        #expect(devices.first?.authToken == "legacy")
        // Not rewritten: dropping the token from the record now would lose it.
        #expect(try Fixtures.readLegacyRecords(from: scratch.defaults).first?.authToken == "legacy")
    }

    // MARK: - Saving

    @Test func persistingADeviceSavesItWithoutItsToken() throws {
        let catalog = makeCatalog()
        let manual = catalog.addManualDevice(host: "192.0.2.30", port: 443, type: .glinetComet)
        var connected = manual
        connected.authToken = "secret"

        let saved = catalog.persistDevice(connected)

        #expect(saved.id == "saved-192.0.2.30-443")
        #expect(saved.authToken == "secret")
        // The manual entry for the same host:port gives way to the saved one.
        #expect(catalog.availableDevices.map(\.id) == ["saved-192.0.2.30-443"])
        #expect(credentials.tokens[FakeCredentialStore.key(host: "192.0.2.30", port: 443)] == "secret")

        let records = try Fixtures.readRecords(from: scratch.defaults)
        #expect(records.count == 1)
        #expect(records.first?.id == "saved-192.0.2.30-443")
        #expect(records.first?.addresses == [.init(host: "192.0.2.30", port: 443)])
        #expect(records.first?.lastUsed == .init(host: "192.0.2.30", port: 443))
        // A manual entry has no nickname to save; the token is not in the record at all.
        #expect(records.first?.nickname == nil)
        let raw = String(decoding: scratch.defaults.data(forKey: Fixtures.savedDevicesKey) ?? Data(), as: UTF8.self)
        #expect(raw.contains("secret") == false)
    }

    @Test func aSavedDeviceComesBackOnTheNextLaunch() {
        let first = makeCatalog()
        let saved = first.persistDevice(Fixtures.device(nickname: "Rack 3", host: "192.0.2.40", authToken: "tok"))

        let second = makeCatalog()

        #expect(second.availableDevices.count == 1)
        let reloaded = second.availableDevices.first
        #expect(reloaded?.id == saved.id)
        #expect(reloaded?.nickname == "Rack 3")
        #expect(reloaded?.host == "192.0.2.40")
        #expect(reloaded?.authToken == "tok")
    }

    @Test func persistingAgainKeepsTheOneRecordAndItsNickname() throws {
        let catalog = makeCatalog()
        let saved = catalog.persistDevice(Fixtures.device(nickname: "Old name", host: "192.0.2.40"))
        // A later connect through the same address, from an entry with another name (a scan, a
        // manual entry) does not rename the device or save a second one.
        _ = catalog.persistDevice(Fixtures.device(id: "manual-other", nickname: "New name", host: "192.0.2.40"))
        _ = catalog.persistDevice(Fixtures.device(id: "scanned-192.0.2.40-443", nickname: nil, host: "192.0.2.40"))

        let records = try Fixtures.readRecords(from: scratch.defaults)
        #expect(records.map(\.nickname) == ["Old name"])
        #expect(records.map(\.id) == [saved.id])
        #expect(catalog.availableDevices.map(\.displayName) == ["Old name"])
        #expect(catalog.availableDevices.map(\.id) == [saved.id])
    }

    @Test func persistingAnEmptyTokenRemovesTheStoredOne() {
        credentials.tokens[FakeCredentialStore.key(host: "192.0.2.40", port: 443)] = "stale"
        let catalog = makeCatalog()

        _ = catalog.persistDevice(Fixtures.device(host: "192.0.2.40", authToken: ""))

        #expect(credentials.tokens[FakeCredentialStore.key(host: "192.0.2.40", port: 443)] == nil)
    }

    // MARK: - Manual devices

    @Test func addsAManualDeviceWithoutSavingIt() throws {
        let catalog = makeCatalog()

        let device = catalog.addManualDevice(host: "192.0.2.50", port: 8443, type: .glinetComet)

        #expect(device.id.hasPrefix("manual-"))
        #expect(device.nickname == nil)
        #expect(device.displayName == "192.0.2.50:8443")
        #expect(device.capabilities == [.videoStreaming, .keyboardInput, .mouseInput])
        #expect(catalog.availableDevices.map(\.id) == [device.id])
        #expect(try Fixtures.readRecords(from: scratch.defaults).isEmpty)
    }

    @Test func addingTheSameAddressTwiceKeepsBothEntries() {
        let catalog = makeCatalog()
        let first = catalog.addManualDevice(host: "192.0.2.50", port: 443, type: .glinetComet)
        let second = catalog.addManualDevice(host: "192.0.2.50", port: 443, type: .glinetComet)

        #expect(first.id != second.id)
        #expect(catalog.availableDevices.count == 2)
    }

    @Test func removingADeviceDropsOnlyThatEntry() throws {
        let catalog = makeCatalog()
        let keep = catalog.addManualDevice(host: "192.0.2.50", port: 443, type: .glinetComet)
        let drop = catalog.addManualDevice(host: "192.0.2.51", port: 443, type: .glinetComet)
        _ = catalog.persistDevice(Fixtures.device(nickname: "Saved", host: "192.0.2.52"))

        catalog.removeDevice(drop)

        #expect(Set(catalog.availableDevices.map(\.id)) == [keep.id, "saved-192.0.2.52-443"])
        // Removing is a list operation; the saved record is untouched.
        #expect(try Fixtures.readRecords(from: scratch.defaults).count == 1)
    }

    // MARK: - Forgetting

    @Test func forgettingADeviceDropsItsRecordSecretsAndPin() throws {
        let pinKey = DeviceTrustStore.key(host: "192.0.2.60", port: 443)
        let otherPinKey = DeviceTrustStore.key(host: "192.0.2.61", port: 443)
        scratch.defaults.set([pinKey: "aa", otherPinKey: "bb"], forKey: "overlook.trusted_certificates.v1")
        let trust = Fixtures.trustStore(scratch)
        let catalog = KVMDeviceManager(defaults: scratch.defaults, credentials: credentials, trustStore: trust)
        let saved = catalog.persistDevice(Fixtures.device(nickname: "Gone", host: "192.0.2.60", authToken: "tok"))
        _ = catalog.persistDevice(Fixtures.device(nickname: "Stays", host: "192.0.2.61", authToken: "tok2"))
        // A manual entry for the same address goes too: forgetting is by host and port.
        _ = catalog.addManualDevice(host: "192.0.2.60", port: 443, type: .glinetComet)

        catalog.forgetDevice(saved)

        #expect(catalog.availableDevices.map(\.displayName) == ["Stays"])
        #expect(try Fixtures.readRecords(from: scratch.defaults).map(\.nickname) == ["Stays"])
        #expect(credentials.deletedTokens == ["192.0.2.60:443"])
        #expect(credentials.deletedPasswords == ["192.0.2.60:443"])
        #expect(credentials.tokens[FakeCredentialStore.key(host: "192.0.2.61", port: 443)] == "tok2")
        #expect(trust.pinnedFingerprint(host: "192.0.2.60", port: 443) == nil)
        #expect(trust.pinnedFingerprint(host: "192.0.2.61", port: 443) == "bb")
    }

    @Test func trustingANewCertificateDropsOnlyThatPin() {
        scratch.defaults.set(
            [DeviceTrustStore.key(host: "192.0.2.60", port: 443): "aa",
             DeviceTrustStore.key(host: "192.0.2.60", port: 8443): "bb"],
            forKey: "overlook.trusted_certificates.v1"
        )
        let trust = Fixtures.trustStore(scratch)
        let catalog = KVMDeviceManager(defaults: scratch.defaults, credentials: credentials, trustStore: trust)

        catalog.trustNewCertificate(host: "192.0.2.60", port: 443)

        #expect(trust.pinnedFingerprint(host: "192.0.2.60", port: 443) == nil)
        #expect(trust.pinnedFingerprint(host: "192.0.2.60", port: 8443) == "bb")
        // And it is written through, so a relaunch does not bring the old pin back.
        #expect(Fixtures.trustStore(scratch).pinnedFingerprint(host: "192.0.2.60", port: 443) == nil)
    }

    // MARK: - Announcing removals

    @Test func removingADeviceAnnouncesItsID() {
        let catalog = makeCatalog()
        let device = catalog.addManualDevice(host: "192.0.2.70", port: 443, type: .glinetComet)
        var heard: [KVMDeviceRemoval] = []
        let watch = catalog.deviceRemovals.sink { heard.append($0) }
        defer { watch.cancel() }

        catalog.removeDevice(device)

        #expect(heard == [.removed(id: device.id)])
    }

    @Test func forgettingADeviceAnnouncesItsAddress() {
        let catalog = makeCatalog()
        let saved = catalog.persistDevice(Fixtures.device(host: "192.0.2.80", port: 8443))
        var heard: [KVMDeviceRemoval] = []
        let watch = catalog.deviceRemovals.sink { heard.append($0) }
        defer { watch.cancel() }

        catalog.forgetDevice(saved)

        #expect(heard == [.forgotten(id: saved.id, addresses: [DeviceAddress(host: "192.0.2.80", port: 8443)])])
    }

    @Test func updatingADeviceReplacesTheEntryWithTheSameID() {
        let catalog = makeCatalog()
        var device = catalog.addManualDevice(host: "192.0.2.90", port: 443, type: .glinetComet)
        device.authToken = "fresh"

        catalog.updateDevice(device)
        catalog.updateDevice(Fixtures.device(id: "not-listed", host: "192.0.2.91"))

        #expect(catalog.availableDevices.map(\.id) == [device.id])
        #expect(catalog.availableDevices.first?.authToken == "fresh")
    }

    // MARK: - Finding a device by address

    @Test func aSelectionByAddressSurvivesTheDeviceBeingSaved() {
        let catalog = makeCatalog()
        let manual = catalog.addManualDevice(host: "192.0.2.95", port: 443, type: .glinetComet)
        catalog.addManualDevice(host: "192.0.2.96", port: 443, type: .glinetComet)
        let selection = manual.address

        // Another window connects to it: saved under a new id, renamed, and the list re-sorted.
        var connected = manual
        connected.nickname = "Rack 3"
        let saved = catalog.persistDevice(connected)

        #expect(saved.id != manual.id)
        #expect(catalog.availableDevices.map(\.host) == ["192.0.2.96", "192.0.2.95"])
        // A selection held as the entry itself (which compares by id) now matches nothing...
        #expect(catalog.availableDevices.contains(manual) == false)
        // ...while one held by address still finds it, and is still one of the Picker's tags.
        #expect(catalog.device(at: selection)?.id == saved.id)
        #expect(catalog.device(at: selection)?.displayName == "Rack 3")
        #expect(catalog.availableDevices.map(\.address).contains(selection))
    }

    @Test func anAddressIsTheHostAndThePort() {
        let catalog = makeCatalog()
        let https = catalog.addManualDevice(host: "192.0.2.97", port: 443, type: .glinetComet)
        let alternate = catalog.addManualDevice(host: "192.0.2.97", port: 8443, type: .glinetComet)

        #expect(catalog.device(at: https.address)?.id == https.id)
        #expect(catalog.device(at: alternate.address)?.id == alternate.id)
        #expect(catalog.device(at: DeviceAddress(host: "192.0.2.97", port: 80)) == nil)
        #expect(Fixtures.device(id: "a", host: "192.0.2.98").address == Fixtures.device(id: "b", host: "192.0.2.98").address)
    }

    // MARK: - Scanning

    @Test func cancellingWithNoScanRunningLeavesTheCatalogIdle() {
        let catalog = makeCatalog()

        catalog.cancelScan()

        #expect(catalog.isScanning == false)
        #expect(catalog.scanProgress == 1.0)
    }
}
