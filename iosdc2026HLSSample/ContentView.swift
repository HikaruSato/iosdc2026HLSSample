import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm = SampleStreamViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    cameraSection
                    controlsSection
                    outputSection
                    playlistSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .navigationTitle("iOSDC HLS Sample")
            .task {
                await vm.onAppear()
            }
            .onChange(of: scenePhase, initial: false) { _, newPhase in
                if newPhase == .background {
                    Task {
                        await vm.stopIfNeeded()
                    }
                }
            }
            .sheet(isPresented: $vm.isShowingPlayer) {
                if let playbackURL = vm.playbackURL {
                    LocalHLSPlayerView(playlistURL: playbackURL)
                }
            }
            .sheet(isPresented: $vm.isShowingWebPreview) {
                if let webPreviewURL = vm.webPreviewURL,
                   let outputDirectoryURL = vm.outputDirectoryURL {
                    LocalHLSWebPreview(
                        htmlURL: webPreviewURL,
                        allowingReadAccessTo: outputDirectoryURL
                    )
                }
            }
        }
    }

    private var cameraSection: some View {
        ZStack(alignment: .topLeading) {
            CameraPreviewView(session: vm.captureSession)
                .frame(height: 420)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(uiColor: .separator), lineWidth: 1)
                }

            statusBadge
                .padding(10)
        }
    }

    private var statusBadge: some View {
        Label(vm.stateText, systemImage: vm.stateSystemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.68), in: Capsule())
            .foregroundStyle(.white)
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    Task {
                        if vm.isRecording {
                            await vm.stopRecording()
                        } else {
                            await vm.startRecording()
                        }
                    }
                } label: {
                    Label(
                        vm.isRecording ? "停止" : "録画開始",
                        systemImage: vm.isRecording ? "stop.fill" : "record.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(vm.isRecording ? .red : .blue)
                .disabled(!vm.canToggleRecording)

                Button {
                    vm.isShowingPlayer = true
                } label: {
                    Label("AVPlayer", systemImage: "play.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(vm.playbackURL == nil || vm.isRecording)
            }

            Button {
                vm.isShowingWebPreview = true
            } label: {
                Label("WebView", systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(vm.webPreviewURL == nil || vm.isRecording)

            if let errorMessage = vm.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("出力")
                .font(.headline)

            LabeledContent("経過秒数") {
                Text(vm.elapsedText)
                    .monospacedDigit()
            }

            LabeledContent("segment") {
                Text("\(vm.segmentCount)")
                    .monospacedDigit()
            }

            if let streamId = vm.streamId {
                LabeledContent("streamId") {
                    Text(streamId)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            if let outputDirectoryText = vm.outputDirectoryText {
                Text(outputDirectoryText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(nil)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("playlist.m3u8")
                .font(.headline)

            ScrollView(.horizontal) {
                Text(vm.playlistText.isEmpty ? "録画開始後にplaylistが表示されます" : vm.playlistText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
