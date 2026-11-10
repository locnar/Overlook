import AppKit
import Foundation
import Testing
@testable import Overlook

/// What a scroll event on the video becomes on its way to the target.
///
/// No manager here has a device: what it would send is read from `sentInputObserver`, and the
/// HID socket's wheel report is checked through `InputManager.glkvmWheelDeltas`. Trackpad
/// scaling is checked on `ScrollAccumulator` alone, then through the manager.
///
/// `ScrollAccumulator` works in the Mac's direction (positive X scrolls left); what the manager
/// sends is in the target's (positive X pans right), so X changes sign on the way through and Y
/// does not. See `InputManager.targetScrollSteps`.
@MainActor
@Suite("Scroll scaling")
struct ScrollScalingTests {
    private static let window = 9_201

    @MainActor
    private final class Capture {
        let scratch = ScratchDefaults()
        let input: InputManager
        var sent: [InputManager.SentInput] = []

        init() {
            input = InputManager(defaults: scratch.defaults, log: SessionLog(destination: .inMemory()))
            input.sentInputObserver = { [unowned self] in self.sent.append($0) }
            input.startMouseCapture()
            input.windowDidBecomeKey(windowNumber: ScrollScalingTests.window)
        }
    }

    // MARK: - The HID wheel report

    private func wheel(_ deltaX: CGFloat, _ deltaY: CGFloat) -> [Int] {
        let report = InputManager.glkvmWheelDeltas(deltaX: deltaX, deltaY: deltaY)
        return [report.x, report.y]
    }

    @Test func aNotchedWheelLineIsOneWheelStep() {
        #expect(wheel(0, 1) == [0, 1])
        #expect(wheel(0, -1) == [0, -1])
        #expect(wheel(0, 3) == [0, 3])
        #expect(wheel(-2, 0) == [-2, 0])
    }

    @Test func fractionalDeltasRoundToTheNearestStep() {
        #expect(wheel(0.4, -0.4) == [0, 0])
        #expect(wheel(0.5, -0.5) == [1, -1])
        #expect(wheel(1.6, -2.6) == [2, -3])
    }

    @Test func theReportIsClampedToASignedByte() {
        #expect(wheel(300, -300) == [127, -127])
        #expect(wheel(127, -127) == [127, -127])
    }

    // MARK: - Through the input manager

    @Test func aNotchedScrollGoesOutAsWholeSteps() {
        let c = Capture()
        c.input.handleVideoMouseScroll(ScrollWheelInput(deltaX: 1.5, deltaY: -2.25))
        c.input.handleVideoMouseScroll(ScrollWheelInput(deltaX: 0.4, deltaY: -1.3, lineDeltaX: 1, lineDeltaY: -2))

        // X goes out with the target's sign: two and one steps left on the Mac, -2 and -1 pan.
        #expect(c.sent == [.scroll(deltaX: -2, deltaY: -2), .scroll(deltaX: -1, deltaY: -2)])
    }

