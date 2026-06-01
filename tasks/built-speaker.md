# Phase 3: speak each pair aloud

Commit `aa04c7c` on branch `speaker`. Step 3 done and building for iOS.

## What I built

The classifier now reads each pair aloud; deciding is the speak→advance loop,
exactly as the plan describes.

**`Speaker.swift`** — replaced the throwaway phrase-looper with the real
per-line speaker:
- `speak(_ line:)` (interrupts any in-flight utterance so a new pair never
  queues behind a stale one), `stop()`, published `isSpeaking`, and an
  adjustable `rate` left at default as the step-4 faster/slower seam.
- A `currentUtterance` identity guard so a late `didFinish` from an interrupted
  utterance can't clear `isSpeaking` for its replacement.
- Keeps `usesApplicationAudioSession = true` — no session config here; that
  arrives with the `Listener` in step 4.

**`PairClassifierView.swift`** — TTS layered additively over the working
Phase-2 UI:
- Speaks `store.current` on appear and after every `accept()`/`skip()`/`back()`;
  stops at end-of-list and on disappear.
- Speaking indicator (`speaker.wave.2.fill`) on the card, plus tap-the-pair-to-
  replay with a hint caption.
- No "Next" button — advancing by deciding *is* the loop, as the plan notes.

**`AudioSpikeView.swift`** — moved the old looping logic into a self-contained,
fileprivate `SpikeSpeaker` so the Phase-1 AEC spike tab keeps working without
coupling to the real `Speaker`.

What's deliberately deferred to step 4 (per plan): no speech
recognition/intents, no `onFinish` hook (no consumer yet), no
`.playAndRecord`/AEC session, no faster/slower wiring.

## Verification
Built for the iOS Simulator (passes), but the plan's actual step-3 check —
*hearing* each pair through BT earbuds, with Accept/Skip speaking the next pair
and Back re-speaking the prior — requires a ⌘R run on the physical device,
since the simulator can't exercise BT audio routing.
