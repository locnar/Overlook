import AppKit
import Testing
@testable import Overlook

/// The one stand-in in front of a console window's delegate: both window features register with
/// it in either order, SwiftUI's delegate (stood in for here) keeps hearing everything, a feature
/// that goes away is never called again, and detaching the last feature or closing the window
/// puts SwiftUI's delegate back. Real windows, never shown.
@MainActor
@Suite("Window delegate interposer")
struct WindowDelegateInterposerTests {
    /// What reached the delegates and participants, in order.
    final class CallLog {
        var calls: [String] = []
    }

    /// Stands in for the delegate SwiftUI installs: records what reaches it.
    final class SwiftUIDelegate: NSObject, NSWindowDelegate {
        let log: CallLog
        var allowsClose = true

        init(log: CallLog) {
            self.log = log
        }

        func windowDidMove(_ notification: Notification) {
            log.calls.append("swiftui didMove")
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            log.calls.append("swiftui shouldClose")
            return allowsClose
        }

        func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
            log.calls.append("swiftui willResize \(Int(frameSize.width))")
            return frameSize
        }

        func windowDidEnterFullScreen(_ notification: Notification) {
            log.calls.append("swiftui didEnterFullScreen")
        }

        func windowWillClose(_ notification: Notification) {
            log.calls.append("swiftui willClose")
        }
    }

    /// Stands in for `ConsoleWindowAttachment` or `WindowAspectRatioSetter`.
    final class Feature: WindowDelegateParticipant {
        let name: String
        let log: CallLog
        var refusesClose = false
        /// Resizes come out this wide, as the aspect-ratio feature constrains them.
        var resizeWidth: CGFloat?

        init(_ name: String, log: CallLog) {
            self.name = name
            self.log = log
        }

        func windowShouldClose(for window: NSWindow) -> Bool {
            log.calls.append("\(name) shouldClose")
            return !refusesClose
        }

        func window(_ window: NSWindow, willResizeTo size: NSSize) -> NSSize {
            log.calls.append("\(name) willResize \(Int(size.width))")
            return NSSize(width: resizeWidth ?? size.width, height: size.height)
        }

        func windowDidEnterFullScreen(for window: NSWindow) {
            log.calls.append("\(name) didEnterFullScreen")
        }
    }

    let log = CallLog()

    private func makeWindow(delegate: NSWindowDelegate) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        return window
    }

    private func moved(_ window: NSWindow) -> Notification {
        Notification(name: NSWindow.didMoveNotification, object: window)
    }

    @Test(arguments: [true, false])
    func bothFeaturesShareOneStandInWhicheverComesFirst(attachmentFirst: Bool) {
        let swiftUI = SwiftUIDelegate(log: log)
        let window = makeWindow(delegate: swiftUI)
        let attachment = Feature("attachment", log: log)
        let aspect = Feature("aspect", log: log)
        aspect.resizeWidth = 320
        let order: [Feature] = attachmentFirst ? [attachment, aspect] : [aspect, attachment]

        let first = WindowDelegateInterposer.install(on: window)
        first.register(order[0])
        let second = WindowDelegateInterposer.install(on: window)
        second.register(order[1])

        #expect(first === second)
        #expect(window.delegate === first)
        #expect(first.forwardedDelegate === swiftUI)

        // What the features handle reaches each of them, then SwiftUI's delegate.
        #expect(window.delegate?.windowShouldClose?(window) == true)
        let size = window.delegate?.windowWillResize?(window, to: NSSize(width: 500, height: 300))
        #expect(size?.width == 320)
        window.delegate?.windowDidEnterFullScreen?(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        // What they do not handle goes straight to SwiftUI's.
        window.delegate?.windowDidMove?(moved(window))

        let names = order.map(\.name)
        #expect(log.calls == [
            "\(names[0]) shouldClose", "\(names[1]) shouldClose", "swiftui shouldClose",
            "\(names[0]) willResize 500", "\(names[1]) willResize \(attachmentFirst ? 500 : 320)", "swiftui willResize 320",
            "\(names[0]) didEnterFullScreen", "\(names[1]) didEnterFullScreen", "swiftui didEnterFullScreen",
            "swiftui didMove",
        ])
    }

    @Test func aFeatureThatRefusesKeepsTheWindowOpenWithoutAskingSwiftUI() {
        let swiftUI = SwiftUIDelegate(log: log)
        let window = makeWindow(delegate: swiftUI)
        let attachment = Feature("attachment", log: log)
        attachment.refusesClose = true
        WindowDelegateInterposer.install(on: window).register(attachment)

        #expect(window.delegate?.windowShouldClose?(window) == false)
        #expect(log.calls == ["attachment shouldClose"])

        // And SwiftUI's own answer stands when every feature agrees.
        attachment.refusesClose = false
        swiftUI.allowsClose = false
        log.calls.removeAll()
        #expect(window.delegate?.windowShouldClose?(window) == false)
        #expect(log.calls == ["attachment shouldClose", "swiftui shouldClose"])
    }

    @Test func detachingTheLastFeaturePutsSwiftUIsDelegateBack() {
        let swiftUI = SwiftUIDelegate(log: log)
        let window = makeWindow(delegate: swiftUI)
        let attachment = Feature("attachment", log: log)
        let aspect = Feature("aspect", log: log)
        let interposer = WindowDelegateInterposer.install(on: window)
        interposer.register(attachment)
        interposer.register(aspect)

        interposer.unregister(aspect)
        #expect(window.delegate === interposer)
        _ = window.delegate?.windowShouldClose?(window)
        #expect(log.calls == ["attachment shouldClose", "swiftui shouldClose"])

        interposer.unregister(attachment)
        #expect(window.delegate === swiftUI)
        #expect(WindowDelegateInterposer.installed(on: window) == nil)
        #expect(interposer.forwardedDelegate == nil)
    }

    @Test func aFeatureThatHasGoneIsSkippedAndSwiftUIStillHearsEverything() {
        weak var weakSwiftUI: SwiftUIDelegate?
        weak var weakFeature: Feature?
        let window: NSWindow
        do {
            let swiftUI = SwiftUIDelegate(log: log)
            weakSwiftUI = swiftUI
            window = makeWindow(delegate: swiftUI)
            let feature = Feature("aspect", log: log)
            weakFeature = feature
            WindowDelegateInterposer.install(on: window).register(feature)
        }
        // The feature's view has gone without detaching; SwiftUI's delegate is held while the
        // interposer stands in front of it (in the app SwiftUI holds it too).
        #expect(weakFeature == nil)
        #expect(weakSwiftUI != nil)

        // Each of these used to be sent on to a forwarding target that had gone.
        #expect(window.delegate?.windowShouldClose?(window) == true)
        window.delegate?.windowDidMove?(moved(window))
        #expect(log.calls == ["swiftui shouldClose", "swiftui didMove"])
    }

    @Test func closingTheWindowTellsSwiftUIOnceThenPutsItsDelegateBack() async {
        let swiftUI = SwiftUIDelegate(log: log)
        let window = makeWindow(delegate: swiftUI)
        let attachment = Feature("attachment", log: log)
        let interposer = WindowDelegateInterposer.install(on: window)
        interposer.register(attachment)

        window.close()
        #expect(log.calls == ["swiftui willClose"])

        // Put back once the close has been delivered.
        for _ in 0..<10 where WindowDelegateInterposer.installed(on: window) != nil {
            await Task.yield()
        }
        #expect(window.delegate === swiftUI)
        #expect(WindowDelegateInterposer.installed(on: window) == nil)
        #expect(log.calls == ["swiftui willClose"])

        // The feature's view going afterwards finds nothing left to undo.
        WindowDelegateInterposer.installed(on: window)?.unregister(attachment)
        #expect(window.delegate === swiftUI)
    }

    @Test func aDelegateSetAfterwardsIsStoodInFrontOfAgain() {
        let swiftUI = SwiftUIDelegate(log: log)
        let window = makeWindow(delegate: swiftUI)
        let interposer = WindowDelegateInterposer.install(on: window)
        interposer.register(Feature("attachment", log: log))

        let replacement = SwiftUIDelegate(log: log)
        window.delegate = replacement
        #expect(WindowDelegateInterposer.install(on: window) === interposer)
        #expect(window.delegate === interposer)
        #expect(interposer.forwardedDelegate === replacement)
    }
}
