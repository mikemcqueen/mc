# Plan: Native iOS Word-Pair Classifier — Build It

## Context

The user has lists of word-pairs (one pair per line in a text file) that must be
manually classified as "good" or not. They want a hands-free iPhone tool: with
Bluetooth earbuds in, it reads each pair aloud (TTS) and listens for a spoken
"yes"/"good" to accept it, plus voice commands (stop / continue / repeat / back /
faster / slower). Accepted pairs are saved to a local file for later reconciliation
with their existing Evernote checked-items tool.

This is a **greenfield** project — the repo (`/Users/mike/code/mc`) contains only
design docs, no code. The design is locked in `design/design-1-opus-native.md`. This
plan turns that design into an executable build.

**Decisions settled in conversation:**
- Native iOS / Swift + SwiftUI. Personal use, run on own device via a **free** Apple ID
  (no paid Developer Program needed).
- **Bluetooth earbuds using their own mic** → HFP profile, "phone-quality" (~16 kHz) TTS
  accepted, AEC engaged for reliable barge-in. (Correction vs. design doc: these are
  generic BT earbuds, *not* AirPods — so drop the AirPods-specific in-ear auto pause/resume
  and use a manual pause control + generic audio-route-change handling instead.)
- **Always-on speech recognition with barge-in** (interrupt TTS mid-utterance); strict
  turn-taking is a one-line fallback.
- **Local file I/O via the Files app / Finder.** Import pair list with a document picker;
  write accepted pairs to the app's Documents folder, exposed for manual copy in Finder
  and the Files app.
- User creates the Xcode app target themselves; Claude writes all Swift + Info.plist keys.

## Part A — Apple ID / Xcode signing walkthrough (user does once)

It's been ~10 years since the user shipped iOS, so the modern free-signing flow:

1. **Apple ID** — any existing Apple ID works. No $99/yr Developer Program required for
   personal on-device installs (limits: app re-signs/expires every 7 days, a few app IDs,
   no push/associated-domains entitlements — none of which this app needs).
2. **Add the account to Xcode** — Xcode ▸ Settings ▸ Accounts ▸ "+" ▸ Apple ID ▸ sign in.
   A **Personal Team** appears automatically.
3. **Project signing** — select the app target ▸ Signing & Capabilities ▸ check
   *Automatically manage signing* ▸ Team = your Personal Team ▸ set a unique reverse-DNS
   **Bundle Identifier** (e.g. `com.<you>.pairclassifier`). Xcode provisions automatically.
4. **iOS 16+ Developer Mode (new since they last shipped)** — on the iPhone:
   Settings ▸ Privacy & Security ▸ Developer Mode ▸ on ▸ restart. Required before any
   self-signed app will launch.
5. **Trust the cert** — first launch may need Settings ▸ General ▸ VPN & Device Management ▸
   trust your developer certificate.
6. **Run** — plug in (or wireless: Window ▸ Devices and Simulators ▸ "Connect via network"),
   pick the device in Xcode's run-destination dropdown, ⌘R.

## Part B — Xcode project creation (user does, Claude specifies settings)

- File ▸ New ▸ Project ▸ iOS ▸ **App**. Interface: **SwiftUI**, Language: **Swift**.
- Minimum deployment: **iOS 16** (on-device recognition + voice processing well-supported).
- After creation, add these **Info.plist** keys (Claude will give exact strings):
  - `NSMicrophoneUsageDescription`
  - `NSSpeechRecognitionUsageDescription`
  - `UIFileSharingEnabled` = YES  (Finder file access)
  - `LSSupportsOpeningDocumentsInPlace` = YES  (Files-app visibility)

## Part C — Swift source Claude will write

All first-party frameworks: `AVFoundation`, `Speech`, `SwiftUI`. Files:

- **`PairStore.swift`** — model. Loads a `.txt` (one pair per line) into an ordered list,
  tracks `currentIndex`, `accept()` appends the *verbatim* current line to the output file
  in Documents (write-through; crash-safe). Holds no audio logic.
- **`Speaker.swift`** — wraps `AVSpeechSynthesizer`: `speak(line)`, `stop()`, did-finish
  callback, adjustable `rate` (faster/slower map to `AVSpeechUtterance.rate`).
- **`Listener.swift`** — owns an always-on `AVAudioEngine` + `SFSpeechRecognizer`
  (`requiresOnDeviceRecognition = true`, check `supportsOnDeviceRecognition`; bias with
  `contextualStrings`). Enables AEC via `inputNode.setVoiceProcessingEnabled(true)`. Emits an
  `Intent` enum: `.accept .stop .continue .repeat .back .faster .slower`. Internally restarts
  the recognition request (~1-min lifetime) so callers never see it. Suppresses self-triggers
  (ignore a match equal to the line currently being spoken).
- **`SessionController.swift`** — `ObservableObject` state machine wiring the three:
  states `.speaking(line) | .awaiting | .paused`. On any `Intent`: stop current utterance if
  speaking, then dispatch (accept→advance, repeat, back, faster/slower→re-speak, stop→pause,
  continue→resume). Configures `AVAudioSession` `.playAndRecord` / `.voiceChat` /
  `.allowBluetooth`; observes `AVAudioSession.routeChangeNotification` to auto-pause when the
  BT device disconnects.
- **`ContentView.swift`** — SwiftUI UI: Import button (`fileImporter` document picker),
  current pair, accepted count, rate, big manual Pause/Resume + Next/Back/Accept buttons
  (so it's fully usable before voice is wired, and as a fallback).

## Build sequence (de-risk audio first)

1. **Audio spike** — throwaway screen: continuously recognize speech while looping TTS
   through the BT earbuds, log every transcription. Answers the only real unknown — *does AEC
   keep TTS out of the recognizer well enough on these earbuds?* — before building the rest.
2. `PairStore` + document-picker import + Documents-folder output, driven by buttons only.
3. `Speaker` + speak→advance loop with a manual "Next" button.
4. `Listener` + full voice command set, barge-in via `SessionController`.
5. Polish: manual pause/resume, route-change auto-pause, session resume after relaunch,
   accepted-count UI.

## Defaults (revisit later)

- On silence in the listening window: **stay and wait** — never auto-accept, never auto-skip.
- `faster`/`slower`: re-speak the current pair so the new rate is audible.
- Input format: one pair per line; accepted lines copied **verbatim** to the output file.

## Verification

- **Spike (step 1):** with BT earbuds connected, confirm spoken "yes" is transcribed cleanly
  while TTS plays, and that TTS words do *not* show up as false matches. This gates the rest.
- **File round-trip:** drop a `pairs.txt` into the app's Documents via Finder, import it,
  classify a few, then confirm the output file appears in Finder / Files with the right pairs.
- **End-to-end hands-free:** run a full short list earbuds-only — accept via "yes/good",
  exercise stop/continue/repeat/back/faster/slower, verify barge-in interrupts mid-utterance.
- **Build/run:** ⌘R to the physical device (Developer Mode on). Simulator can validate UI +
  file logic but **not** BT audio routing — audio testing must be on the device.
- Manual button controls mirror every voice command, so each piece is testable before voice
  recognition is trusted.
