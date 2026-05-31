import SwiftUI

/// App root. Phase 2 adds the button-driven pair classifier; the Phase 1 audio
/// spike stays reachable on its own tab so it can still be run on-device to
/// validate AEC.
struct ContentView: View {
    var body: some View {
        TabView {
            PairClassifierView()
                .tabItem { Label("Classifier", systemImage: "checklist") }

            AudioSpikeView()
                .tabItem { Label("Audio Spike", systemImage: "waveform") }
        }
    }
}

#Preview {
    ContentView()
}
