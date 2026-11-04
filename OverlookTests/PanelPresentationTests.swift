import Foundation
import Testing
@testable import Overlook

@MainActor
@Suite("Panel presentation")
struct PanelPresentationTests {
    let scratch = ScratchDefaults()

    private func makePanels() -> PanelPresentation {
        PanelPresentation(defaults: scratch.defaults)
    }

    // MARK: - One panel at a time

    @Test func startsWithNothingOpenAndNoSession() {
        let panels = makePanels()
        #expect(panels.openPanel == nil)
        #expect(panels.isAnyOpen == false)
        #expect(panels.isSessionActive == false)
    }

    @Test func showingAPanelReplacesTheOneOpen() {
        let panels = makePanels()
        panels.show(.connections)
        panels.show(.log)
        #expect(panels.openPanel == .log)
        #expect(panels.isOpen(.log))
        #expect(panels.isOpen(.connections) == false)
    }

    @Test func toggleOpensThenCloses() {
        let panels = makePanels()
        panels.toggle(.settings)
        #expect(panels.openPanel == .settings)
        panels.toggle(.settings)
        #expect(panels.openPanel == nil)
    }

    @Test func toggleSwitchesFromAnotherPanel() {
        let panels = makePanels()
        panels.show(.connections)
        panels.toggle(.log)
        #expect(panels.openPanel == .log)
    }

    @Test func closeIfOpenLeavesOtherPanelsAlone() {
        let panels = makePanels()
        panels.show(.log)
        panels.closeIfOpen(.connections)
        #expect(panels.openPanel == .log)
        panels.closeIfOpen(.log)
        #expect(panels.openPanel == nil)
    }

    @Test func presentedBindingReadsAndWritesOnePanel() {
        let panels = makePanels()
        let settings = panels.isPresented(.settings)
        #expect(settings.wrappedValue == false)

        settings.wrappedValue = true
        #expect(panels.openPanel == .settings)

        // Dismissing a panel that is no longer the open one must not close its replacement.
        panels.show(.log)
        settings.wrappedValue = false
        #expect(panels.openPanel == .log)

        panels.isPresented(.log).wrappedValue = false
        #expect(panels.openPanel == nil)
    }

    // MARK: - What needs a session

    @Test func onlySettingsNeedsASession() {
        let panels = makePanels()
        #expect(panels.isEnabled(.connections))
        #expect(panels.isEnabled(.log))
        #expect(panels.isEnabled(.settings) == false)

        panels.isSessionActive = true
        #expect(panels.isEnabled(.settings))
    }

    @Test func menuTitlesAreStable() {
        #expect(PanelPresentation.Panel.allCases.map(\.menuTitle) == [
            "Show Connections Panel", "Show Log Panel", "Show Settings Panel",
        ])
        #expect(PanelPresentation.Panel.allCases.map(\.title) == ["Connections", "Connection Log", "Settings"])
    }

    // MARK: - Width

    @Test func widthDefaultsWhenNeverSaved() {
        #expect(makePanels().width == PanelPresentation.defaultWidth)
    }

    // Literals rather than `maxWidth` / `minWidth`: the arguments are evaluated off the main
    // actor, and the bounds are pinned by `clampLeavesSomeVideoVisible` below.
    @Test(arguments: [
        (500.0, 500.0),
        (5_000.0, 1_000.0),
        (120.0, 300.0),
    ])
    func savedWidthIsClampedOnLoad(saved: Double, expected: Double) {
        scratch.defaults.set(saved, forKey: "OverlookPanelWidth")
        #expect(makePanels().width == expected)
    }

    @Test func widthIsWrittenOnlyWhenPersisted() {
        let panels = makePanels()
        panels.width = 600
        #expect(scratch.defaults.object(forKey: "OverlookPanelWidth") == nil)

        panels.persistWidth()
        #expect(scratch.defaults.double(forKey: "OverlookPanelWidth") == 600)
        #expect(makePanels().width == 600)
    }

    @Test func resetReturnsToTheDefaultAndSavesIt() {
        let panels = makePanels()
        panels.width = 900
        panels.resetWidth()
        #expect(panels.width == PanelPresentation.defaultWidth)
        #expect(scratch.defaults.double(forKey: "OverlookPanelWidth") == PanelPresentation.defaultWidth)
    }

    @Test func clampLeavesSomeVideoVisible() {
        #expect(PanelPresentation.minWidth == 300)
        #expect(PanelPresentation.maxWidth == 1_000)
        // The panel never takes more than the window minus 160 points...
        #expect(PanelPresentation.clampWidth(900, available: 800) == 640)
        // ...but never goes below its minimum, even in a narrow window.
        #expect(PanelPresentation.clampWidth(900, available: 350) == PanelPresentation.minWidth)
        #expect(PanelPresentation.clampWidth(400, available: nil) == 400)
    }
}
