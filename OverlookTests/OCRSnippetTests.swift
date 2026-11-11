import AppKit
import Combine
import CoreVideo
import Foundation
import Testing
@testable import Overlook

// MARK: - Test frames and a reader that records what it was given

/// What the stub line reader saw of each crop it was handed: its size, and how bright its top-left
/// pixel is (0…255), so a test can tell which part of the frame was cut out.
final class SnippetReads: @unchecked Sendable {
    struct Read: Equatable {
        let width: Int
        let height: Int
        let topLeftBrightness: Int
    }

    private let lock = NSLock()
    private var seen: [Read] = []

    var all: [Read] { lock.withLock { seen } }
    var count: Int { all.count }

    func record(_ buffer: CVPixelBuffer) {
        let read = Read(
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            topLeftBrightness: SnippetFrames.topLeftBrightness(of: buffer)
        )
        lock.withLock { seen.append(read) }
    }
}

enum SnippetFrames {
    /// A BGRA frame whose top `whiteRows` rows are white and the rest black.
    static func frame(width: Int = 1920, height: Int = 1080, whiteRows: Int? = nil) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &created)
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let white = whiteRows ?? height / 2
        for row in 0..<height {
            let value: UInt8 = row < white ? 0xFF : 0x00
            let line = base + row * stride
            for x in 0..<width {
                line[x * 4 + 0] = value
                line[x * 4 + 1] = value
                line[x * 4 + 2] = value
                line[x * 4 + 3] = 0xFF
            }
        }
        return buffer
    }

    static func topLeftBrightness(of buffer: CVPixelBuffer) -> Int {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return -1 }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        return Int(base[1])
    }
}

// MARK: - The snippet in a session

/// The OCR snippet (⇧⌘T) in a console session of its own, with a stub reading the text instead of
/// Vision, a frame made here instead of the stream, and the clipboard seam recording writes
/// instead of reaching the Mac's clipboard. Nothing here touches the network or the clipboard.
@MainActor
@Suite("OCR snippet")
struct OCRSnippetTests {
    let scratch: ScratchDefaults
    let reads: SnippetReads
    let session: ConsoleSession
    /// What the snippet put on the clipboard, in order.
    let clipboard: ClipboardRecorder

    @MainActor
    final class ClipboardRecorder {
        var writes: [String] = []
    }

