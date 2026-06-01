import Foundation
import Combine
import AVFoundation

/// Reads word-pairs aloud, one line at a time. Owns no list and configures no audio
/// session: it speaks whatever line the caller hands it and tracks whether it's
/// currently speaking. It rides the app's active audio session
/// (`usesApplicationAudioSession`); the `.playAndRecord` / AEC configuration arrives
/// with the `Listener` in step 4.
@MainActor
final class Speaker: NSObject, ObservableObject {

    /// True while an utterance is in flight. Drives the on-screen speaking indicator
    /// and, later, barge-in.
    @Published private(set) var isSpeaking = false

    /// Applied to every utterance.
    var rate = AVSpeechUtteranceDefaultSpeechRate

    /// Called on the main actor when an utterance finishes *naturally* — not when it's
    /// interrupted by `stop()` or a new `speak(_:)`. Lets the controller advance state.
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

    /// Speak `line`, interrupting anything already in flight so a new pair never queues
    /// behind a stale one.
    func speak(_ line: String) {
        isSpeaking = true
        let rate = rate
        // Drive the synthesizer from the main dispatch queue, not whatever context
        // called us. speak()/stop() are reached from voice-command dispatch (the
        // recognizer callback) and from begin()'s Task — calling AVSpeechSynthesizer
        // from a structured-concurrency Task trips the "unsafeForcedSync called from
        // Swift Concurrent context" runtime check and can wedge the shared VPIO audio
        // graph (taking the mic/recognizer down with it). Same trap SpikeSpeaker avoids.
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

extension Speaker: AVSpeechSynthesizerDelegate {
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

/// Run `body` on the main dispatch queue with main-actor isolation. AVFoundation
/// (AVSpeechSynthesizer / AVAudioEngine) must be driven from the main *queue*, not the
/// cooperative executor a `Task { @MainActor }` runs on; the latter trips the
/// "unsafeForcedSync called from Swift Concurrent context" runtime check.
nonisolated func onMainQueue(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}
