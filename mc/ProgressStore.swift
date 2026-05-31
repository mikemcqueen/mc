import Foundation

/// Per-file processing progress, persisted so a file resumes where it was left off
/// after the app is quit and relaunched. Saved write-through on every decision — iOS
/// does not deliver a reliable "app is terminating" callback on swipe-close, so we
/// never defer writes to app exit.
///
/// Only the *decided prefix* is stored: decisions are made on the current pair moving
/// forward, so decided pairs are always a contiguous prefix and the resume point is the
/// first undecided pair (= `decisions.count`).
struct FileProgress: Codable {
    /// One char per decided pair: `a` accepted, `s` skipped. Undecided pairs (everything
    /// past this prefix) are not stored.
    var decisions: String
    /// Pair count when saved — used to detect the input file changing under us.
    var total: Int

    var decidedCount: Int { decisions.count }
    var acceptedCount: Int { decisions.reduce(0) { $0 + ($1 == "a" ? 1 : 0) } }
}

/// UserDefaults-backed store of `FileProgress` keyed by file name.
final class ProgressStore {
    static let shared = ProgressStore()

    private let key = "fileProgress.v1"
    private let defaults = UserDefaults.standard

    private init() {}

    func progress(for name: String) -> FileProgress? { all()[name] }

    func set(_ progress: FileProgress, for name: String) {
        var map = all()
        map[name] = progress
        save(map)
    }

    func clear(_ name: String) {
        var map = all()
        guard map.removeValue(forKey: name) != nil else { return }
        save(map)
    }

    /// Drop entries for files that are no longer present in the queue.
    func prune(keeping names: Set<String>) {
        let map = all()
        let filtered = map.filter { names.contains($0.key) }
        if filtered.count != map.count { save(filtered) }
    }

    private func all() -> [String: FileProgress] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: FileProgress].self, from: data)
        else { return [:] }
        return map
    }

    private func save(_ map: [String: FileProgress]) {
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: key)
        }
    }
}
