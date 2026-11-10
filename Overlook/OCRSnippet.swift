import Foundation
import AppKit
import CoreVideo

/// The one-shot OCR snippet: ⇧⌘T, the toolbar's text-viewfinder button, or Capture › Copy Text
/// from Area. The operator drags a box over the video; when the mouse button comes up, the text
/// in the box, read from the newest frame at the stream's full resolution, goes on this Mac's
/// clipboard as plain text, and a notice says how many lines were copied.
///
/// The drag is the capture region's: the same overlay, rubber band, Esc handling and view-to-video
/// conversion (`VideoSurfaceView`, `VideoSelectionGeometry`), and the same pause of keyboard,
/// mouse and scroll input to the target (`ConsoleSession.syncInputCaptureWithOverlays`), which
/// lasts from `begin` until the box is released or the snippet is cancelled. Recognition runs
/// after that, with the overlay gone and input flowing again.
///
/// Separate from OCR mode (⇧⌘C), which stays on and draws the text it finds over the video:
/// starting one ends the other (`ConsoleSession.startOCRSnippet`).
@MainActor
final class OCRSnippet: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// The overlay is up, waiting for the operator to press on the video.
        case ready
        /// The mouse button is down and the box is being drawn.
        case dragging

        /// Whether the overlay is up (and input to the target paused).
        var isSelecting: Bool { self != .idle }
    }

    /// The smallest box that is read, in video pixels on each side. Anything smaller — a click
    /// without a drag, or a sliver — is taken as a change of mind: the snippet ends quietly, with
    /// nothing read, nothing copied and no notice. Eight pixels is about the height of the
    /// smallest legible text on a 1080p screen.
    nonisolated static let minimumSide: CGFloat = 8

    @Published private(set) var phase: Phase = .idle {
        didSet {
            if oldValue.isSelecting != phase.isSelecting {
                onSelectingChanged?()
            }
        }
    }

    /// Whether a snippet can start: a device connected and its video on screen. Kept current by
    /// the session; the toolbar button and the menu item are greyed out while it is false.
    @Published var isAvailable = false {
        didSet {
            if !isAvailable {
                cancel()
            }
        }
    }

    /// True while a released box is being read.
    @Published private(set) var isRecognizing = false

    var isSelecting: Bool { phase.isSelecting }

    /// What the last snippet came to, once its recognition has ended.
    private(set) var lastOutcome: OCROutcome?
    /// The most recent recognition, for tests to wait on.
    private(set) var recognition: Task<Void, Never>?
    private var recognitionsInFlight = 0

    /// The newest decoded frame, at the stream's own resolution. Tests replace it.
    var readFrame: () -> CVPixelBuffer?
    /// Puts plain text on this Mac's clipboard. Tests replace it; under the test host the default
    /// writes nowhere, so no test can reach the operator's clipboard.
    var writeClipboard: (String) -> Void = { OCRSnippet.writeToGeneralPasteboard($0) }
    /// Runs after the overlay has come up or gone away; the session pauses or resumes input.
    var onSelectingChanged: (() -> Void)?

    private let ocrManager: OCRManager
    private let captureManager: CaptureManager

    init(ocrManager: OCRManager, captureManager: CaptureManager, readFrame: @escaping () -> CVPixelBuffer?) {
        self.ocrManager = ocrManager
        self.captureManager = captureManager
        self.readFrame = readFrame
    }

    // MARK: The drag

    /// Puts up the overlay. False, and nothing changed, while no video is showing.
    @discardableResult
    func begin() -> Bool {
        guard isAvailable else { return false }
        guard phase == .idle else { return true }
        captureManager.dismissNotice()
        phase = .ready
        return true
    }

    /// Esc, a click on the lit toolbar button, or the video going away: the overlay goes, input
    /// resumes, and nothing is read or shown.
    func cancel() {
        phase = .idle
    }

    /// The mouse button went down on the video, or the box changed size.
    func dragDidChange() {
        if phase == .ready {
            phase = .dragging
        }
    }

    /// The mouse button came up. `region` is the box in frame fractions (origin top-left), already
    /// clamped to the video, or nil when there was none; `videoSize` is the stream's size, for the
    /// minimum. The overlay goes and input resumes at once; a box big enough is then read.
    func release(region: CGRect?, videoSize: CGSize?) {
        guard phase.isSelecting else { return }
        phase = .idle
        guard let region, Self.isLargeEnough(region, videoSize: videoSize) else { return }

        let frame = readFrame()
        recognitionsInFlight += 1
        isRecognizing = true
        recognition = Task { [weak self, ocrManager] in
            let result: Result<[String], Error>
            do {
                result = .success(try await ocrManager.recognizeLines(inTopLeftRegion: region, of: frame))
            } catch {
                result = .failure(error)
            }
            self?.finish(result)
        }
    }

    /// Whether `region` (frame fractions) is at least `minimumSide` video pixels on each side.
    /// With the stream's size unknown, any box with an area counts.
    nonisolated static func isLargeEnough(_ region: CGRect, videoSize: CGSize?) -> Bool {
        guard !region.isNull, region.width > 0, region.height > 0 else { return false }
        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else { return true }
        let width = (region.width * videoSize.width).rounded()
        let height = (region.height * videoSize.height).rounded()
        return width >= minimumSide && height >= minimumSide
    }

    // MARK: The result

    private func finish(_ result: Result<[String], Error>) {
        recognitionsInFlight -= 1
        isRecognizing = recognitionsInFlight > 0

        let outcome = Self.outcome(for: result)
        lastOutcome = outcome
        switch outcome {
        case .text(let text):
            writeClipboard(text)
            captureManager.showCopiedTextNotice(text)
        case .noText, .failed:
            // Nothing is written: the clipboard keeps what it had.
            captureManager.showOCRNotice(for: outcome)
        case .cancelled:
            break
        }
    }

    /// The lines read, one per line of the copied text; blank lines are dropped and each line is
    /// trimmed. No lines at all, or only blank ones, is "No text found".
    static func outcome(for result: Result<[String], Error>) -> OCROutcome {
        switch result {
        case .success(let lines):
            let kept = lines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return OCROutcome(.success(kept.joined(separator: "\n")))
        case .failure(let error):
            return OCROutcome(.failure(error))
        }
    }

    // MARK: The clipboard

    nonisolated static func writeToGeneralPasteboard(_ text: String) {
        guard !AppEnvironment.isHostingTests else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The copied-text notice's symbol: a clipboard with a checkmark drawn inside it. SF Symbols
    /// has no clipboard with a check (macOS 14 through 27 were checked), so the notice draws the
    /// check itself (`CaptureManager.Notice.systemImageBadge`).
    static let copiedSymbolName = "clipboard"
    static let copiedSymbolBadge = "checkmark"
}

