import SwiftUI

/// Phase 2 processing screen for one active file: button-driven, no voice yet.
/// Step through the pairs with Accept / Skip / Back; each decision is saved
/// immediately so the file resumes here after a quit. At the end, "Finish & remove
/// file" writes the accepted pairs to Results/ and deletes the input so it's never
/// offered again.
struct PairClassifierView: View {
    let file: URL
    let library: PairLibrary

    @StateObject private var store = PairStore()
    @StateObject private var speaker = Speaker()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            header
            Spacer()
            pairCard
            Spacer()
            footer
            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .navigationTitle(file.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !store.isLoaded {
                store.load(file: file, resultsDirectory: library.resultsURL)
            }
            speakCurrent()
        }
        .onDisappear { speaker.stop() }
    }

    /// Speak the pair now awaiting a decision (or fall silent at the end of the list).
    /// Called on appear and after every decision, so deciding *is* the speak→advance loop.
    private func speakCurrent() {
        if let current = store.current {
            speaker.speak(current)
        } else {
            speaker.stop()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text(store.progress)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Text("Accepted: \(store.acceptedCount)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var pairCard: some View {
        if let current = store.current {
            VStack(spacing: 12) {
                Text(current)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .topTrailing) {
                        if speaker.isSpeaking {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { speaker.speak(current) }
                if let decision = store.currentDecision, decision != .undecided {
                    Text("previously: \(decision == .accepted ? "accepted" : "skipped")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("tap the pair to hear it again")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("All \(store.pairs.count) reviewed")
                    .font(.title3)
                Text("\(store.acceptedCount) accepted")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Tap Finish to save the results and remove the file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if store.isAtEnd {
            Button(role: .destructive) {
                store.finish()
                library.complete(file)
                dismiss()
            } label: {
                Label("Finish & remove file", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        } else {
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                store.back()
                speakCurrent()
            } label: {
                Label("Back", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!store.hasPrevious)

            Button {
                store.skip()
                speakCurrent()
            } label: {
                Label("Skip", systemImage: "forward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(store.current == nil)

            Button {
                store.accept()
                speakCurrent()
            } label: {
                Label("Accept", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(store.current == nil)
        }
        .labelStyle(.titleAndIcon)
    }
}
