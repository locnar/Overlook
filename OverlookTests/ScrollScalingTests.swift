import AppKit
import Foundation
import Testing
@testable import Overlook

/// What a scroll event on the video becomes on its way to the target.
///
/// No manager here has a device: what it would send is read from `sentInputObserver`, and the
/// HID socket's wheel report is checked through `InputManager.glkvmWheelDeltas`. Trackpad
/// scaling is checked on `ScrollAccumulator` alone, then through the manager.
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

    @Test func aScrollGoesOutWithTheDeltasItArrivedWith() {
        let c = Capture()
        c.input.handleVideoMouseScroll(ScrollWheelInput(deltaX: 1.5, deltaY: -2.25))

        #expect(c.sent == [.scroll(deltaX: 1.5, deltaY: -2.25)])
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

        #expect(c.sent == [
            .scroll(deltaX: 0, deltaY: 1),
            .scroll(deltaX: 0, deltaY: -3),
            .scroll(deltaX: 2, deltaY: 0),
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
        #expect(c.sent == [.scroll(deltaX: -cap, deltaY: cap)])
    }

    // MARK: - ScrollAccumulator

    private func precise(
        _ deltaX: CGFloat,
        _ deltaY: CGFloat,
        at time: TimeInterval,
        phase: NSEvent.Phase = .changed,
        momentum: NSEvent.Phase = []
    ) -> ScrollWheelInput {
        ScrollWheelInput(
            deltaX: deltaX,
            deltaY: deltaY,
            hasPreciseDeltas: true,
            phase: phase,
            momentumPhase: momentum,
            timestamp: time
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

    @Test func notchedWheelDeltasPassThroughUnchanged() {
        #expect(steps([
            ScrollWheelInput(deltaX: 0, deltaY: 1),
            ScrollWheelInput(deltaX: 0, deltaY: -1),
            ScrollWheelInput(deltaX: 0.4, deltaY: 7.5),
            ScrollWheelInput(deltaX: 0, deltaY: 300),
        ]) == [[0, 1], [0, -1], [0.4, 7.5], [0, 300]])
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

    @Test func aLineEventScrollsTheTargetTheWayItArrived() throws {
        let c = Capture()
        let lines: [(vertical: Int32, horizontal: Int32)] = [(1, 0), (-1, 0), (0, 1), (0, -1), (2, -3)]
        for line in lines {
            let event = try #require(NSEvent(cgEvent: try lineEvent(vertical: line.vertical, horizontal: line.horizontal)))
            c.input.handleVideoMouseScroll(ScrollWheelInput(event: event))
        }

        // The vertical line goes out as Y and the horizontal one as X, each with its own sign.
        #expect(reports(c.sent) == [[0, 1], [0, -1], [1, 0], [-1, 0], [-3, 2]])
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
}
