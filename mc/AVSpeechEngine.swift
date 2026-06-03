import Foundation
import AVFoundation

/// `SpeechEngine` backed by the system `AVSpeechSynthesizer`. This is verbatim the logic
/// `Speaker` used to own; `Speaker` is now a thin facade that may delegate here or to
/// `KokoroEngine`. Configures no audio session — it rides the app's active session
/// (`usesApplicationAudioSession`), so `Listener`'s VPIO unit cancels it from the mic.
@MainActor
final class AVSpeechEngine: NSObject, SpeechEngine {

    private(set) var isSpeaking = false

    var rate = AVSpeechUtteranceDefaultSpeechRate

    var onFinish: (() -> Void)?

    private let synth = AVSpeechSynthesizer()
    /// The utterance currently being spoken, so a late `didFinish` from an utterance we
    /// already interrupted can't clear `isSpeaking` for its replacement.
    private var currentUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synth.delegate = self
        // Ride the app's audio session rather than swapping in our own.
        synth.usesApplicationAudioSession = true
    }

    func speak(_ line: String, rateScale: Float) {
        isSpeaking = true
        let rate = rate * rateScale
        // Drive the synthesizer from the main dispatch queue, not whatever context
        // called us. speak()/stop() are reached from voice-command dispatch (the
        // recognizer callback) and from begin()'s Task — calling AVSpeechSynthesizer
        // from a structured-concurrency Task trips the "unsafeForcedSync called from
        // Swift Concurrent context" runtime check and can wedge the shared VPIO audio
        // graph (taking the mic/recognizer down with it).
        // Build the utterance inside the hop so nothing non-Sendable crosses the closure.
        onMainQueue {
            self.synth.stopSpeaking(at: .immediate)
            let utterance = AVSpeechUtterance(string: line)
            utterance.rate = rate
            self.currentUtterance = utterance
            self.synth.speak(utterance)
        }
    }

    func stop() {
        currentUtterance = nil
        isSpeaking = false
        onMainQueue { self.synth.stopSpeaking(at: .immediate) }
    }
}

extension AVSpeechEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        // Hop to the main queue (not a Task) for the same reason speak()/stop() do.
        // Carry the utterance's identity (Sendable) rather than the utterance itself.
        let finished = ObjectIdentifier(utterance)
        onMainQueue {
            // Only the utterance still current may clear the flag; an utterance we
            // interrupted reports later and must be ignored.
            guard let current = self.currentUtterance, ObjectIdentifier(current) == finished
            else { return }
            self.currentUtterance = nil
            self.isSpeaking = false
            self.onFinish?()
        }
    }
}
