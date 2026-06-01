import Foundation
import Combine

/// Wires the data model (`PairStore`) to audio (`Speaker` + `Listener`) for one active
/// file. Voice commands and the on-screen buttons funnel through the same `dispatch`, so
/// they behave identically — and a future "auto-skip on silence" can just call
/// `dispatch(.skip)`. Speaking the current pair whenever it changes (the step-3 loop)
/// lives here now.
@MainActor
final class SessionController: ObservableObject {

    enum State: Equatable { case speaking, awaiting, paused }

    @Published private(set) var state: State = .awaiting
    /// Set when voice control can't start (permissions / no recognizer); the UI surfaces
    /// it so the buttons are understood as the fallback rather than the norm.
    @Published private(set) var voiceUnavailable = false

    /// The most recent command the controller acted on, for an on-screen confirmation
    /// (and to tell "recognizer is deaf" apart from "heard it but didn't act").
    @Published private(set) var lastCommand: String?

    /// Live transcription so the classifier screen can show what the mic is hearing.
    var transcript: [Listener.LogLine] { listener.log }

    /// Exposed for the view to read pair text, progress, counts, etc.
    let store = PairStore()

    private let speaker = Speaker()
    private let listener = Listener()
    private var cancellables = Set<AnyCancellable>()

    init() {
        // The view observes this controller, so forward the model's changes upward.
        store.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Forward the listener too, so the transcript strip refreshes as lines arrive.
        listener.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        speaker.onFinish = { [weak self] in self?.speechFinished() }
        listener.onIntent = { [weak self] in self?.dispatch($0) }
    }

    // MARK: - Lifecycle

    func begin(file: URL, resultsDirectory: URL) {
        if !store.isLoaded { store.load(file: file, resultsDirectory: resultsDirectory) }
        Task {
            // Start the recognizer (which configures the AEC audio session) before the
            // first utterance, so TTS plays into the right session from the start.
            await listener.start()
            voiceUnavailable = !listener.isRunning
            speakCurrent()
        }
    }

    func end() {
        speaker.stop()
        listener.stop()
    }

    /// Write results and tear down audio; the caller removes the file and dismisses.
    @discardableResult
    func finish() -> URL? {
        let url = store.finish()
        end()
        return url
    }

    // MARK: - Commands (buttons call these; voice arrives via dispatch directly)

    func accept() { dispatch(.accept) }
    func skip()   { dispatch(.skip) }
    func back()   { dispatch(.back) }
    func repeatCurrent() { dispatch(.repeat) }

    // MARK: - Dispatch

    private func dispatch(_ intent: Intent) {
        lastCommand = "\(intent)"
        // Barge-in: whatever the command, interrupt any utterance before acting on it.
        speaker.stop()

        // While paused only continue/stop are live; everything else is ignored so a
        // stray "yes" can't slip a decision in behind the user's back.
        guard state != .paused else {
            if intent == .continue { resume() }
            return
        }

        switch intent {
        case .accept:   store.accept(); speakCurrent()
        case .skip:     store.skipOrAdvance(); speakCurrent()
        case .reject:   store.reject(); speakCurrent()
        case .status:   speakStatus()
        case .back:     store.back();   speakCurrent()
        case .repeat:   speakCurrent()
        case .faster:   speaker.faster(); speakCurrent()
        case .slower:   speaker.slower(); speakCurrent()
        case .stop:     pause()
        case .continue: speakCurrent()   // already running; just re-speak
        }
    }

    /// Speak the current pair's classification aloud without changing it or advancing.
    private func speakStatus() {
        let word: String
        if store.current == nil {
            word = "done"   // past the end of the list — nothing to classify
        } else {
            switch store.currentDecision {
            case .accepted: word = "accepted"
            case .skipped:  word = "skipped"
            default:        word = "unclassified"
            }
        }
        state = .speaking
        listener.setSpokenLine(word)
        speaker.speak(word)
    }

    private func pause() {
        state = .paused
        listener.setSpokenLine(nil)   // nothing playing → nothing to suppress
    }

    private func resume() {
        state = .awaiting
        speakCurrent()
    }

    /// Speak the pair now awaiting a decision, or fall silent at the end of the list.
    private func speakCurrent() {
        guard state != .paused else { return }
        if let line = store.current {
            state = .speaking
            listener.setSpokenLine(line)
            speaker.speak(line)
        } else {
            state = .awaiting
            listener.setSpokenLine(nil)
        }
    }

    private func speechFinished() {
        listener.setSpokenLine(nil)
        if state == .speaking { state = .awaiting }
    }
}
