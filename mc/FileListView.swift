import SwiftUI
import UniformTypeIdentifiers

/// Phase 2 queue UI: the list of pending input files. Tap one to make it active
/// and process it. Finished files are removed (in `PairClassifierView`), so they
/// drop off this list and can't be picked again.
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
                        Button {
                            selected = url
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.blue)
                                Text(url.lastPathComponent)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
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
}

#Preview {
    NavigationStack { FileListView() }
}
