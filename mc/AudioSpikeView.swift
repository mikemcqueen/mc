import SwiftUI
import Combine
import AVFoundation

/// Phase 1 throwaway UI: drive the audio spike. Toggle the always-on listener and
/// the looping TTS independently, watch the live transcription log. The thing to
/// look for: with the TTS loop running and AirPods in, does the log fill with the
/// spoken phrases ("apple orange"…) — AEC failing — or stay quiet until *you*
/// speak — AEC working?
struct AudioSpikeView: View {
    @StateObject private var listener = Listener()
    @StateObject private var speaker = SpikeSpeaker()

    var body: some View {
        VStack(spacing: 12) {
            Text("Audio Spike")
                .font(.headline)

            HStack(spacing: 12) {
                Button(listener.isRunning ? "Stop Listening" : "Start Listening") {
                    Task {
                        if listener.isRunning { listener.stop() }
                        else { await listener.start() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(listener.isRunning ? .red : .blue)

                Button(speaker.isLooping ? "Stop TTS" : "Loop TTS") {
                    if speaker.isLooping { speaker.stop() } else { speaker.startLooping() }
                }
                .buttonStyle(.bordered)
            }

            HStack {
                Text("\(listener.log.count) lines")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear", action: listener.clearLog)
                    .font(.caption)
            }

            transcriptList
        }
        .padding()
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            List(listener.log) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text(line.time, format: .dateTime.hour().minute().second())
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text(line.text)
                        .font(.callout)
                        .foregroundStyle(line.isFinal ? .primary : .secondary)
                    Spacer(minLength: 0)
                }
                .id(line.id)
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            }
            .listStyle(.plain)
            .onChange(of: listener.log.count) { _, _ in
                if let last = listener.log.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

#Preview {
    AudioSpikeView()
}

/// Phase 1 throwaway: loops a short phrase list through TTS so the spike can observe
/// whether the always-on `Listener` transcribes its own playback. Self-contained (its
/// own synthesizer) so the real `Speaker` stays focused on speaking one pair at a time.
@MainActor
private final class SpikeSpeaker: NSObject, ObservableObject {

    @Published private(set) var isLooping = false

    private let synth = AVSpeechSynthesizer()
    private let phrases = ["apple orange", "table chair", "river mountain"]
    private var index = 0
    private nonisolated let gap: TimeInterval = 1.5

    override init() {
        super.init()
        synth.delegate = self
        // Use the .playAndRecord session the listener configures, so AEC applies.
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

extension SpikeSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        // Schedule the next phrase on the main run loop rather than re-entering `speak`
        // from inside a structured-concurrency Task, which trips the
        // "unsafeForcedSync called from Swift Concurrent context" runtime check.
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
            MainActor.assumeIsolated {
                guard self.isLooping else { return }
                self.speakNext()
            }
        }
    }
}
