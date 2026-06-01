# Phase 4: voice commands + SessionController

Commit `29dbd16` on branch `listener`. Step 4 done and building for iOS.

## What I built

**`Listener` → intent stream** (kept the spike's hard parts intact):
- A word→`Intent` map (`yes`/`good`→accept, `no`/`skip`/`next`→skip, plus
  stop/continue/repeat/back/faster/slower) that doubles as the recognizer's
  bias vocabulary.
- Fires **once per utterance**: acts on partial results for low-latency
  barge-in, then restarts recognition so the same word can't re-fire.
- **Self-trigger suppression**: `setSpokenLine` excludes words from the line
  currently being spoken, so the TTS can't trip a command even if AEC leaks.
- The log/spike path stays alive (gated on `onIntent == nil`), so the Audio
  Spike tab is unaffected.

**`SessionController`** (new) — the `.speaking/.awaiting/.paused` state machine
wiring `PairStore` + `Speaker` + `Listener`:
- Voice and buttons funnel through one `dispatch(_:)` with **barge-in** (stop
  TTS before acting).
- Paused state only honors `continue`, so a stray "yes" can't sneak a decision
  in.
- Starts the recognizer (which configures the AEC session) *before* the first
  utterance.

**`Speaker`** gained the deferred `onFinish` callback and `faster()`/`slower()`.

**`PairClassifierView`** now drives the controller; buttons mirror every voice
command and it surfaces speaking/paused/voice-off state.

## On the skip command
Skip may later become automatic on silence. I added the `.skip` command now (a
deliberate deviation from the locked vocabulary — noted in the plan doc), and
structured `dispatch` so a future silence-timeout just calls `dispatch(.skip)`
from a timer. I also updated the plan's "Defaults" to reflect the planned
skip-on-silence direction.

## Verification
Builds for the iOS Simulator. The real test — barge-in, "yes/no" classifying,
stop/continue/repeat/back/faster/slower through BT earbuds — needs a ⌘R on the
device (the simulator can't do BT audio routing or reliable on-device
recognition). One pre-existing deprecation warning (`allowBluetooth` →
`allowBluetoothHFP`) sits in the spike's session config; left as-is since it
predates this work and is step-5 polish.
