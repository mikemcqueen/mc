import Foundation
import Combine

/// Per-file processor. Loads one word-pair file (one pair per line) into an ordered
/// list, tracks the current position, and appends accepted pairs *verbatim* to a
/// result file. Write-through: each accept hits disk immediately, so a crash
/// mid-session loses nothing. Knows nothing about audio or the file queue.
@MainActor
final class PairStore: ObservableObject {

    @Published private(set) var pairs: [String] = []
    @Published private(set) var index = 0
    @Published private(set) var acceptedCount = 0
    @Published private(set) var fileName: String?
    @Published private(set) var outputURL: URL?
    @Published private(set) var lastError: String?

    /// The pair awaiting a decision, or nil once the list is exhausted.
    var current: String? { pairs.indices.contains(index) ? pairs[index] : nil }
    var isAtEnd: Bool { !pairs.isEmpty && index >= pairs.count }
    var hasPrevious: Bool { index > 0 }
    var isLoaded: Bool { !pairs.isEmpty }

    /// 1-based "n / total" for display.
    var progress: String {
        guard !pairs.isEmpty else { return "0 / 0" }
        return "\(min(index + 1, pairs.count)) / \(pairs.count)"
    }

    private let fm = FileManager.default

    // MARK: - Loading

    func load(file url: URL, resultsDirectory: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            // Preserve each line's content verbatim (just drop CR and blank lines).
            let lines = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

            guard !lines.isEmpty else {
                reportError("\(url.lastPathComponent) has no pairs.")
                return
            }

            pairs = lines
            index = 0
            acceptedCount = 0
            fileName = url.lastPathComponent
            lastError = nil
            outputURL = uniqueResultURL(
                in: resultsDirectory,
                base: url.deletingPathExtension().lastPathComponent + "-accepted")
        } catch {
            reportError("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Navigation / decisions

    /// Append the current pair to the result file and move on.
    func accept() {
        guard let line = current else { return }
        append(line)
        acceptedCount += 1
        advance()
    }

    /// Skip the current pair without recording it.
    func skip() { advance() }

    func advance() { index = min(index + 1, pairs.count) }

    func back() { index = max(index - 1, 0) }

    // MARK: - Output

    private func append(_ line: String) {
        guard let url = outputURL else { return }
        let data = Data((line + "\n").utf8)
        do {
            if fm.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        } catch {
            reportError("Couldn't save accepted pair: \(error.localizedDescription)")
        }
    }

    func reportError(_ message: String) { lastError = message }

    /// Avoid clobbering results from a previously processed file of the same name.
    private func uniqueResultURL(in dir: URL, base: String) -> URL {
        var dest = dir.appendingPathComponent("\(base).txt")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) \(n).txt")
            n += 1
        }
        return dest
    }
}
