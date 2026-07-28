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
        contentController.add(context.coordinator, name: "preloadArchives")
        contentController.add(context.coordinator, name: "debugLog")
        contentController.add(context.coordinator, name: "forceSave") // 新增：强制保存

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
                handlePreloadArchives()
            case "debugLog":
                log("🐛 \(message.body)")
            case "forceSave":
                handleForceSave(message: message)
            default:
                log("⚠️ 未知消息: \(message.name)")
            }
        }

        // MARK: - 保存存档
        private func handleSave(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let key = dict["key"] as? String,
                  let dataString = dict["data"] as? String else {
                log("⚠️ 保存消息格式错误: \(message.body)")
                return
            }
            
            let fileIdStr = key.replacingOccurrences(of: "RPG File", with: "")
            guard let fileId = Int(fileIdStr) else {
                log("⚠️ 无法解析 fileId: \(key)")
                return
            }
            
            let fileName = "file\(fileId).rpgsave"
            let fileURL = saveDir.appendingPathComponent(fileName)
            
            log("📝 保存: \(key), 数据长度: \(dataString.count)")
            let preview = String(dataString.prefix(100))
            log("📄 数据预览: \(preview)...")
            
            // 如果数据是 "0" 或 "1"，尝试强制从游戏获取完整数据
            if dataString == "0" || dataString == "1" || dataString.count < 10 {
                log("⚠️ 检测到占位数据，尝试强制获取完整存档...")
                if let webView = webView {
                    let forceScript = """
                    (function() {
                        // 尝试从 StorageManager 获取所有存档
                        var result = null;
                        if (typeof StorageManager !== 'undefined' && StorageManager.load) {
                            try {
                                var data = StorageManager.load(\(fileId));
                                if (data) {
                                    result = JSON.stringify(data);
                                }
                            } catch(e) {
                                console.error('强制获取存档失败:', e);
                            }
                        }
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.forceSave) {
                            window.webkit.messageHandlers.forceSave.postMessage({
                                fileId: \(fileId),
                                data: result || ''
                            });
                        }
                    })();
                    """
                    webView.evaluateJavaScript(forceScript, completionHandler: nil)
                }
            } else {
                // 数据正常，直接保存
                do {
                    try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
                    log("✅ 写入成功: \(fileName)")
                } catch {
                    log("❌ 写入失败: \(error)")
                }
            }
        }

        // MARK: - 强制保存（从游戏获取完整数据后）
        private func handleForceSave(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let fileId = dict["fileId"] as? Int,
                  let dataString = dict["data"] as? String else {
                log("⚠️ 强制保存消息格式错误")
                return
            }
            
            let fileName = "file\(fileId).rpgsave"
            let fileURL = saveDir.appendingPathComponent(fileName)
            
            if dataString.isEmpty || dataString == "null" || dataString == "undefined" {
                log("⚠️ 强制获取数据失败，数据为空")
                return
            }
            
            log("📝 强制保存: file\(fileId), 数据长度: \(dataString.count)")
            let preview = String(dataString.prefix(100))
            log("📄 数据预览: \(preview)...")
            
            do {
                try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
                log("✅ 强制保存成功: \(fileName)")
            } catch {
                log("❌ 强制保存失败: \(error)")
            }
        }

        // MARK: - 预加载存档到 localStorage
        private func handlePreloadArchives() {
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
                        let fileIdStr = fileName.replacingOccurrences(of: "file", with: "").replacingOccurrences(of: ".rpgsave", with: "")
                        if let fileId = Int(fileIdStr) {
                            do {
                                let data = try String(contentsOf: fileURL, encoding: .utf8)
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

            let script = RPGWebView.bridgeJavaScript()
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    self.log("❌ 重新注入失败: \(error)")
                } else {
                    self.log("✅ 重新注入成功")
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let triggerScript = """
                (function() {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.preloadArchives) {
                        window.webkit.messageHandlers.preloadArchives.postMessage('preload');
                    }
                })();
                """
                webView.evaluateJavaScript(triggerScript, completionHandler: nil)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                let checkScript = """
                (function() {
                    var items = [];
                    for (var i = 0; i < localStorage.length; i++) {
                        var key = localStorage.key(i);
                        if (key && key.indexOf('RPG') !== -1) {
                            items.push(key + ':' + localStorage.getItem(key).length);
                        }
                    }
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                        window.webkit.messageHandlers.debugLog.postMessage('localStorage 内容: ' + items.join(', '));
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

    // MARK: - JavaScript 桥接
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

            // ========== 拦截 localStorage.setItem ==========
            var originalSetItem = localStorage.setItem;
            localStorage.setItem = function(key, value) {
                originalSetItem.call(this, key, value);
                
                if (key && key.indexOf('RPG File') === 0 && value !== undefined && value !== null) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                        window.webkit.messageHandlers.debugLog.postMessage('localStorage.setItem: ' + key + ', 长度: ' + value.length);
                    }
                    
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveGameFile) {
                        window.webkit.messageHandlers.saveGameFile.postMessage({
                            key: key,
                            data: value
                        });
                        console.log('📤 localStorage 已备份: ' + key);
                    }
                }
            };

            // ========== 拦截 StorageManager.save ==========
            var originalSave = StorageManager.save;
            StorageManager.save = function(savefile) {
                var result = originalSave.call(this, savefile);
                console.log('📤 StorageManager.save 被调用');
                return result;
            };

            console.log('✅ 全方位拦截已启动');
        })();
        """
    }
}
