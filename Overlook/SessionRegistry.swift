import Foundation
import Combine

/// Every console session the app has — one per window — and which of them is active.
///
/// The app delegate owns it. A session is added when its window appears and removed when the
/// window closes, and quitting shuts down every session listed here.
///
/// The active session is the one in the key window. Only a window *becoming* key changes it: when
/// Overlook stops being frontmost no window is key, and the console the operator was last using
/// stays active. The menu-bar agent acts on the active session.
@MainActor
final class SessionRegistry: ObservableObject {
    /// Sessions whose windows are open, in the order the windows appeared.
    @Published private(set) var sessions: [ConsoleSession] = []
    /// The key window's session, or the last one to have been key.
    @Published private(set) var activeSession: ConsoleSession?

    /// The device catalog every session shares.
    let catalog: KVMDeviceManager

    /// Opens one more console window. The app delegate has no way to open a SwiftUI window
    /// itself, so a window hands over its `openWindow` action when it appears.
    var openWindowAction: (@MainActor () -> Void)?

    private let sessionFactory: @MainActor (KVMDeviceManager) -> ConsoleSession
    /// Sessions made for windows that have been asked for and have not appeared yet.
    private var pending: [ConsoleSession] = []
    /// Sessions in the order they were last key, most recent last, so that closing the active
    /// window hands "active" to the one used before it.
    private var keyOrder: [ObjectIdentifier] = []

    /// `makeSession` is for tests, which give each session a recording link and scratch defaults.
    init(
        catalog: KVMDeviceManager,
        makeSession: @escaping @MainActor (KVMDeviceManager) -> ConsoleSession = { ConsoleSession(catalog: $0) }
    ) {
        self.catalog = catalog
        self.sessionFactory = makeSession
    }

    /// Every session quitting has to shut down: the open windows' and any still waiting for theirs.
    var allSessions: [ConsoleSession] { sessions + pending }

    // MARK: - Windows coming and going

    /// The session for a window that is being built: the one `openWindow()` made for it, or a new
    /// one — for File › New Window, the first window at launch, or a window restored from the
    /// last run.
    func sessionForNewWindow() -> ConsoleSession {
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        return makeSession()
    }

    /// Opens a new console window and returns its session at once, so the caller can start
    /// connecting it while the window is still on its way. Nil before any window has handed over
    /// `openWindowAction`.
    func openWindow() -> ConsoleSession? {
        guard let openWindowAction else { return nil }
        let session = makeSession()
        pending.append(session)
        openWindowAction()
        return session
    }

    /// A session's window has appeared. The first one becomes active straight away, so the menu
    /// bar has something to act on before any window has been reported key.
    func add(_ session: ConsoleSession) {
        pending.removeAll { $0 === session }
        guard !sessions.contains(where: { $0 === session }) else { return }
        session.registry = self
        sessions.append(session)
        if activeSession == nil {
            activeSession = session
        }
    }

    /// A session's window has closed. If it was active, the session used most recently before it
    /// takes over, or none when it was the last window.
    func remove(_ session: ConsoleSession) {
        pending.removeAll { $0 === session }
        sessions.removeAll { $0 === session }
        keyOrder.removeAll { $0 == ObjectIdentifier(session) }
        guard activeSession === session else { return }
        let previous = keyOrder.last.flatMap { id in sessions.first { ObjectIdentifier($0) == id } }
        activeSession = previous ?? sessions.last
    }

    /// A session's window has become key.
    func sessionDidBecomeKey(_ session: ConsoleSession) {
        guard sessions.contains(where: { $0 === session }) else { return }
        keyOrder.removeAll { $0 == ObjectIdentifier(session) }
        keyOrder.append(ObjectIdentifier(session))
        if activeSession !== session {
            activeSession = session
        }
    }

    // MARK: - One window per device

    /// The session showing the device at `address`, or signing in to it, other than `excluding`.
    /// A device is open in one window at most; a second connect to it brings that window forward.
    func session(showing address: DeviceAddress, excluding: ConsoleSession? = nil) -> ConsoleSession? {
        allSessions.first { $0 !== excluding && $0.isShowing(address) }
    }

    /// The session showing `device` through any of its addresses, or signing in to it, other
    /// than `excluding`.
    func session(showing device: KVMDevice, excluding: ConsoleSession? = nil) -> ConsoleSession? {
        allSessions.first { $0 !== excluding && $0.isShowing(device) }
    }

    /// Where a connect from the menu-bar agent goes.
    enum ConnectTarget {
        /// The device is already open in this session's window: bring it forward instead.
        case bringForward(ConsoleSession)
        /// The active session is free: connect there.
        case connect(ConsoleSession)
        /// The active session is busy, or there is none: open a new window for it.
        case newWindow
    }

    func connectTarget(for address: DeviceAddress) -> ConnectTarget {
        if let open = session(showing: address) {
            return .bringForward(open)
        }
        return idleTarget()
    }

    /// Where a connect to `device` goes: the window showing it through any of its addresses, else
    /// the active window if it is free, else a new one.
    func connectTarget(for device: KVMDevice) -> ConnectTarget {
        if let open = session(showing: device) {
            return .bringForward(open)
        }
        return idleTarget()
    }

    private func idleTarget() -> ConnectTarget {
        if let active = activeSession, active.isIdle {
            return .connect(active)
        }
        return .newWindow
    }

    // MARK: - Quitting

    /// Runs every session's quit steps (finish the recording, release HID, hang up), side by side
    /// rather than one after another, so that a session whose HID socket is slow to close does not
    /// use up the grace period the others need to hang up.
    func shutDownAll() async {
        let sessions = allSessions
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { await session.shutDownForTermination() }
            }
        }
    }

    private func makeSession() -> ConsoleSession {
        let session = sessionFactory(catalog)
        session.registry = self
        return session
    }
}