    static let videoSize = CGSize(width: 1920, height: 1080)
    static let box = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2)

    init() throws {
        try self.init(lines: ["ls -la", "total 48"])
    }

    init(lines: [String]) throws {
        try self.init { _ in lines }
    }

    init(gate: OCRManagerTests.Gate? = nil, read: @escaping @Sendable (CVPixelBuffer) throws -> [String]) throws {
        let scratch = ScratchDefaults()
        let reads = SnippetReads()
        let clipboard = ClipboardRecorder()
        self.scratch = scratch
        self.reads = reads
        self.clipboard = clipboard
        let ocr = OCRManager(lineReader: { buffer in
            reads.record(buffer)
            gate?.pass()
            return try read(buffer)
        })
        session = ConsoleSession(
            catalog: Fixtures.catalog(scratch),
            defaults: scratch.defaults,
            link: RecordingSessionLink(),
            audioPreferences: AudioPreferences(defaults: scratch.defaults),
            connectionLog: .inMemory(),
            ocrManager: ocr
        )
        let frame = try SnippetFrames.frame()
        session.ocrSnippet.readFrame = { frame }
        session.ocrSnippet.writeClipboard = { clipboard.writes.append($0) }
    }

    private var snippet: OCRSnippet { session.ocrSnippet }

    /// Connected, with the stream's video on screen.
    private func showVideo() {
        session.connection.connectedDevice = Fixtures.device()
        session.webRTCManager.isConnected = true
        session.webRTCManager.videoSize = Self.videoSize
    }

    private func finishRecognition() async {
        await snippet.recognition?.value
    }

    // MARK: Availability

    @Test func itNeedsAConnectionAndVideo() {
        #expect(snippet.isAvailable == false)
        session.toggleOCRSnippet()
        #expect(snippet.phase == .idle)

        session.connection.connectedDevice = Fixtures.device()
        session.webRTCManager.isConnected = true
        #expect(snippet.isAvailable == false, "no video size yet")
        session.toggleOCRSnippet()
        #expect(snippet.phase == .idle)

        session.webRTCManager.videoSize = Self.videoSize
        #expect(snippet.isAvailable)
        session.toggleOCRSnippet()
        #expect(snippet.phase == .ready)
    }

    @Test func losingTheVideoOrTheConnectionEndsASnippet() {
        showVideo()
        session.startOCRSnippet()
        #expect(snippet.isSelecting)
        session.webRTCManager.videoSize = nil
        #expect(snippet.phase == .idle)
        #expect(snippet.isAvailable == false)

        session.webRTCManager.videoSize = Self.videoSize
        session.startOCRSnippet()
        #expect(snippet.isSelecting)
        session.connection.disconnectFromDevice()
        #expect(snippet.phase == .idle)
    }

    // MARK: Start → dragging → released → OCR → copied

    @Test func aBoxIsReadCopiedAndAnnounced() async throws {
        showVideo()
        session.toggleOCRSnippet()
        #expect(snippet.phase == .ready)

        snippet.dragDidChange()
        #expect(snippet.phase == .dragging)

        snippet.release(region: Self.box, videoSize: Self.videoSize)
        // The overlay goes as soon as the box is released, before the text is read.
        #expect(snippet.phase == .idle)
        #expect(snippet.isRecognizing)

        await finishRecognition()
        #expect(snippet.isRecognizing == false)
        #expect(reads.count == 1)
        #expect(clipboard.writes == ["ls -la\ntotal 48"])
        #expect(snippet.lastOutcome == .text("ls -la\ntotal 48"))

        let notice = try #require(session.captureManager.notice)
        #expect(notice.title == "Copied 2 lines")
        #expect(notice.detail == "“ls -la”")
        #expect(notice.copiedText == "ls -la\ntotal 48")
        #expect(notice.systemImage == "clipboard")
        #expect(notice.systemImageBadge == "checkmark")
        #expect(notice.tintsSymbol)
        #expect(notice.isError == false)
        #expect(notice.fileURL == nil)
    }

    @Test func theOverlayIsGoneWhileTheTextIsStillBeingRead() async throws {
        let gate = OCRManagerTests.Gate()
        let test = try OCRSnippetTests(gate: gate) { _ in ["held"] }
        test.showVideo()
        test.session.startOCRSnippet()
        test.session.ocrSnippet.dragDidChange()
        test.session.ocrSnippet.release(region: Self.box, videoSize: Self.videoSize)

        #expect(await waitUntil { gate.timesEntered == 1 })
        #expect(test.session.ocrSnippet.phase == .idle)
        #expect(test.session.panels.isInputCapturePaused == false)
        #expect(test.clipboard.writes.isEmpty)

        gate.open()
        await test.finishRecognition()
        #expect(test.clipboard.writes == ["held"])
    }

    /// The box is cut from the frame at the frame's own resolution, top-left origin: a box over
    /// the white top half reads white, one over the black bottom half reads black.
    @Test func theBoxIsCutFromTheFullResolutionFrame() async throws {
        showVideo()
        session.startOCRSnippet()
        snippet.release(region: CGRect(x: 0.25, y: 0, width: 0.5, height: 0.25), videoSize: Self.videoSize)
        await finishRecognition()

        session.startOCRSnippet()
        snippet.release(region: CGRect(x: 0, y: 0.75, width: 0.25, height: 0.25), videoSize: Self.videoSize)
        await finishRecognition()

        let seen = reads.all
        try #require(seen.count == 2)
        #expect(seen[0].width == 960)
        #expect(seen[0].height == 270)
        #expect(seen[0].topLeftBrightness > 200)
        #expect(seen[1].width == 480)
        #expect(seen[1].height == 270)
        #expect(seen[1].topLeftBrightness >= 0)
        #expect(seen[1].topLeftBrightness < 50)
    }

    // MARK: Ending without reading

    @Test func escapeCancelsWithNothingReadOrShown() async {
        showVideo()
        session.startOCRSnippet()
        snippet.dragDidChange()
        snippet.cancel()   // what the overlay's Esc monitor calls

        #expect(snippet.phase == .idle)
        // A release arriving after the cancel (the mouse coming up) changes nothing.
        snippet.release(region: Self.box, videoSize: Self.videoSize)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(reads.count == 0)
        #expect(clipboard.writes.isEmpty)
        #expect(session.captureManager.notice == nil)
        #expect(snippet.recognition == nil)
    }

    @Test func aClickWithoutADragCancelsQuietly() async {
        showVideo()
        session.startOCRSnippet()
        snippet.dragDidChange()
        snippet.release(region: nil, videoSize: Self.videoSize)
        #expect(snippet.phase == .idle)

        session.startOCRSnippet()
        snippet.dragDidChange()
        snippet.release(region: CGRect(x: 0.5, y: 0.5, width: 0, height: 0), videoSize: Self.videoSize)
        #expect(snippet.phase == .idle)

        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(reads.count == 0)
        #expect(clipboard.writes.isEmpty)
        #expect(session.captureManager.notice == nil)
    }

    @Test func aBoxUnderEightVideoPixelsCancelsQuietly() async {
        showVideo()
        let pixel = CGSize(width: 1 / Self.videoSize.width, height: 1 / Self.videoSize.height)
        // 7 × 200 and 200 × 7 pixels.
        for size in [CGSize(width: 7 * pixel.width, height: 200 * pixel.height),
                     CGSize(width: 200 * pixel.width, height: 7 * pixel.height)] {
            session.startOCRSnippet()
            snippet.release(region: CGRect(origin: CGPoint(x: 0.5, y: 0.5), size: size), videoSize: Self.videoSize)
            #expect(snippet.phase == .idle)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(reads.count == 0)
        #expect(session.captureManager.notice == nil)

        // 8 × 8 is read.
        session.startOCRSnippet()
        snippet.release(
            region: CGRect(x: 0.5, y: 0.5, width: 8 * pixel.width, height: 8 * pixel.height),
            videoSize: Self.videoSize
        )
        await finishRecognition()
        #expect(reads.count == 1)
    }

    @Test func theMinimumIsEightVideoPixels() {
        #expect(OCRSnippet.minimumSide == 8)
        let size = CGSize(width: 1000, height: 1000)
        #expect(OCRSnippet.isLargeEnough(CGRect(x: 0, y: 0, width: 0.008, height: 0.008), videoSize: size))
        #expect(!OCRSnippet.isLargeEnough(CGRect(x: 0, y: 0, width: 0.007, height: 0.5), videoSize: size))
        #expect(!OCRSnippet.isLargeEnough(CGRect(x: 0, y: 0, width: 0.5, height: 0.007), videoSize: size))
        #expect(!OCRSnippet.isLargeEnough(.null, videoSize: size))
        // With the stream's size unknown any box with an area counts.
        #expect(OCRSnippet.isLargeEnough(CGRect(x: 0, y: 0, width: 0.001, height: 0.001), videoSize: nil))
    }

    // MARK: Other tools

    @Test func startingEndsOCRMode() {
        showVideo()
        session.isOCRModeEnabled = true
        session.startOCRSnippet()
        #expect(session.isOCRModeEnabled == false)
        #expect(snippet.phase == .ready)
    }

    @Test func startingEndsARegionSelection() {
        showVideo()
        session.captureManager.beginRegionSelection()
        #expect(session.captureManager.isSelectingRegion)
        session.startOCRSnippet()
        #expect(session.captureManager.isSelectingRegion == false)
        #expect(snippet.phase == .ready)
    }

    @Test func startingClosesAPanel() {
        showVideo()
        session.panels.show(.log)
        session.startOCRSnippet()
        #expect(session.panels.isAnyOpen == false)
        #expect(snippet.isSelecting)
    }

    @Test func ocrModeOrARegionSelectionEndsASnippet() {
        showVideo()
        session.startOCRSnippet()
        session.isOCRModeEnabled = true
        #expect(snippet.phase == .idle)

        session.isOCRModeEnabled = false
        session.startOCRSnippet()
        session.captureManager.beginRegionSelection()
        #expect(snippet.phase == .idle)
        #expect(session.captureManager.isSelectingRegion)
    }

    /// The toolbar button, the menu item and ⇧⌘T all toggle: a second press while the box is up
    /// cancels it.
    @Test func theChordStartsAndThenCancels() {
        showVideo()
        session.perform(.copyTextFromArea)
        #expect(snippet.phase == .ready)
        session.perform(.copyTextFromArea)
        #expect(snippet.phase == .idle)
    }

    // MARK: Results

    @Test func noTextCopiesNothingAndSaysSo() async throws {
        let test = try OCRSnippetTests(lines: ["   ", "", "\t"])
        test.showVideo()
        test.session.startOCRSnippet()
        test.session.ocrSnippet.release(region: Self.box, videoSize: Self.videoSize)
        await test.finishRecognition()

        #expect(test.clipboard.writes.isEmpty)
        let notice = try #require(test.session.captureManager.notice)
        #expect(notice.title == "No text found")
        #expect(notice.copiedText == nil)
        #expect(test.session.ocrSnippet.lastOutcome == .noText)
    }

    @Test func aFailureCopiesNothingAndSaysWhy() async throws {
        let test = try OCRSnippetTests { _ in throw OCRError.processingFailed }
        test.showVideo()
        test.session.startOCRSnippet()
        test.session.ocrSnippet.release(region: Self.box, videoSize: Self.videoSize)
        await test.finishRecognition()

        #expect(test.clipboard.writes.isEmpty)
        let notice = try #require(test.session.captureManager.notice)
        #expect(notice.title == "Text recognition failed")
        #expect(notice.detail == "OCR processing failed")
        #expect(notice.isError)
    }

    @Test func noFrameIsAFailure() async throws {
        showVideo()
        snippet.readFrame = { nil }
        session.startOCRSnippet()
        snippet.release(region: Self.box, videoSize: Self.videoSize)
        await finishRecognition()

        #expect(reads.count == 0)
        #expect(clipboard.writes.isEmpty)
        #expect(session.captureManager.notice?.title == "Text recognition failed")
        #expect(session.captureManager.notice?.detail == "No video frame available for OCR")
    }

    @Test func linesAreTrimmedAndBlankLinesDropped() async throws {
        let test = try OCRSnippetTests(lines: ["  first  ", " ", "second", "\t"])
        test.showVideo()
        test.session.startOCRSnippet()
        test.session.ocrSnippet.release(region: Self.box, videoSize: Self.videoSize)
        await test.finishRecognition()
        #expect(test.clipboard.writes == ["first\nsecond"])
        #expect(test.session.captureManager.notice?.title == "Copied 2 lines")
    }

    @Test func eachSnippetWritesTheClipboardOnce() async throws {
        showVideo()
        for _ in 0..<3 {
            session.startOCRSnippet()
            snippet.release(region: Self.box, videoSize: Self.videoSize)
            await finishRecognition()
        }
        #expect(clipboard.writes == Array(repeating: "ls -la\ntotal 48", count: 3))
    }

    /// Under the test host the app's own clipboard writer writes nowhere, so a test that forgot
    /// the seam still cannot reach the operator's clipboard.
    @Test func theDefaultClipboardWriterIsInertUnderTheTestHost() {
        #expect(AppEnvironment.isHostingTests)
        let before = NSPasteboard.general.changeCount
        OCRSnippet.writeToGeneralPasteboard("must not land")
        #expect(NSPasteboard.general.changeCount == before)
    }

    /// Show text on the notice asks the window for the results sheet with everything copied.
    @Test func showTextOpensTheSheetWithTheFullText() async throws {
        let lines = ["first line", "second line", "third line"]
        let test = try OCRSnippetTests(lines: lines)
        var sheets: [String] = []
        let subscription = test.session.recognizedTextRequests.sink { sheets.append($0) }
        defer { subscription.cancel() }

        test.showVideo()
        test.session.startOCRSnippet()
        test.session.ocrSnippet.release(region: Self.box, videoSize: Self.videoSize)
        await test.finishRecognition()

        let notice = try #require(test.session.captureManager.notice)
        let text = try #require(notice.copiedText)
        test.session.showRecognizedText(text)
        #expect(sheets == ["first line\nsecond line\nthird line"])
    }

    @Test func theNoticeSymbolsExist() {
        #expect(NSImage(systemSymbolName: OCRSnippet.copiedSymbolName, accessibilityDescription: nil) != nil)
        #expect(NSImage(systemSymbolName: OCRSnippet.copiedSymbolBadge, accessibilityDescription: nil) != nil)
        #expect(NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil) != nil)
    }
}

