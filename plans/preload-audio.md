# Pre-generate prev/current/next pair audio

## Context

When the active TTS engine is `KokoroEngine` (on-device neural synthesis), each pair is
synthesized synchronously on a background MLX thread before it can play. Navigating with
next/prev/back therefore stalls while the new current line is generated. The system engine
(`AVSpeechEngine`) streams and has no such cost.

Goal: keep up to **three** clips ready at all times — prev / current / next — so moving
between pairs plays instantly with no generation delay. Per the user, this should be a
**protocol capability** (`supportsPreGeneration`), not a Kokoro-only hack, so a future
remote/HTTP engine can opt in the same way.

## Approach

### 1. `mc/SpeechEngine.swift` — capability + hooks
Add to the `SpeechEngine` protocol:
- `var supportsPreGeneration: Bool { get }`
- `func prefetch(_ line: String)`
- `func retain(_ lines: [String])`

Plus a protocol extension giving no-op defaults (`false` / empty bodies) so
`AVSpeechEngine` opts out for free and needs no changes. Declaring them as protocol
*requirements* (not just extension methods) ensures dynamic dispatch picks
`KokoroEngine`'s overrides through the `SpeechEngine` existential.

### 2. `mc/KokoroEngine.swift` — cache + prefetch + dedup
- `var supportsPreGeneration: Bool { true }`.
- Add `private var cache: [String: [Float]] = [:]`, keyed by **voice + speed + text**
  (via a `static func cacheKey(line:voice:speed:)`), so a Settings voice change or speed
  change never replays a stale clip.
- Add `private var pending: [String: [([Float]?) -> Void]] = [:]` — completions waiting on
  an in-flight generation, so a `speak(_:)` that lands on a line a `prefetch(_:)` is
  already generating **joins** that work instead of queueing a duplicate behind it on the
  serial MLX thread.
- Refactor the generation path into a single private
  `generate(_ line:then:)` that resolves from cache, joins `pending`, or enqueues a new
  job on `queue`; on completion it caches the PCM and fans out to all waiters on the main
  actor.
- `speak(_:)` bumps `generation`, then calls `generate`; its completion guards
  `gen == generation` (so a barge-in / stale result is ignored) and plays via `player`.
  A cache hit plays immediately in the same main-actor turn.
- `prefetch(_:)` just calls `generate(line) { _ in }` to populate the cache. It does **not**
  bump `generation`, so it never affects what's currently playing.
- `retain(_ lines:)` filters `cache` down to the keys for `lines`, discarding the rest.
- `stop()` and `warmUp()` unchanged; the cache deliberately survives `stop()` for fast
  replay.

### 3. `mc/PairStore.swift` — neighbor accessor
Add:
```swift
/// The pair `offset` positions from the cursor (negative = earlier), or nil if out of
/// range. Used to pre-generate prev/current/next audio.
func line(at offset: Int) -> String? {
    let i = cursor + offset
    return pairs.indices.contains(i) ? pairs[i] : nil
}
```

### 4. `mc/Speaker.swift` — forward through the facade
Add forwarding to `currentEngine()` (builds the engine lazily as `speak` already does):
- `var supportsPreGeneration: Bool { currentEngine().supportsPreGeneration }`
- `func prefetch(_ line: String) { currentEngine().prefetch(line) }`
- `func retain(_ lines: [String]) { currentEngine().retain(lines) }`

### 5. `mc/SessionController.swift` — drive prefetch on navigation
- At the end of `speakCurrent()` (both branches), call `prepareNeighbors()`.
- New private method:
```swift
/// Keep prev/current/next synthesized and cached (on engines that support it) so
/// next/prev/back play without a generation delay; drop anything further out.
private func prepareNeighbors() {
    guard speaker.supportsPreGeneration else { return }
    let neighbors = [-1, 0, 1].compactMap { store.line(at: $0) }
    speaker.retain(neighbors)
    if let prev = store.line(at: -1) { speaker.prefetch(prev) }
    if let next = store.line(at: 1)  { speaker.prefetch(next) }
}
```
This runs after every accept/skip/reject/back/repeat/continue (all funnel through
`speakCurrent`). At the end of the list it still retains/prefetches the previous line so
`back` is instant. Announcements (status, faster/slower) speak through the generic
`speak(_:)` and intentionally don't disturb the cached neighbors.

## Notes / trade-offs
- Only `KokoroEngine` benefits today; `AVSpeechEngine` short-circuits via
  `supportsPreGeneration == false`, so zero overhead there.
- In-flight dedup matters for the exact race the feature targets: prefetch(next) running
  when the user hits "skip" — `speak(next)` attaches to the pending job rather than
  doubling MLX work.
- Memory stays bounded to 3 clips by `retain`, regardless of file length.
- Consistent with existing constraints: drive synth/playback from the main queue
  (`onMainQueue`), keep MLX work on the one `PinnedThread`.

## Verification
- Build for a real device (Kokoro is device-only): the app must compile and link.
- With `ttsEngine = "kokoro"`: start a session, let the first pair read, then issue
  next/skip and back rapidly — subsequent pairs should play with no audible synthesis
  gap (vs. the current stall). The very first pair still pays one generation cost.
- Switch voice in Settings mid-session and advance — the new voice should be used (cache
  key includes voice), confirming no stale-clip replay.
- With `ttsEngine = "system"` (or simulator): behavior unchanged; verify no regressions in
  speak/stop/auto-advance.
