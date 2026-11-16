import AVFoundation
import KokoroCoreML

/// Owns the Kokoro-82M CoreML models (shared by every output channel). Loading compiles
/// and warms the models on a background thread; until `isWarm`, Apple's voice speaks.
@MainActor
final class KokoroRuntime {
    let directory: URL
    private(set) var engine: KokoroEngine?
    private(set) var isWarm = false
    private var warming: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory
    }

    var isInstalled: Bool { KokoroEngine.isDownloaded(at: directory) }

    /// Loads the models in the background if they're installed and not loaded yet.
    func warmUp() {
        guard warming == nil, engine == nil, isInstalled else { return }
        let directory = directory
        warming = Task { [weak self] in
            let loaded: KokoroEngine? = await Task.detached(priority: .utility) {
                guard let engine = try? KokoroEngine(modelDirectory: directory) else { return nil }
                // The engine loads on its own thread; wait (up to two minutes on a first compile).
                for _ in 0..<1_200 where !engine.isReady {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return engine.isReady ? engine : nil
            }.value
            guard let self else { return }
            self.warming = nil
            if let loaded {
                self.engine = loaded
                self.isWarm = true
            }
        }
    }

    func unload() {
        warming?.cancel()
        warming = nil
        engine = nil
        isWarm = false
    }
}

/// Natural voice: Kokoro-82M on-device, played through AVAudioEngine.
///
/// The reply is cut into sentence-sized pieces (`SentenceChunker`, first piece short) and
/// synthesised one after another on a background thread while earlier pieces play, so
/// the first words start after one short synthesis rather than the whole reply.
@MainActor
final class KokoroSynthesizerEngine: SpeechSynthesizerEngine {
    let kind = SpeechVoiceKind.natural
    private(set) var isSpeaking = false

    private let runtime: KokoroRuntime
    private let settings: SpeechSettings
    private let audio = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var job: Task<Void, Never>?
    private var completion: (@MainActor (Bool) -> Void)?
    private var generation = 0
    private var scheduled = 0
    private var played = 0
    private var producerDone = false

    /// Gap between pieces, like a breath between sentences.
    nonisolated static let pieceGap: TimeInterval = 0.08

    init(runtime: KokoroRuntime, settings: SpeechSettings) {
        self.runtime = runtime
        self.settings = settings
        audio.attach(player)
        audio.connect(player, to: audio.mainMixerNode, format: KokoroEngine.audioFormat)
    }

    func speak(_ text: String, completion: @escaping @MainActor (Bool) -> Void) {
        end(finished: false)
        guard let engine = runtime.engine else { completion(false); return }
        let pieces = SentenceChunker.chunks(text)
        guard !pieces.isEmpty else { completion(true); return }

        generation += 1
        let current = generation
        self.completion = completion
        isSpeaking = true
        scheduled = 0
        played = 0
        producerDone = false
        do {
            if !audio.isRunning {
                audio.prepare()
                try audio.start()
            }
        } catch {
            end(finished: false)
            return
        }
        player.play()

        let voice = settings.naturalVoiceID
        job = Task { [weak self] in
            let stream = Self.buffers(engine: engine, pieces: pieces, voice: voice)
            for await buffer in stream {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.schedule(buffer, generation: current)
            }
            guard let self, self.generation == current else { return }
            self.producerDone = true
            self.checkDone(generation: current)
        }
    }

    func stop() {
        end(finished: false)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, generation current: Int) {
        scheduled += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.played += 1
                self.checkDone(generation: current)
            }
        }
    }

    private func checkDone(generation current: Int) {
        guard generation == current, producerDone, played >= scheduled else { return }
        end(finished: scheduled > 0)
    }

    private func end(finished: Bool) {
        generation += 1
        job?.cancel()
        job = nil
        if isSpeaking { player.stop() }
        isSpeaking = false
        let callback = completion
        completion = nil
        callback?(finished)
    }

    /// Synthesises the pieces in order off the main thread, yielding playable buffers.
    /// Cancelling the consumer cancels synthesis.
    nonisolated static func buffers(engine: KokoroEngine, pieces: [String], voice: String) -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { continuation in
            let producer = Task.detached(priority: .userInitiated) {
                for (index, piece) in pieces.enumerated() {
                    if Task.isCancelled { break }
                    if index > 0, let gap = silence(seconds: pieceGap) { continuation.yield(gap) }
                    guard let events = try? engine.speak(piece, voice: voice, paceToRealtime: false) else { continue }
                    for await event in events {
                        if Task.isCancelled { break }
                        if case .audio(let buffer) = event { continuation.yield(buffer) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    nonisolated private static func silence(seconds: TimeInterval) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(seconds * Double(KokoroEngine.sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: KokoroEngine.audioFormat, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        if let data = buffer.floatChannelData?[0] { data.initialize(repeating: 0, count: Int(frames)) }
        return buffer
    }
}
