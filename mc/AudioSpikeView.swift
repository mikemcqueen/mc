import SwiftUI

/// Phase 1 throwaway UI: drive the audio spike. Toggle the always-on listener and
/// the looping TTS independently, watch the live transcription log. The thing to
/// look for: with the TTS loop running and AirPods in, does the log fill with the
/// spoken phrases ("apple orange"…) — AEC failing — or stay quiet until *you*
/// speak — AEC working?
struct AudioSpikeView: View {
    @StateObject private var listener = Listener()
    @StateObject private var speaker = Speaker()

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
