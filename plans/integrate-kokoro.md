# Integrate KokoroSwift as a selectable high-quality TTS engine

## Context

The app reads word-pairs aloud with `AVSpeechSynthesizer`, which falls back to the
robotic compact system voice — the source of the "TTS quality" complaint that also
motivated `plans/voice-chooser.md`. KokoroSwift (the Kokoro-82M neural TTS model,
running on-device via MLX) is a far larger quality jump than picking a better system
voice, and ships ~54 natural voices.

Goal: add Kokoro as a **selectable** TTS engine behind a protocol, keeping
`AVSpeechSynthesizer` as the default/fallback. AVSpeech must stay because Kokoro is
**Apple-Silicon device only**. NOTE (as-built): linking MLX makes the app **device-only
to *build*** — the simulator can't link `Cmlx` (the simulator Metal SDK is missing
`_MTLTensorDomain`/`_MTLIOErrorDomain`), and SwiftPM/Xcode can't exclude a package product
for simulator-only (device & simulator are the same "platform"). So the AVSpeech runtime
fallback does **not** keep the simulator building; per decision, simulator/CI builds are
unsupported while Kokoro is linked. The device build is clean (verified). For now the
~327 MB model + voice files are **bundled in the app** to
keep the integration simple (no download UI/state machine); Xcode's differential
install means the unchanged model isn't re-copied on every dev build.

**How hard, short answer:** Medium. The protocol/refactor is small and clean. The
real work is (1) wiring in MLX + bundling the model/voice assets, and (2) routing
Kokoro's raw PCM through the existing AEC audio graph so TTS still doesn't self-trigger
the recognizer. No changes to `SessionController` are needed if `Speaker` keeps its API.

## Key facts driving the design

- **Package:** `https://github.com/mlalma/kokoro-ios.git` (latest tag 1.0.11),
  product/import `KokoroSwift`. Pulls in mlx-swift, MisakiSwift, MLXUtilsLibrary.
  Requires iOS 18 / macOS 15 (project is at iOS 26.5 ✓), Swift tools 6.2 (Xcode 26).
- **API:** `KokoroTTS(modelPath: URL)` then
  `generateAudio(voice: MLXArray, language: .enUS, text:, speed:) -> ([Float], [MToken]?)`.
  Output is **mono 24 kHz Float PCM**, batch (whole clip per call), ~3.3× real-time
  after a slow first/warm-up call.
- **Assets (no conversion, no self-hosting):** `prince-canuma/Kokoro-82M` hosts the
  exact formats KokoroSwift consumes — `kokoro-v1_0.safetensors` (fp32, 327 MB, the
  same file the working test app loads) and a `voices/` folder of **per-voice
  `.safetensors`** (all 54; ~522 KB each = the full `[510,1,256]` token-indexed style
  pack). So we can **skip `voices.npz`/`NpyzReader`**: load a per-voice safetensors
  with `MLX.loadArrays` and pass its single array straight to `generateAudio(voice:)`.
  Direct: `…/resolve/main/kokoro-v1_0.safetensors`,
  `…/resolve/main/voices/<name>.safetensors`. (Provenance: a duplicate of the official
  `hexgrad/Kokoro-82M`, which itself only ships `.pth` + a `voices/` folder of `.pt` —
  wrong format for MLX. Same Apache-2.0 v1.0 weights.) **Bundle** these in the app for
  now; keep the 327 MB model out of git.
- **Current TTS seam:** `mc/Speaker.swift` directly owns `AVSpeechSynthesizer`; there
  is no abstraction. `SessionController` (`mc/SessionController.swift:40,57,77,102,167`)
  only uses `speaker.speak(_:)`, `speaker.stop()`, `speaker.onFinish`,
  `speaker.isSpeaking`, `speaker.rate`. Preserve exactly this surface.
- **AEC / self-trigger:** today AVSpeechSynthesizer rides the app session
  (`usesApplicationAudioSession = true`) so `Listener`'s VPIO unit cancels it from the
  mic. `Listener` (`mc/Listener.swift`) owns the only `AVAudioEngine` (VPIO enabled,
  `mainMixerNode` touched at `:125`). It also suppresses the spoken line's words
  (`setSpokenLine` / `spokenWords`, `:143`/`:54`) as a second line of defense.
