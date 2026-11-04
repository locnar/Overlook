import SwiftUI
import AppKit

/// Which of the three trailing-edge panels is open.
///
/// Connections, the connection log and Settings all slide into the same 360-point strip, so at
/// most one can be on screen. Modelling that as one optional rather than three booleans makes
/// the rule structural: there is no state in which two are open, so no call site has to
/// remember to close the others.
///
/// It lives outside `ContentView` because the View menu needs it too, and menu commands are
/// built in the `App` scope where a view's `@State` is out of reach.
@MainActor
final class PanelPresentation: ObservableObject {
    enum Panel: String, CaseIterable, Identifiable {
        case connections
        case log
        case settings

        var id: String { rawValue }

        /// The panel's own name, as its header shows it.
        var title: String {
            switch self {
            case .connections: return "Connections"
            case .log: return "Connection Log"
            case .settings: return "Settings"
            }
        }

        /// The View menu's wording, which names the thing being shown rather than the panel:
        /// the menu lists several kinds of item, and "Connections" alone reads like a place to
        /// manage devices rather than a panel to open.
        var menuTitle: String {
            switch self {
            case .connections: return "Show Connections Panel"
            case .log: return "Show Log Panel"
            case .settings: return "Show Settings Panel"
            }
        }

        /// Whether this panel is worth opening with no device connected. The log is: it is most
        /// wanted in the minute after a drop, which is exactly when there is no session.
        var requiresSession: Bool {
            switch self {
            case .connections, .log: return false
            case .settings: return true
            }
        }
    }

    @Published var openPanel: Panel?

    /// Whether a device is connected, so the menu can disable what a panel needs a session for.
    /// Driven from the session's `SessionConnection` (see `ConsoleSession`) rather than mirrored
    /// from a view: menu items stay clickable with no window open, and a view-scoped mirror stops
    /// updating the moment that window closes.
    @Published var isSessionActive = false

    // MARK: - Input capture paused behind a panel
    //
    // Lives here, beside `openPanel`, because the two have to agree. While these were view state
    // and `openPanel` was not, closing the window with a panel open stranded them: the reopened
    // window saw a panel open and capture already stopped, recorded "capture was off" as the
    // state to restore, and passthrough to the target stayed dead until the operator noticed.

    var pausedCaptureKeyboardWasEnabled: Bool?
    var pausedCaptureMouseWasEnabled: Bool?
    var isInputCapturePaused = false

    // MARK: - Width

    /// How wide the strip is. Shared by all three panels — they are the same strip — and
    /// persisted, so a width chosen for reading long log lines survives a relaunch.
    @Published var width: Double

    static let defaultWidth: Double = 440
    static let minWidth: Double = 300
    static let maxWidth: Double = 1000
    private static let widthKey = "OverlookPanelWidth"

    private let defaults: UserDefaults

    /// `defaults` is for tests, which pass a scratch suite; the app takes `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.widthKey)
        // `double(forKey:)` returns 0 for a key that was never written.
        width = stored > 0 ? Self.clampWidth(stored) : Self.defaultWidth
    }

    /// Written once at the end of a drag rather than on every frame of it.
    func persistWidth() {
        defaults.set(width, forKey: Self.widthKey)
    }

    func resetWidth(available: Double? = nil) {
        width = Self.clampWidth(Self.defaultWidth, available: available)
        persistWidth()
    }

    /// `available` is the window's content width; the panel always leaves some video visible.
    static func clampWidth(_ value: Double, available: Double? = nil) -> Double {
        var upper = maxWidth
        if let available {
            upper = min(upper, max(minWidth, available - 160))
        }
        return min(max(value, minWidth), upper)
    }

    var isAnyOpen: Bool { openPanel != nil }

    func isOpen(_ panel: Panel) -> Bool { openPanel == panel }

    func show(_ panel: Panel) { openPanel = panel }

    func close() { openPanel = nil }

    func toggle(_ panel: Panel) {
        openPanel = (openPanel == panel) ? nil : panel
    }

    /// Closes `panel` if it happens to be the one open, and leaves the others alone.
    func closeIfOpen(_ panel: Panel) {
        guard openPanel == panel else { return }
        openPanel = nil
    }

    func isEnabled(_ panel: Panel) -> Bool {
        panel.requiresSession == false || isSessionActive
    }

    /// A `Bool` binding for one panel, for the panels that take `isPresented` and close
    /// themselves.
    func isPresented(_ panel: Panel) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.openPanel == panel },
            set: { [weak self] shown in
                guard let self else { return }
                if shown {
                    self.openPanel = panel
                } else if self.openPanel == panel {
                    self.openPanel = nil
                }
            }
        )
    }
}

/// The drag handle on a panel's leading edge.
///
/// Log lines are long — a Janus hangup with its reason, or a candidate pair with two addresses —
/// and at 360 points they wrap to four or five lines each. Dragging the edge is the fix. The
/// width is shared, so widening it for the log widens Settings and Connections too.
struct PanelResizeHandle: View {
    @EnvironmentObject private var panels: PanelPresentation

    /// The width the panel sits in, so the clamp can keep some video visible. Passed down rather
    /// than read off `NSApp.keyWindow`, which is nil often enough to quietly drop the rule.
    let availableWidth: Double?

