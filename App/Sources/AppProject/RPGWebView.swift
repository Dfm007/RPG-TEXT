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

        // 注册所有消息处理器
        contentController.add(context.coordinator, name: "saveGameFile")
        contentController.add(context.coordinator, name: "loadGameFile")
        contentController.add(context.coordinator, name: "bridgeReady")

        // 注入初始桥接（页面加载前）
        let bridgeScript = WKUserScript(
            source: getBridgeJavaScript(),
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
            context.coordinator.log("✅ 加载 index.html: \(indexURL.path)")
        } else {
            context.coordinator.log("❌ 未找到 index.html")
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
            case "saveGameFile":
                handleSave(message: message)
            case "loadGameFile":
                handleLoad(message: message)
            case "bridgeReady":
                log("📨 Bridge 状态: \(message.body)")
            default:
                log("⚠️ 未知消息: \(message.name)")
            }
        }

        private func handleSave(message: WKScriptMessage) {
            log("📩 收到 saveGameFile")
            guard let dict = message.body as? [String: Any],
                  let fileName = dict["fileName"] as? String,
                  let dataString = dict["data"] as? String else {
                log("⚠️ 格式错误: \(message.body)")
                return
            }
            log("📄 文件名: \(fileName), 数据长度: \(dataString.count)")
            let fileURL = saveDir.appendingPathComponent(fileName)
            do {
                try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
                log("✅ 写入成功: \(fileURL.lastPathComponent)")
            } catch {
                log("❌ 写入失败: \(error)")
            }
        }

        private func handleLoad(message: WKScriptMessage) {
            // 预留
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            log("🌐 页面加载完成")
            // 关键：再次注入桥接，确保覆盖（可能游戏脚本晚于我们的注入加载）
            let reinjectScript = getBridgeJavaScript()
            webView.evaluateJavaScript(reinjectScript) { _, error in
                if let error = error {
                    self.log("❌ 重新注入失败: \(error)")
                } else {
                    self.log("✅ 重新注入桥接成功")
                }
            }

            // 延迟1秒再次确认（有些游戏脚本加载更晚）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                webView.evaluateJavaScript(reinjectScript) { _, error in
                    if let error = error {
                        self.log("❌ 延迟注入失败: \(error)")
                    } else {
                        self.log("✅ 延迟注入桥接成功")
                    }
                }
                // 发送检测脚本，确认 StorageManager.save 是否已覆盖
                let checkScript = """
                (function() {
                    var status = '未覆盖';
                    if (typeof StorageManager !== 'undefined' && StorageManager.save) {
                        status = '已覆盖';
                    }
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                        window.webkit.messageHandlers.bridgeReady.postMessage('StorageManager 状态: ' + status);
                    }
                })();
                """
                webView.evaluateJavaScript(checkScript, completionHandler: nil)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log("❌ 导航失败: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            log("❌ 临时加载失败: \(error)")
        }
    }

    // MARK: - 桥接 JavaScript
    private func getBridgeJavaScript() -> String {
        return """
        (function() {
            // 通知 Native 脚本执行
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始');
            }

            if (typeof StorageManager === 'undefined') {
                console.warn('StorageManager not found, bridge may not work.');
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                    window.webkit.messageHandlers.bridgeReady.postMessage('StorageManager 未定义');
                }
                // 即使 StorageManager 未定义，也尝试保存原始引用（如果以后定义）
                // 但我们没法重写，只能等待再次注入。
                return;
            }

            // 保存原始方法
            var originalSave = StorageManager.save;

            // 重写 save
            StorageManager.save = function(savefile) {
                var fileId = savefile.savefileId || 1;
                var fileName = 'file' + fileId + '.rpgsave';
                var data = JSON.stringify(savefile);

                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveGameFile) {
                    try {
                        window.webkit.messageHandlers.saveGameFile.postMessage({
                            fileName: fileName,
                            data: data
                        });
                        console.log('📤 存档已发送到 Native：' + fileName);
                    } catch (e) {
                        console.error('发送存档失败:', e);
                    }
                } else {
                    console.warn('Native bridge not available');
                }

                // 仍然调用原始方法
                return originalSave.call(this, savefile);
            };

            // 通知 Native 桥接成功
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('✅ StorageManager.save 已覆盖');
            }
            console.log('✅ RPG Maker 文件桥接已注入');
        })();
        """
    }
}
