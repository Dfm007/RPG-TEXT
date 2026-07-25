import SwiftUI
import WebKit

struct RPGWebView: UIViewRepresentable {
    let folderURL: URL
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        
        // ⭐ 关键：将 WebView 背景设为黑色
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.isOpaque = false  // 让背景色生效
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        let indexURL = folderURL.appendingPathComponent("index.html")
        uiView.loadFileURL(indexURL, allowingReadAccessTo: folderURL)
    }
}