// MARK: - From the view to the video

/// Where a drag on the video lands in the video. The video is letterboxed into the view (black
/// bars on the sides or top and bottom), so a point in the view is first clamped to the part the
/// video fills and then measured against it. Shared by the capture region and the OCR snippet.
enum VideoSelectionGeometry {
    /// The rect a `videoSize` picture fills inside a view of `viewSize`, keeping its aspect ratio
    /// and centred. Both sizes must be non-zero.
    static func letterboxedRect(viewSize: CGSize, videoSize: CGSize) -> CGRect {
        let viewAspect = viewSize.width / viewSize.height
        let videoAspect = videoSize.width / videoSize.height

        if viewAspect > videoAspect {
            let contentWidth = viewSize.height * videoAspect
            let xOffset = (viewSize.width - contentWidth) / 2.0
            return CGRect(x: xOffset, y: 0, width: contentWidth, height: viewSize.height)
        } else {
            let contentHeight = viewSize.width / videoAspect
            let yOffset = (viewSize.height - contentHeight) / 2.0
            return CGRect(x: 0, y: yOffset, width: viewSize.width, height: contentHeight)
        }
    }

    /// The letterboxed rect; the whole view until the stream's size is known, and `.zero` for an
    /// empty view.
    static func contentRect(viewSize: CGSize, videoSize: CGSize?) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }
        return letterboxedRect(viewSize: viewSize, videoSize: videoSize)
    }

    /// The rubber band from `start` to `current`, in view points, clamped to the video so the
    /// black bars cannot be selected. Nil for an empty view.
    static func selectionRect(from start: CGPoint, to current: CGPoint, viewSize: CGSize, videoSize: CGSize?) -> CGRect? {
        let content = contentRect(viewSize: viewSize, videoSize: videoSize)
        guard content.width > 0, content.height > 0 else { return nil }
        func clamp(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: min(max(point.x, content.minX), content.maxX),
                y: min(max(point.y, content.minY), content.maxY)
            )
        }
        let a = clamp(start)
        let b = clamp(current)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// View points → frame fractions (origin top-left, the frame's own orientation).
    static func normalizedRegion(forViewRect rect: CGRect, viewSize: CGSize, videoSize: CGSize?) -> CGRect {
        let content = contentRect(viewSize: viewSize, videoSize: videoSize)
        guard content.width > 0, content.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(
            x: (rect.minX - content.minX) / content.width,
            y: (rect.minY - content.minY) / content.height,
            width: rect.width / content.width,
            height: rect.height / content.height
        )
    }

    /// View points → video pixels (origin top-left), unrounded.
    static func videoPixelRect(forViewRect rect: CGRect, viewSize: CGSize, videoSize: CGSize) -> CGRect {
        let region = normalizedRegion(forViewRect: rect, viewSize: viewSize, videoSize: videoSize)
        return CGRect(
            x: region.minX * videoSize.width,
            y: region.minY * videoSize.height,
            width: region.width * videoSize.width,
            height: region.height * videoSize.height
        )
    }
}