// MARK: - The titlebar's OCR buttons

@Suite("OCR toolbar symbols")
struct OCRToolbarSymbolTests {
    @Test func theSelectionToggleNeverLooksLikeCopyTextFromArea() {
        // The toggle used to switch to Copy Text from Area's symbol while OCR mode was on.
        #expect(OCRToolbarSymbols.selection != OCRToolbarSymbols.copyTextFromArea)
        #expect(OCRToolbarSymbols.selection != "text.viewfinder")
        #expect(OCRToolbarSymbols.copyTextFromArea == "text.viewfinder")
    }

    @Test func bothSymbolsExist() {
        #expect(NSImage(systemSymbolName: OCRToolbarSymbols.selection, accessibilityDescription: nil) != nil)
        #expect(NSImage(systemSymbolName: OCRToolbarSymbols.copyTextFromArea, accessibilityDescription: nil) != nil)
    }
}

// MARK: - The notice's words

@MainActor
@Suite("OCR snippet notice")
struct OCRSnippetNoticeTests {
    @Test func oneLine() {
        let summary = CaptureManager.copiedTextSummary("ls -la")
        #expect(summary.title == "Copied 1 line")
        #expect(summary.detail == "“ls -la”")
    }

    @Test func severalLines() {
        let summary = CaptureManager.copiedTextSummary("root@host:~# uptime\n 14:02 up 3 days\nload average: 0.10")
        #expect(summary.title == "Copied 3 lines")
        #expect(summary.detail == "“root@host:~# uptime”")
    }

