import Foundation
import Combine

/// Wires the data model (`PairStore`) to audio (`Speaker` + `Listener`) for one active
/// file. Voice commands and the on-screen buttons funnel through the same `dispatch`, so
/// they behave identically. Speaking the current pair whenever it changes lives here too.
///
/// Auto-advance is the core review mode: once enabled (by "continue"), each pair is read
/// aloud and then auto-skipped after `delaySeconds` of silence unless the user classifies
/// it first ("yes"/"no"). "stop" disables it; "faster"/"slower" tune the delay. The
/// session starts *stopped* — it reads the first unclassified pair and waits.
@MainActor
final class SessionController: ObservableObject {

    enum State: Equatable { case speaking, idle }

    @Published private(set) var state: State = .idle
    /// Set when voice control can't start (permissions / no recognizer); the UI surfaces
    /// it so the buttons are understood as the fallback rather than the norm.
    @Published private(set) var voiceUnavailable = false

    /// The most recent command the controller acted on, for an on-screen confirmation
    /// (and to tell "recognizer is deaf" apart from "heard it but didn't act").
    @Published private(set) var lastCommand: String?

    /// When on, an unclassified pair is auto-skipped `delaySeconds` after it finishes
    /// being read, unless the user classifies it first. Off until "continue" is heard.
    @Published private(set) var autoAdvance = false

    /// Seconds of silence before an unclassified pair is auto-skipped. Tuned by the
    /// faster/slower commands (1-second floor).
    @Published private(set) var delaySeconds = 2

    /// Live transcription so the classifier screen can show what the mic is hearing.
    var transcript: [Listener.LogLine] { listener.log }

    /// Exposed for the view to read pair text, progress, counts, etc.
    let store = PairStore()

    private let speaker = Speaker()
    private let listener = Listener()
    private var cancellables = Set<AnyCancellable>()

    /// Fires `delaySeconds` after a pair finishes being read (auto-advance only) to
    /// synthesize a `.skip`. Invalidated by any command so a decision resets the clock.
    private var autoSkipTimer: Timer?

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
        // Let a selected Kokoro engine play its PCM through the listener's VPIO graph, so
        // neural TTS is echo-cancelled out of the mic exactly like AVSpeech is.
        speaker.pcmPlayer = listener
    }

    // MARK: - Lifecycle

    func begin(file: URL, resultsDirectory: URL) {
        if !store.isLoaded { store.load(file: file, resultsDirectory: resultsDirectory) }
        Task {
            // Start the recognizer (which configures the AEC audio session) before the
            // first utterance, so TTS plays into the right session from the start.
            await listener.start()
            voiceUnavailable = !listener.isRunning
            // Stopped mode: read the first unclassified pair and wait for a command.
            speakCurrent()
        }
    }

    func end() {
        cancelAutoSkip()
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
    func repeatSlowly()  { dispatch(.repeatSlowly) }

    // MARK: - Dispatch

    private func dispatch(_ intent: Intent) {
        lastCommand = "\(intent)"
        // Any command resets the auto-skip clock and barges in on any utterance.
        cancelAutoSkip()
        speaker.stop()

        switch intent {
        case .accept:   store.accept(); speakCurrent()
        case .skip:     store.skipOrAdvance(); speakCurrent()
        case .reject:   store.reject(); speakCurrent()
        case .status:   speakStatus()
        case .back:     store.back();   speakCurrent()
        case .repeat:   speakCurrent()
        case .repeatSlowly: speakCurrentSlowly()
        case .faster:   adjustDelay(by: -1)
        case .slower:   adjustDelay(by: +1)
        case .stop:     autoAdvance = false   // timer already cancelled above
        case .continue: startAutoAdvance()
        }
    }

    /// "continue": skip past the current pair and auto-advance from here on. Re-issuing it
    /// (already advancing) just steps forward, matching the spoken intent.
    private func startAutoAdvance() {
        autoAdvance = true
        store.skipOrAdvance()
        speakCurrent()
    }

    /// Shift the auto-skip delay (1-second floor), announce it, and re-read the current
    /// pair so the new window covers a fresh hearing of it.
    private func adjustDelay(by delta: Int) {
        delaySeconds = max(1, delaySeconds + delta)
        let announcement = "\(delaySeconds) \(delaySeconds == 1 ? "second" : "seconds")"
        if let line = store.current {
            speak("\(announcement). \(line)")
        } else {
            speak(announcement)
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
        speak(word)
    }

    /// Speak the pair now awaiting a decision, or fall silent at the end of the list.
    private func speakCurrent() {
        if let line = store.current {
            speak(line)
        } else {
            state = .idle
            listener.setSpokenLine(nil)
        }
        prepareNeighbors()
    }

    /// Keep prev/current/next synthesized and cached (on engines that support it) so
    /// next/prev/back play without a generation delay; drop anything further out. At the end
    /// of the list there's no current, but the previous line is still retained/prefetched so
    /// `back` stays instant.
    private func prepareNeighbors() {
        guard speaker.supportsPreGeneration else { return }
        let neighbors = [-1, 0, 1].compactMap { store.line(at: $0) }
        speaker.retain(neighbors)
        if let prev = store.line(at: -1) { speaker.prefetch(prev) }
        if let next = store.line(at: 1)  { speaker.prefetch(next) }
    }

    /// Re-read the current pair once at half speed without changing its decision or the
    /// position — a transient, one-off slow playback ("repeat slowly"). The slow rate is
    /// not retained: the next pair (or a plain "repeat") speaks at normal speed again.
    private func speakCurrentSlowly() {
        guard let line = store.current else { return }
        speak(line, rateScale: 0.5)
    }

    /// Speak `text`, suppressing its own words so the recognizer can't self-trigger.
    /// `rateScale` (1.0 = normal) applies to this utterance only.
    private func speak(_ text: String, rateScale: Float = 1.0) {
        state = .speaking
        listener.setSpokenLine(text)
        speaker.speak(text, rateScale: rateScale)
    }

    private func speechFinished() {
        listener.setSpokenLine(nil)
        if state == .speaking { state = .idle }
        // The silent reaction window opens once the pair has been fully read.
        scheduleAutoSkip()
    }

    // MARK: - Auto-skip timer

    private func scheduleAutoSkip() {
        cancelAutoSkip()
        guard autoAdvance, store.current != nil else { return }
        autoSkipTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delaySeconds),
                                             repeats: false) { _ in
            onMainQueue { [weak self] in self?.dispatch(.skip) }
        }
    }

    private func cancelAutoSkip() {
        autoSkipTimer?.invalidate()
        autoSkipTimer = nil
    }
}
