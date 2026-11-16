import XCTest
import AVFoundation
import CoreLocation
@testable import DuoDash

@MainActor
final class DashcamTests: XCTestCase {
    private var base: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appending(path: "DashcamTests-\(UUID().uuidString)")
        suiteName = "DashcamTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func make(free: Int64 = 50_000_000_000,
                      thermal: ProcessInfo.ThermalState = .nominal,
                      loopMinutes: Int = 5) -> (DashcamModel, DemoDashcamRecorder, Box) {
        let settings = DashcamSettings(defaults: defaults)
        settings.loopMinutes = loopMinutes
        let recorder = DemoDashcamRecorder()
        let box = Box(free: free, thermal: thermal)
        let model = DashcamModel(settings: settings, recorder: recorder, storage: DashcamStorage(base: base),
                                 freeSpace: { box.free }, thermalState: { box.thermal },
                                 photoSaver: { urls in box.photos.append(contentsOf: urls) },
                                 observesLifecycle: false)
        return (model, recorder, box)
    }

    private final class Box {
        var free: Int64
        var thermal: ProcessInfo.ThermalState
        var photos: [URL] = []
        init(free: Int64, thermal: ProcessInfo.ThermalState) { self.free = free; self.thermal = thermal }
    }

    private func loopNames(_ model: DashcamModel) -> [String] {
        model.storage.loopSegments().map(\.lastPathComponent)
    }

    /// Rotates `count` times and waits for each closed segment to be processed.
    private func rotate(_ model: DashcamModel, _ count: Int) async {
        for _ in 0..<count {
            model.rotateSegment()
            try? await Task.sleep(for: .milliseconds(5))
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(30))
    }

    // MARK: Loop budget

    func testLoopKeepsOnlyTheBudget() async {
        let (model, recorder, _) = make(loopMinutes: 5)
        XCTAssertEqual(model.segmentLimit, 5)
        await model.start()
        XCTAssertEqual(model.state, .recording)
        XCTAssertNotNil(model.recordingStartedAt)

        await rotate(model, 12)
        // 5 finished segments plus the one being recorded.
        let names = loopNames(model)
        XCTAssertEqual(names.count, 6)
        XCTAssertEqual(names.last, model.currentSegment?.lastPathComponent)
        // The newest ones survive.
        let expected = recorder.recordedFiles.suffix(6).map(\.lastPathComponent)
        XCTAssertEqual(names, expected)
        // Every finished segment has a sidecar.
        for url in model.storage.loopSegments().dropLast() {
            XCTAssertNotNil(model.storage.readSidecar(for: url), url.lastPathComponent)
        }

        model.stop()
        await waitUntil { self.loopNames(model).count == 5 }
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(loopNames(model).count, 5, "stopping closes the last file and prunes to the budget")
    }

    func testShorterLoopPrunesOnNextSegment() async {
        let (model, _, _) = make(loopMinutes: 10)
        await model.start()
        await rotate(model, 10)
        XCTAssertEqual(loopNames(model).count, 11)
        model.settings.loopMinutes = 5
        model.pruneLoop()
        XCTAssertEqual(loopNames(model).count, 6)
        model.stop()
    }

    // MARK: Saving clips

    func testSaveClipMovesPreviousAndCurrentSegments() async throws {
        let (model, _, _) = make()
        model.ingest(CLLocation(latitude: -37.8136, longitude: 144.9631))
        await model.start()
        await rotate(model, 3)
        let before = loopNames(model)
        let previous = before[before.count - 2]
        let current = try XCTUnwrap(model.currentSegment?.lastPathComponent)

        let saved = await model.saveClip(reason: "Test")
        let clip = try XCTUnwrap(saved)
        XCTAssertEqual(clip.segments.map(\.lastPathComponent), [previous, current])
        XCTAssertTrue(clip.folder.path().contains("/Saved/"))
        for name in [previous, current] {
            XCTAssertFalse(loopNames(model).contains(name), "\(name) left the loop")
            XCTAssertTrue(FileManager.default.fileExists(atPath: clip.folder.appending(path: name).path()))
        }
        // Sidecars moved along with the video.
        XCTAssertNotNil(model.storage.readSidecar(for: clip.folder.appending(path: current)))
        XCTAssertEqual(model.savedClips.map(\.id), [clip.id])
        XCTAssertEqual(model.state, .recording, "a new segment started straight away")
        XCTAssertNotEqual(model.currentSegment?.lastPathComponent, current)
        XCTAssertEqual(model.message, "Clip saved")
        XCTAssertTrue(model.protected.isEmpty)

        await model.saveToPhotos(clip)
        XCTAssertEqual(model.message, "Demo: not saved to Photos")
        model.stop()
    }

    func testSavedClipsAreNeverPruned() async throws {
        let (model, _, _) = make(loopMinutes: 5)
        await model.start()
        await rotate(model, 2)
        let saved = await model.saveClip()
        let clip = try XCTUnwrap(saved)
        await rotate(model, 20)
        XCTAssertEqual(loopNames(model).count, 6)
        let reloaded = try XCTUnwrap(model.savedClips.first)
        XCTAssertEqual(reloaded.segments.count, 2)
        for url in clip.segments {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path()), "\(url.lastPathComponent) kept")
        }
        model.stop()
    }

    func testProtectedSegmentsSurvivePruning() {
        let storage = DashcamStorage(base: base)
        var urls: [URL] = []
        for _ in 0..<8 {
            let url = storage.newSegmentURL()
            try? Data("x".utf8).write(to: url)
            urls.append(url)
        }
        let deleted = storage.prune(keeping: 3, protected: [urls[0].lastPathComponent, urls[1].lastPathComponent])
        XCTAssertEqual(deleted.map(\.lastPathComponent), urls[2..<5].map(\.lastPathComponent))
        let left = storage.loopSegments().map(\.lastPathComponent)
        XCTAssertEqual(left, [urls[0], urls[1], urls[5], urls[6], urls[7]].map(\.lastPathComponent))
    }

    func testSaveWhenStoppedKeepsTheLastTwoSegments() async throws {
        let (model, _, _) = make()
        await model.start()
        await rotate(model, 3)
        model.stop()
        await waitUntil { model.currentSegment == nil && self.loopNames(model).count == 4 }
        let last = Array(loopNames(model).suffix(2))
        let saved = await model.saveClip()
        let clip = try XCTUnwrap(saved)
        XCTAssertEqual(clip.segments.map(\.lastPathComponent), last)
        XCTAssertEqual(loopNames(model).count, 2)
    }

    func testDeleteClip() async throws {
        let (model, _, _) = make()
        await model.start()
        await rotate(model, 1)
        let saved = await model.saveClip()
        let clip = try XCTUnwrap(saved)
        model.stop()
        model.rename(clip, to: "Hume Highway")
        XCTAssertEqual(model.savedClips.first?.title, "Hume Highway")
        model.delete(clip)
        XCTAssertTrue(model.savedClips.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.folder.path()))
    }

    // MARK: Disk space

    func testRefusesToStartWhenDiskIsLow() async {
        let (model, recorder, _) = make(free: 1_500_000_000)
        await model.start()
        XCTAssertEqual(model.state, .unavailable(DashcamModel.lowDiskText))
        XCTAssertEqual(model.message, DashcamModel.lowDiskText)
        XCTAssertTrue(recorder.recordedFiles.isEmpty)
        XCTAssertFalse(recorder.isSessionRunning)
    }

    func testStopsWhenDiskRunsLowWhileRecording() async {
        let (model, recorder, box) = make()
        await model.start()
        await rotate(model, 2)
        box.free = 500_000_000
        model.rotateSegment()
        XCTAssertEqual(model.state, .unavailable(DashcamModel.lowDiskText))
        XCTAssertFalse(recorder.isSessionRunning)
        XCTAssertNil(model.currentSegment)
    }

    // MARK: Heat

    func testThermalDecision() {
        XCTAssertEqual(DashcamThermalAction(.nominal), .normal)
        XCTAssertEqual(DashcamThermalAction(.fair), .normal)
        XCTAssertEqual(DashcamThermalAction(.serious), .reduced)
        XCTAssertEqual(DashcamThermalAction(.critical), .paused)
        XCTAssertEqual(DashcamThermalAction(.serious).quality, .hd720)
        XCTAssertEqual(DashcamThermalAction(.fair).quality, .hd1080)
    }

    func testHeatDropsTo720pThenPausesThenRecovers() async {
        let (model, recorder, _) = make()
        await model.start()
        XCTAssertEqual(recorder.quality, .hd1080)

        await model.handleThermalState(.serious)
        XCTAssertEqual(model.state, .recording)
        XCTAssertEqual(model.quality, .hd720)
        XCTAssertEqual(recorder.quality, .hd720)
        XCTAssertEqual(model.heatWarning, DashcamModel.heatReducedText)

        await model.handleThermalState(.critical)
        XCTAssertEqual(model.state, .interrupted(DashcamModel.heatPausedText))
        XCTAssertFalse(recorder.isSessionRunning)

        await model.handleThermalState(.fair)
        XCTAssertEqual(model.state, .recording)
        XCTAssertEqual(model.quality, .hd1080)
        XCTAssertNil(model.heatWarning)
        model.stop()
    }

    func testStartsAt720pWhenAlreadyHot() async {
        let (model, recorder, _) = make(thermal: .serious)
        await model.start()
        XCTAssertEqual(model.state, .recording)
        XCTAssertEqual(recorder.quality, .hd720)
        model.stop()
    }

    // MARK: Lifecycle and permissions

    func testInterruptionPausesAndResumes() async {
        let (model, recorder, _) = make()
        await model.start()
        recorder.simulateInterruption("Paused: Duo Dash isn't on screen")
        await waitUntil { model.state != .recording }
        XCTAssertEqual(model.state, .interrupted("Paused: Duo Dash isn't on screen"))
        XCTAssertNil(model.currentSegment)
        recorder.simulateInterruptionEnded()
        await waitUntil { model.state == .recording }
        XCTAssertEqual(model.state, .recording)
        XCTAssertNotNil(model.currentSegment)
        model.stop()
    }

    func testPermissionDenied() async {
        let (model, recorder, _) = make()
        recorder.permission = .notDetermined
        recorder.grantsAccess = false
        await model.start()
        XCTAssertEqual(model.state, .permissionDenied)
        XCTAssertTrue(recorder.recordedFiles.isEmpty)
    }

    func testRuntimeFailureShowsUnavailable() async {
        let (model, recorder, _) = make()
        await model.start()
        recorder.simulateFailure("Camera broke")
        await waitUntil { model.state != .recording }
        XCTAssertEqual(model.state, .unavailable("Camera broke"))
    }

    // MARK: Location

    func testSidecarTrackSampledOncePerSecond() async throws {
        let (model, _, _) = make()
        await model.start()
        let start = Date()
        for tenth in 0..<35 {
            model.ingest(CLLocation(coordinate: CLLocationCoordinate2D(latitude: -37.8 + Double(tenth) * 0.0001, longitude: 144.9),
                                    altitude: 30, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 16,
                                    timestamp: start.addingTimeInterval(Double(tenth) / 10)))
        }
        let segment = try XCTUnwrap(model.currentSegment)
        model.rotateSegment()
        let sidecar = try XCTUnwrap(model.storage.readSidecar(for: segment))
        XCTAssertEqual(sidecar.track.count, 4, "0 s, 1 s, 2 s, 3 s")
        XCTAssertEqual(sidecar.track.first?.speed, 16)
        model.stop()
    }

    func testSegmentGetsStartLocationMetadata() async throws {
        let (model, recorder, _) = make()
        model.ingest(CLLocation(coordinate: CLLocationCoordinate2D(latitude: 37.3317, longitude: -122.0302),
                                altitude: 12.5, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: .now))
        await model.start()
        let url = try XCTUnwrap(model.currentSegment)
        XCTAssertEqual(recorder.infos[url]?.iso6709, "+37.3317-122.0302+12.500/")
        XCTAssertEqual(DashcamSegmentInfo.iso6709(latitude: -7.5, longitude: 5.25, altitude: nil), "-07.5000+005.2500/")
        let items = DashcamCaptureEngine.metadata(for: try XCTUnwrap(recorder.infos[url]))
        XCTAssertTrue(items.contains { $0.identifier == .quickTimeMetadataLocationISO6709 })
        XCTAssertTrue(items.contains { $0.identifier == .quickTimeMetadataCreationDate })
        model.stop()
    }

    // MARK: Settings

    func testSettingsPersist() {
        let settings = DashcamSettings(defaults: defaults)
        XCTAssertEqual(settings.loopMinutes, 10, "10-minute loop by default")
        XCTAssertFalse(settings.recordsAudio)
        XCTAssertFalse(settings.autoStart)
        XCTAssertEqual(settings.lens, .ultraWide, "Ultra Wide by default")

        settings.lens = .wide
        XCTAssertEqual(DashcamSettings(defaults: defaults).lens, .wide)
        settings.loopMinutes = 20
        settings.recordsAudio = true
        settings.autoStart = true
        let reloaded = DashcamSettings(defaults: defaults)
        XCTAssertEqual(reloaded.loopMinutes, 20)
        XCTAssertTrue(reloaded.recordsAudio)
        XCTAssertTrue(reloaded.autoStart)

        reloaded.loopMinutes = 7
        XCTAssertEqual(reloaded.loopMinutes, DashcamSettings.defaultLoopMinutes, "only 2/5/10/20/30")
        XCTAssertEqual(DashcamSettings(defaults: defaults).loopMinutes, DashcamSettings.defaultLoopMinutes)
    }

    func testAutoStart() async {
        let (model, _, _) = make()
        await model.startIfAutoStart()
        XCTAssertEqual(model.state, .idle)
        model.settings.autoStart = true
        await model.startIfAutoStart()
        XCTAssertEqual(model.state, .recording)
        model.stop()
    }
}