    @Test func windowsLineEndingsCountOnce() {
        #expect(CaptureManager.copiedTextSummary("a\r\nb").title == "Copied 2 lines")
    }

    @Test func aLongFirstLineIsCutShort() {
        let long = String(repeating: "abcdefghij", count: 8)   // 80 characters
        let summary = CaptureManager.copiedTextSummary(long + "\nsecond")
        let limit = CaptureManager.copiedLinePreviewLength
        #expect(summary.detail == "“" + String(long.prefix(limit - 1)) + "…”")
        #expect(summary.detail.count == limit + 2)
    }

    @Test func aFirstLineAtTheLimitIsWhole() {
        let exact = String(repeating: "x", count: CaptureManager.copiedLinePreviewLength)
        #expect(CaptureManager.copiedTextSummary(exact).detail == "“\(exact)”")
    }

    @Test func noSpaceIsLeftBeforeTheEllipsis() {
        let limit = CaptureManager.copiedLinePreviewLength
        let line = String(repeating: "y", count: limit - 2) + "  and more after the cut"
        let detail = CaptureManager.copiedTextSummary(line).detail
        #expect(detail.hasSuffix("y…”"))
    }
}

// MARK: - View to video

/// Where a drag on the video lands in the video, with the picture letterboxed into the view.
@Suite("Video selection geometry")
struct VideoSelectionGeometryTests {
    static let video = CGSize(width: 1920, height: 1080)

