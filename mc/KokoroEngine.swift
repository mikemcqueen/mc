#if canImport(KokoroSwift)
import Foundation
import MLX
import KokoroSwift

/// `SpeechEngine` backed by the on-device Kokoro-82M neural model (via KokoroSwift/MLX).
/// Apple-Silicon **device only** — there is no Metal/MLX on the simulator, so `Speaker`
/// only ever builds this when `isAvailable` is true and otherwise falls back to
/// `AVSpeechEngine`.
///
/// Generation is synchronous and heavy, so it runs on a background serial queue; only the
/// resulting `[Float]` PCM crosses back to the main actor, where it's handed to the
/// injected `PCMPlayer` (the `Listener`) so it rides the same VPIO graph that echo-cancels
/// TTS out of the mic. A monotonically increasing `generation` discards the result of any
/// in-flight generation that a `stop()` (barge-in) has superseded — the synchronous
/// `generateAudio` call itself can't be cancelled mid-flight.
@MainActor
final class KokoroEngine: SpeechEngine {

    private(set) var isSpeaking = false

    /// Kokoro speed multiplier (1.0 = normal). Independent of `AVSpeechEngine`'s word-rate
    /// scale; the `Speaker` facade does not forward AVSpeech rates here.
    var rate: Float = 1.0

    var onFinish: (() -> Void)?

    /// Plays generated PCM through the AEC graph. Weak: it's the `Listener`, owned by
    /// `SessionController`, which also owns this engine's `Speaker`.
    private weak var player: PCMPlayer?

    /// All KokoroTTS / MLX state lives here, touched only from `queue`.
    private let synth: KokoroSynth
    /// A *single, persistent* OS thread for all MLX work. MLX caches compiled Metal
    /// kernels and ties GPU evaluation to the calling thread; a GCD queue hops across the
    /// thread pool, which defeats that cache (kernels JIT-recompile every call) and can
    /// yield bad results. One pinned thread mirrors how the reference app drove MLX (off
    /// the main thread, but always the *same* thread).
    private let queue = PinnedThread(label: "kokoro.mlx")

    /// Bumped by `stop()` and each `speak()`; a generation's completion only acts if it's
    /// still current. Mirrors `Listener.generation`.
    private var generation = 0

    /// The bundled fp32 model file, or nil if it wasn't bundled (e.g. a dev build that
    /// skipped `fetch-models.sh`).
    static var modelURL: URL? {
        Bundle.main.url(forResource: "kokoro-v1_0", withExtension: "safetensors")
    }

    /// Whether Kokoro can actually run here: a real device (Metal/MLX) with the model
    /// bundled. `Speaker` consults this before selecting the engine.
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return modelURL != nil
        #endif
    }

    /// Fails if the model isn't bundled. (Simulator is excluded one level up via
    /// `isAvailable`, which `Speaker` checks first.)
    init?(player: PCMPlayer) {
        guard let url = Self.modelURL else { return nil }
        self.player = player
        self.synth = KokoroSynth(modelURL: url)
    }

    /// Generate (and discard) one short clip so the expensive first call — model load +
    /// MLX warm-up — happens before the first real pair instead of stalling it. Safe to
    /// call once at session start.
    func warmUp() {
        let synth = synth
        let voice = Self.currentVoiceName
        queue.async { _ = synth.generate(text: "ready", voiceName: voice, speed: 1.0) }
    }

    func speak(_ line: String) {
        isSpeaking = true
        generation &+= 1
        let gen = generation
        let synth = synth
        let voice = Self.currentVoiceName
        let speed = rate
        queue.async {
            let audio = synth.generate(text: line, voiceName: voice, speed: speed)
            onMainQueue { [weak self] in
                guard let self, gen == self.generation else { return }
                guard let audio, let player = self.player else {
                    // Generation failed (bad voice / model) — don't wedge the session;
                    // report it as a finished utterance so the controller advances.
                    self.finish(gen: gen)
                    return
                }
                player.play(audio, sampleRate: Double(KokoroTTS.Constants.samplingRate)) { [weak self] in
                    self?.finish(gen: gen)
                }
            }
        }
    }

    func stop() {
        generation &+= 1   // discard any in-flight generation's result
        isSpeaking = false
        player?.stopPlayback()
    }

    /// Clear `isSpeaking` and fire `onFinish` iff `gen` is still the current utterance.
    private func finish(gen: Int) {
        guard gen == generation else { return }
        isSpeaking = false
        onFinish?()
    }

    /// The selected voice's base name (e.g. `af_heart`), read fresh so a Settings change
    /// takes effect on the next pair. Defaults to Kokoro's flagship US-English voice.
    static var currentVoiceName: String {
        UserDefaults.standard.string(forKey: "kokoroVoice") ?? "af_heart"
    }
}

