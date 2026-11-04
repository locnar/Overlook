import Foundation
import Combine

/// What the menu-bar agent's status menu says about the console sessions: which are connected,
/// which of them is active, and what the actions on the active one are called and whether they
/// can be used. Plain values worked out from the registry, so the menu's contents can be tested
/// without a status item.
///
/// One list for every window ("option B"): the connected sessions, with a checkmark on the active
/// one and a marker on any that is recording, then the actions, which act on the active session.
/// Choosing another session brings its window forward, which makes it active.
struct StatusMenuModel: Equatable {
    /// One session as the menu sees it.
    struct SessionState: Equatable {
        let id: ObjectIdentifier
        /// The connected device's name; nil while the session is not connected.
        var deviceName: String?
        var isRecording: Bool
    }

    /// A connected session, as listed under "Connected".
    struct ConnectedItem: Equatable {
        let id: ObjectIdentifier
        let deviceName: String
        /// Shown with a checkmark.
        let isActive: Bool
        /// Shown with a trailing recording marker.
        let isRecording: Bool

        /// The item's plain title: the device, then the marker while it records.
        var title: String {
            isRecording ? "\(deviceName)  \(StatusMenuModel.recordingMarker)" : deviceName
        }
    }

    static let showTitle = "Show Overlook"
    static let connectedHeader = "Connected"
    static let noneConnectedTitle = "No devices connected"
    static let recordingMarker = "● rec"
    static let screenshotTitle = "Save Screenshot"

    /// Connected sessions, in the order their windows opened.
    let connected: [ConnectedItem]
    /// The active session's device, while that session is connected.
    let activeDeviceName: String?
    let isActiveRecording: Bool

    init(sessions: [SessionState], activeID: ObjectIdentifier?) {
        connected = sessions.compactMap { state in
            guard let name = state.deviceName else { return nil }
            return ConnectedItem(id: state.id, deviceName: name, isActive: state.id == activeID, isRecording: state.isRecording)
        }
        let active = sessions.first { $0.id == activeID }
        activeDeviceName = active?.deviceName
        isActiveRecording = active?.isRecording ?? false
    }

    var isAnyConnected: Bool { !connected.isEmpty }

    // MARK: Actions on the active session

    /// Disabled, not hidden, while the active session is not connected, so the menu keeps its
    /// shape.
    var canSaveScreenshot: Bool { activeDeviceName != nil }

    var recordingTitle: String { isActiveRecording ? "Stop Recording" : "Start Recording" }
    /// A recording that is running can always be stopped.
    var canToggleRecording: Bool { activeDeviceName != nil || isActiveRecording }

    /// Names the device, so it is plain which of several windows will be disconnected.
    var disconnectTitle: String { activeDeviceName.map { "Disconnect \($0)" } ?? "Disconnect" }
    var canDisconnect: Bool { activeDeviceName != nil }
}

/// Keeps a `StatusMenuModel` current as sessions connect and disconnect, start and stop recording,
/// and as the active session changes.
///
/// It holds no session, only each one's identity and its subscriptions, which are dropped when the
/// session leaves the registry, so the menu bar never keeps a closed window's session alive.
@MainActor
final class StatusMenuState: ObservableObject {
    @Published private(set) var model = StatusMenuModel(sessions: [], activeID: nil)

    private var order: [ObjectIdentifier] = []
    private var states: [ObjectIdentifier: StatusMenuModel.SessionState] = [:]
    private var activeID: ObjectIdentifier?
    private var cancellables = Set<AnyCancellable>()
    private var sessionCancellables: [ObjectIdentifier: AnyCancellable] = [:]

    init(registry: SessionRegistry) {
        // `@Published` fires in `willSet`, so everything here is built from the emitted values
        // rather than read back from the registry or the sessions.
        registry.$sessions
            .sink { [weak self] sessions in
                self?.track(sessions)
            }
            .store(in: &cancellables)
        registry.$activeSession
            .sink { [weak self] active in
                guard let self else { return }
                self.activeID = active.map(ObjectIdentifier.init)
                self.rebuild()
            }
            .store(in: &cancellables)
    }

    private func track(_ sessions: [ConsoleSession]) {
        let ids = sessions.map(ObjectIdentifier.init)
        order = ids
        for id in Array(sessionCancellables.keys) where !ids.contains(id) {
            sessionCancellables[id] = nil
            states[id] = nil
        }
        for session in sessions {
            let id = ObjectIdentifier(session)
            guard sessionCancellables[id] == nil else { continue }
            sessionCancellables[id] = session.connection.$connectedDevice
                .combineLatest(session.captureManager.$isRecording)
                .sink { [weak self] device, isRecording in
                    guard let self else { return }
                    self.states[id] = StatusMenuModel.SessionState(id: id, deviceName: device?.name, isRecording: isRecording)
                    self.rebuild()
                }
        }
        rebuild()
    }

    private func rebuild() {
        let next = StatusMenuModel(sessions: order.compactMap { states[$0] }, activeID: activeID)
        if next != model {
            model = next
        }
    }
}
