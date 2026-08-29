import Foundation

/// HLSファイルの保存先を抽象化するプロトコル。
///
/// PublisherはHTTPの詳細を知らずに公開順だけを担当でき、テストではインメモリ実装へ差し替えられる。
protocol HLSClient: Sendable {
    var viewerURL: URL { get }

    func healthCheck() async throws
    func playlistURL(streamId: String) -> URL
    func putInitSegment(streamId: String, data: Data) async throws
    func putMediaSegment(streamId: String, seq: Int, data: Data) async throws
    func putPlaylist(streamId: String, text: String) async throws
}

/// サーバーURLまたはHTTPレスポンスが期待する形式でない場合のエラー。
enum HTTPHLSClientError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "サーバーURLが正しくありません"
        case .invalidResponse:
            return "サーバーからHTTPレスポンスを受信できませんでした"
        case let .httpStatus(statusCode):
            return "サーバーがHTTP \(statusCode)を返しました"
        }
    }
}

/// `init.mp4`、`.m4s`、`playlist.m3u8` をHTTP PUTで保存するClient。
///
/// サーバーは映像変換を行わない。iPhoneが完成させたHLSファイルを、そのまま静的配信できるパスへ置く。
struct HTTPHLSClient: HLSClient {
    let viewerURL: URL

    private let session: URLSession

    /// `/streams/...` を追加できるよう、baseURLをschemeとhostだけの形へ正規化する。
    init(baseURL: URL, session: URLSession = .shared) throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.path.isEmpty || components.path == "/" else {
            throw HTTPHLSClientError.invalidServerURL
        }

        components.path = ""
        components.query = nil
        components.fragment = nil

        guard let normalizedURL = components.url else {
            throw HTTPHLSClientError.invalidServerURL
        }

        viewerURL = normalizedURL
        self.session = session
    }

    /// 配信開始前にサーバーへの到達性を短いtimeoutで確認する。
    func healthCheck() async throws {
        var request = URLRequest(url: endpoint("health"))
        request.timeoutInterval = 5
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func playlistURL(streamId: String) -> URL {
        streamEndpoint(streamId: streamId).appendingPathComponent("playlist.m3u8")
    }

    /// `EXT-X-MAP` が参照する初期化segmentを保存する。
    func putInitSegment(streamId: String, data: Data) async throws {
        try await put(
            data,
            to: streamEndpoint(streamId: streamId).appendingPathComponent("init.mp4"),
            contentType: "video/mp4"
        )
    }

    /// sequenceと同じ6桁ファイル名でmedia segmentを保存する。
    func putMediaSegment(streamId: String, seq: Int, data: Data) async throws {
        let url = streamEndpoint(streamId: streamId)
            .appendingPathComponent("seg", isDirectory: true)
            .appendingPathComponent("\(HLSManifest.paddedSequence(seq)).m4s")
        try await put(data, to: url, contentType: "video/mp4")
    }

    /// ViewerがpollingするplaylistをMPEG URLのContent-Typeで保存する。
    func putPlaylist(streamId: String, text: String) async throws {
        try await put(
            Data(text.utf8),
            to: playlistURL(streamId: streamId),
            contentType: "application/vnd.apple.mpegurl"
        )
    }

    /// 全PUTに共通するHTTPリクエスト生成と2xx検証。
    private func put(_ data: Data, to url: URL, contentType: String) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.timeoutInterval = 15
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    private func streamEndpoint(streamId: String) -> URL {
        endpoint("streams").appendingPathComponent(streamId, isDirectory: true)
    }

    private func endpoint(_ pathComponent: String) -> URL {
        viewerURL.appendingPathComponent(pathComponent)
    }

    private func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPHLSClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw HTTPHLSClientError.httpStatus(httpResponse.statusCode)
        }
    }
}
