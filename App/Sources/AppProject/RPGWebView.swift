import SwiftUI
import WebKit

struct RPGWebView: UIViewRepresentable {
    let gamePath: URL
    @Binding var isLoading: Bool
    let onWebViewCreated: ((WKWebView) -> Void)?

    init(gamePath: URL, isLoading: Binding<Bool> = .constant(false), onWebViewCreated: ((WKWebView) -> Void)? = nil) {
        self.gamePath = gamePath
        self._isLoading = isLoading
        self.onWebViewCreated = onWebViewCreated
    }

    init(folderURL: URL, onWebViewCreated: ((WKWebView) -> Void)? = nil) {
        self.gamePath = folderURL
        self._isLoading = .constant(false)
        self.onWebViewCreated = onWebViewCreated
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        contentController.add(context.coordinator, name: "bridgeReady")
        contentController.add(context.coordinator, name: "debugLog")
        contentController.add(context.coordinator, name: "saveData")

        let bridgeScript = WKUserScript(
            source: RPGWebView.bridgeJavaScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(bridgeScript)

        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        let indexURL = gamePath.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            webView.loadFileURL(indexURL, allowingReadAccessTo: gamePath)
            context.coordinator.log("✅ 加载 index.html")
        } else {
            context.coordinator.log("❌ index.html 不存在")
        }

        DispatchQueue.main.async {
            self.onWebViewCreated?(webView)
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(gamePath: gamePath)
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let gamePath: URL
        let saveDir: URL
        private let logFileURL: URL
        private weak var webView: WKWebView?

        init(gamePath: URL) {
            self.gamePath = gamePath
            self.saveDir = gamePath.appendingPathComponent("save")
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.logFileURL = docs.appendingPathComponent("bridge_log.txt")
            super.init()
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            log("===== Bridge 初始化 =====")
            log("游戏路径: \(gamePath.path)")
            log("存档目录: \(saveDir.path)")
        }

        func log(_ message: String) {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
            let line = "[\(timestamp)] \(message)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logFileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: logFileURL) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: logFileURL)
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "bridgeReady":
                log("📨 \(message.body)")
            case "debugLog":
                log("🐛 \(message.body)")
            case "saveData":
                handleSaveData(message: message)
            default:
                log("⚠️ 未知消息: \(message.name)")
            }
        }

        // MARK: - 接收保存数据
        private func handleSaveData(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let fileId = dict["fileId"] as? Int,
                  let dataString = dict["data"] as? String else {
                log("⚠️ 保存数据格式错误")
                return
            }
            
            let fileName = "file\(fileId).rpgsave"
            let fileURL = saveDir.appendingPathComponent(fileName)
            
            log("💾 收到保存数据: file\(fileId), 长度: \(dataString.count)")
            
            if dataString.count > 100 {
                do {
                    try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
                    log("✅ 保存成功: \(fileName)")
                } catch {
                    log("❌ 保存失败: \(error)")
                }
            } else {
                log("⚠️ 数据过小 (\(dataString.count) 字节)")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            log("🌐 页面加载完成")

            let script = RPGWebView.bridgeJavaScript()
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    self.log("❌ 注入失败: \(error)")
                } else {
                    self.log("✅ 桥接注入成功")
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log("❌ 导航失败: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            log("❌ 临时加载失败: \(error)")
        }
    }

    // MARK: - JavaScript 桥接
    private static func bridgeJavaScript() -> String {
        return """
        (function() {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始');
            }

            if (typeof StorageManager !== 'undefined') {
                var originalSave = StorageManager.save;
                StorageManager.save = function(savefile) {
                    var result = originalSave.call(this, savefile);
                    var fileId = savefile.savefileId || savefile.id || 1;
                    
                    setTimeout(function() {
                        try {
                            var key = 'RPG File' + fileId;
                            var data = localStorage.getItem(key);
                            if (data && data.length > 100) {
                                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveData) {
                                    window.webkit.messageHandlers.saveData.postMessage({
                                        fileId: fileId,
                                        data: data
                                    });
                                    console.log('📤 存档已备份，长度: ' + data.length);
                                }
                            }
                        } catch(e) {
                            console.error('备份失败:', e);
                        }
                    }, 300);
                    
                    return result;
                };
            }

            console.log('✅ 桥接注入完成');
        })();
        """
    }
}
