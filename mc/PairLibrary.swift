import Foundation
import Combine

/// Manages the on-device queue of input files. Drop word-pair `.txt` files into
/// the app's Documents folder (via Finder file sharing or the Files app, both
/// enabled in Info.plist) and they show up here. Pick one to process; when it's
/// finished the input file is deleted, so it never appears in the queue again —
/// each file is processed exactly once. Accepted-pair results are written to a
/// `Results/` subfolder, which survives deletion of the input.
@MainActor
final class PairLibrary: ObservableObject {

    @Published private(set) var files: [URL] = []
    @Published var lastError: String?

    private let fm = FileManager.default

    var documentsURL: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    var resultsURL: URL { documentsURL.appendingPathComponent("Results", isDirectory: true) }

    init() { refresh() }

    /// Re-scan the Documents folder for pending input files.
    func refresh() {
        try? fm.createDirectory(at: resultsURL, withIntermediateDirectories: true)
        let contents = (try? fm.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        files = contents
            .filter { $0.pathExtension.lowercased() == "txt" }   // excludes the Results dir
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Bring an externally-picked file into the queue by copying it into Documents.
    /// (Finder/Files drops land in Documents directly and don't need this.)
    func importFile(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try fm.copyItem(at: url, to: uniqueDestination(for: url.lastPathComponent))
            refresh()
        } catch {
            lastError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// The input file has been fully processed — remove it so it's never offered
    /// again. Results were already written through to the Results folder.
    func complete(_ url: URL) {
        do {
            try fm.removeItem(at: url)
        } catch {
            lastError = "Couldn't remove \(url.lastPathComponent): \(error.localizedDescription)"
        }
        refresh()
    }

    private func uniqueDestination(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var dest = documentsURL.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            dest = documentsURL.appendingPathComponent(candidate)
            n += 1
        }
        return dest
    }
}