    @Test func aSlowNotchReachesTheTarget() {
        // Rounded as it arrives, a slow notch's fraction of a line was a report of nothing.
        #expect(wheel(0, 0.1) == [0, 0])
        #expect(wheel(0, -0.4) == [0, 0])

        let c = Capture()
        c.input.handleVideoMouseScroll(ScrollWheelInput(deltaX: 0, deltaY: 0.1, lineDeltaX: 0, lineDeltaY: 1))
        c.input.handleVideoMouseScroll(ScrollWheelInput(deltaX: 0, deltaY: -0.4, lineDeltaX: 0, lineDeltaY: -1))
        c.input.handleVideoMouseScroll(ScrollWheelInput(deltaX: 0, deltaY: 0.2, lineDeltaX: 0, lineDeltaY: 0))

        #expect(c.sent == [
            .scroll(deltaX: 0, deltaY: 1),
            .scroll(deltaX: 0, deltaY: -1),
            .scroll(deltaX: 0, deltaY: 1),
        ])
        #expect(reports(c.sent) == [[0, 1], [0, -1], [0, 1]])
    }

    @Test func aHugeLineDeltaIsClampedInTheReport() {
        let c = Capture()
        c.input.handleVideoMouseScroll(ScrollWheelInput(deltaX: -90, deltaY: 90, lineDeltaX: -500, lineDeltaY: 500))

        // 500 lines right on the Mac is a pan of +500 on the target, clamped to +127.
        #expect(c.sent == [.scroll(deltaX: 500, deltaY: 500)])
        #expect(reports(c.sent) == [[127, 127]])
    }

    @Test func nothingIsSentWithoutMouseCapture() {
        let c = Capture()
        c.input.stopMouseCapture()
        c.input.handleVideoMouseScroll(ScrollWheelInput(deltaX: 0, deltaY: 1))

        #expect(c.sent.isEmpty)
    }

    @Test func relativeModeSendsNothingUntilThePointerIsLocked() {
        let c = Capture()
        c.input.setGLKVMAbsoluteMouseMode(false)
        #expect(c.input.isRelativeMouseMode)
        #expect(c.input.isPointerLocked == false)

        c.input.handleVideoMouseScroll(ScrollWheelInput(deltaX: 0, deltaY: 1))

        #expect(c.sent.isEmpty)
    }

    @Test func aNotchedWheelStillGoesOutUnchanged() {
        let c = Capture()
        c.input.handleVideoMouseScroll(ScrollWheelInput(deltaX: 0, deltaY: 1))
        c.input.handleVideoMouseScroll(ScrollWheelInput(deltaX: 0, deltaY: -3))
        c.input.handleVideoMouseScroll(ScrollWheelInput(deltaX: 2, deltaY: 0))

        // Unscaled: the same number of steps, with X in the target's direction.
        #expect(c.sent == [
            .scroll(deltaX: 0, deltaY: 1),
            .scroll(deltaX: 0, deltaY: -3),
            .scroll(deltaX: -2, deltaY: 0),
        ])
    }

    @Test func aTrackpadGestureGoesOutAsWholeWheelSteps() {
        let c = Capture()
        // 20 events of 2.5 points: 50 points, five wheel steps, one each time ten points add up.
        c.input.handleVideoMouseScroll(precise(0, 2.5, at: 0, phase: .began))
        for i in 1..<20 {
            c.input.handleVideoMouseScroll(precise(0, 2.5, at: Double(i) * 0.01, phase: .changed))
        }

        #expect(c.sent == Array(repeating: .scroll(deltaX: 0, deltaY: 1), count: 5))
    }

    @Test func aTrackpadFlickIsCappedThroughTheManager() {
        let c = Capture()
        c.input.handleVideoMouseScroll(precise(-400, 300, at: 0, phase: .began))

        let cap = CGFloat(ScrollAccumulator.maxStepsPerEvent)
        // 400 points right on the Mac, capped, is a pan of +cap on the target.
        #expect(c.sent == [.scroll(deltaX: cap, deltaY: cap)])
    }

    // MARK: - ScrollAccumulator

    private func precise(
        _ deltaX: CGFloat,
        _ deltaY: CGFloat,
        at time: TimeInterval,
        phase: NSEvent.Phase = .changed,
        momentum: NSEvent.Phase = [],
        inverted: Bool = false
    ) -> ScrollWheelInput {
        ScrollWheelInput(
            deltaX: deltaX,
            deltaY: deltaY,
            hasPreciseDeltas: true,
            phase: phase,
            momentumPhase: momentum,
            timestamp: time,
            invertedFromDevice: inverted
        )
    }

    /// Feeds `inputs` in order and returns the steps sent for each, `[0, 0]` where nothing went out.
    private func steps(_ inputs: [ScrollWheelInput], into accumulator: inout ScrollAccumulator) -> [[CGFloat]] {
        inputs.map { input in
            guard let out = accumulator.add(input) else { return [0, 0] }
            return [out.deltaX, out.deltaY]
        }
    }

    private func steps(_ inputs: [ScrollWheelInput]) -> [[CGFloat]] {
        var accumulator = ScrollAccumulator()
        return steps(inputs, into: &accumulator)
    }

    @Test func manySmallPreciseDeltasMakeProportionalSteps() {
        // 120 events of 1.25 points: 150 points in all.
        let inputs = (0..<120).map { precise(0, 1.25, at: Double($0) * 0.008, phase: $0 == 0 ? .began : .changed) }

        let out = steps(inputs)
        let total = out.reduce(0) { $0 + $1[1] }

        #expect(total == 150 / ScrollAccumulator.pointsPerStep)
        #expect(out.allSatisfy { $0[1] == 0 || $0[1] == 1 })
        #expect(out.allSatisfy { $0[0] == 0 })
    }

    @Test func theDefaultScaleIsTenPointsPerStep() {
        #expect(ScrollAccumulator.pointsPerStep == 10)
        #expect(ScrollAccumulator.maxStepsPerEvent == 5)
        #expect(ScrollAccumulator.idleReset == 0.25)
        #expect(steps([precise(0, 7.5, at: 0), precise(0, 2.5, at: 0.01)]) == [[0, 0], [0, 1]])
    }

    @Test func theRemainderCarriesOverToTheNextEvent() {
        var accumulator = ScrollAccumulator()
        let out = steps([
            precise(0, 12.5, at: 0, phase: .began),
            precise(0, 5, at: 0.01),
            precise(0, 2.5, at: 0.02),
        ], into: &accumulator)

        #expect(out == [[0, 1], [0, 0], [0, 1]])
        #expect(accumulator.pendingY == 0)
    }

    @Test func negativeDeltasStepTheOtherWay() {
        #expect(steps([
            precise(-6, -6, at: 0, phase: .began),
            precise(-6, -6, at: 0.01),
        ]) == [[0, 0], [-1, -1]])
    }

    @Test func reversingDirectionDropsWhatWasPending() {
        var accumulator = ScrollAccumulator()
        let out = steps([
            precise(0, 9, at: 0, phase: .began),
            // Without the reset this would cancel the 9 points down and send nothing.
            precise(0, -9, at: 0.01),
            precise(0, -1, at: 0.02),
        ], into: &accumulator)

        #expect(out == [[0, 0], [0, 0], [0, -1]])
    }

    @Test func aReversalOnOneAxisLeavesTheOtherAlone() {
        let out = steps([
            precise(6, 6, at: 0, phase: .began),
            precise(-1, 6, at: 0.01),
        ])

        #expect(out == [[0, 0], [0, 1]])
    }

    @Test func theEndOfAGestureDropsWhatWasPending() {
        var accumulator = ScrollAccumulator()
        let out = steps([
            precise(0, 9, at: 0, phase: .began),
            precise(0, 0, at: 0.01, phase: .ended),
            precise(0, 2, at: 0.02, phase: .began),
        ], into: &accumulator)

        #expect(out == [[0, 0], [0, 0], [0, 0]])
        #expect(accumulator.pendingY == 0.2)
    }

    @Test func aCancelledGestureDropsWhatWasPending() {
        #expect(steps([
            precise(0, 9, at: 0, phase: .began),
            precise(0, 0, at: 0.01, phase: .cancelled),
            precise(0, 2, at: 0.02),
        ]) == [[0, 0], [0, 0], [0, 0]])
    }

    @Test func aNewTouchStartsFromNothing() {
        #expect(steps([
            precise(0, 9, at: 0),
            precise(0, 0, at: 0.01, phase: .mayBegin),
            precise(0, 2, at: 0.02, phase: .began),
        ]) == [[0, 0], [0, 0], [0, 0]])
    }

    @Test func momentumStartsFreshAndEndsTheGesture() {
        var accumulator = ScrollAccumulator()
        let out = steps([
            precise(0, 9, at: 0, phase: .changed),
            precise(0, 5, at: 0.01, phase: [], momentum: .began),
            precise(0, 8, at: 0.02, phase: [], momentum: .changed),
            precise(0, 9, at: 0.03, phase: [], momentum: .changed),
            precise(0, 0, at: 0.04, phase: [], momentum: .ended),
        ], into: &accumulator)

        #expect(out == [[0, 0], [0, 0], [0, 1], [0, 1], [0, 0]])
        #expect(accumulator.pendingY == 0)
    }

    @Test func anIdlePauseDropsWhatWasPending() {
        let gap = ScrollAccumulator.idleReset
        #expect(steps([
            precise(0, 9, at: 1),
            precise(0, 2, at: 1 + gap + 0.01),
        ]) == [[0, 0], [0, 0]])
        #expect(steps([
            precise(0, 9, at: 1),
            precise(0, 2, at: 1 + gap - 0.01),
        ]) == [[0, 0], [0, 1]])
    }

    @Test func aFastFlickIsCappedAndTheExcessDropped() {
        var accumulator = ScrollAccumulator()
        let cap = CGFloat(ScrollAccumulator.maxStepsPerEvent)
        let out = steps([
            precise(0, 1_000.5, at: 0, phase: .began),
            precise(0, -1_000, at: 0.01),
        ], into: &accumulator)

        #expect(out == [[0, cap], [0, -cap]])
        #expect(accumulator.pendingY == 0)
    }

    @Test func withoutLineDeltasANotchRoundsButNeverToNothing() {
        #expect(steps([
            ScrollWheelInput(deltaX: 0, deltaY: 1),
            ScrollWheelInput(deltaX: 0, deltaY: -1),
            ScrollWheelInput(deltaX: 0.4, deltaY: 7.5),
            ScrollWheelInput(deltaX: -0.1, deltaY: 2.4),
            ScrollWheelInput(deltaX: 0, deltaY: 300),
        ]) == [[0, 1], [0, -1], [1, 8], [-1, 2], [0, 300]])
    }

    // MARK: - Notched wheel steps

    private func notched(
        _ deltaX: CGFloat, _ deltaY: CGFloat, lines lineX: Int?, _ lineY: Int?
    ) -> [Int] {
        let out = ScrollAccumulator.notchedSteps(
            ScrollWheelInput(deltaX: deltaX, deltaY: deltaY, lineDeltaX: lineX, lineDeltaY: lineY)
        )
        return [out.x, out.y]
    }

    @Test func aSlowNotchIsOneStepFromItsWholeLine() {
        #expect(notched(0, 0.1, lines: 0, 1) == [0, 1])
        #expect(notched(0, 0.4, lines: 0, 1) == [0, 1])
    }

    @Test func aSlowNotchWithNoWholeLineIsStillOneStep() {
        #expect(notched(0, 0.2, lines: 0, 0) == [0, 1])
        #expect(notched(0, -0.2, lines: 0, 0) == [0, -1])
        #expect(notched(0, 0.2, lines: nil, nil) == [0, 1])
    }

    @Test func aSlowNotchDownIsOneStepDown() {
        #expect(notched(0, -0.1, lines: 0, -1) == [0, -1])
        #expect(notched(0, -0.35, lines: 0, -1) == [0, -1])
    }

    @Test func aFastSpinSendsItsWholeLines() {
        #expect(notched(0, 4.7, lines: 0, 6) == [0, 6])
        #expect(notched(0, -4.7, lines: 0, -6) == [0, -6])
        // The whole lines win even when the fraction would round higher.
        #expect(notched(0, 2.6, lines: 0, 2) == [0, 2])
    }

    @Test func aHorizontalNotchStepsX() {
        #expect(notched(0.15, 0, lines: 1, 0) == [1, 0])
        #expect(notched(-0.4, 0, lines: 0, 0) == [-1, 0])
        #expect(notched(-3.2, 0, lines: -4, 0) == [-4, 0])
    }

    @Test func bothAxesStepTogether() {
        #expect(notched(-0.1, 0.3, lines: -1, 2) == [-1, 2])
        #expect(notched(0.2, -0.2, lines: 0, 0) == [1, -1])
    }

    @Test func aZeroNotchedEventSendsNothing() {
        #expect(notched(0, 0, lines: 0, 0) == [0, 0])
        #expect(notched(0, 0, lines: nil, nil) == [0, 0])
        #expect(steps([ScrollWheelInput(deltaX: 0, deltaY: 0, lineDeltaX: 0, lineDeltaY: 0)]) == [[0, 0]])
        #expect(notched(.nan, .infinity, lines: nil, nil) == [0, 0])
    }

    @Test func wholeLinesWithNoFractionStillStep() {
        #expect(notched(0, 0, lines: 0, 3) == [0, 3])
    }

    @Test func aDisagreeingSignFollowsTheScrollingDelta() {
        #expect(notched(0, -0.3, lines: 0, 2) == [0, -2])
        #expect(notched(0.3, 0, lines: -1, 0) == [1, 0])
    }

    @Test func aPreciseEventIgnoresLineDeltas() {
        let precise = ScrollWheelInput(
            deltaX: 0, deltaY: 2.5, hasPreciseDeltas: true, phase: .began, lineDeltaX: 0, lineDeltaY: 5
        )
        var accumulator = ScrollAccumulator()
        #expect(accumulator.add(precise) == nil)
        #expect(accumulator.pendingY == 0.25)
    }

    @Test func aNotchedWheelEventClearsPreciseLeftovers() {
        var accumulator = ScrollAccumulator()
        let out = steps([
            precise(0, 9, at: 0),
            ScrollWheelInput(deltaX: 0, deltaY: 1, timestamp: 0.01),
            precise(0, 2, at: 0.02),
        ], into: &accumulator)

        #expect(out == [[0, 0], [0, 1], [0, 0]])
    }

    @Test func theAxesAccumulateIndependently() {
        var accumulator = ScrollAccumulator()
        let out = steps([
            precise(4, 7, at: 0, phase: .began),
            precise(4, 7, at: 0.01),
            precise(4, 0, at: 0.02),
        ], into: &accumulator)

        #expect(out == [[0, 0], [0, 1], [1, 0]])
        #expect(abs(accumulator.pendingX - 0.2) < 1e-9)
        #expect(abs(accumulator.pendingY - 0.4) < 1e-9)
    }

    @Test func zeroDeltasSendNothing() {
        #expect(steps([
            precise(0, 0, at: 0, phase: .mayBegin),
            precise(0, 0, at: 0.01, phase: .began),
            precise(0, 0, at: 0.02, phase: .ended),
            ScrollWheelInput(deltaX: 0, deltaY: 0),
        ]) == [[0, 0], [0, 0], [0, 0], [0, 0]])
    }

    @Test func aZeroDeltaOnOneAxisKeepsThatAxisPending() {
        #expect(steps([
            precise(0, 6, at: 0, phase: .began),
            precise(3, 0, at: 0.01),
            precise(0, 6, at: 0.02),
        ]) == [[0, 0], [0, 0], [0, 1]])
    }

    // MARK: - From the NSEvent

    @Test func aPixelScrollEventIsPreciseWithItsPhase() throws {
        let cg = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -12, wheel2: 3, wheel3: 0
        ))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue))
        let event = try #require(NSEvent(cgEvent: cg))

        let input = ScrollWheelInput(event: event)

        #expect(input.hasPreciseDeltas)
        #expect(input.phase == .began)
        #expect(input.momentumPhase == [])
        #expect(input.deltaY < 0)
        #expect(input.deltaX > 0)
    }

    @Test func aLineScrollEventIsNotPrecise() throws {
        let cg = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0
        ))
        let event = try #require(NSEvent(cgEvent: cg))

        let input = ScrollWheelInput(event: event)

        #expect(input.hasPreciseDeltas == false)
        #expect(input.phase == [])
        #expect(input.deltaY > 0)
    }

    // MARK: - A line event, end to end

    /// A notched wheel's event as a source builds it: whole lines on each axis (axis 1 vertical,
    /// axis 2 horizontal), with no acceleration.
    private func lineEvent(vertical: Int32, horizontal: Int32 = 0) throws -> CGEvent {
        try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0
        ))
    }

    /// The HID wheel reports for what `sent` holds, in order.
    private func reports(_ sent: [InputManager.SentInput]) -> [[Int]] {
        sent.compactMap {
            guard case let .scroll(deltaX, deltaY) = $0 else { return nil }
            return wheel(deltaX, deltaY)
        }
    }

    @Test func aLineEventScrollsTheTargetTheWayTheMacWould() throws {
        let c = Capture()
        let lines: [(vertical: Int32, horizontal: Int32)] = [(1, 0), (-1, 0), (0, 1), (0, -1), (2, -3)]
        for line in lines {
            let event = try #require(NSEvent(cgEvent: try lineEvent(vertical: line.vertical, horizontal: line.horizontal)))
            c.input.handleVideoMouseScroll(ScrollWheelInput(event: event))
        }

        // The vertical line goes out as Y with its own sign: up on the Mac (positive) is up in
        // HID (positive). The horizontal line goes out as X with its sign flipped: positive
        // `scrollingDeltaX` is left on the Mac, but positive HID AC Pan is right. Sent unflipped,
        // as this test once pinned, the target scrolled sideways backwards.
        #expect(reports(c.sent) == [[0, 1], [0, -1], [-1, 0], [1, 0], [3, 2]])
    }

    // MARK: - Horizontal direction

    /// The wheel report for each line event fed through a fresh manager, in order.
    private func reportsForLineEvents(_ lines: [(vertical: Int32, horizontal: Int32)]) throws -> [[Int]] {
        let c = Capture()
        for line in lines {
            let event = try #require(NSEvent(cgEvent: try lineEvent(vertical: line.vertical, horizontal: line.horizontal)))
            c.input.handleVideoMouseScroll(ScrollWheelInput(event: event))
        }
        return reports(c.sent)
    }

    @Test func onlyXChangesSignOnTheWayToTheTarget() {
        func target(_ x: CGFloat, _ y: CGFloat) -> [CGFloat] {
            let out = InputManager.targetScrollSteps(macDeltaX: x, macDeltaY: y)
            return [out.deltaX, out.deltaY]
        }
        #expect(target(1, 1) == [-1, 1])
        #expect(target(-3, -2) == [3, -2])
        #expect(target(0, 4) == [0, 4])
    }

    @Test func scrollingLeftIsANegativePan() throws {
        // A positive `scrollingDeltaX` is the Mac scrolling left.
        let event = try #require(NSEvent(cgEvent: try lineEvent(vertical: 0, horizontal: 1)))
        #expect(event.scrollingDeltaX > 0)

        #expect(try reportsForLineEvents([(0, 1), (0, 2)]) == [[-1, 0], [-2, 0]])
    }

    @Test func scrollingRightIsAPositivePan() throws {
        #expect(try reportsForLineEvents([(0, -1), (0, -4)]) == [[1, 0], [4, 0]])
    }

    @Test func verticalScrollingKeepsItsSign() throws {
        #expect(try reportsForLineEvents([(1, 0), (-1, 0), (3, 0), (-5, 0)]) == [[0, 1], [0, -1], [0, 3], [0, -5]])
    }

    @Test func aCombinedEventFlipsOnlyItsX() throws {
        // Up and left on the Mac: up and left on the target, which is +Y and -X in HID.
        #expect(try reportsForLineEvents([(1, 1), (-2, 3), (2, -1)]) == [[-1, 1], [-3, -2], [1, 2]])
    }

    @Test func aTrackpadSwipeFlipsXOnce() {
        let c = Capture()
        // 20 events of 2.5 points to the left on the Mac: five steps, each a pan of -1. Flipped
        // twice, they would come out +1; not flipped at all, the same.
        c.input.handleVideoMouseScroll(precise(2.5, 0, at: 0, phase: .began))
        for i in 1..<20 {
            c.input.handleVideoMouseScroll(precise(2.5, 0, at: Double(i) * 0.01, phase: .changed))
        }

        #expect(c.sent == Array(repeating: .scroll(deltaX: -1, deltaY: 0), count: 5))
        #expect(reports(c.sent) == Array(repeating: [-1, 0], count: 5))
    }

    @Test func aTrackpadEventFromTheNSEventFlipsXOnce() throws {
        let c = Capture()
        // 25 points left and 12 down on the Mac, as a trackpad's pixel event.
        let cg = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -12, wheel2: 25, wheel3: 0
        ))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue))
        let event = try #require(NSEvent(cgEvent: cg))
        c.input.handleVideoMouseScroll(ScrollWheelInput(event: event))

        // Two steps of pan to the left and one down.
        #expect(reports(c.sent) == [[-2, -1]])
    }

    @Test(arguments: [1, -1, 3, -6] as [Int32])
    func aLineEventsWholeLineFieldsMatchItsScrollingDeltas(lines: Int32) throws {
        let vertical = try lineEvent(vertical: lines)
        let horizontal = try lineEvent(vertical: 0, horizontal: lines)
        let up = try #require(NSEvent(cgEvent: vertical))
        let left = try #require(NSEvent(cgEvent: horizontal))

        #expect(vertical.getIntegerValueField(.scrollWheelEventDeltaAxis1) == Int64(lines))
        #expect(vertical.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 0)
        #expect(up.scrollingDeltaY == CGFloat(lines))
        #expect(up.scrollingDeltaX == 0)

        #expect(horizontal.getIntegerValueField(.scrollWheelEventDeltaAxis2) == Int64(lines))
        #expect(horizontal.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0)
        #expect(left.scrollingDeltaX == CGFloat(lines))
        #expect(left.scrollingDeltaY == 0)
    }

    @Test(arguments: [-12, 25, 3, -40] as [Int32])
    func aPixelEventsWholeLineFieldNeverDisagreesWithItsScrollingDelta(pixels: Int32) throws {
        let cg = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: pixels, wheel2: pixels, wheel3: 0
        ))
        let event = try #require(NSEvent(cgEvent: cg))
        let lineY = cg.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let lineX = cg.getIntegerValueField(.scrollWheelEventDeltaAxis2)

        #expect(event.scrollingDeltaY == CGFloat(pixels))
        #expect(event.scrollingDeltaX == CGFloat(pixels))
        // Built in memory, these come out as -1, 2, 1 and -4 lines: never zero, never the other
        // way. Only the sign is pinned here.
        #expect(lineY == 0 || (lineY < 0) == (pixels < 0))
        #expect(lineX == 0 || (lineX < 0) == (pixels < 0))
    }

    @Test func aLineEventCarriesItsWholeLines() throws {
        let event = try #require(NSEvent(cgEvent: try lineEvent(vertical: 1, horizontal: -2)))

        let input = ScrollWheelInput(event: event)

        #expect(input.hasPreciseDeltas == false)
        #expect(input.lineDeltaY == 1)
        #expect(input.lineDeltaX == -2)
        #expect(steps([input]) == [[-2, 1]])
    }

    @Test func aPixelEventCarriesItsWholeLinesButStillScalesByPoints() throws {
        let cg = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -12, wheel2: 25, wheel3: 0
        ))
        let event = try #require(NSEvent(cgEvent: cg))

        let input = ScrollWheelInput(event: event)

        #expect(input.hasPreciseDeltas)
        #expect(input.lineDeltaY == Int(cg.getIntegerValueField(.scrollWheelEventDeltaAxis1)))
        #expect(input.lineDeltaX == Int(cg.getIntegerValueField(.scrollWheelEventDeltaAxis2)))
        // -12 and 25 points: one step down and two to the side, from the points alone.
        #expect(steps([input]) == [[2, -1]])
    }

    @Test func aSlowNotchFromTheEventIsOneStep() throws {
        // One notch that acceleration scaled to a tenth of a line.
        let cg = try lineEvent(vertical: 1)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0.1)
        let event = try #require(NSEvent(cgEvent: cg))

        let input = ScrollWheelInput(event: event)

        #expect(abs(input.deltaY - 0.1) < 0.001)
        #expect(input.lineDeltaY == Int(cg.getIntegerValueField(.scrollWheelEventDeltaAxis1)))
        #expect(steps([input]) == [[0, 1]])
    }

    // MARK: - Natural Scrolling: physical direction out

    // Each case below gives the same physical scroll twice: as macOS hands it over with Natural
    // Scrolling off, and as it hands it over with Natural Scrolling on (both signs flipped,
    // `invertedFromDevice` set). The target must receive the same thing from both.

    @Test func physicalDirectionUndoesNaturalScrollingOnBothAxes() {
        let natural = ScrollWheelInput(
            deltaX: 0.25, deltaY: -3.5, hasPreciseDeltas: true, phase: .changed, timestamp: 4,
            lineDeltaX: 1, lineDeltaY: -4, invertedFromDevice: true
        )

        let physical = natural.physicalDirection

        #expect(physical == ScrollWheelInput(
            deltaX: -0.25, deltaY: 3.5, hasPreciseDeltas: true, phase: .changed, timestamp: 4,
            lineDeltaX: -1, lineDeltaY: 4, invertedFromDevice: false
        ))
        // Missing whole lines stay missing.
        let noLines = ScrollWheelInput(deltaX: 1, deltaY: 2, invertedFromDevice: true).physicalDirection
        #expect(noLines.lineDeltaX == nil && noLines.lineDeltaY == nil)
        #expect([noLines.deltaX, noLines.deltaY] == [-1, -2])
    }

    @Test func physicalDirectionLeavesAnUnflippedEventAlone() {
        let traditional = ScrollWheelInput(
            deltaX: 0.25, deltaY: -3.5, timestamp: 4, lineDeltaX: 1, lineDeltaY: -4, invertedFromDevice: false
        )
        #expect(traditional.physicalDirection == traditional)
    }

    @Test func aNotchedEventReachesTheTargetTheSameWithNaturalScrollingOnOrOff() {
        let off = Capture()
        off.input.handleVideoMouseScroll(ScrollWheelInput(deltaX: 0.2, deltaY: -0.3, lineDeltaX: 1, lineDeltaY: -2))
        off.input.handleVideoMouseScroll(ScrollWheelInput(deltaX: 0, deltaY: 1, lineDeltaX: 0, lineDeltaY: 1))

        let on = Capture()
        on.input.handleVideoMouseScroll(ScrollWheelInput(
            deltaX: -0.2, deltaY: 0.3, lineDeltaX: -1, lineDeltaY: 2, invertedFromDevice: true
        ))
        on.input.handleVideoMouseScroll(ScrollWheelInput(
            deltaX: 0, deltaY: -1, lineDeltaX: 0, lineDeltaY: -1, invertedFromDevice: true
        ))

        // One line left and two down, then one up: X flipped once for HID, Y as it physically went.
        let expected: [InputManager.SentInput] = [.scroll(deltaX: -1, deltaY: -2), .scroll(deltaX: 0, deltaY: 1)]
        #expect(off.sent == expected)
        #expect(on.sent == expected)
        #expect(reports(on.sent) == [[-1, -2], [0, 1]])
    }

    @Test func aTrackpadGestureReachesTheTargetTheSameWithNaturalScrollingOnOrOff() {
        func gesture(_ sign: CGFloat, inverted: Bool) -> [InputManager.SentInput] {
            let c = Capture()
            c.input.handleVideoMouseScroll(precise(sign * 2.5, sign * 2.5, at: 0, phase: .began, inverted: inverted))
            for i in 1..<20 {
                c.input.handleVideoMouseScroll(
                    precise(sign * 2.5, sign * 2.5, at: Double(i) * 0.01, phase: .changed, inverted: inverted)
                )
            }
            return c.sent
        }

        // 50 points left and up, physically: five steps, each a pan of -1 and a wheel of +1.
        let expected = Array(repeating: InputManager.SentInput.scroll(deltaX: -1, deltaY: 1), count: 5)
        #expect(gesture(1, inverted: false) == expected)
        #expect(gesture(-1, inverted: true) == expected)
    }

    @Test func theHorizontalFlipStillHappensOnceWithNaturalScrollingOn() {
        let c = Capture()
        // Physically one line left (Mac-traditional +1): macOS hands it over as -1, flagged.
        c.input.handleVideoMouseScroll(ScrollWheelInput(deltaX: -1, deltaY: 0, lineDeltaX: -1, lineDeltaY: 0, invertedFromDevice: true))
        // Physically one line right.
        c.input.handleVideoMouseScroll(ScrollWheelInput(deltaX: 1, deltaY: 0, lineDeltaX: 1, lineDeltaY: 0, invertedFromDevice: true))

        #expect(reports(c.sent) == [[-1, 0], [1, 0]])
    }

    @Test func aReversalWithNaturalScrollingOnStillDropsWhatWasPending() {
        let c = Capture()
        c.input.handleVideoMouseScroll(precise(0, -9, at: 0, phase: .began, inverted: true))
        // Without the reset this would cancel the 9 points and send nothing.
        c.input.handleVideoMouseScroll(precise(0, 9, at: 0.01, inverted: true))
        c.input.handleVideoMouseScroll(precise(0, 1, at: 0.02, inverted: true))

        // Physically 9 points up, then 10 down: one step down.
        #expect(c.sent == [.scroll(deltaX: 0, deltaY: -1)])
    }

    @Test func momentumWithNaturalScrollingOnStartsFreshAndEndsTheGesture() {
        let c = Capture()
        for input in [
            precise(0, -9, at: 0, phase: .changed, inverted: true),
            precise(0, -5, at: 0.01, phase: [], momentum: .began, inverted: true),
            precise(0, -8, at: 0.02, phase: [], momentum: .changed, inverted: true),
            precise(0, -9, at: 0.03, phase: [], momentum: .changed, inverted: true),
            precise(0, 0, at: 0.04, phase: [], momentum: .ended, inverted: true),
        ] {
            c.input.handleVideoMouseScroll(input)
        }

        // As `momentumStartsFreshAndEndsTheGesture`, physically up: the 9 points before momentum
        // are dropped, and momentum's 22 points send two steps.
        #expect(c.sent == [.scroll(deltaX: 0, deltaY: 1), .scroll(deltaX: 0, deltaY: 1)])
    }

    /// The field behind `NSEvent.isDirectionInvertedFromDevice`. It is not a public
    /// `CGEventField`: a run that set every field from 100 to 255 on a scroll event found that
    /// 137, and only 137, turns the flag on. Only these tests use it, to build the event macOS
    /// delivers with Natural Scrolling on; the app reads the public NSEvent property.
    private static let directionInvertedField = CGEventField(rawValue: 137)!

    /// `cg` as macOS delivers it with Natural Scrolling on: both axes flipped and the flag set.
    private func flippedForNaturalScrolling(_ cg: CGEvent) -> CGEvent {
        for (whole, fixed, point) in [
            (CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventFixedPtDeltaAxis1,
             CGEventField.scrollWheelEventPointDeltaAxis1),
            (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2),
        ] {
            // Read all three first: setting one of them can recompute the others.
            let values = (cg.getIntegerValueField(whole), cg.getDoubleValueField(fixed), cg.getIntegerValueField(point))
            cg.setIntegerValueField(whole, value: -values.0)
            cg.setDoubleValueField(fixed, value: -values.1)
            cg.setIntegerValueField(point, value: -values.2)
        }
        cg.setIntegerValueField(Self.directionInvertedField, value: 1)
        return cg
    }

    @Test func theEventsInvertedFlagIsCaptured() throws {
        let plain = try #require(NSEvent(cgEvent: try lineEvent(vertical: 1)))
        let natural = try #require(NSEvent(cgEvent: flippedForNaturalScrolling(try lineEvent(vertical: 1))))

        #expect(plain.isDirectionInvertedFromDevice == false)
        #expect(ScrollWheelInput(event: plain).invertedFromDevice == false)
        #expect(natural.isDirectionInvertedFromDevice)
        #expect(natural.scrollingDeltaY < 0)
        let input = ScrollWheelInput(event: natural)
        #expect(input.invertedFromDevice)
        #expect(input.lineDeltaY == -1)
        #expect(input.physicalDirection.lineDeltaY == 1)
        #expect(input.physicalDirection.deltaY > 0)
    }

    @Test func aLineEventFromTheNSEventReachesTheTargetTheSameWithNaturalScrollingOnOrOff() throws {
        let lines: [(vertical: Int32, horizontal: Int32)] = [(1, 0), (0, 1), (-2, 3)]
        let off = Capture()
        let on = Capture()
        for line in lines {
            let plain = try lineEvent(vertical: line.vertical, horizontal: line.horizontal)
            let natural = flippedForNaturalScrolling(try lineEvent(vertical: line.vertical, horizontal: line.horizontal))
            off.input.handleVideoMouseScroll(ScrollWheelInput(event: try #require(NSEvent(cgEvent: plain))))
            on.input.handleVideoMouseScroll(ScrollWheelInput(event: try #require(NSEvent(cgEvent: natural))))
        }

        // Up; left (X flipped once); down two and left three.
        #expect(reports(off.sent) == [[0, 1], [-1, 0], [-3, -2]])
        #expect(reports(on.sent) == reports(off.sent))
    }

    @Test func aTrackpadEventFromTheNSEventReachesTheTargetTheSameWithNaturalScrollingOnOrOff() throws {
        func pixelEvent() throws -> CGEvent {
            let cg = try #require(CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -12, wheel2: 25, wheel3: 0
            ))
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue))
            return cg
        }
        let off = Capture()
        off.input.handleVideoMouseScroll(ScrollWheelInput(event: try #require(NSEvent(cgEvent: try pixelEvent()))))
        let natural = try #require(NSEvent(cgEvent: flippedForNaturalScrolling(try pixelEvent())))
        #expect(natural.isDirectionInvertedFromDevice)
        #expect(natural.scrollingDeltaX < 0)
        let on = Capture()
        on.input.handleVideoMouseScroll(ScrollWheelInput(event: natural))

        // Physically 25 points left and 12 down: two steps of pan left, one down.
        #expect(reports(off.sent) == [[-2, -1]])
        #expect(reports(on.sent) == [[-2, -1]])
    }
}
