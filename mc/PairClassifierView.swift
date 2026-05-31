import SwiftUI
import UniformTypeIdentifiers

/// Phase 2 UI: button-driven, no voice yet. Import a word-pair file, step through
/// it, and Accept / Skip / Back. Accepted pairs are written through to a file in
/// Documents (visible in Finder and the Files app). This proves the whole data
/// flow before `Listener` intents replace the buttons in Phase 4.
struct PairClassifierView: View {
    @StateObject private var store = PairStore()
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 24) {
            header
            Spacer()
            pairCard
            Spacer()
            controls
            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.plainText, .text, .utf8PlainText],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { store.load(from: url) }
            case .failure(let error):
                store.reportError(error.localizedDescription)
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 4) {
            HStack {
                Button {
                    showImporter = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                Spacer()
                Text("Accepted: \(store.acceptedCount)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let source = store.sourceName {
                Text("\(source) — \(store.progress)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        } else if store.isAtEnd {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("Done — \(store.acceptedCount) accepted")
                    .font(.title3)
                if let out = store.outputURL {
                    Text("Saved to \(out.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Import a word-pair file to begin")
                    .foregroundStyle(.secondary)
            }
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

#Preview {
    PairClassifierView()
}
