import Foundation
import Combine
import AVFoundation
import Speech

/// A recognized voice command. `skip` rejects the current pair (no voice command in the
/// original design — added so rejection is hands-free too; a future silence timeout can
/// synthesize it). `continue`/`repeat` are escaped because they're Swift keywords.
enum Intent {
    case accept, skip, stop, `continue`, `repeat`, back, faster, slower
}

/// Phase 1 audio spike: always-on, on-device speech recognition running while TTS
/// plays through the same (AEC-enabled) audio session. Its only job here is to log
/// every transcription with a timestamp so we can answer the one question that
/// gates the whole design: *does Apple's acoustic echo cancellation keep the TTS
/// out of the recognizer?*
@MainActor
final class Listener: ObservableObject {

    struct LogLine: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
        let isFinal: Bool
    }

    @Published private(set) var log: [LogLine] = []
    @Published private(set) var isRunning = false

    /// Called on the main actor with each recognized command. Nil in the audio-spike
    /// screen, which only wants the raw transcription log; set by `SessionController`.
    var onIntent: ((Intent) -> Void)?

    /// Spoken-word → command map. Several synonyms per intent so natural phrasings land;
    /// the keys double as the recognizer's bias vocabulary (`contextualStrings`).
    static let commands: [String: Intent] = [
        "yes": .accept, "good": .accept, "yep": .accept, "yeah": .accept, "accept": .accept,
        "no": .skip, "skip": .skip, "next": .skip, "nope": .skip, "bad": .skip,
        "stop": .stop, "pause": .stop,
        "continue": .continue, "resume": .continue, "go": .continue,
        "repeat": .repeat, "again": .repeat,
        "back": .back, "previous": .back,
        "faster": .faster, "slower": .slower,
    ]
    static let vocabulary = Array(commands.keys)

    /// Words in the line currently being spoken, so the recognizer transcribing the TTS
    /// can't fire a command (e.g. a pair containing "back"). Updated by the controller.
    private var spokenWords: Set<String> = []

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// On-device requests have a finite lifetime (~1 min). Recreate the request
    /// periodically so recognition never silently dies mid-session.
    private var restartTimer: Timer?

    /// Bumped on every (re)install. A task's completion handler captures the
    /// generation it was created under and bails if it's been superseded — this
    /// stops a cancelled task from spawning a replacement (which otherwise
    /// cascades, or after `stop()` leaves a zombie task that starves the next one).
    private var generation = 0

    func start() async {
        guard !isRunning else { return }

        guard await Self.requestSpeechAuthorization() else {
            append("✗ speech recognition not authorized"); return
        }
        guard await Self.requestMicAuthorization() else {
            append("✗ microphone not authorized"); return
        }
        guard let recognizer, recognizer.isAvailable else {
            append("✗ recognizer unavailable"); return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            append("✗ on-device recognition unsupported for locale"); return
        }

        do {
            try configureSession()
            if !engine.inputNode.isVoiceProcessingEnabled {
                try engine.inputNode.setVoiceProcessingEnabled(true)   // engages AEC
            }
            // VPIO is duplex: enabling voice processing routes the engine's *output*
            // through the same unit for echo cancellation. With nothing connected to
            // the output graph its render callback has no source and spams
            // "auou/vpio render err: -1" every cycle. Touching mainMixerNode forces
            // the lazy mainMixer → output connection so the unit always renders
            // (silent) audio.
            _ = engine.mainMixerNode
            engine.prepare()
            try engine.start()
            installRecognition()
            startRestartTimer()
            isRunning = true
            append("▶︎ listener started (on-device, AEC on)")
        } catch {
            append("✗ start failed: \(error.localizedDescription)")
            teardown()
        }
    }

    func stop() {
        guard isRunning else { return }
        teardown()
        isRunning = false
        append("■ listener stopped")
    }

    func clearLog() { log.removeAll() }

    // MARK: - Intent parsing

    /// Tell the listener which line is being spoken so its words are suppressed as
    /// self-triggers; pass nil once TTS stops.
    func setSpokenLine(_ line: String?) {
        spokenWords = Set(Self.words(in: line ?? ""))
    }

    /// Map a transcription to a command. Scans most-recent-word-first so a correction
    /// ("yes… no") lands on the latest word, and skips any word that's part of the TTS
    /// currently playing.
    private func parse(_ text: String) -> Intent? {
        for word in Self.words(in: text).reversed() where !spokenWords.contains(word) {
            if let intent = Self.commands[word] { return intent }
        }
        return nil
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init)
    }

    // MARK: - Audio session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .voiceChat + .allowBluetooth puts us on the HFP profile (AirPods mic) and
        // turns on Apple's voice processing / echo cancellation.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Recognition lifecycle

    /// Creates a fresh request + task and (re)installs the mic tap. The engine keeps
    /// running across restarts so there is no audible gap.
    private func installRecognition() {
        guard let recognizer else { return }

        // Retire any in-flight request/task and mark this generation current so a
        // late callback from the outgoing task can't reinstall over us.
        generation &+= 1
        let gen = generation
        task?.cancel()
        request?.endAudio()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = Self.vocabulary
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            // The voice-processing input node emits empty priming buffers at engine
            // start and while TTS ducks the mic; forwarding those triggers
            // "AVAudioBuffer.mm:281 mDataByteSize (0)". Drop them before appending.
            guard buffer.frameLength > 0 else { return }
            request.append(buffer)
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                // Ignore callbacks after stop() or from a task we've already replaced.
                guard self.isRunning, gen == self.generation else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.append(text, isFinal: result.isFinal)
                    // Act on partials for low-latency barge-in, then immediately restart
                    // recognition so one utterance fires its command exactly once.
                    if self.onIntent != nil, let intent = self.parse(text) {
                        self.onIntent?(intent)
                        self.installRecognition()
                        return
                    }
                }
                if result?.isFinal == true || error != nil { self.installRecognition() }
            }
        }
    }

    private func startRestartTimer() {
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.installRecognition() }
        }
    }

    private func teardown() {
        restartTimer?.invalidate(); restartTimer = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Logging

    private func append(_ text: String, isFinal: Bool = true) {
        guard !text.isEmpty else { return }
        // Collapse consecutive partials of the same in-flight phrase into one line.
        if !isFinal, let last = log.last, !last.isFinal {
            log[log.count - 1] = LogLine(text: text, isFinal: false)
        } else {
            log.append(LogLine(text: text, isFinal: isFinal))
        }
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // MARK: - Authorization

    private static func requestSpeechAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    private static func requestMicAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
    }
}
