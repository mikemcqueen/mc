import SwiftUI

/// Phase 2 processing screen for one active file: button-driven, no voice yet.
/// Step through the pairs with Accept / Skip / Back; accepted pairs are written
/// through to the Results folder. At the end, "Finish & remove file" deletes the
/// input so it's never offered again. Backing out without finishing leaves the
/// file in the queue (progress is not yet persisted — that's Phase 5).
struct PairClassifierView: View {
    let file: URL
    let library: PairLibrary

    @StateObject private var store = PairStore()
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
            Text(current)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("Done — \(store.acceptedCount) accepted")
                    .font(.title3)
                if let out = store.outputURL {
                    Text("Saved to Results/\(out.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if store.isAtEnd {
            Button(role: .destructive) {
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
            } label: {
                Label("Back", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!store.hasPrevious)

            Button {
                store.skip()
            } label: {
                Label("Skip", systemImage: "forward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(store.current == nil)

            Button {
                store.accept()
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