    private func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.01) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    @Test func aWideViewHasBarsAtTheSides() {
        let content = VideoSelectionGeometry.contentRect(viewSize: CGSize(width: 1000, height: 450), videoSize: Self.video)
        #expect(close(content, CGRect(x: 100, y: 0, width: 800, height: 450)))
    }

    @Test func aTallViewHasBarsAboveAndBelow() {
        let content = VideoSelectionGeometry.contentRect(viewSize: CGSize(width: 800, height: 800), videoSize: Self.video)
        #expect(close(content, CGRect(x: 0, y: 175, width: 800, height: 450)))
    }

    @Test func untilTheVideoSizeIsKnownTheWholeViewIsVideo() {
        let content = VideoSelectionGeometry.contentRect(viewSize: CGSize(width: 640, height: 480), videoSize: nil)
        #expect(content == CGRect(x: 0, y: 0, width: 640, height: 480))
        #expect(VideoSelectionGeometry.contentRect(viewSize: .zero, videoSize: Self.video) == .zero)
    }

    /// The input manager's letterbox is the same one.
    @MainActor
    @Test func theInputManagerUsesTheSameLetterbox() {
        let scratch = ScratchDefaults()
        let input = InputManager(defaults: scratch.defaults, log: SessionLog(destination: .inMemory()))
        let view = CGSize(width: 1000, height: 450)
        #expect(input.videoContentRect(viewSize: view, videoSize: Self.video)
                == VideoSelectionGeometry.letterboxedRect(viewSize: view, videoSize: Self.video))
    }

    @Test func aBoxInsideThePictureMapsToVideoPixels() {
        // View 1000 × 450: the picture is 800 × 450 at x = 100.
        let view = CGSize(width: 1000, height: 450)
        let band = VideoSelectionGeometry.selectionRect(
            from: CGPoint(x: 300, y: 225),
            to: CGPoint(x: 140, y: 45),
            viewSize: view,
            videoSize: Self.video
        )
        #expect(band.map { close($0, CGRect(x: 140, y: 45, width: 160, height: 180)) } == true)
        if let rect = band {
            let region = VideoSelectionGeometry.normalizedRegion(forViewRect: rect, viewSize: view, videoSize: Self.video)
            #expect(close(region, CGRect(x: 0.05, y: 0.1, width: 0.2, height: 0.4), tolerance: 0.0001))
            let pixels = VideoSelectionGeometry.videoPixelRect(forViewRect: rect, viewSize: view, videoSize: Self.video)
            #expect(close(pixels, CGRect(x: 96, y: 108, width: 384, height: 432)))
        }
    }

    @Test func aDragIntoTheBarsStopsAtThePicture() {
        // View 800 × 800: the picture is 800 × 450 at y = 175.
        let view = CGSize(width: 800, height: 800)
        let band = VideoSelectionGeometry.selectionRect(
            from: CGPoint(x: 400, y: 10),
            to: CGPoint(x: 900, y: 400),
            viewSize: view,
            videoSize: Self.video
        )
        #expect(band.map { close($0, CGRect(x: 400, y: 175, width: 400, height: 225)) } == true)
        if let band {
            let pixels = VideoSelectionGeometry.videoPixelRect(forViewRect: band, viewSize: view, videoSize: Self.video)
            #expect(close(pixels, CGRect(x: 960, y: 0, width: 960, height: 540)))
        }
    }

    @Test func aDragEntirelyInABarIsEmpty() {
        let view = CGSize(width: 1000, height: 450)
        let band = VideoSelectionGeometry.selectionRect(
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 90, y: 400),
            viewSize: view,
            videoSize: Self.video
        )
        #expect(band.map { $0.width == 0 } == true)
        if let band {
            let region = VideoSelectionGeometry.normalizedRegion(forViewRect: band, viewSize: view, videoSize: Self.video)
            #expect(OCRSnippet.isLargeEnough(region, videoSize: Self.video) == false)
        }
    }
}

