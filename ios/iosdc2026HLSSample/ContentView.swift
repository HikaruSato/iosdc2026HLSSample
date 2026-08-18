import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hlsServerBaseURL") private var serverURLText = ""
    @State private var vm = SampleStreamViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    serverSection
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
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Mac HTTP Server", systemImage: "server.rack")
                    .font(.headline)

                Spacer()

                Label(vm.serverStateText, systemImage: vm.serverStateSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(serverStateColor)
            }

            TextField("http://192.168.x.x:8080", text: $serverURLText)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .disabled(vm.isRecording)

            Button {
                Task {
                    await vm.checkServer(serverURLText: serverURLText)
                }
            } label: {
                Label("接続確認", systemImage: "network")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(serverURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isRecording)

            if let serverErrorMessage = vm.serverErrorMessage {
                Text(serverErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
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
                            await vm.startRecording(serverURLText: serverURLText)
                        }
                    }
                } label: {
                    Label(
                        vm.isRecording ? "停止" : "配信開始",
                        systemImage: vm.isRecording ? "stop.fill" : "record.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(vm.isRecording ? .red : .blue)
                .disabled(!vm.canToggleRecording || serverURLText.isEmpty)

                if let viewerURL = vm.viewerURL {
                    ShareLink(item: viewerURL) {
                        Label("Viewer", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

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
            Text("配信")
                .font(.headline)

            LabeledContent("経過秒数") {
                Text(vm.elapsedText)
                    .monospacedDigit()
            }

            LabeledContent("segment") {
                Text("\(vm.segmentCount)")
                    .monospacedDigit()
            }

            LabeledContent("pending upload") {
                Text("\(vm.pendingUploadCount)")
                    .monospacedDigit()
            }

            if let streamId = vm.streamId {
                LabeledContent("streamId") {
                    Text(streamId)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            if let viewerURL = vm.viewerURL {
                urlText("Viewer", url: viewerURL)
            }

            if let playlistURL = vm.playlistURL {
                urlText("playlist", url: playlistURL)
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
                Text(vm.playlistText.isEmpty ? "最初のsegment upload後にplaylistが表示されます" : vm.playlistText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var serverStateColor: Color {
        switch vm.serverState {
        case .unchecked:
            return .secondary
        case .checking:
            return .orange
        case .connected:
            return .green
        case .error:
            return .red
        }
    }

    private func urlText(_ label: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(url.absoluteString)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}