    @State private var drag: DragSession?
    @State private var isHovering = false
    @State private var isDragging = false
    /// Tracks the `NSCursor` push independently of hover, so every path that can end the
    /// interaction — exit, drag end, the panel closing — pops exactly the pushes it made.
    @State private var didPushCursor = false

    /// Straddles the panel edge (see `resizablePanel()`), so it can be grabbed from either side.
    private static let grabWidth: CGFloat = 10

    /// One drag, identified by where it started. `onEnded` does not fire when a gesture is
    /// *cancelled* — a modal alert raised by a connection event will do that mid-drag — so a
    /// start width cached in `onEnded`-cleared state goes stale and the next drag jumps. The
    /// start location is constant within a drag and differs between drags, which makes a stale
    /// session detectable instead of invisible.
    private struct DragSession {
        let startLocation: CGPoint
        let startWidth: Double
    }

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: Self.grabWidth)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isHovering ? Color.accentColor : Color.primary.opacity(0.12))
                    .frame(width: isHovering ? 2 : 1)
                    .animation(.easeOut(duration: 0.12), value: isHovering)
            }
            .onHover { inside in
                guard inside != isHovering else { return }
                isHovering = inside

                if inside {
                    // A hover with no drag under way means any previous one is over; a cancelled
                    // gesture (a modal alert during a resize) never reports that itself.
                    isDragging = false
                    pushCursor()
                } else if isDragging == false {
                    // Not while dragging: once the width hits a clamp the handle stops following
                    // the pointer, which slides off the strip — and the cursor would flip back to
                    // an arrow exactly when the operator is pushing against the limit.
                    popCursor()
                }
            }
            .onDisappear {
                // The panel can close while the pointer is still on the handle.
                popCursor()
                isHovering = false
                isDragging = false
                drag = nil
            }
            .gesture(
                // `.global`, not the default `.local`. This handle sits on the panel's leading
                // edge, so resizing moves the very view the gesture is attached to: widen by D
                // and the handle travels left by D, which cancels D of the pointer's movement
                // out of a local translation. The panel then tracked at exactly half mouse
                // speed (W = W₀ - D/2). A fixed coordinate space reports the true delta.
                //
                // 4 points of slop, not 1: at 1 point any trackpad jitter between press and
                // release starts a drag, which cancels the double-click that resets the width.
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        let session: DragSession
                        if let drag, drag.startLocation == value.startLocation {
                            session = drag
                        } else {
                            session = DragSession(startLocation: value.startLocation, startWidth: panels.width)
                            drag = session
                        }
                        isDragging = true

                        // Handle on the leading edge of a trailing-aligned panel: dragging left
                        // gives a negative translation, so subtracting widens.
                        panels.width = PanelPresentation.clampWidth(
                            session.startWidth - value.translation.width,
                            available: availableWidth
                        )
                    }
                    .onEnded { _ in
                        drag = nil
                        isDragging = false
                        // The pointer may have been pushed off the strip by a clamp, in which
                        // case the pop that `onHover` skipped is owed here.
                        if isHovering == false { popCursor() }
                        panels.persistWidth()
                    }
            )
            .onTapGesture(count: 2) {
                panels.resetWidth(available: availableWidth)
            }
            .help("Drag to resize · double-click to reset")
    }

    private func pushCursor() {
        guard didPushCursor == false else { return }
        didPushCursor = true
        // A bare `set()` is undone by the window's own cursor rects the moment the pointer
        // crosses the video, so the cursor is pushed and popped instead.
        NSCursor.resizeLeftRight.push()
    }

    private func popCursor() {
        guard didPushCursor else { return }
        didPushCursor = false
        NSCursor.pop()
    }
}

extension View {
    /// Puts the resize handle on this panel's leading edge. An overlay, so the handle takes no
    /// width of its own and the panel keeps exactly the size it was given. The negative padding
    /// straddles the strip across the edge — half over the panel, half over the video — so the
    /// edge can be grabbed on the approach instead of only once the pointer is already inside.
    func resizablePanel(availableWidth: Double?) -> some View {
        overlay(alignment: .leading) {
            PanelResizeHandle(availableWidth: availableWidth)
                .padding(.leading, -5)
        }
    }
}

/// The panel entries in the View menu, above Show Toolbar.
///
/// The menu is the only way to reach these when the window is in fullscreen and the operator has
/// not summoned the auto-hiding control strip, so all three belong here whether or not they have
/// a toolbar button on screen at the time.
///
/// `before: .toolbar` anchors to the group `ToolbarCommands()` contributes, which is why the app
/// declares it — without that group there is nothing for this to sit before.
///
/// Deliberately no key equivalents. Every chord the app claims is one the remote target stops
/// receiving, and this codebase already spends ⇧⌘S and ⇧⌘R on capture; three more for panels
/// that are one click away is a poor trade. (Same reasoning as the capture-region commands.)
struct PanelCommands: Commands {
    @ObservedObject var panels: PanelPresentation

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(PanelPresentation.Panel.allCases) { panel in
                Toggle(panel.menuTitle, isOn: Binding(
                    get: { panels.isOpen(panel) },
                    set: { _ in panels.toggle(panel) }
                ))
                // Enablement gates opening, never closing: a panel already on screen when the
                // session dropped would otherwise be checked and greyed out at the same time.
                .disabled(panels.isEnabled(panel) == false && panels.isOpen(panel) == false)
            }

            Divider()
        }
    }
}
