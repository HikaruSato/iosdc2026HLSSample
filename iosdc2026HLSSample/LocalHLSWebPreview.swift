import SwiftUI
import WebKit

struct LocalHLSWebPreview: UIViewRepresentable {
    let htmlURL: URL
    let allowingReadAccessTo: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadFileURL(htmlURL, allowingReadAccessTo: allowingReadAccessTo)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadFileURL(htmlURL, allowingReadAccessTo: allowingReadAccessTo)
    }
}
