import SwiftUI

/// App root. The Files tab is the Phase 2 process-once queue; the Audio Spike tab
/// keeps the Phase 1 AEC test reachable on-device.
struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack {
                FileListView()
            }
            .tabItem { Label("Files", systemImage: "tray.full") }

            AudioSpikeView()
                .tabItem { Label("Audio Spike", systemImage: "waveform") }
        }
    }
}

#Preview {
    ContentView()
}
