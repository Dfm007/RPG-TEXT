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
        contentController.add(context.coordinator, name: "preloadArchives") // 新增：预加载存档列表

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
            case "bridgeReady":
                log("📨 \(message.body)")
            case "preloadArchives":
                handlePreloadArchives(message: message)
            default:
                log("⚠️ 未知消息: \(message.name)")
            }
        }

        // MARK: - 保存存档
        private func handleSave(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let fileId = dict["fileId"] as? Int,
                  let dataString = dict["data"] as? String else {
                log("⚠️ 保存消息格式错误: \(message.body)")
                return
            }
            
            let fileName = "file\(fileId).rpgsave"
            let fileURL = saveDir.appendingPathComponent(fileName)
            
            log("📝 保存存档 ID: \(fileId), 数据长度: \(dataString.count)")
            do {
                try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
                log("✅ 写入成功: \(fileName)")
            } catch {
                log("❌ 写入失败: \(error)")
            }
        }

        // MARK: - 预加载存档到 localStorage
        private func handlePreloadArchives(message: WKScriptMessage) {
            log("📦 预加载存档到 localStorage")
            
            guard let webView = webView else {
                log("❌ webView 不可用")
                return
            }
            
            do {
                let files = try FileManager.default.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil)
                var loadedCount = 0
                var jsScripts: [String] = []
                
                for fileURL in files {
                    let fileName = fileURL.lastPathComponent
                    if fileName.hasPrefix("file") && fileName.hasSuffix(".rpgsave") {
                        // 提取 fileId
                        let fileIdStr = fileName.replacingOccurrences(of: "file", with: "").replacingOccurrences(of: ".rpgsave", with: "")
                        if let fileId = Int(fileIdStr) {
                            do {
                                let data = try String(contentsOf: fileURL, encoding: .utf8)
                                // 转义特殊字符
                                let escapedData = data.replacingOccurrences(of: "\\", with: "\\\\")
                                                         .replacingOccurrences(of: "'", with: "\\'")
                                                         .replacingOccurrences(of: "\n", with: "\\n")
                                                         .replacingOccurrences(of: "\r", with: "\\r")
                                
                                let key = "RPG File\(fileId)"
                                let script = "localStorage.setItem('\(key)', '\(escapedData)');"
                                jsScripts.append(script)
                                loadedCount += 1
                                log("📄 预加载: \(key) (\(data.count) 字节)")
                            } catch {
                                log("⚠️ 读取文件失败: \(fileName)")
                            }
                        }
                    }
                }
                
                // 批量执行 JavaScript
                if !jsScripts.isEmpty {
                    let combinedScript = jsScripts.joined(separator: " ")
                    webView.evaluateJavaScript(combinedScript) { _, error in
                        if let error = error {
                            self.log("❌ 预加载失败: \(error)")
                        } else {
                            self.log("✅ 预加载完成: \(loadedCount) 个存档")
                        }
                    }
                } else {
                    log("📭 没有找到存档文件")
                }
            } catch {
                log("❌ 扫描存档目录失败: \(error)")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            log("🌐 页面加载完成")

            // 注入桥接
            let script = RPGWebView.bridgeJavaScript()
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    self.log("❌ 重新注入失败: \(error)")
                } else {
                    self.log("✅ 重新注入成功")
                }
            }

            // 延迟预加载存档
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // 先检查是否有需要预加载的存档
                let checkScript = """
                (function() {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.preloadArchives) {
                        window.webkit.messageHandlers.preloadArchives.postMessage('preload');
                    }
                })();
                """
                webView.evaluateJavaScript(checkScript, completionHandler: nil)
                
                // 检查注入状态
                let statusScript = """
                (function() {
                    var status = '未定义';
                    if (typeof StorageManager !== 'undefined') {
                        status = '已定义';
                        if (StorageManager.save) status += ', save已覆盖';
                        if (StorageManager.load) status += ', load未覆盖(原生)';
                    }
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                        window.webkit.messageHandlers.bridgeReady.postMessage('StorageManager: ' + status);
                    }
                })();
                """
                webView.evaluateJavaScript(statusScript, completionHandler: nil)
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

            if (typeof StorageManager === 'undefined') {
                console.warn('StorageManager not found');
                return;
            }

            // 保存原始方法
            var originalSave = StorageManager.save;
            var originalLoad = StorageManager.load;

            // ========== 重写 save（保存到 localStorage + 备份到文件） ==========
            StorageManager.save = function(savefile) {
                // 先调用原始 save，更新 localStorage
                var result = originalSave.call(this, savefile);
                
                // 从 localStorage 读取完整数据，备份到文件
                var fileId = savefile.savefileId || 1;
                var key = "RPG File" + fileId;
                var data = localStorage.getItem(key);
                
                if (data && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveGameFile) {
                    window.webkit.messageHandlers.saveGameFile.postMessage({
                        fileId: fileId,
                        data: data
                    });
                    console.log('📤 存档已备份到文件，ID: ' + fileId);
                }
                
                return result;
            };

            // ========== load 不重写，保持原生 ==========
            // 游戏从 localStorage 读取，而 localStorage 在启动时已被预加载

            // ========== 预加载触发 ==========
            // 页面加载完成后，通知 Native 预加载存档
            if (document.readyState === 'complete') {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.preloadArchives) {
                    window.webkit.messageHandlers.preloadArchives.postMessage('preload');
                }
            } else {
                document.addEventListener('DOMContentLoaded', function() {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.preloadArchives) {
                        window.webkit.messageHandlers.preloadArchives.postMessage('preload');
                    }
                });
            }

            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('✅ 桥接注入完成（预加载模式）');
            }
            console.log('✅ 桥接注入完成 - 预加载模式');
        })();
        """
    }
}
