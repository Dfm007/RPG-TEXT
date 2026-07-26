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

        contentController.add(context.coordinator, name: "saveGameFile")
        contentController.add(context.coordinator, name: "loadGameFile")
        contentController.add(context.coordinator, name: "bridgeReady")
        contentController.add(context.coordinator, name: "localStorageReport")

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
                log("📨 \(message.body)")
            case "localStorageReport":
                log("📦 \(message.body)")
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
            log("📥 \(message.body)")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            log("🌐 页面加载完成")
            let script = RPGWebView.bridgeJavaScript()
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    self.log("❌ 重新注入失败: \(error)")
                } else {
                    self.log("✅ 重新注入成功")
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                webView.evaluateJavaScript(script) { _, error in
                    if let error = error {
                        self.log("❌ 延迟注入失败: \(error)")
                    } else {
                        self.log("✅ 延迟注入成功")
                    }
                }
                let checkScript = """
                (function() {
                    var status = '未定义';
                    if (typeof StorageManager !== 'undefined') {
                        status = '已定义，save方法' + (StorageManager.save ? '已覆盖' : '未覆盖');
                        status += ', load方法' + (StorageManager.load ? '已覆盖' : '未覆盖');
                    }
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                        window.webkit.messageHandlers.bridgeReady.postMessage('StorageManager: ' + status);
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

    // MARK: - Static JavaScript
    private static func bridgeJavaScript() -> String {
        return """
        (function() {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始');
            }

            if (typeof StorageManager === 'undefined') {
                console.warn('StorageManager not found');
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                    window.webkit.messageHandlers.bridgeReady.postMessage('StorageManager 未定义');
                }
                return;
            }

            // 保存原始方法
            var originalSave = StorageManager.save;
            var originalLoad = StorageManager.load;

            // 重写 save
            StorageManager.save = function(savefile) {
                // 先调用原始方法，更新 localStorage
                var result = originalSave.call(this, savefile);

                // 从 localStorage 中获取实际存档数据
                var fileId = savefile.savefileId || 1;
                var storageKey = "RPG File" + fileId;   // RPG Maker 使用的 key
                var data = localStorage.getItem(storageKey);
                if (data) {
                    var fileName = 'file' + fileId + '.rpgsave';
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveGameFile) {
                        try {
                            window.webkit.messageHandlers.saveGameFile.postMessage({
                                fileName: fileName,
                                data: data
                            });
                            console.log('📤 存档已发送到 Native：' + fileName + ' 长度: ' + data.length);
                        } catch (e) {
                            console.error('发送存档失败:', e);
                        }
                    }
                } else {
                    // 如果 localStorage 中没有，可能使用其他 key，尝试从 savefile 对象获取
                    console.warn('localStorage 中没有 key: ' + storageKey);
                    // 可选：尝试将 savefile 对象序列化（但可能不完整）
                    var fallbackData = JSON.stringify(savefile);
                    if (fallbackData && fallbackData !== '{}') {
                        var fileName = 'file' + fileId + '.rpgsave';
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveGameFile) {
                            window.webkit.messageHandlers.saveGameFile.postMessage({
                                fileName: fileName,
                                data: fallbackData
                            });
                        }
                    }
                }

                // 报告 localStorage 中的 keys（用于调试）
                try {
                    var keys = Object.keys(localStorage);
                    var report = 'localStorage keys: ' + keys.join(', ');
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.localStorageReport) {
                        window.webkit.messageHandlers.localStorageReport.postMessage(report);
                    }
                } catch (e) {}

                return result;
            };

            // 重写 load（仅用于日志，不影响游戏逻辑）
            StorageManager.load = function(savefileId) {
                var result = originalLoad.call(this, savefileId);
                var msg = '加载存档 ID: ' + savefileId + ', 结果: ' + (result ? '成功' : '失败');
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.loadGameFile) {
                    window.webkit.messageHandlers.loadGameFile.postMessage(msg);
                }
                return result;
            };

            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('✅ StorageManager.save 和 load 已覆盖');
            }
            console.log('✅ 桥接注入完成');
        })();
        """
    }
}
