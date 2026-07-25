import AVFoundation
import AVKit
import SwiftUI

struct LocalHLSPlayerView: View {
    private let playlistURL: URL
    @State private var player: AVPlayer

    init(playlistURL: URL) {
        self.playlistURL = playlistURL
        _player = State(initialValue: AVPlayer(url: playlistURL))
    }

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("AVPlayer")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            player.replaceCurrentItem(with: AVPlayerItem(url: playlistURL))
                            player.play()
                        } label: {
                            Label("Reload", systemImage: "arrow.clockwise")
                        }
                    }
                }
                .onAppear {
                    let audioSession = AVAudioSession.sharedInstance()
                    try? audioSession.setCategory(.playback)
                    try? audioSession.setActive(true)
                    player.play()
                }
                .onDisappear {
                    player.pause()
                }
        }
    }
}
