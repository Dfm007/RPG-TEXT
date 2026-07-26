import SwiftUI
import WebKit

struct RPGWebView: UIViewRepresentable {
    let folderURL: URL
    // 新增：暴露 webView 的回调
    var onWebViewCreated: ((WKWebView) -> Void)?
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.isOpaque = false
        
        // 暴露 webView
        onWebViewCreated?(webView)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        let indexURL = folderURL.appendingPathComponent("index.html")
        uiView.loadFileURL(indexURL, allowingReadAccessTo: folderURL)
    }
}
