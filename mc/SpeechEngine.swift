import Foundation

/// The seam every TTS backend implements. `Speaker` owns one of these (chosen at
/// runtime) and forwards its whole public surface to it, so `SessionController` never
/// learns which engine is speaking. Two implementations exist: `AVSpeechEngine` (the
/// system synthesizer, always available — the default and simulator/CI fallback) and
/// `KokoroEngine` (on-device neural TTS, Apple-Silicon device only).
@MainActor
protocol SpeechEngine: AnyObject {
    /// True while an utterance is in flight. Drives the on-screen speaking indicator
    /// and barge-in.
    var isSpeaking: Bool { get }

    /// Applied to every utterance. Interpreted per-engine (AVSpeech's word-rate scale
    /// vs. Kokoro's speed multiplier); the facade just passes it through.
    var rate: Float { get set }

    /// Called on the main actor when an utterance finishes *naturally* — not when it's
    /// interrupted by `stop()` or a new `speak(_:)`. Lets the controller advance state.
    var onFinish: (() -> Void)? { get set }

    /// Whether this engine pays a per-utterance synthesis cost worth hiding by generating
    /// ahead of time. Streaming/system engines (`AVSpeechEngine`) return false; engines
    /// that synthesize a whole clip up front — neural (`KokoroEngine`) or a future remote
    /// one — return true and implement `prefetch`/`retain` so navigation plays instantly.
    /// Defaults to false; the controller only bothers pre-generating when it's true.
    var supportsPreGeneration: Bool { get }

    /// Speak `line`, interrupting anything already in flight so a new pair never queues
    /// behind a stale one. If `line` was previously `prefetch`ed it plays without the
    /// synthesis delay.
    func speak(_ line: String)

    /// Stop any utterance in flight without firing `onFinish`.
    func stop()

    /// Synthesize `line` ahead of time and cache the result, so a later `speak(_:)` of the
    /// same line plays immediately. No-op on engines without pre-generation.
    func prefetch(_ line: String)

    /// Bound the pre-generation cache to `lines` (the ones worth keeping ready, e.g.
    /// prev/current/next), discarding anything else. No-op without pre-generation.
    func retain(_ lines: [String])
}

/// No-op defaults so streaming engines opt out of pre-generation for free; engines that
/// support it (e.g. `KokoroEngine`) override all three.
extension SpeechEngine {
    var supportsPreGeneration: Bool { false }
    func prefetch(_ line: String) {}
    func retain(_ lines: [String]) {}
}

/// Plays raw mono Float PCM through an audio graph. `KokoroEngine` produces `[Float]`
/// samples and hands them here rather than owning its own `AVAudioEngine`, so the audio
/// rides `Listener`'s VPIO graph and stays echo-cancelled out of the mic. `Listener` is
/// the production conformer; the protocol keeps the engine from being hard-coupled to it
/// (and trivially fakeable in isolation).
@MainActor
protocol PCMPlayer: AnyObject {
    /// Schedule `samples` for playback. `onDone` fires on the main actor when the buffer
    /// finishes *naturally* — not when `stopPlayback()` cuts it off.
    func play(_ samples: [Float], sampleRate: Double, onDone: @escaping () -> Void)
    /// Stop any buffer in flight without firing its `onDone`.
    func stopPlayback()
}

/// Run `body` on the main dispatch queue with main-actor isolation. AVFoundation
/// (AVSpeechSynthesizer / AVAudioEngine) must be driven from the main *queue*, not the
/// cooperative executor a `Task { @MainActor }` runs on; the latter trips the
/// "unsafeForcedSync called from Swift Concurrent context" runtime check.
nonisolated func onMainQueue(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}
