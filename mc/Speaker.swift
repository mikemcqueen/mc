import Foundation
import Combine
import AVFoundation

/// Phase 1 audio spike: loops a short phrase through TTS so we can observe whether
/// the always-on `Listener` transcribes its own playback. Uses the application
/// audio session configured by `Listener` (does not manage its own), so AEC applies.
@MainActor
final class Speaker: NSObject, ObservableObject {

    @Published private(set) var isLooping = false

    private let synth = AVSpeechSynthesizer()
    private let phrases = ["apple orange", "table chair", "river mountain"]
    private var index = 0
    private nonisolated let gap: TimeInterval = 1.5

    override init() {
        super.init()
        synth.delegate = self
        // Use our configured .playAndRecord session rather than swapping it out.
        synth.usesApplicationAudioSession = true
    }

    func startLooping() {
        guard !isLooping else { return }
        isLooping = true
        speakNext()
    }

    func stop() {
        isLooping = false
        synth.stopSpeaking(at: .immediate)
    }

    private func speakNext() {
        guard isLooping else { return }
        let utterance = AVSpeechUtterance(string: phrases[index % phrases.count])
        index += 1
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        // Schedule the next phrase on the main run loop rather than re-entering
        // `speak` from inside a structured-concurrency Task, which trips the
        // "unsafeForcedSync called from Swift Concurrent context" runtime check.
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
            MainActor.assumeIsolated {
                guard self.isLooping else { return }
                self.speakNext()
            }
        }
    }
}
