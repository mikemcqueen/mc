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

    /// Speak `line`, interrupting anything already in flight so a new pair never queues
    /// behind a stale one.
    func speak(_ line: String)

    /// Stop any utterance in flight without firing `onFinish`.
    func stop()
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
