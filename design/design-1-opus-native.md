# Mobile Word-Pair Classifier — Native iOS Design

A hands-free iPhone tool that reads word-pairs aloud via TTS over AirPods, listens
for spoken "yes"/"good" to classify pairs, supports voice commands, and records
accepted pairs to a local file for later reconciliation with Evernote.

## Decisions locked in

- **Platform:** Native iOS / Swift (SwiftUI for the trivial UI). Personal use — run on
  own device via a free Apple dev account (app re-signs every 7 days; no App Store).
- **Audio hardware:** AirPods / Bluetooth earbuds using *their own mic*. This puts the
  link on the Bluetooth **HFP** profile, so TTS will be "phone quality" (~16 kHz) rather
  than rich audio — an accepted trade. The upside: HFP/`.voiceChat` engages Apple's voice
  processing / acoustic echo cancellation (AEC), which is what makes barge-in reliable.
- **Save target:** Append accepted "yes/good" pairs to a **local text file** during the
  session. Reconcile with Evernote afterward using the existing Evernote round-trip tool.
  Evernote stays out of the real-time loop deliberately (no in-app OAuth / ENML editing in
  the hot path).
- **Interaction model:** Always-on speech recognition with **barge-in** (interrupt TTS
  mid-utterance). Strict turn-taking is the degenerate fallback, reachable via a one-line
  guard rather than a rewrite.

## Why barge-in is feasible here (not a minefield)

The usual blocker for "listen while speaking" is acoustic echo: TTS travels through open
air back into the mic and the recognizer transcribes its own voice. Earbuds fire TTS
directly into the ear canal (little leakage), and iOS AEC (`inputNode.setVoiceProcessingEnabled(true)`
on `AVAudioEngine`, iOS 13+; also engaged by the `.voiceChat` session mode) subtracts the
known TTS output from the mic input. Earbuds + AEC together make continuous listening
during playback reliable.

Cost of the interrupt capability vs. strict turn-taking — plumbing, concentrated in two spots:

1. **Keeping recognition alive.** On-device `SFSpeechRecognizer` requests have a finite
   lifetime (~1 minute), so the recognition request is restarted periodically / on
   finalization. The `Listener` hides this from the rest of the app.
2. **Suppressing self-triggers.** Even with AEC, occasionally ignore a result that is just
   leaked TTS. Cheap mitigations: bias the recognizer to the tiny vocabulary with
   `contextualStrings`, and/or ignore matches whose text equals the word-pair currently
   being spoken.

## Stack

| Concern        | Choice |
|----------------|--------|
| App            | Native iOS / Swift (SwiftUI UI), run on own device via free dev account |
| TTS            | `AVSpeechSynthesizer` |
| Speech-to-text | `SFSpeechRecognizer`, `requiresOnDeviceRecognition = true`, biased with `contextualStrings` |
| Audio          | `AVAudioSession` category `.playAndRecord`, mode `.voiceChat`, option `.allowBluetooth` (engages AEC + AirPods mic) |
| Input data     | Plain text file of word-pairs (exported from the Evernote tool) |
| Output         | Local text file of "yes" pairs; reconcile to Evernote afterward |

All first-party frameworks — no third-party libraries required.

## Component shape

- **`PairStore`** — loads the textfile into an ordered list, tracks current index, appends
  accepted pairs to the output file (write-through, so a crash mid-session loses nothing).
  Knows nothing about audio.
- **`Speaker`** — wraps `AVSpeechSynthesizer`; `speak(pair)`, `stop()`, and a "did finish"
  callback. Rate is adjustable (faster/slower commands map to `AVSpeechUtterance.rate`).
- **`Listener`** — owns the always-on `AVAudioEngine` + `SFSpeechRecognizer`. Emits a single
  enum stream of recognized intents: `.accept`, `.stop`, `.continue`, `.repeat`, `.back`,
  `.faster`, `.slower`. Handles the periodic recognition-request restart internally so the
  rest of the app never sees it.
- **`SessionController`** — the state machine that wires the three together. Barge-in lives
  here: on any intent from `Listener`, stop the current utterance if needed and act.

## The loop

```
SessionController state: .speaking(pair) | .awaiting | .paused

Listener runs continuously the whole time.

on enter .speaking(pair):  Speaker.speak(pair)
Speaker "finished"      →  go .awaiting (brief window, then advance)
Listener emits intent   →  Speaker.stop() if speaking; dispatch:
    .accept   → PairStore.accept(current); advance; speak next
    .repeat   → speak current again
    .back     → PairStore.index -= 1; speak
    .faster   → rate += step; (optionally) repeat current
    .slower   → rate -= step
    .stop     → .paused (Listener stays on, only .continue/.stop act)
    .continue → resume → speak current
```

Because the recognizer is always on, "interrupt while it's still talking" and "answer
after it finishes" are the same code path. If AEC ever misbehaves on the AirPods, neuter
barge-in by ignoring intents while `.speaking` — a one-line guard.

## Build sequence (de-risk the audio first)

1. **Audio spike, day one.** Throwaway screen: continuously recognize speech while looping
   TTS through the AirPods, log every transcription. Answers the one question that matters —
   *does AEC keep the TTS out of the recognizer well enough?* — before building anything real.
2. Wire `PairStore` + file load/save with a button-driven (no-voice) UI to prove the data flow.
3. Add `Speaker` and the speak→advance loop, manual "next" button.
4. Replace the button with `Listener` intents; implement the full command set
   (stop / continue / repeat / back / faster / slower + yes/good).
5. Polish: in-ear pause/resume via AirPods detection, a visible current-pair + accepted-count
   UI, session resume after relaunch.

## Open defaults (sensible now, revisit later)

- **On silence in the listening window:** stay and wait — never auto-accept, never auto-skip.
- **faster/slower:** re-speak the current pair so the new rate is audible.

## Command vocabulary

`yes` / `good` → accept · `stop` · `continue` · `repeat` · `back` · `faster` · `slower`
