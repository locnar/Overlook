import Foundation
import Testing
@testable import Overlook

@MainActor
@Suite("Capture manager")
struct CaptureManagerTests {
    let scratch = ScratchDefaults()
    let connection: SessionConnection
    let capture: CaptureManager

    init() {
        let catalog = KVMDeviceManager(
            defaults: scratch.defaults,
            credentials: FakeCredentialStore(),
            trustStore: Fixtures.trustStore(scratch)
        )
        connection = SessionConnection(catalog: catalog)
        capture = CaptureManager(webRTCManager: WebRTCManager(), connection: connection, defaults: scratch.defaults)
    }

    private func connect(name: String = "Test KVM") {
        connection.connectedDevice = Fixtures.device(name: name)
    }

    private func disconnect() {
        connection.connectedDevice = nil
    }

    /// A fixed local time, so the expected file names can be written out in full.
    private static let sampleDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 13
        components.hour = 14
        components.minute = 5
        components.second = 22
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    private func makeTemporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverlookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Settings

    @Test func defaultsWhenNothingIsSaved() {
        #expect(capture.recordingMode == .videoAndAudio)
        #expect(capture.videoCodec == .h264)
        #expect(capture.showsRegionOutline)
        #expect(capture.screenshotsFolder == CaptureManager.Folder.screenshots.defaultURL)
        #expect(capture.recordingsFolder == CaptureManager.Folder.recordings.defaultURL)
        #expect(capture.isRecording == false)
        #expect(capture.captureRegion == nil)
    }

    @Test func defaultFoldersAreOverlookUnderPicturesAndMovies() {
        let screenshots = CaptureManager.Folder.screenshots.defaultURL
        let recordings = CaptureManager.Folder.recordings.defaultURL
        #expect(screenshots.lastPathComponent == "Overlook")
        #expect(screenshots.deletingLastPathComponent().lastPathComponent == "Pictures")
        #expect(recordings.lastPathComponent == "Overlook")
        #expect(recordings.deletingLastPathComponent().lastPathComponent == "Movies")
    }

    @Test func readsSavedSettings() {
        let defaults = scratch.defaults
        defaults.set("audioOnly", forKey: "overlook.capture.recordingMode")
        defaults.set("hevc", forKey: "overlook.capture.videoCodec")
        defaults.set(false, forKey: "overlook.capture.showsRegionOutline")
        defaults.set("/tmp/shots", forKey: "overlook.capture.screenshotsFolder")
        defaults.set("/tmp/movies", forKey: "overlook.capture.recordingsFolder")

        let reloaded = CaptureManager(webRTCManager: WebRTCManager(), connection: connection, defaults: defaults)

        #expect(reloaded.recordingMode == .audioOnly)
        #expect(reloaded.videoCodec == .hevc)
        #expect(reloaded.showsRegionOutline == false)
        #expect(reloaded.screenshotsFolder.path == "/tmp/shots")
        #expect(reloaded.recordingsFolder.path == "/tmp/movies")
    }

    @Test func unknownSavedValuesFallBackToDefaults() {
        scratch.defaults.set("betamax", forKey: "overlook.capture.recordingMode")
        scratch.defaults.set("mpeg2", forKey: "overlook.capture.videoCodec")
        scratch.defaults.set("", forKey: "overlook.capture.screenshotsFolder")

        let reloaded = CaptureManager(webRTCManager: WebRTCManager(), connection: connection, defaults: scratch.defaults)

        #expect(reloaded.recordingMode == .videoAndAudio)
        #expect(reloaded.videoCodec == .h264)
        #expect(reloaded.screenshotsFolder == CaptureManager.Folder.screenshots.defaultURL)
    }

    @Test func changesAreSavedUnderTheirKeys() {
        capture.recordingMode = .videoOnly
        capture.videoCodec = .hevc
        capture.showsRegionOutline = false
        capture.screenshotsFolder = URL(fileURLWithPath: "/tmp/a", isDirectory: true)
        capture.resetFolder(.screenshots)

        let defaults = scratch.defaults
        #expect(defaults.string(forKey: "overlook.capture.recordingMode") == "videoOnly")
        #expect(defaults.string(forKey: "overlook.capture.videoCodec") == "hevc")
        #expect(defaults.object(forKey: "overlook.capture.showsRegionOutline") as? Bool == false)
        #expect(defaults.string(forKey: "overlook.capture.screenshotsFolder") == CaptureManager.Folder.screenshots.defaultURL.path)
    }

    @Test func recordingFileTypesFollowTheMode() {
        #expect(RecordingMode.videoAndAudio.fileExtension == "mp4")
        #expect(RecordingMode.videoOnly.fileExtension == "mp4")
        #expect(RecordingMode.audioOnly.fileExtension == "m4a")
    }

    // MARK: - File names

    @Test func fileNameCarriesTheTimestamp() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = capture.makeFileURL(in: folder, extension: "png", date: Self.sampleDate)

