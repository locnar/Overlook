import AppKit

/// One scroll-wheel event as the video view received it.
struct ScrollWheelInput: Equatable {
    /// `NSEvent.scrollingDeltaX/Y`: lines for a notched wheel, points for a trackpad or Magic
    /// Mouse. The user's natural-scrolling choice is already applied.
    var deltaX: CGFloat
    var deltaY: CGFloat
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
        timestamp: TimeInterval = 0
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.hasPreciseDeltas = hasPreciseDeltas
        self.phase = phase
        self.momentumPhase = momentumPhase
        self.timestamp = timestamp
    }

    init(event: NSEvent) {
        self.init(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            timestamp: event.timestamp
        )
    }
}

/// Turns scroll events into wheel steps for the target.
///
/// A notched wheel passes through as it always has: its line deltas are already wheel steps.
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
            guard input.deltaX != 0 || input.deltaY != 0 else { return nil }
            return (input.deltaX, input.deltaY)
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
