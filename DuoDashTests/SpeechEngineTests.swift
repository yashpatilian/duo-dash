import XCTest
import Compression
@testable import DuoDash

// MARK: - Settings and engine selection

@MainActor
final class SpeechSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "SpeechSettingsTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsPreferNaturalEngines() {
        let settings = SpeechSettings(defaults: defaults, mode: .full)
        XCTAssertEqual(settings.recognizer, .whisper)
        XCTAssertEqual(settings.voice, .natural)
        XCTAssertEqual(settings.naturalVoiceID, NaturalVoice.defaultID)
        XCTAssertFalse(settings.whisperPrepared)
    }

    func testChoicesPersist() {
        let settings = SpeechSettings(defaults: defaults, mode: .full)
        settings.recognizer = .apple
        settings.voice = .apple
        settings.naturalVoiceID = "bm_george"
        settings.whisperVariantID = WhisperModelCatalog.largeTurbo.id
        settings.whisperPrepared = true

        let reloaded = SpeechSettings(defaults: defaults, mode: .full)
        XCTAssertEqual(reloaded.recognizer, .apple)
        XCTAssertEqual(reloaded.voice, .apple)
        XCTAssertEqual(reloaded.naturalVoiceID, "bm_george")
        XCTAssertEqual(reloaded.whisperVariantID, WhisperModelCatalog.largeTurbo.id)
        XCTAssertTrue(reloaded.whisperPrepared)
    }

    func testInvalidValuesFallBack() {
        defaults.set("demo", forKey: SpeechSettings.Keys.recognizer)
        defaults.set("robot", forKey: SpeechSettings.Keys.voice)
        defaults.set("xx_nobody", forKey: SpeechSettings.Keys.naturalVoice)
        let settings = SpeechSettings(defaults: defaults, mode: .full)
        XCTAssertEqual(settings.recognizer, .whisper)
        XCTAssertEqual(settings.voice, .natural)
        XCTAssertEqual(settings.naturalVoiceID, NaturalVoice.defaultID)
        settings.naturalVoiceID = "nope"
        XCTAssertEqual(settings.naturalVoiceID, NaturalVoice.defaultID)
    }

    func testModelNotReadyFallsBackToApple() {
        let settings = SpeechSettings(defaults: defaults, mode: .full)
        for state: SpeechModelState in [.notDownloaded, .downloading(0.5), .paused(0.3), .preparing, .failed("x")] {
            settings.whisperState = state
            settings.kokoroState = state
            XCTAssertEqual(settings.activeRecognizer, .apple, "\(state)")
            XCTAssertEqual(settings.activeVoice, .apple, "\(state)")
        }
        settings.whisperState = .ready
        settings.kokoroState = .ready
        XCTAssertEqual(settings.activeRecognizer, .whisper)
        XCTAssertEqual(settings.activeVoice, .natural)
        // The user's choice wins over a ready model.
        settings.recognizer = .apple
        settings.voice = .apple
        XCTAssertEqual(settings.activeRecognizer, .apple)
        XCTAssertEqual(settings.activeVoice, .apple)
    }

    func testModesOverrideChoices() {
        XCTAssertEqual(SpeechEngineSelection.recognizer(choice: .whisper, whisper: .ready, mode: .appleOnly), .apple)
        XCTAssertEqual(SpeechEngineSelection.voice(choice: .natural, natural: .ready, mode: .appleOnly), .apple)
        XCTAssertEqual(SpeechEngineSelection.recognizer(choice: .apple, whisper: .notDownloaded, mode: .demo), .demo)
        XCTAssertEqual(SpeechEngineSelection.voice(choice: .apple, natural: .notDownloaded, mode: .demo), .demo)
    }

    func testLaunchArgumentsPickMode() {
        XCTAssertEqual(SpeechRuntimeMode.current(arguments: ["-DemoSpeech"]), .demo)
        XCTAssertEqual(SpeechRuntimeMode.current(arguments: ["-AppleSpeech"]), .appleOnly)
        // Tests (and the Simulator) never download models.
        XCTAssertEqual(SpeechRuntimeMode.current(arguments: []), .appleOnly)
    }

    func testCenterHandsOutAppleEnginesUntilModelsAreReady() {
        let settings = SpeechSettings(defaults: defaults, mode: .appleOnly)
        let center = SpeechCenter(settings: settings)
        XCTAssertEqual(center.recognizer().kind, .apple)
        XCTAssertEqual(center.synthesizer(channel: "test").kind, .apple)
        let demo = SpeechCenter(settings: SpeechSettings(defaults: defaults, mode: .demo))
        XCTAssertEqual(demo.recognizer().kind, .demo)
        XCTAssertEqual(demo.synthesizer(channel: "test").kind, .demo)
        XCTAssertTrue(demo.synthesizer(channel: "test") === demo.synthesizer(channel: "test"))
    }

    func testWhisperVariantFollowsDeviceSupport() {
        XCTAssertEqual(WhisperModelCatalog.preferred(supported: ["openai_whisper-base", WhisperModelCatalog.largeTurbo.id]),
                       WhisperModelCatalog.largeTurbo)
        XCTAssertEqual(WhisperModelCatalog.preferred(supported: ["openai_whisper-small.en"]), WhisperModelCatalog.smallEnglish)
        XCTAssertLessThanOrEqual(WhisperModelCatalog.largeTurbo.downloadBytes, 650_000_000)
    }
}

