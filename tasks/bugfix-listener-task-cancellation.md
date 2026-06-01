# Listener goes deaf after Stop → Start

## Symptom

Recognition worked on first run (and worked with TTS looping simultaneously),
but after tapping **Stop Listening** and then **Start Listening** again, the
listener transcribed nothing. No error was surfaced in the UI.

## Root cause

In `Listener.stop()`, `teardown()` calls `task?.cancel()`. Cancelling an
`SFSpeechRecognitionTask` fires its completion handler **with an error**. The old
handler reinstalled recognition on *any* error:

```swift
if error != nil { self.installRecognition() }
```

That reinstall ran *after* teardown had already nilled the request/task and
stopped the engine, so it resurrected a brand-new request + task and re-installed
a tap on the now-stopped engine. On the next **Start**, a fresh task was created,
but the zombie task from the cancel was still alive. The on-device recognizer
serves **one** task at a time, so the new task got starved → silence.

Two contributing leaks made it worse over time:

- The 50s `restartTimer` and the `isFinal` branch both called
  `installRecognition()` without retiring the previous task/request, so tasks
  piled up across a long session.
- Re-enabling voice processing (`setVoiceProcessingEnabled(true)`) on every Start
  was unnecessary and resets the AEC unit.

## Fix

All in `mc/Listener.swift`:

1. **Ignore stale callbacks.** The recognition completion handler now bails when
   the listener has stopped or the task has been superseded:
   ```swift
   guard self.isRunning, gen == self.generation else { return }
   ```

2. **Generation token.** `installRecognition()` bumps a `generation` counter and
   captures it; a superseded task's late callback no longer triggers a
   replacement (which previously cascaded, or after `stop()` left a zombie).

3. **Retire the prior task/request first.** `installRecognition()` now calls
   `task?.cancel()` / `request?.endAudio()` before creating the new ones, so the
   timer/`isFinal`/error reinstall paths can't leak overlapping tasks.

4. **Don't re-toggle AEC.** Voice processing is only enabled when not already on:
   ```swift
   if !engine.inputNode.isVoiceProcessingEnabled {
       try engine.inputNode.setVoiceProcessingEnabled(true)
   }
   ```

## Verification

Builds clean for the iOS Simulator SDK. Behavior must be confirmed on a physical
device (the simulator has no AEC/mic path):

1. Start → say "yes"/"stop" → confirms transcription.
2. Stop → Start → say the words again → should transcribe immediately.
3. Repeat the Stop/Start cycle 3–4 times — the old leaks degraded progressively,
   so repeated cycles are the real proof.

## If still deaf after restart

Next suspect is the audio-session `setActive(false)` in `teardown()` colliding
with the re-`setActive(true)` in `start()`. Try leaving the session active across
stop/start instead of deactivating it.
