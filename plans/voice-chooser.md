# Add a TTS voice picker (Settings tab)

## Context

The app reads word-pairs aloud with `AVSpeechSynthesizer` but never sets
`utterance.voice`, so iOS falls back to the **compact default** system voice — the
robotic one. That's the source of the "TTS quality" complaint: we're not even
using the best on-device voice available.

The cheapest, lowest-risk, fully-offline improvement is to let the user choose a
voice — and, importantly, surface iOS's **enhanced/premium** voices, which sound
dramatically better. (Those only appear once the user downloads them in
**Settings → Accessibility → Spoken Content → Voices**; the app can't fetch them,
but it can list them, label quality, and nudge the user there.)

Scope for now: a **Settings tab** with a **voice picker + preview**. Built-in
voices only. No cloud TTS, no rate/delay controls — just the picker.

## Design

`Speaker` is privately owned by `SessionController`, which is created fresh inside
`PairClassifierView`. Rather than expose the private speaker and pipe a selection
down, use a single persisted key as the source of truth:

- **`@AppStorage("voiceIdentifier")`** holds the chosen `AVSpeechSynthesisVoice`
  identifier string (empty = system default).
- The **picker** writes it; **`Speaker` reads it** when building each utterance.
- A changed voice takes effect on the next spoken pair automatically — no wiring
  through `SessionController`. AEC/barge-in is untouched (still
  `AVSpeechSynthesizer` + `usesApplicationAudioSession`).

## Changes

### 1. `mc/Speaker.swift` — apply the selected voice
In `speak(_:)`, inside the existing `onMainQueue` block (after building
`utterance`), resolve and set the voice from the stored identifier:

```swift
let utterance = AVSpeechUtterance(string: line)
utterance.rate = rate
if let id = UserDefaults.standard.string(forKey: "voiceIdentifier"), !id.isEmpty,
   let voice = AVSpeechSynthesisVoice(identifier: id) {
    utterance.voice = voice
}   // else: leave nil → system default
```
Reading inside the `@MainActor` closure keeps it Sendable-safe (`id` is a String;
voice is constructed inside). Same `"voiceIdentifier"` literal the picker uses.

### 2. New `mc/SettingsView.swift` — the picker + preview
A `List`-based SwiftUI view:
- Source: `AVSpeechSynthesisVoice.speechVoices()` filtered to English
  (`language.hasPrefix("en")`), sorted by quality (premium → enhanced → compact)
  then name. (English-only keeps the list usable; recognizer is en-US.)
- Selection bound to `@AppStorage("voiceIdentifier")`; each row shows the voice
  name, its language, and a **quality label** (Premium / Enhanced / Compact), with
  a checkmark on the active one. A "System default" row clears the stored choice.
- A **preview** control (per-row play button) speaks a fixed sample line using a
  small retained `AVSpeechSynthesizer` held by a tiny `@StateObject` preview model
  (the synth must be retained or it stops). The preview is reached only from a
  SwiftUI button action (already on the main actor/queue), so it can drive the
  synthesizer directly — no `onMainQueue` hop needed (unlike `Speaker`, which is
  also reached from recognizer callbacks and Tasks). The preview synth uses its
  own audio session (not `usesApplicationAudioSession`) so it works on the Settings
  tab regardless of whether a session is live.
- A footer hint: if no enhanced/premium voice is installed, point the user to
  **Settings → Accessibility → Spoken Content → Voices** to download better ones.

### 3. `mc/ContentView.swift` — add the tab
Add a third tab to the existing `TabView`:
```swift
SettingsView()
    .tabItem { Label("Settings", systemImage: "gearshape") }
```

## Files
- `mc/Speaker.swift` — read `voiceIdentifier`, set `utterance.voice` (~4 lines).
- `mc/SettingsView.swift` — **new**, the picker + preview (~80–120 lines). The
  project uses Xcode synchronized file groups, so a new file in `mc/` is included
  automatically — no `project.pbxproj` edit needed.
- `mc/ContentView.swift` — one new `.tabItem`.

## Verification
1. Build & run on device/simulator. Confirm a third **Settings** tab appears.
2. In Settings, tap **Preview** on a few voices — each speaks the sample in that
   voice. Confirm quality labels look right and the install-more hint shows when
   only compact voices are present.
3. Pick a non-default voice, go to **Files**, process a file: the spoken pairs use
   the chosen voice. Pick a premium voice (download one first if needed) and
   confirm the audible quality jump.
4. Confirm voice persists across an app relaunch (`@AppStorage`).
5. Regression: voice commands / barge-in still work while speaking — picking a
   voice didn't disturb the AEC session.