/// Confines all non-`Sendable` Kokoro/MLX state (the `KokoroTTS` instance and the loaded
/// voice embeddings) to `KokoroEngine.queue`. Marked `@unchecked Sendable` so it can be
/// captured into that queue's closures: every method here is called **only** from that
/// serial queue, so the state is never touched concurrently.
private final class KokoroSynth: @unchecked Sendable {
    private let modelURL: URL
    private var tts: KokoroTTS?
    private var voices: [String: MLXArray] = [:]

    init(modelURL: URL) { self.modelURL = modelURL }

    /// Synthesize `text` in `voiceName`, returning mono 24 kHz Float PCM, or nil if the
    /// model/voice can't be loaded or generation throws. Lazily loads the (expensive)
    /// model on first call.
    func generate(text: String, voiceName: String, speed: Float) -> [Float]? {
        if tts == nil {
            // MLX's buffer-reuse cache defaults to the whole device memory limit, so on a
            // phone with abundant RAM it never returns the large per-utterance activation
            // buffers to the OS — the footprint climbs every pair until iOS OOM-kills the
            // app. Cap it so freed buffers are reclaimed on the next allocation.
            MLX.GPU.set(cacheLimit: 32 * 1024 * 1024)
            tts = KokoroTTS(modelPath: modelURL)
        }
        guard let tts, let voice = voice(named: voiceName) else { return nil }
        // Voice-name prefix selects the accent: 'a' = US English, 'b' = GB English.
        // (Other Kokoro languages need eSpeakNG, which KokoroSwift ships disabled.)
        let language: Language = voiceName.first == "b" ? .enGB : .enUS
        do {
            let (audio, _) = try tts.generateAudio(voice: voice, language: language,
                                                   text: text, speed: speed)
            return audio
        } catch {
            NSLog("KokoroEngine: generation failed for '\(text)': \(error)")
            return nil
        }
    }

    /// Load and cache a per-voice safetensors (`voices/<name>.safetensors`, a single
    /// `[510,1,256]` style pack). No `voices.npz`/`NpyzReader` needed.
    private func voice(named name: String) -> MLXArray? {
        if let cached = voices[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "safetensors",
                                        subdirectory: "voices")
                ?? Bundle.main.url(forResource: name, withExtension: "safetensors"),
              let arrays = try? MLX.loadArrays(url: url),
              let array = arrays["voice"] ?? arrays.values.first else { return nil }
        voices[name] = array
        return array
    }
}

/// A single OS thread that serially runs submitted jobs — unlike a `DispatchQueue`, which
/// hops across GCD's thread pool. MLX wants the same thread every call (kernel cache + GPU
/// stream affinity). The worker thread retains the instance and loops for the app's
/// lifetime; that's intentional (there's one per `KokoroEngine`, which is itself cached).
private final class PinnedThread: @unchecked Sendable {
    private let cond = NSCondition()
    private var jobs: [@Sendable () -> Void] = []

    init(label: String) {
        let thread = Thread { [self] in
            while true {
                cond.lock()
                while jobs.isEmpty { cond.wait() }
                let job = jobs.removeFirst()
                cond.unlock()
                autoreleasepool { job() }
            }
        }
        thread.name = label
        thread.stackSize = 8 << 20
        thread.start()
    }

    func async(_ job: @escaping @Sendable () -> Void) {
        cond.lock()
        jobs.append(job)
        cond.signal()
        cond.unlock()
    }
}
#endif