// MARK: - Text helpers

final class SpeechTextTests: XCTestCase {
    func testChunksStartShortAndKeepEveryWord() {
        let text = "Starting route to Apple Park Visitor Center, via the Shell on Stevens Creek Boulevard, which adds about two minutes. 18 minutes. Turn left in 300 metres."
        let chunks = SentenceChunker.chunks(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertLessThanOrEqual(chunks[0].count, SentenceChunker.firstChunkLimit)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= SentenceChunker.maximumChunk })
        XCTAssertEqual(chunks.joined(separator: " ").split(separator: " "), text.split(separator: " "))
    }

    func testTinySentencesMerge() {
        XCTAssertEqual(SentenceChunker.chunks("OK. Done."), ["OK. Done."])
        XCTAssertEqual(SentenceChunker.chunks("   "), [])
        XCTAssertEqual(SentenceChunker.chunks("Hello there"), ["Hello there"])
    }

    func testSentencesRespectAbbreviationsAndDecimals() {
        XCTAssertEqual(SentenceChunker.sentences(in: "Head to St. Kilda Rd. now. It is 3.5 km away! Ready?"),
                       ["Head to St. Kilda Rd. now.", "It is 3.5 km away!", "Ready?"])
    }

    func testLongSentenceSplitsAtClauses() {
        let long = Array(repeating: "word", count: 80).joined(separator: " ")
        let parts = SentenceChunker.split(long, limit: 100)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 100 })
        XCTAssertEqual(parts.joined(separator: " "), long)
    }

    func testLocaleVariants() {
        let au = SpeechLocale(Locale(identifier: "en_AU"))
        XCTAssertEqual(au.whisperLanguage, "en")
        XCTAssertTrue(au.prefersBritishSpelling)
        XCTAssertNotNil(au.whisperPrompt)
        let us = SpeechLocale(Locale(identifier: "en_US"))
        XCTAssertFalse(us.prefersBritishSpelling)
        XCTAssertNil(us.whisperPrompt)
        XCTAssertEqual(SpeechLocale(Locale(identifier: "de_DE")).whisperLanguage, "de")
    }

    func testWhisperCleanerDropsTagsAndEchoedPrompt() {
        XCTAssertEqual(WhisperTextCleaner.clean(" [BLANK_AUDIO] Take me  home (engine noise) "), "Take me home")
        let prompt = SpeechLocale(Locale(identifier: "en_GB")).whisperPrompt
        XCTAssertEqual(WhisperTextCleaner.clean(" Colour, favourite, centre, metres, kilometres, motorway.", prompt: prompt), "")
        XCTAssertEqual(WhisperTextCleaner.clean("Find the nearest centre", prompt: prompt), "Find the nearest centre")
    }
}

// MARK: - End of speech

final class EndOfSpeechDetectorTests: XCTestCase {
    private let frame = 0.1

    private func run(_ detector: inout EndOfSpeechDetector, level: Float, seconds: Double) -> EndOfSpeechDetector.Decision {
        var decision = EndOfSpeechDetector.Decision.waiting
        for _ in 0..<Int((seconds / frame).rounded()) {
            decision = detector.process(levelDB: level, duration: frame)
        }
        return decision
    }

