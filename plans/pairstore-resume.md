# Plan: Mid-file resume (quit-safe progress)

## Context
`PairStore` currently keeps the cursor (`index`) only in memory and appends accepted
pairs to the result file write-through. Finishing a file deletes its input
(process-once). But if the user **quits mid-file** — swipe-closes the app, or it's
killed while backgrounded — the cursor is lost and the file restarts from the top.
We want to resume exactly where they left off, and (nice-to-have, user-confirmed)
let **Back undo a prior Accept**.

**Why we persist per-action, not at exit** (answers the user's question — this is the
standard, supported iOS pattern):
- Swipe-closing from the App Switcher (the usual force-quit), or the system reaping a
  suspended app, does **not** call `applicationWillTerminate` or any save hook.
- Backgrounding delivers `scenePhase == .background` / `didEnterBackground` — the only
  semi-reliable "about to stop" signal — but the app may already be suspended and later
  killed with no further callback, and there's no guarantee of time for heavy work.
- Apple's guidance is to **persist incrementally** (state restoration / write-through),
  never to rely on a termination callback.

So progress is saved **write-through on every decision**. No exit hook involved.

## Approach
Model each file's progress as a **decision vector**, persisted immediately on every
decision. Decided pairs are always a contiguous prefix (you can only decide the current
pair moving forward), so **no cursor is stored** — the resume point is just the first
undecided pair. Generate the results `.txt` at **Finish** (an explicit, synchronous user
action) from the accepted decisions — the persisted decisions are the crash-safe source
of truth. This also makes Back/undo clean: a revisited pair's decision is simply
overwritten.

### New: `mc/ProgressStore.swift`
- UserDefaults-backed map `[String: FileProgress]` under key `"fileProgress.v1"`.
- `struct FileProgress: Codable { var decisions: String; var total: Int }` where
  `decisions` is the **decided prefix only** — one char per decided pair, `a` accepted /
  `s` skipped. Undecided pairs aren't stored; they're everything past the prefix.
  Derived on load: resume index = `decisions.count`, `acceptedCount` = count of `a`.
  `total` is kept for the queue display and an integrity check (file unchanged).
- API: `progress(for:)`, `set(_:for:)`, `clear(_:)`, `prune(keeping:)`.
- Exposed as `ProgressStore.shared` so both `PairStore` and `PairLibrary` use it without
  init plumbing (`PairStore` is created as a no-arg `@StateObject`).
- Tiny per-file state; UserDefaults is the simplest supported store. If pair lists ever
  get very large, swap the backing to a JSON sidecar in Documents behind the same API.

### `mc/PairStore.swift` (modify)
- In memory: `decisions: [Decision]` (`enum Decision { case undecided, accepted, skipped }`,
  length = `pairs.count`; decided pairs are a contiguous prefix, the rest `.undecided`)
  plus an **in-memory-only** `cursor` for navigation (Back). The cursor isn't persisted —
  the resume point is always the first undecided pair.
- `load(file:resultsDirectory:)`: parse pairs as today; look up
  `ProgressStore.shared.progress(for: fileName)`. If found **and** `total == pairs.count`,
  restore the decided prefix and set `cursor = decisions.count` (first undecided);
  otherwise start fresh (all `.undecided`, cursor 0). Keep `resultsDirectory` for finish.
- `accept()` / `skip()`: set `decisions[cursor]`, advance cursor, `persist()`.
- `back()`: `cursor -= 1` (no persist — cursor isn't stored and decisions are unchanged).
  A subsequent Accept/Skip on the revisited pair overwrites its decision → undo, and that
  `persist()` captures it.
- Derived: `current`, `isAtEnd` (cursor ≥ count), `acceptedCount`, `progress`,
  `currentDecision` (so the view can show the existing decision when revisiting).
- `finish() -> URL`: write accepted pairs **verbatim, in order** to a unique URL (reuse
  the existing `uniqueResultURL` helper, lines 103–111) and return it. Replaces live append.
- `persist()`: store `FileProgress(decisions: <a/s prefix>, total: pairs.count)` for `fileName`.

### `mc/PairLibrary.swift` (modify)
- `refresh()`: after building `files`, call
  `ProgressStore.shared.prune(keeping: Set(files.map { $0.lastPathComponent }))`.
- Add `progress(for url: URL) -> FileProgress?` for row display.
- `complete(_:)`: also `ProgressStore.shared.clear(name)` alongside deleting the input.
- Add `restart(_ url: URL)`: `ProgressStore.shared.clear(name)` + `refresh()`.

### `mc/PairClassifierView.swift` (modify)
- Resume is automatic (no prompt): `store.load` already restores.
- Finish footer: `let out = store.finish()` → `library.complete(file)` → `dismiss()`;
  show `out.lastPathComponent` on the Done screen.
- Optional: small "previously: accepted/skipped" label on the pair card when
  `store.currentDecision != .undecided`, for Back context.

### `mc/FileListView.swift` (modify)
- Row subtitle when `library.progress(for: url)` exists, e.g.
  "In progress · {cursor}/{total} · {accepted} kept".
- Swipe action **Restart** → `library.restart(url)`.

## Notes / edge cases
- **No stored cursor:** decisions are only made on the current pair moving forward, so
  decided pairs form a contiguous prefix and the resume point = first undecided =
  `decisions.count`. Trade-off: a Back excursion isn't restored across a quit — resume
  lands at the frontier, not where you'd Back'd to. Negligible, arguably better.
- **Write ordering:** decision mutation + persist run synchronously on the MainActor
  between taps; a kill can only land between taps, never mid-write.
- **File changed under us:** if saved `total != pairs.count`, discard saved progress and
  start fresh (avoids misaligned decisions).
- **Manual deletion:** progress for vanished files is pruned on `refresh()`.
- **Result clobber:** `finish()` reuses the unique-name helper, so a re-dropped
  same-named file's results never overwrite prior results.
- **Belt-and-suspenders:** a `scenePhase`/`.background` flush is unnecessary (we persist
  per action) and can be added later if ever wanted.

## Verification
- Build: `xcodebuild -project mc.xcodeproj -scheme mc -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug build CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED.
- Resume: import a multi-pair file, Accept/Skip a few, **swipe-close from the App
  Switcher** (real force-quit), relaunch → file shows "In progress" with correct counts;
  opening resumes at the first undecided pair with earlier decisions intact.
- Undo: Accept a pair → Back → Skip it → confirm it's absent from results.
- Finish: result `.txt` in `Results/` holds exactly the accepted pairs verbatim; input
  deleted; file gone from queue; progress entry cleared.
- Restart: swipe Restart → progress cleared; file starts from the top.
