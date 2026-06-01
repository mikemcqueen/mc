import Foundation
import Combine

enum Decision: Character {
    case undecided = "u"
    case accepted = "a"
    case skipped = "s"
}

/// Per-file processor. Loads one word-pair file (one pair per line) into an ordered
/// list and records a decision for each pair. Progress is persisted write-through on
/// every decision (see `ProgressStore`) so the file resumes after a quit; the accepted
/// pairs are written to a result file only at `finish()`. Knows nothing about audio or
/// the file queue.
@MainActor
final class PairStore: ObservableObject {

    @Published private(set) var pairs: [String] = []
    @Published private(set) var decisions: [Decision] = []
    /// In-memory navigation position. Not persisted — on resume we jump to the first
    /// undecided pair, since decided pairs are always a contiguous prefix.
    @Published private(set) var cursor = 0
    @Published private(set) var fileName: String?
    @Published private(set) var lastError: String?

    private var resultsDirectory: URL?
    private let fm = FileManager.default

    /// The pair awaiting a decision, or nil once the list is exhausted.
    var current: String? { pairs.indices.contains(cursor) ? pairs[cursor] : nil }
    /// The decision already recorded for the current pair (relevant after Back).
    var currentDecision: Decision? { decisions.indices.contains(cursor) ? decisions[cursor] : nil }
    var isAtEnd: Bool { !pairs.isEmpty && cursor >= pairs.count }
    var hasPrevious: Bool { cursor > 0 }
    var isLoaded: Bool { !pairs.isEmpty }
    var acceptedCount: Int { decisions.reduce(0) { $0 + ($1 == .accepted ? 1 : 0) } }

    /// 1-based "n / total" for display.
    var progress: String {
        guard !pairs.isEmpty else { return "0 / 0" }
        return "\(min(cursor + 1, pairs.count)) / \(pairs.count)"
    }

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
            fileName = url.lastPathComponent
            self.resultsDirectory = resultsDirectory
            lastError = nil
            restoreOrStartFresh()
        } catch {
            reportError("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func restoreOrStartFresh() {
        var restored = [Decision](repeating: .undecided, count: pairs.count)
        if let name = fileName,
           let saved = ProgressStore.shared.progress(for: name),
           saved.total == pairs.count {
            for (i, ch) in saved.decisions.enumerated() where i < pairs.count {
                restored[i] = Decision(rawValue: ch) ?? .undecided
            }
            cursor = min(saved.decidedCount, pairs.count)   // first undecided
        } else {
            cursor = 0
        }
        decisions = restored
    }

    // MARK: - Navigation / decisions

    func accept() { decide(.accepted) }

    /// Explicit rejection ("no"/"bad"): mark skipped no matter the current decision.
    func reject() { decide(.skipped) }

    /// "skip"/"next": classify as skipped only if still undecided, otherwise leave the
    /// existing decision untouched and just move past it. Lets a user re-hear a decided
    /// pair (via `back`) and step forward again without clobbering their earlier call.
    func skipOrAdvance() {
        if currentDecision == .undecided {
            decide(.skipped)
        } else {
            cursor = min(cursor + 1, pairs.count)
        }
    }

    private func decide(_ decision: Decision) {
        guard decisions.indices.contains(cursor) else { return }
        decisions[cursor] = decision
        cursor = min(cursor + 1, pairs.count)
        persist()
    }

    func back() { cursor = max(cursor - 1, 0) }

    // MARK: - Finish

    /// Write accepted pairs verbatim, in order, to a unique result file; return its URL.
    @discardableResult
    func finish() -> URL? {
        guard let dir = resultsDirectory, let name = fileName else { return nil }
        let base = (name as NSString).deletingPathExtension + "-accepted"
        let url = uniqueResultURL(in: dir, base: base)
        let accepted = zip(pairs, decisions).filter { $0.1 == .accepted }.map { $0.0 }
        let body = accepted.isEmpty ? "" : accepted.joined(separator: "\n") + "\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            reportError("Couldn't write results: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Persistence

    private func persist() {
        guard let name = fileName else { return }
        // Decided pairs are a contiguous prefix; store only that.
        let encoded = decisions
            .prefix { $0 != .undecided }
            .map { String($0.rawValue) }
            .joined()
        ProgressStore.shared.set(FileProgress(decisions: encoded, total: pairs.count), for: name)
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
