import SwiftUI

/// Processing screen for one active file. Each pair is read aloud and classified by
/// voice ("yes/good" accept, "no/skip" reject, plus stop/continue/repeat/back/
/// faster/slower); the buttons mirror every command as a fallback. Decisions are saved
/// immediately so the file resumes here after a quit. "Finish & remove file" writes the
/// accepted pairs to Results/ and deletes the input so it's never offered again.
struct PairClassifierView: View {
    let file: URL
    let library: PairLibrary

    @StateObject private var session = SessionController()
    @Environment(\.dismiss) private var dismiss

    private var store: PairStore { session.store }

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
        .onAppear { session.begin(file: file, resultsDirectory: library.resultsURL) }
        .onDisappear { session.end() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text(store.progress)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if session.voiceUnavailable {
                Label("Voice off", systemImage: "mic.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
            }
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
                        if session.state == .speaking {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { session.repeatCurrent() }
                if session.state == .paused {
                    Text("paused — say \"continue\"")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let decision = store.currentDecision, decision != .undecided {
                    Text("previously: \(decision == .accepted ? "accepted" : "skipped")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("say \"yes\" / \"no\", or tap the pair to hear it again")
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
                session.finish()
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
                session.back()
            } label: {
                Label("Back", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!store.hasPrevious)

            Button {
                session.skip()
            } label: {
                Label("Skip", systemImage: "forward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(store.current == nil)

            Button {
                session.accept()
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
