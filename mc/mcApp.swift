//
//  mcApp.swift
//  mc
//
//  Created by Michael McQueen on 5/31/26.
//

import SwiftUI

@main
struct mcApp: App {
    init() {
        // No engine-selection UI yet (that arrives with the voice-chooser Settings tab),
        // so default the TTS engine to Kokoro here. `register(defaults:)` only sets the
        // fallback value, so a launch argument (`-ttsEngine system`) or a future Settings
        // toggle still overrides it, and nothing is persisted to the user's plist.
        // On simulator / a build without the bundled model, `Speaker` falls back to the
        // system voice regardless.
        UserDefaults.standard.register(defaults: [
            "ttsEngine": "kokoro",
            "kokoroVoice": "af_jessica",
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