// MARK: - Input to the target while the box is up

/// While the snippet's overlay is up nothing reaches the target — no key, button, wheel or move
/// report on the HID socket — and once the box is released (or the snippet cancelled) input
/// flows again. On a HID socket answered in the test.
@MainActor
@Suite("OCR snippet pauses input")
struct OCRSnippetInputPauseTests {
    static let window = 9_301

    let scratch = ScratchDefaults()
    let sockets = FakeHIDSockets()
    let device = StubDevice(config: FakeUserConfig(["is_absolute_mouse": .bool(true)]))
    let session: ConsoleSession
    let sent = SentLog()

    @MainActor
    final class SentLog {
        var all: [InputManager.SentInput] = []
    }

    init() throws {
        session = ConsoleSession(
            catalog: Fixtures.catalog(scratch),
            defaults: scratch.defaults,
            link: RecordingSessionLink(),
            audioPreferences: AudioPreferences(defaults: scratch.defaults),
            connectionLog: .inMemory(),
            ocrManager: OCRManager(lineReader: { _ in ["text"] })
        )
        session.ocrSnippet.readFrame = { try? SnippetFrames.frame(width: 64, height: 64) }
        session.ocrSnippet.writeClipboard = { _ in }

        let client = try device.makeClient()
        client.hidSocketTiming = .testing()
        let sockets = self.sockets
        client.makeHIDSocket = { _ in sockets.make() }

        session.connection.connectedDevice = Fixtures.device()
        session.webRTCManager.isConnected = true
        session.webRTCManager.videoSize = CGSize(width: 1920, height: 1080)

        let input = session.inputManager
        let sent = self.sent
        input.sentInputObserver = { sent.all.append($0) }
        input.setGLKVMClient(client)
        input.startFullInputCapture()
        input.windowDidBecomeKey(windowNumber: Self.window)
    }

    private var input: InputManager { session.inputManager }