        #expect(url.lastPathComponent == "Overlook 2026-09-13 at 14.05.22.png")
        #expect(url.deletingLastPathComponent().path == folder.path)
    }

    @Test func fileNameCarriesTheConnectedDeviceNameMadeSafe() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        connect(name: " Rack/3: Lab ")

        let url = capture.makeFileURL(in: folder, extension: "mp4", date: Self.sampleDate)

        #expect(url.lastPathComponent == "Overlook Rack-3- Lab 2026-09-13 at 14.05.22.mp4")
    }

    @Test func fileNameIsMadeUniqueInTheFolder() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = capture.makeFileURL(in: folder, extension: "png", date: Self.sampleDate)
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = capture.makeFileURL(in: folder, extension: "png", date: Self.sampleDate)
        FileManager.default.createFile(atPath: second.path, contents: Data())
        let third = capture.makeFileURL(in: folder, extension: "png", date: Self.sampleDate)

        #expect(second.lastPathComponent == "Overlook 2026-09-13 at 14.05.22 (2).png")
        #expect(third.lastPathComponent == "Overlook 2026-09-13 at 14.05.22 (3).png")
    }

    // MARK: - Needing a connection

    @Test func recordingNeedsAConnection() {
        capture.startRecording()
        #expect(capture.isRecording == false)
        #expect(capture.notice?.title == "Not connected")
        #expect(capture.notice?.isError == true)
    }

    @Test func regionSelectionNeedsAConnection() {
        capture.beginRegionSelection()
        #expect(capture.isSelectingRegion == false)
        #expect(capture.notice?.title == "Not connected")

        connect()
        capture.beginRegionSelection()
        #expect(capture.isSelectingRegion)
    }

    @Test func disconnectingEndsARegionSelection() {
        connect()
        capture.beginRegionSelection()

        disconnect()

        #expect(capture.isSelectingRegion == false)
    }

    @Test func aDisconnectKeepsTheRegionItself() {
        connect()
        capture.setCaptureRegion(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), videoSize: nil)

        disconnect()

        #expect(capture.captureRegion == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }

    // MARK: - The region

    @Test func regionIsClampedToTheFrame() {
        capture.setCaptureRegion(CGRect(x: 0.5, y: -0.25, width: 1, height: 0.5), videoSize: nil)
        #expect(capture.captureRegion == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.25))
    }

    @Test func aRegionWithNoAreaIsIgnored() {
        capture.setCaptureRegion(CGRect(x: 0.5, y: 0.5, width: 0, height: 0.3), videoSize: nil)
        #expect(capture.captureRegion == nil)
        capture.setCaptureRegion(CGRect(x: 2, y: 2, width: 0.5, height: 0.5), videoSize: nil)
        #expect(capture.captureRegion == nil)
    }

    @Test func toggleSelectsThenClearsTheRegion() {
        connect()
        capture.toggleRegionSelection()
        #expect(capture.isSelectingRegion)

        capture.toggleRegionSelection()
        #expect(capture.isSelectingRegion == false)

        capture.setCaptureRegion(CGRect(x: 0, y: 0, width: 0.5, height: 0.5), videoSize: CGSize(width: 1920, height: 1080))
        #expect(capture.notice?.title == "Capture region set — 960 × 540")

        capture.toggleRegionSelection()
        #expect(capture.captureRegion == nil)
        #expect(capture.notice?.title == "Capture region off")
    }

    @Test func regionSizeTextNeedsARegionAndAKnownSize() {
        #expect(capture.regionSizeText(videoSize: CGSize(width: 1920, height: 1080)) == nil)
        capture.setCaptureRegion(CGRect(x: 0, y: 0, width: 0.5, height: 1), videoSize: nil)
        #expect(capture.regionSizeText(videoSize: nil) == nil)
        #expect(capture.regionSizeText(videoSize: CGSize(width: 1920, height: 1080)) == "960 × 1080")
    }
}

@Suite("Capture region geometry")
struct CaptureRegionGeometryTests {
    private let frame = CGSize(width: 1000, height: 1000)

    @Test func theWholeRegionIsTheWholeFrame() {
        #expect(CaptureRegionGeometry.pixelRect(for: CGRect(x: 0, y: 0, width: 1, height: 1), in: CGSize(width: 1920, height: 1080))
            == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    @Test func oddFrameSizesAreTrimmedToEven() {
        #expect(CaptureRegionGeometry.pixelRect(for: CGRect(x: 0, y: 0, width: 1, height: 1), in: CGSize(width: 1921, height: 1081))
            == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    @Test func edgesSnapToEvenPixels() {
        #expect(CaptureRegionGeometry.pixelRect(for: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), in: frame)
            == CGRect(x: 100, y: 100, width: 500, height: 500))
        // 103 → 102, 201 → 200, 403 → 402, 501 → 500.
        #expect(CaptureRegionGeometry.pixelRect(for: CGRect(x: 0.103, y: 0.201, width: 0.3, height: 0.3), in: frame)
            == CGRect(x: 102, y: 200, width: 300, height: 300))
    }

    @Test func aTinyRegionGrowsToTheMinimumAndStaysInside() {
        #expect(CaptureRegionGeometry.pixelRect(for: CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001), in: frame)
            == CGRect(x: 500, y: 500, width: 16, height: 16))
        #expect(CaptureRegionGeometry.pixelRect(for: CGRect(x: 0.995, y: 0.995, width: 0.005, height: 0.005), in: frame)
            == CGRect(x: 984, y: 984, width: 16, height: 16))
    }

    @Test func aRegionOutsideTheFrameMeansTheWholeFrame() {
        #expect(CaptureRegionGeometry.pixelRect(for: CGRect(x: 2, y: 2, width: 1, height: 1), in: frame)
            == CGRect(x: 0, y: 0, width: 1000, height: 1000))
    }

    @Test func sizeTextIsWidthByHeight() {
        #expect(CaptureRegionGeometry.sizeText(for: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), in: CGSize(width: 1280, height: 720))
            == "640 × 360")
    }
}
