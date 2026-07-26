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
            case "saveGameFile":
                handleSave(message: message)
            case "loadGameFile":
                handleLoad(message: message)
            case "bridgeReady":
                log("📨 \(message.body)")
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

        // 同步存档到 localStorage（启动时调用）
        private func syncArchivesToLocalStorage(webView: WKWebView) {
            log("🔄 开始同步存档到 localStorage")
            guard let files = try? FileManager.default.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil) else {
                log("⚠️ 无法读取存档目录")
                return
            }
            var jsScripts: [String] = []
            for fileURL in files where fileURL.pathExtension == "rpgsave" {
                let fileName = fileURL.lastPathComponent
                // 提取 fileId
                let fileIdStr = fileName.replacingOccurrences(of: "file", with: "").replacingOccurrences(of: ".rpgsave", with: "")
                guard let fileId = Int(fileIdStr) else { continue }
                do {
                    let data = try String(contentsOf: fileURL, encoding: .utf8)
                    // 转义 JSON 字符串中的单引号
                    let escapedData = data.replacingOccurrences(of: "'", with: "\\'")
                    let js = "localStorage.setItem('RPG File\(fileId)', '\(escapedData)');"
                    jsScripts.append(js)
                    log("📥 同步存档 ID \(fileId) 长度 \(data.count)")
                } catch {
                    log("❌ 读取存档文件失败: \(fileURL.lastPathComponent)")
                }
            }
            if !jsScripts.isEmpty {
                let combinedScript = jsScripts.joined(separator: " ")
                webView.evaluateJavaScript(combinedScript) { _, error in
                    if let error = error {
                        self.log("❌ 同步存档到 localStorage 失败: \(error)")
                    } else {
                        self.log("✅ 同步存档到 localStorage 成功")
                    }
                }
            } else {
                log("⚠️ 没有找到存档文件")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            log("🌐 页面加载完成")

            // 重新注入桥接（确保覆盖）
            let script = RPGWebView.bridgeJavaScript()
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    self.log("❌ 重新注入失败: \(error)")
                } else {
                    self.log("✅ 重新注入成功")
                }
            }

            // 延迟同步存档（等待游戏完全初始化）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.syncArchivesToLocalStorage(webView: webView)
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

            var originalSave = StorageManager.save;

            StorageManager.save = function(savefile) {
                var result = originalSave.call(this, savefile);
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

            // 保持 load 原始不变，游戏从 localStorage 读取

            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('✅ StorageManager.save 已覆盖');
            }
            console.log('✅ 桥接注入完成（仅保存拦截）');
        })();
        """
    }
}
