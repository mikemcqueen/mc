import Foundation
import Combine
import AVFoundation

/// Reads word-pairs aloud, one line at a time. `Speaker` is a thin facade: it owns a
/// `SpeechEngine` chosen at first use from `@AppStorage("ttsEngine")` (`"system"` →
/// `AVSpeechEngine`, the default and simulator/CI fallback; `"kokoro"` → `KokoroEngine`,
/// on-device neural TTS) and forwards its whole public surface to it. `SessionController`
/// talks only to this facade and never learns which engine is speaking.
///
/// The facade owns the published `isSpeaking` flag (so it behaves identically across
/// engines) and routes `onFinish` from whichever engine is active.
@MainActor
final class Speaker: ObservableObject {

    /// True while an utterance is in flight. Drives the on-screen speaking indicator
    /// and barge-in.
    @Published private(set) var isSpeaking = false

    /// Set when Kokoro was requested but couldn't run (simulator, missing model, or no
    /// PCM player injected) and we fell back to the system voice. The UI can surface it.
    @Published private(set) var note: String?

    /// Applied to every utterance. Forwarded to `AVSpeechEngine` (its word-rate scale);
    /// `KokoroEngine` keeps its own speed default since the scales differ.
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate {
        didSet { (engine as? AVSpeechEngine)?.rate = rate }
    }

    /// Called on the main actor when an utterance finishes *naturally* — not when it's
    /// interrupted by `stop()` or a new `speak(_:)`. Lets the controller advance state.
    var onFinish: (() -> Void)?

    /// Injected by `SessionController` (the `Listener`) before the first `speak(_:)` so a
    /// selected `KokoroEngine` can play its PCM through the shared VPIO/AEC graph. AVSpeech
    /// ignores it.
    weak var pcmPlayer: PCMPlayer?

    /// Built lazily on first use, by which point `pcmPlayer` has been injected.
    private var engine: SpeechEngine?

    /// Speak `line` at `rateScale`× the active engine's normal rate (1.0 = normal). The
    /// scale is transient and never mutates the persistent `rate`.
    func speak(_ line: String, rateScale: Float = 1.0) {
        isSpeaking = true
        currentEngine().speak(line, rateScale: rateScale)
    }

    func stop() {
        isSpeaking = false
        engine?.stop()
    }

    // MARK: - Pre-generation (forwarded to the active engine; no-op on streaming engines)

    var supportsPreGeneration: Bool { currentEngine().supportsPreGeneration }
    func prefetch(_ line: String) { currentEngine().prefetch(line) }
    func retain(_ lines: [String]) { currentEngine().retain(lines) }

    // MARK: - Engine selection

    private func currentEngine() -> SpeechEngine {
        if let engine { return engine }
        let chosen = makeEngine()
        chosen.onFinish = { [weak self] in self?.finished() }
        engine = chosen
        return chosen
    }

    private func makeEngine() -> SpeechEngine {
        if UserDefaults.standard.string(forKey: "ttsEngine") == "kokoro" {
            #if canImport(KokoroSwift)
            if KokoroEngine.isAvailable, let player = pcmPlayer,
               let kokoro = KokoroEngine(player: player) {
                kokoro.warmUp()
                return kokoro
            }
            #endif
            // Requested but unavailable here — keep the app usable on the system voice.
            note = "Kokoro unavailable — using the system voice."
        }
        let av = AVSpeechEngine()
        av.rate = rate
        return av
    }

    private func finished() {
        isSpeaking = false
        onFinish?()
    }
}