    private func openedSocket() async throws -> FakeHIDSocket {
        #expect(await waitUntil(timeout: .seconds(5)) {
            sockets.count > 0 && sockets.all[0].frames.contains(where: \.clearsKeyboard)
        })
        return try #require(sockets.all.first)
    }

    /// Key, button, move and wheel reports (kvmd's binary events 0x01…0x05), less the report that
    /// clears the keyboard.
    private func inputReports(on socket: FakeHIDSocket) -> [FakeHIDSocket.Frame] {
        socket.frames.filter { frame in
            guard case .binary(let bytes) = frame, let kind = bytes.first else { return false }
            return (0x01...0x05).contains(kind) && !frame.clearsKeyboard
        }
    }

    private func key(_ keyCode: UInt16, down: Bool) -> NSEvent {
        NSEvent.keyEvent(
            with: down ? .keyDown : .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: Self.window,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    /// A key, a click, a move and a scroll, as the video surface would hand them on.
    private func useKeyboardAndMouse() {
        _ = input.routeMonitoredKeyEvent(key(0, down: true))
        _ = input.routeMonitoredKeyEvent(key(0, down: false))
        let point = CGPoint(x: 500, y: 300)
        let view = CGSize(width: 1000, height: 600)
        input.handleVideoMouseMove(pointInView: point, viewSize: view, videoSize: CGSize(width: 1920, height: 1080))
        input.handleVideoMouseButton(button: .left, isDown: true, pointInView: point, viewSize: view, videoSize: nil)
        input.handleVideoMouseButton(button: .left, isDown: false, pointInView: point, viewSize: view, videoSize: nil)
        input.handleVideoMouseScroll(ScrollWheelInput(deltaX: 0, deltaY: 3))
    }

    @Test func nothingReachesTheTargetWhileTheBoxIsUpAndInputResumesOnRelease() async throws {
        let socket = try await openedSocket()

        // Before: input reaches the target.
        useKeyboardAndMouse()
        #expect(await waitUntil { inputReports(on: socket).contains { $0.keyText == "KeyA up" } })
        #expect(sent.all.contains(.key(0, isDown: true)))
        #expect(sent.all.contains(.button(.left, isDown: true)))
        #expect(sent.all.contains(.scroll(deltaX: 0, deltaY: 3)))
        try await Task.sleep(nanoseconds: 200_000_000)
        let before = inputReports(on: socket).count
        sent.all.removeAll()

        session.startOCRSnippet()
        #expect(input.isKeyboardCaptureEnabled == false)
        #expect(input.isMouseCaptureEnabled == false)

        // Waiting for the press, then mid-drag: nothing goes out.
        useKeyboardAndMouse()
        session.ocrSnippet.dragDidChange()
        useKeyboardAndMouse()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(sent.all.isEmpty)
        #expect(inputReports(on: socket).count == before)

        // Released: capture is back on at once, before the text has been read.
        session.ocrSnippet.release(region: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3), videoSize: CGSize(width: 1920, height: 1080))
        #expect(input.isKeyboardCaptureEnabled)
        #expect(input.isMouseCaptureEnabled)
        #expect(session.panels.isInputCapturePaused == false)
        await session.ocrSnippet.recognition?.value

        useKeyboardAndMouse()
        #expect(await waitUntil { inputReports(on: socket).count > before })
        #expect(sent.all.contains(.key(0, isDown: true)))
        #expect(sent.all.contains(.button(.left, isDown: true)))
        await input.shutdown()
    }

    @Test func escapeResumesInputToo() async throws {
        let socket = try await openedSocket()
        // The socket's opening resync releases every button; that is not the operator's input.
        try await Task.sleep(nanoseconds: 200_000_000)
        let before = inputReports(on: socket).count
        session.startOCRSnippet()
        useKeyboardAndMouse()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(sent.all.isEmpty)
        #expect(inputReports(on: socket).count == before)

        session.ocrSnippet.cancel()
        #expect(input.isKeyboardCaptureEnabled)
        #expect(input.isMouseCaptureEnabled)
        useKeyboardAndMouse()
        #expect(await waitUntil { inputReports(on: socket).contains { $0.keyText == "KeyA down" } })
        await input.shutdown()
    }

    /// Keys typed while the box is up go to Overlook rather than being kept by capture, so Esc
    /// reaches the overlay.
    @Test func keysGoToTheAppWhileTheBoxIsUp() async throws {
        _ = try await openedSocket()
        session.startOCRSnippet()
        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: Self.window,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        )!
        #expect(input.routeMonitoredKeyEvent(escape) === escape)
        #expect(sent.all.isEmpty)
        await input.shutdown()
    }

    /// Capture that was off before the snippet stays off after it.
    @Test func captureThatWasOffStaysOff() async throws {
        _ = try await openedSocket()
        input.stopKeyboardCapture()
        session.startOCRSnippet()
        session.ocrSnippet.cancel()
        #expect(input.isKeyboardCaptureEnabled == false)
        #expect(input.isMouseCaptureEnabled)
        await input.shutdown()
    }
}
