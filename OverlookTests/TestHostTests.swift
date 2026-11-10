import Foundation
import Testing
@testable import Overlook

/// The app hosts these tests, so what it builds at launch runs before any of them. Under the test
/// host it must build on stores that lead nowhere: no `.standard` defaults, no keychain, no log
/// file, no console window or menu-bar agent.
@MainActor
@Suite("Test host")
struct TestHostTests {
    @Test func knowsItIsHostingTheTests() {
        #expect(AppEnvironment.isHostingTests)
    }

    @Test func detectsTheTestHostFromXcodesVariables() {
        #expect(!AppEnvironment.isTestHost(environment: [:]))
        #expect(!AppEnvironment.isTestHost(environment: ["HOME": "/Users/operator", "PATH": "/usr/bin"]))
        for name in AppEnvironment.testHostVariables {
            #expect(AppEnvironment.isTestHost(environment: [name: "/tmp/x"]), "\(name)")
        }
    }

    @Test func sharedObjectsUseTheTestHostsStores() {
        #expect(AppEnvironment.defaults !== UserDefaults.standard)
        #expect(AppEnvironment.makeCredentialStore() is InMemoryDeviceCredentials)
        #expect(!ConnectionLog.shared.writesFile)
        #expect(AudioPreferences.shared.defaults === AppEnvironment.defaults)
        #expect(DeviceTrustStore.shared.defaults === AppEnvironment.defaults)
    }

    @Test func appBuiltItsCatalogOnTheTestHostsStores() throws {
        let app = try #require(AppDelegate.launched)
        #expect(app.kvmDeviceManager.defaults === AppEnvironment.defaults)
        #expect(app.kvmDeviceManager.credentials is InMemoryDeviceCredentials)
        #expect(app.kvmDeviceManager.trustStore === DeviceTrustStore.shared)
        #expect(app.menuBarAgent == nil)
        // The window it opened is not a console: no session was made for it.
        #expect(app.sessionRegistry.allSessions.isEmpty)
    }

    @Test func defaultArgumentsTakeTheTestHostsDefaults() {
        let catalog = KVMDeviceManager()
        #expect(catalog.defaults === AppEnvironment.defaults)
        #expect(catalog.credentials is InMemoryDeviceCredentials)
        #expect(DeviceTrustStore().defaults === AppEnvironment.defaults)
    }

    @Test func inMemoryCredentialsKeepWhatTheyAreGiven() {
        let store = InMemoryDeviceCredentials()
        #expect(store.setToken("abc", host: "KVM.Example", port: 443))
        #expect(store.token(host: "kvm.example", port: 443) == "abc")
        #expect(store.token(host: "kvm.example", port: 8443) == nil)
        store.deleteToken(host: "kvm.example", port: 443)
        #expect(store.token(host: "kvm.example", port: 443) == nil)
        #expect(store.setToken("", host: "kvm.example", port: 443))
        #expect(store.token(host: "kvm.example", port: 443) == nil)
    }
}
