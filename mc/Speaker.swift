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

    /// Applied to every utterance. Adjusted by the faster/slower commands; re-speak the
    /// current pair after changing it so the new rate is audible.
    var rate = AVSpeechUtteranceDefaultSpeechRate

    /// Called on the main actor when an utterance finishes *naturally* — not when it's
    /// interrupted by `stop()` or a new `speak(_:)`. Lets the controller advance state.
    var onFinish: (() -> Void)?

    private let synth = AVSpeechSynthesizer()
    private let rateStep: Float = 0.06
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
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: line)
        utterance.rate = rate
        currentUtterance = utterance
        isSpeaking = true
        synth.speak(utterance)
    }

    func stop() {
        currentUtterance = nil
        isSpeaking = false
        synth.stopSpeaking(at: .immediate)
    }

    func faster() { rate = min(rate + rateStep, AVSpeechUtteranceMaximumSpeechRate) }
    func slower() { rate = max(rate - rateStep, AVSpeechUtteranceMinimumSpeechRate) }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // Only the utterance still current may clear the flag; an utterance we
            // interrupted reports later and must be ignored.
            guard utterance === self.currentUtterance else { return }
            self.currentUtterance = nil
            self.isSpeaking = false
            self.onFinish?()
        }
    }
}