    func testSpeechThenPauseEnds() {
        var detector = EndOfSpeechDetector()
        XCTAssertEqual(run(&detector, level: -60, seconds: 0.5), .waiting)        // cabin noise
        XCTAssertEqual(run(&detector, level: -25, seconds: 1.5), .speaking)
        XCTAssertEqual(run(&detector, level: -60, seconds: 0.6), .speaking)       // short pause between words
        XCTAssertEqual(run(&detector, level: -25, seconds: 0.5), .speaking)
        XCTAssertEqual(run(&detector, level: -60, seconds: 1.3), .endOfSpeech)
    }

    func testClicksDontCountAsSpeech() {
        var detector = EndOfSpeechDetector()
        _ = run(&detector, level: -60, seconds: 0.5)
        _ = detector.process(levelDB: -20, duration: 0.05)
        XCTAssertFalse(detector.hasSpeech)
    }

    func testSilenceGivesUp() {
        var detector = EndOfSpeechDetector()
        XCTAssertEqual(run(&detector, level: -60, seconds: 6.1), .noSpeech)
    }

    func testLoudCabinRaisesTheThreshold() {
        var detector = EndOfSpeechDetector()
        _ = run(&detector, level: -35, seconds: 1)    // road noise
        XCTAssertGreaterThan(detector.threshold, -30)
        XCTAssertEqual(run(&detector, level: -34, seconds: 1), .waiting)
        XCTAssertEqual(run(&detector, level: -15, seconds: 0.5), .speaking)
    }
}

// MARK: - Fake engines, dictation and cancellation

@MainActor
final class DemoSpeechEngineTests: XCTestCase {
    func testDemoRecognizerStreamsPartialsThenFinal() async throws {
        let engine = DemoRecognizerEngine(transcript: "take me home", step: .milliseconds(5))
        var events: [RecognitionEvent] = []
        let done = expectation(description: "final")
        try await engine.start(locale: .current) { event in
            events.append(event)
            if case .final = event { done.fulfill() }
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(events, [.partial("take"), .partial("take me"), .partial("take me home"), .final("take me home")])
    }

    func testFinishDeliversWhatWasHeardSoFar() async throws {
        let engine = DemoRecognizerEngine(transcript: "one two three four", step: .seconds(5))
        var finals: [String] = []
        try await engine.start(locale: .current) { event in
            if case .final(let text) = event { finals.append(text) }
        }
        engine.finish()
        engine.finish()
        XCTAssertEqual(finals, [""])
    }

    func testCancelledRecognizerIsSilent() async throws {
        let engine = DemoRecognizerEngine(transcript: "hello there", step: .milliseconds(5))
        var events: [RecognitionEvent] = []
        try await engine.start(locale: .current) { events.append($0) }
        engine.cancel()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(events.isEmpty)
    }

    func testDemoSynthesizerCompletesOrReportsStop() async {
        let engine = DemoSynthesizerEngine(duration: .milliseconds(10))
        let finished = expectation(description: "finished")
        engine.speak("Turn left") { XCTAssertTrue($0); finished.fulfill() }
        XCTAssertTrue(engine.isSpeaking)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(engine.isSpeaking)

        var results: [Bool] = []
        engine.duration = .seconds(5)
        engine.speak("Old prompt") { results.append($0) }
        engine.speak("New prompt") { results.append($0) }   // replaces: old one reports false
        engine.stop()
        XCTAssertEqual(results, [false, false])
        XCTAssertEqual(engine.spoken, ["Turn left", "Old prompt", "New prompt"])
        XCTAssertFalse(engine.isSpeaking)
    }

    func testDictationUsesTheCenterEngineAndHandsBackFinalText() async throws {
        let suite = "DictationDemoTests"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = SpeechCenter(settings: SpeechSettings(defaults: defaults, mode: .demo))
        let dictation = Dictation()
        dictation.center = center
        let id = UUID()
        var partials: [String] = []
        let done = expectation(description: "finish")
        var final = ""
        await dictation.toggle(id: id) { partials.append($0) } onFinish: { final = $0; done.fulfill() }
        XCTAssertEqual(dictation.activeID, id)
        XCTAssertEqual(dictation.activeEngine, .demo)
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(final, "Take me home")
        XCTAssertEqual(partials.last, "Take me home")
        XCTAssertNil(dictation.activeID)
    }

    func testTappingAgainStopsDictation() async throws {
        let suite = "DictationStopTests"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = SpeechCenter(settings: SpeechSettings(defaults: defaults, mode: .demo))
        let dictation = Dictation()
        dictation.center = center
        let id = UUID()
        var finished = 0
        await dictation.toggle(id: id) { _ in } onFinish: { _ in finished += 1 }
        await dictation.toggle(id: id) { _ in } onFinish: { _ in finished += 1 }
        XCTAssertNil(dictation.activeID)
        XCTAssertEqual(finished, 0, "nothing heard yet, so nothing handed back")
    }

    func testSpokenOutputReportsFinishAndStop() async {
        let suite = "SpokenOutputTests"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = SpeechCenter(settings: SpeechSettings(defaults: defaults, mode: .demo))
        let output = SpokenOutput(channel: "test", center: center)
        let finished = expectation(description: "onFinish")
        output.onFinish = { finished.fulfill() }
        output.speak("Rerouting")
        XCTAssertTrue(output.isSpeaking)
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertFalse(output.isSpeaking)
        let demo = center.synthesizer(channel: "test") as? DemoSynthesizerEngine
        XCTAssertEqual(demo?.spoken, ["Rerouting"])

        output.isMuted = true
        output.speak("Ignored")
        XCTAssertEqual(demo?.spoken, ["Rerouting"])
    }
}

// MARK: - Model unpacking

final class TarGzExtractorTests: XCTestCase {
    private func tarHeader(name: String, size: Int, type: Character = "0") -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        for (i, b) in name.utf8.prefix(100).enumerated() { header[i] = b }
        let sizeField = String(size, radix: 8).leftPad(11) + "\0"
        for (i, b) in sizeField.utf8.enumerated() { header[124 + i] = b }
        header[156] = UInt8(ascii: type.unicodeScalars.first!)
        for (i, b) in "ustar\0".utf8.enumerated() { header[257 + i] = b }
        for i in 148..<156 { header[i] = 0x20 }
        let checksum = header.reduce(0) { $0 + Int($1) }
        for (i, b) in (String(checksum, radix: 8).leftPad(6) + "\0 ").utf8.enumerated() { header[148 + i] = b }
        return Data(header)
    }

