import Foundation
import Testing
@testable import iosdc2026HLSSample

@Suite(.serialized)
struct HTTPHLSClientTests {
    @Test func healthCheckUsesHealthEndpoint() async throws {
        URLProtocolStub.reset()
        let client = try makeClient()

        try await client.healthCheck()

        let request = try #require(URLProtocolStub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/health")
    }

    @Test func uploadsUseExpectedPathsMethodsAndContentTypes() async throws {
        URLProtocolStub.reset()
        let client = try makeClient()

        try await client.putInitSegment(streamId: "stream-1", data: Data([0x01]))
        try await client.putMediaSegment(streamId: "stream-1", seq: 7, data: Data([0x02]))
        try await client.putPlaylist(streamId: "stream-1", text: "#EXTM3U\n")

        let requests = URLProtocolStub.requests
        #expect(requests.map(\.httpMethod) == ["PUT", "PUT", "PUT"])
        #expect(requests.map { $0.url?.path } == [
            "/streams/stream-1/init.mp4",
            "/streams/stream-1/seg/000007.m4s",
            "/streams/stream-1/playlist.m3u8"
        ])
        #expect(requests.map { $0.value(forHTTPHeaderField: "Content-Type") } == [
            "video/mp4",
            "video/mp4",
            "application/vnd.apple.mpegurl"
        ])
    }

    @Test func nonSuccessfulStatusThrows() async throws {
        URLProtocolStub.reset(statusCode: 503)
        let client = try makeClient()

        do {
            try await client.healthCheck()
            Issue.record("HTTP 503 must throw")
        } catch let error as HTTPHLSClientError {
            guard case let .httpStatus(statusCode) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(statusCode == 503)
        }
    }

    private func makeClient() throws -> HTTPHLSClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return try HTTPHLSClient(
            baseURL: #require(URL(string: "http://192.168.1.10:8080")),
            session: URLSession(configuration: configuration)
        )
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var responseStatusCode = 200

    static var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    static func reset(statusCode: Int = 200) {
        lock.withLock {
            recordedRequests = []
            responseStatusCode = statusCode
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let statusCode = Self.lock.withLock {
            Self.recordedRequests.append(request)
            return Self.responseStatusCode
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
