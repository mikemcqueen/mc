import SwiftUI
import UniformTypeIdentifiers

/// Phase 2 queue UI: the list of pending input files. Tap one to make it active
/// and process it. In-progress files show how far along they are and can be
/// restarted; finished files are removed (in `PairClassifierView`), so they drop
/// off this list and can't be picked again.
struct FileListView: View {
    @StateObject private var library = PairLibrary()
    @State private var selected: URL?
    @State private var showImporter = false

    var body: some View {
        List {
            if library.files.isEmpty {
                ContentUnavailableView {
                    Label("No files", systemImage: "tray")
                } description: {
                    Text("Add files with the + button, or drop .txt files into this app's folder in Finder or the Files app.")
                }
            } else {
                Section("To process") {
                    ForEach(library.files, id: \.self) { url in
                        row(for: url)
                    }
                }
            }
        }
        .navigationTitle("Files")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { library.refresh() } label: { Image(systemName: "arrow.clockwise") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImporter = true } label: { Image(systemName: "plus") }
            }
        }
        .navigationDestination(item: $selected) { url in
            PairClassifierView(file: url, library: library)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.plainText, .text, .utf8PlainText],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                urls.forEach(library.importFile)
            }
        }
        .onAppear { library.refresh() }
        .overlay(alignment: .bottom) {
            if let error = library.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding()
            }
        }
    }

    private func row(for url: URL) -> some View {
        let progress = library.progress(for: url)
        return Button {
            selected = url
        } label: {
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .foregroundStyle(.primary)
                    if let progress {
                        Text("In progress · \(progress.decidedCount)/\(progress.total) · \(progress.acceptedCount) kept")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .swipeActions(edge: .trailing) {
            if progress != nil {
                Button(role: .destructive) {
                    library.restart(url)
                } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }
}

#Preview {
    NavigationStack { FileListView() }
}
