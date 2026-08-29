import Foundation

protocol HLSClient: Sendable {
    var viewerURL: URL { get }

    func healthCheck() async throws
    func playlistURL(streamId: String) -> URL
    func putInitSegment(streamId: String, data: Data) async throws
    func putMediaSegment(streamId: String, seq: Int, data: Data) async throws
    func putPlaylist(streamId: String, text: String) async throws
}

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

struct HTTPHLSClient: HLSClient {
    let viewerURL: URL

    private let session: URLSession

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

    func healthCheck() async throws {
        var request = URLRequest(url: endpoint("health"))
        request.timeoutInterval = 5
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func playlistURL(streamId: String) -> URL {
        streamEndpoint(streamId: streamId).appendingPathComponent("playlist.m3u8")
    }

    func putInitSegment(streamId: String, data: Data) async throws {
        try await put(
            data,
            to: streamEndpoint(streamId: streamId).appendingPathComponent("init.mp4"),
            contentType: "video/mp4"
        )
    }

    func putMediaSegment(streamId: String, seq: Int, data: Data) async throws {
        let url = streamEndpoint(streamId: streamId)
            .appendingPathComponent("seg", isDirectory: true)
            .appendingPathComponent("\(HLSManifest.paddedSequence(seq)).m4s")
        try await put(data, to: url, contentType: "video/mp4")
    }

    func putPlaylist(streamId: String, text: String) async throws {
        try await put(
            Data(text.utf8),
            to: playlistURL(streamId: streamId),
            contentType: "application/vnd.apple.mpegurl"
        )
    }

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