    private func entry(_ name: String, _ contents: Data, type: Character = "0") -> Data {
        var data = tarHeader(name: name, size: contents.count, type: type)
        data.append(contents)
        data.append(Data(count: (512 - contents.count % 512) % 512))
        return data
    }

    private func gzip(_ data: Data) throws -> Data {
        var output = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        let capacity = data.count + 1024
        var buffer = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { raw in
            compression_encode_buffer(&buffer, capacity, raw.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        XCTAssertGreaterThan(written, 0)
        output.append(contentsOf: buffer[0..<written])
        output.append(Data(count: 8))   // CRC/size aren't checked
        return output
    }

    func testExtractsFilesDirectoriesAndPaxNames() throws {
        let weights = Data((0..<5_000).map { UInt8($0 % 251) })
        let longName = "kokoro_backend.mlmodelc/" + String(repeating: "deep/", count: 25) + "weight.bin"
        var tar = Data()
        tar.append(entry("voices/", Data(), type: "5"))
        tar.append(entry("voices/af_heart.bin", Data("voice".utf8)))
        tar.append(entry("voices/._af_heart.bin", Data("apple double".utf8)))
        let pax = "\(longName.count + 15) path=\(longName)\n"
        tar.append(entry("PaxHeader", Data(pax.utf8), type: "x"))
        tar.append(entry("ignored-short-name", weights))
        tar.append(Data(count: 1024))

        let dir = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let archive = dir.appending(component: "m.tar.gz")
        try gzip(tar).write(to: archive)
        let out = dir.appending(component: "out")
        try TarGzExtractor.extract(archive, to: out)

        XCTAssertEqual(try Data(contentsOf: out.appending(path: "voices/af_heart.bin")), Data("voice".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appending(path: "voices/._af_heart.bin").path))
        XCTAssertEqual(try Data(contentsOf: out.appending(path: longName)), weights)
    }

    func testRejectsPathTraversal() throws {
        var tar = entry("../escape.txt", Data("x".utf8))
        tar.append(Data(count: 1024))
        let dir = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let archive = dir.appending(component: "bad.tar.gz")
        try gzip(tar).write(to: archive)
        XCTAssertThrowsError(try TarGzExtractor.extract(archive, to: dir.appending(component: "out")))
    }

    func testRejectsNonGzip() throws {
        let file = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try Data("not gzip at all".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try TarGzExtractor.extract(file, to: file.deletingLastPathComponent())) {
            XCTAssertEqual($0 as? TarGzExtractor.Failure, .notGzip)
        }
    }
}

private extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
