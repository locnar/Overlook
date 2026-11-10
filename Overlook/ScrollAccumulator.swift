import AppKit

/// One scroll-wheel event as the video view received it.
struct ScrollWheelInput: Equatable {
    /// `NSEvent.scrollingDeltaX/Y`: lines for a notched wheel, points for a trackpad or Magic
    /// Mouse. The user's natural-scrolling choice is already applied. A notched wheel's lines are
    /// scaled by macOS's wheel acceleration, so one slow notch is often a fraction of a line.
    var deltaX: CGFloat
    var deltaY: CGFloat
    /// The event's whole-line deltas (`scrollWheelEventDeltaAxis2` and `Axis1`). For a notched
    /// wheel this is at least one line per notch, and more when a fast spin is accelerated. Nil
    /// when the event did not carry them.
    var lineDeltaX: Int?
    var lineDeltaY: Int?
    /// True for a trackpad or Magic Mouse (many small point deltas, then momentum); false for a
    /// notched wheel (one line delta per notch).
    var hasPreciseDeltas: Bool
    /// The touch gesture's phase; empty for a notched wheel and for momentum events.
    var phase: NSEvent.Phase
    /// The momentum phase after the fingers lift; empty while they are down.
    var momentumPhase: NSEvent.Phase
    /// Seconds on the clock of `NSEvent.timestamp`.
    var timestamp: TimeInterval

    init(
        deltaX: CGFloat,
        deltaY: CGFloat,
        hasPreciseDeltas: Bool = false,
        phase: NSEvent.Phase = [],
        momentumPhase: NSEvent.Phase = [],
        timestamp: TimeInterval = 0,
        lineDeltaX: Int? = nil,
        lineDeltaY: Int? = nil
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.lineDeltaX = lineDeltaX
        self.lineDeltaY = lineDeltaY
        self.hasPreciseDeltas = hasPreciseDeltas
        self.phase = phase
        self.momentumPhase = momentumPhase
        self.timestamp = timestamp
    }

    init(event: NSEvent) {
        let cgEvent = event.cgEvent
        // Kept within 32 bits so flipping the sign can never overflow.
        func lines(_ field: CGEventField) -> Int? {
            cgEvent.map { Int(Int32(clamping: $0.getIntegerValueField(field))) }
        }
        self.init(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            timestamp: event.timestamp,
            lineDeltaX: lines(.scrollWheelEventDeltaAxis2),
            lineDeltaY: lines(.scrollWheelEventDeltaAxis1)
        )
    }
}

/// Turns scroll events into wheel steps for the target.
///
/// A notched wheel sends one wheel step per whole line the event reports; see `notchedSteps`.
/// A trackpad or Magic Mouse reports points, many per gesture; sent as they are, every point
/// became a whole wheel step on the target. Its deltas are summed per axis and sent as one wheel
/// step per `pointsPerStep` points, keeping what is left over for the next event.
struct ScrollAccumulator {
    /// Points of precise scrolling per wheel step. macOS counts a notched wheel's line as about
    /// ten points (`CGEventSourceGetPixelsPerLine`), and one line already goes out as one wheel
    /// step, so the same scrolling distance sends the same number of steps from either device.
    static let pointsPerStep: CGFloat = 10
    /// The most wheel steps one precise event sends on an axis; anything beyond is dropped, so a
    /// fast flick cannot spin the target's wheel far past what the user meant.
    static let maxStepsPerEvent = 5
    /// A pause longer than this between precise events starts the sums over.
    static let idleReset: TimeInterval = 0.25

    /// What has been scrolled on each axis and not yet sent, in wheel steps (always under one).
    private(set) var pendingX: CGFloat = 0
    private(set) var pendingY: CGFloat = 0
    private var lastPreciseTimestamp: TimeInterval?

    /// The wheel deltas to send for `input`, or nil when there is nothing to send.
    mutating func add(_ input: ScrollWheelInput) -> (deltaX: CGFloat, deltaY: CGFloat)? {
        guard input.hasPreciseDeltas else {
            reset()
            let steps = Self.notchedSteps(input)
            guard steps.x != 0 || steps.y != 0 else { return nil }
            return (CGFloat(steps.x), CGFloat(steps.y))
        }

        if let last = lastPreciseTimestamp, input.timestamp - last > Self.idleReset {
            reset()
        }
        // A new touch, or momentum taking over from the fingers, starts from nothing.
        if !input.phase.isDisjoint(with: [.mayBegin, .began]) || input.momentumPhase.contains(.began) {
            reset()
        }
        lastPreciseTimestamp = input.timestamp

        let stepsX = Self.take(&pendingX, adding: input.deltaX / Self.pointsPerStep)
        let stepsY = Self.take(&pendingY, adding: input.deltaY / Self.pointsPerStep)

        // The fingers lifting without momentum, or momentum running out, ends the gesture.
        if !input.phase.isDisjoint(with: [.ended, .cancelled])
            || !input.momentumPhase.isDisjoint(with: [.ended, .cancelled]) {
            reset()
        }

        guard stepsX != 0 || stepsY != 0 else { return nil }
        return (CGFloat(stepsX), CGFloat(stepsY))
    }

    /// The wheel steps a notched wheel's event sends on each axis.
    ///
    /// `scrollingDelta` is scaled by wheel acceleration: one slow notch is often 0.1 to 0.4 of a
    /// line, which rounded to nothing and lost the notch. The event's whole-line delta is at
    /// least one per notch and grows on a fast spin, so it is what is sent. Should it be zero
    /// or missing while `scrollingDelta` is not, the notch still sends at least one step.
    static func notchedSteps(_ input: ScrollWheelInput) -> (x: Int, y: Int) {
        (notchedSteps(lines: input.lineDeltaX, delta: input.deltaX),
         notchedSteps(lines: input.lineDeltaY, delta: input.deltaY))
    }

    /// One axis of `notchedSteps(_:)`.
    static func notchedSteps(lines: Int?, delta: CGFloat) -> Int {
        let delta = delta.isFinite ? delta : 0
        if let lines, lines != 0 {
            // The two have the same sign. Should they ever differ, follow `scrollingDelta`: it is
            // the one documented to carry the user's natural-scrolling choice.
            if delta != 0, (delta < 0) != (lines < 0) { return -lines }
            return lines
        }
        guard delta != 0 else { return 0 }
        let whole = Int(min(max(abs(delta).rounded(), 1), 1_000_000))
        return delta < 0 ? -whole : whole
    }

    mutating func reset() {
        pendingX = 0
        pendingY = 0
        lastPreciseTimestamp = nil
    }

    /// Adds `delta` (in steps) to `pending` and takes out the whole steps, capped. Scrolling the
    /// other way drops what was pending in the old direction first.
    private static func take(_ pending: inout CGFloat, adding delta: CGFloat) -> Int {
        guard delta != 0, delta.isFinite else { return 0 }
        if pending != 0, (pending < 0) != (delta < 0) {
            pending = 0
        }
        pending += delta
        let whole = pending.rounded(.towardZero)
        pending -= whole
        let limit = CGFloat(maxStepsPerEvent)
        return Int(min(max(whole, -limit), limit))
    }
}
