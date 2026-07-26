import SwiftUI
import WebKit

struct RPGWebView: UIViewRepresentable {
    let folderURL: URL
    var configuration: WKWebViewConfiguration? = nil  // 可选自定义配置
    var onWebViewCreated: ((WKWebView) -> Void)?
    
    func makeUIView(context: Context) -> WKWebView {
        let config = configuration ?? WKWebViewConfiguration()
        // 基础设置（保留）
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.isOpaque = false
        
        onWebViewCreated?(webView)
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        let indexURL = folderURL.appendingPathComponent("index.html")
        uiView.loadFileURL(indexURL, allowingReadAccessTo: folderURL)
    }
}
