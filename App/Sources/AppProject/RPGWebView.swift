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

            // 关键：加载完成后，将 save 文件夹中的所有存档注入到 localStorage
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.injectArchivesToLocalStorage(webView: webView)
            }
        }

        // 将 save/ 文件夹中的所有 .rpgsave 注入到 localStorage
        private func injectArchivesToLocalStorage(webView: WKWebView) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil) else {
                log("⚠️ 无法读取存档目录")
                return
            }
            for fileURL in files where fileURL.pathExtension == "rpgsave" {
                let fileName = fileURL.lastPathComponent
                // 提取 fileId（从 "fileX.rpgsave" 中提取 X）
                let baseName = (fileName as NSString).deletingPathExtension
                if baseName.hasPrefix("file") {
                    let fileId = String(baseName.dropFirst(4))
                    if let fileIdInt = Int(fileId) {
                        do {
                            let data = try String(contentsOf: fileURL, encoding: .utf8)
                            // 注入到 localStorage
                            let key = "RPG File\(fileIdInt)"
                            let script = "localStorage.setItem('\(key)', '\(data.replacingOccurrences(of: "'", with: "\\'")');"
                            webView.evaluateJavaScript(script) { _, error in
                                if let error = error {
                                    self.log("❌ 注入存档 \(fileName) 失败: \(error)")
                                } else {
                                    self.log("✅ 注入存档 \(fileName) 到 localStorage (key: \(key))")
                                }
                            }
                        } catch {
                            log("❌ 读取存档文件失败: \(fileName)")
                        }
                    }
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

            // 仅拦截 save，不修改 load
            var originalSave = StorageManager.save;
            StorageManager.save = function(savefile) {
                // 先调用原始方法，更新 localStorage
                var result = originalSave.call(this, savefile);

                // 从 localStorage 中获取实际存档数据
                var fileId = savefile.savefileId || 1;
                var storageKey = "RPG File" + fileId;
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
                    console.warn('localStorage 中没有 key: ' + storageKey);
                }

                return result;
            };

            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('✅ StorageManager.save 已覆盖（不拦截 load）');
            }
            console.log('✅ 桥接注入完成');
        })();
        """
    }
}