- **Threading invariant:** AVFoundation audio must be driven from the **main dispatch
  queue**, not a `Task` (`onMainQueue` helper, `mc/Speaker.swift:86`). Kokoro
  *generation* runs on a background queue; *playback scheduling* must hop to main.

## Design

### 1. Extract a TTS protocol — `mc/SpeechEngine.swift` (new)
```swift
@MainActor protocol SpeechEngine: AnyObject {
    var isSpeaking: Bool { get }
    var rate: Float { get set }
    var onFinish: (() -> Void)? { get set }
    func speak(_ line: String)
    func stop()
}
```
Move the existing `AVSpeechSynthesizer` logic from `Speaker` into
`AVSpeechEngine: SpeechEngine` (essentially today's `Speaker` body verbatim,
including the voice-identifier read from `plans/voice-chooser.md` if that lands).

### 2. `mc/Speaker.swift` — make it a thin facade
`Speaker` keeps its current public API but delegates to a `SpeechEngine` chosen from
`@AppStorage("ttsEngine")` (values `"system"` | `"kokoro"`), defaulting to `system`.
It forwards `isSpeaking`/`onFinish`/`rate`/`speak`/`stop`. This keeps
`SessionController` untouched. If Kokoro is selected but its model isn't present
(or we're on simulator), fall back to `AVSpeechEngine` and surface a note.

### 3. `mc/KokoroEngine.swift` (new) — the Kokoro `SpeechEngine`
- Holds a single cached `KokoroTTS` instance (init is expensive), built from the
  bundled `kokoro-v1_0.safetensors` (`Bundle.main.url(forResource:withExtension:)`).
- Voice: load the selected per-voice safetensors lazily via `MLX.loadArrays(url:)`
  and take its single array (no `voices.npz`/`NpyzReader`). Cache loaded voices.
- **Warm up** once at session start with a throwaway `generateAudio` so the first
  real pair isn't slow.
- `speak(_:)`: set `isSpeaking = true`, capture a monotonically increasing
  `generation` (mirror `Listener.generation`, `mc/Listener.swift:69`), run
  `generateAudio` on a background `DispatchQueue`, then `onMainQueue` { if still the
  current generation, schedule the PCM on the player node }. On the player node's
  completion handler, `onMainQueue` clear `isSpeaking` and call `onFinish`.
- `stop()`: bump `generation` (so an in-flight generation's result is discarded — the
  synchronous `generateAudio` call can't be cancelled mid-flight, same pattern
  `Listener` uses for recognition tasks), stop the player node, clear `isSpeaking`.

### 4. Audio routing — play Kokoro PCM through the VPIO engine (preserve AEC)
Kokoro returns `[Float]`; it must be played via an `AVAudioPlayerNode`. To keep AEC
cancelling TTS from the mic, play through **`Listener`'s existing VPIO engine**, not a
separate one. Add a small playback seam to `mc/Listener.swift`:
```swift
func play(_ samples: [Float], sampleRate: Double, onDone: @escaping () -> Void)
func stopPlayback()
```
It lazily attaches one `AVAudioPlayerNode`, connects it to `mainMixerNode` with
`AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)`, copies `samples`
into an `AVAudioPCMBuffer`, and schedules it (completion handler → `onMainQueue` →
`onDone`). `KokoroEngine` is handed this player seam (a `PCMPlayer` protocol so it
isn't hard-coupled to `Listener`); `SessionController` injects `listener` into the
Kokoro engine when it builds the facade. Word-suppression (`setSpokenLine`) remains
the backstop, so even imperfect AEC won't fire false commands.

### 5. Assets — bundle in the app (for now)
- Fetch `kokoro-v1_0.safetensors` and the per-voice `.safetensors` you want (at least
  `af_heart.safetensors`; or all 54 ≈ 28 MB to back the picker) into a **gitignored**
  `Resources/` via a small `fetch-models.sh` / `Makefile` target that `curl`s the
  Hugging Face `resolve/main/...` URLs above; add the dir to the Xcode target and
  reference via `Bundle.main.url`.
- **Don't** git-submodule `KokoroTestApp` to "inherit" the model: its safetensors is
  Git-LFS-tracked under *that owner's* LFS bandwidth quota (fetches throttle/fail once
  exhausted), it drags in a whole example app, and it's a redundant second coupling to
  the SwiftPM dep author. The HF fetch script gets the same files without those risks.
- No download module/first-run UI. If on simulator (no Metal) or the model resource
  is missing, `Speaker` falls back to `AVSpeechEngine`. (Runtime download can replace
  bundling later without touching the engine code — only the asset-resolution call.)

### 6. Add the SwiftPM dependency
Add `kokoro-ios` via Xcode (File → Add Package Dependencies → the repo URL, "Up to
Next Major" from 1.0.0). This writes `XCRemoteSwiftPackageReference` +
`packageProductDependencies` into `mc.xcodeproj/project.pbxproj` (today empty). New
`.swift` files need no pbxproj edit (synchronized file group), but the package
product link does.

### Interaction with `plans/voice-chooser.md`
They compose: the voice-chooser Settings tab becomes the natural home for both the
engine toggle and the voice picker. When engine = Kokoro, the picker lists the ~54
voice names; when = system, it lists `AVSpeechSynthesisVoice.speechVoices()`.
Recommend landing voice-chooser first (tiny, pure-AVSpeech), then this on top.

## Files
- `mc/SpeechEngine.swift` — **new**, protocol (~12 lines).
- `mc/AVSpeechEngine.swift` — **new**, today's `Speaker` synth logic moved here.
- `mc/KokoroEngine.swift` — **new**, Kokoro impl: cached `KokoroTTS` from bundled
  safetensors, per-voice `MLX.loadArrays`, warm-up, background generate → main-queue
  play, generation-guarded `stop()`.
- **Bundled assets:** `kokoro-v1_0.safetensors` + per-voice `.safetensors` added to
  the target (gitignored), fetched via `fetch-models.sh`. No new code file for download.
- `mc/Speaker.swift` — slim to a facade over `SpeechEngine` chosen by
  `@AppStorage("ttsEngine")`; same public API.
- `mc/Listener.swift` — add `play(_:sampleRate:onDone:)` / `stopPlayback()` on the
  VPIO engine (a `PCMPlayer` seam).
- `mc/SessionController.swift` — inject `listener` as Kokoro's player; otherwise
  untouched (still calls `speaker.speak/stop`, observes `isSpeaking`).
- `mc/SettingsView.swift` — (with voice-chooser) engine toggle + Kokoro voice picker.
- `mc.xcodeproj/project.pbxproj` — KokoroSwift package reference (via Xcode UI).

## Constraints / risks to call out
- **Apple-Silicon device only — including to *build*.** MLX/Metal won't link for the
  simulator (`Cmlx` undefined `_MTLTensorDomain`/`_MTLIOErrorDomain`), and a package
  product can't be excluded for simulator-only. The AVSpeech runtime fallback keeps the
  app *usable* if Kokoro is unselected/unavailable, but it does **not** make simulator
  builds compile/link. Decision: simulator/CI builds are unsupported with Kokoro linked.
  Keep `system` the default so a device build with no model still works.
- **First-call latency:** warm up at session start; word-pairs are tiny (<510 tokens)
  so post-warm-up generation is well under real-time. Barge-in (`stop()`) is handled
  by the generation guard + `stopPlayback()`.
- **Bundling adds ~327 MB to the app**, but Xcode differential-installs it once (not
  re-copied on every dev build). Keep it out of git. A runtime download can replace
  bundling later by swapping only the asset-resolution call (engine code unchanged).
- Confirm Xcode 26 toolchain (Swift tools 6.2) — implied by the iOS 26.5 target.

## Verification
1. Build & run **on an Apple-Silicon device** (Kokoro won't run on simulator).
2. With engine = `system` (default), confirm everything behaves exactly as today
   (AVSpeech speaks, barge-in/AEC intact) — pure regression check.
3. Switch engine = `kokoro`: confirm the bundled `kokoro-v1_0.safetensors` loads and
   the selected per-voice safetensors resolves via `Bundle.main.url`.
4. Process a file: pairs are spoken in the Kokoro voice. Confirm the first pair isn't
   noticeably delayed (warm-up worked).
5. **AEC/self-trigger regression:** while a pair plays, confirm the recognizer doesn't
   fire a command from the TTS audio (e.g. a pair containing "back"/"skip"), proving
   playback rides the VPIO graph + word-suppression.
6. **Barge-in:** say "yes"/"no" mid-utterance — playback stops promptly and the next
   pair advances (generation guard discards any in-flight generation).
7. Toggle back to `system` mid-session and confirm a clean handoff.
