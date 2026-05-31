# Mobile Classifier Tool — Technology Stack Design

## Technology Stack Recommendation

### Platform: React Native (Expo)

- Single codebase for iOS, handles audio/mic/BT well
- `expo-speech` for TTS (built-in iOS voices, no external dep needed)
- `expo-av` for audio session management + mic input

### Voice Recognition

This is the trickiest piece. Options:

1. **`@react-native-voice/voice`** — wraps iOS's native `SFSpeechRecognizer`, best offline support, recognizes short commands well ("yes", "stop", "back", etc.)
2. **Whisper via API** — more accurate but requires network; overkill here

Recommendation: option 1. iOS native speech recognition handles short keyword commands very well and works without network.

### Bluetooth Audio

Transparent — iOS routes TTS + audio automatically to whatever BT device is connected. No special Bluetooth library needed. Just ensure the `AVAudioSession` category is set correctly (Expo handles this).

### Storage

- Start with local JSON file (AsyncStorage or plain file via `expo-file-system`)
- Evernote integration is addable later but skip it initially — the checkbox-API approach requires OAuth and the Evernote SDK, which is non-trivial

### Summary

| Concern | Choice |
|---|---|
| Framework | Expo (React Native) |
| TTS | `expo-speech` |
| Voice input | `@react-native-voice/voice` |
| Storage | `expo-file-system` (JSON) |
| Evernote (optional) | Evernote JS SDK later |

## Supported Voice Commands

- `yes` / `good` — classify current pair as positive
- `stop` — pause
- `continue` — resume
- `repeat` — re-read current pair
- `back` — go to previous pair
- `faster` / `slower` — adjust playback interval

## Key Risk

`@react-native-voice/voice` requires a native build (not Expo Go), so `expo prebuild` + TestFlight or direct device install via Xcode is needed. Everything else works in managed Expo.
