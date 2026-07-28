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
        contentController.add(context.coordinator, name: "preloadArchives")
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
        private var saveTimers: [Int: Timer] = [:]
        private var hasLoadedSave = false

        init(gamePath: URL) {
            self.gamePath = gamePath
            self.saveDir = gamePath.appendingPathComponent("save")
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.logFileURL = docs.appendingPathComponent("bridge_log.txt")
            super.init()
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            log("===== Bridge 初始化 (RPG Maker MZ 专用) =====")
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
            case "preloadArchives":
                handlePreloadArchives()
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
                    hasLoadedSave = true
                } catch {
                    log("❌ 保存失败: \(error)")
                }
            } else {
                log("⚠️ 数据过小 (\(dataString.count) 字节)，可能是空存档，忽略")
            }
        }

        // MARK: - ⭐ 核心：从 StorageManager._data 提取所有存档
        private func extractAllArchives() {
            guard let webView = webView else {
                log("❌ webView 不可用")
                return
            }
            
            log("🔍 从 StorageManager._data 提取所有存档")
            
            let script = """
            (function() {
                var result = {};
                
                try {
                    // 直接读取 StorageManager._data（RPG Maker MZ 内部存储）
                    if (typeof StorageManager !== 'undefined' && StorageManager._data) {
                        var data = StorageManager._data;
                        if (data) {
                            // 遍历所有存档
                            for (var key in data) {
                                if (key.indexOf('file') === 0) {
                                    var fileId = parseInt(key.replace('file', ''));
                                    if (!isNaN(fileId)) {
                                        var saveData = data[key];
                                        if (saveData) {
                                            var jsonData = JSON.stringify(saveData);
                                            if (jsonData && jsonData.length > 100) {
                                                result[fileId] = jsonData;
                                                console.log('📤 提取存档 file' + fileId + '，长度: ' + jsonData.length);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } catch(e) {
                    console.error('提取存档失败:', e);
                }
                
                // 发送给 Native
                for (var fileId in result) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveData) {
                        window.webkit.messageHandlers.saveData.postMessage({
                            fileId: parseInt(fileId),
                            data: result[fileId]
                        });
                    }
                }
                
                // 如果没有提取到任何存档，尝试从 localStorage 读取
                if (Object.keys(result).length === 0) {
                    try {
                        for (var i = 0; i < localStorage.length; i++) {
                            var key = localStorage.key(i);
                            if (key && key.indexOf('RPG File') === 0) {
                                var value = localStorage.getItem(key);
                                if (value && value.length > 100) {
                                    var fileId = parseInt(key.replace('RPG File', ''));
                                    if (!isNaN(fileId) && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveData) {
                                        window.webkit.messageHandlers.saveData.postMessage({
                                            fileId: fileId,
                                            data: value
                                        });
                                        console.log('📤 从 localStorage 提取: ' + key + ', 长度: ' + value.length);
                                    }
                                }
                            }
                        }
                    } catch(e) {}
                }
            })();
            """
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        // MARK: - 预加载存档
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
                            // 预加载后，从 StorageManager._data 提取存档
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.extractAllArchives()
                            }
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
                    self.log("❌ 注入失败: \(error)")
                } else {
                    self.log("✅ 桥接注入成功")
                }
            }

            // 延迟预加载
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
            
            // ⭐ 启动定时轮询，每 5 秒检查一次是否有新存档
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                self.startPolling()
            }
        }
        
        // MARK: - ⭐ 定时轮询
        private func startPolling() {
            log("🔄 启动定时轮询 (每 5 秒检查一次)")
            
            Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                self.extractAllArchives()
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
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始 (RPG Maker MZ)');
            }

            // ==========================================
            // RPG Maker MZ 专用拦截
            // ==========================================
            
            if (typeof StorageManager === 'undefined') {
                console.warn('StorageManager 未定义');
                return;
            }

            // ⭐ 拦截 StorageManager.save
            var originalSave = StorageManager.save;
            StorageManager.save = function(savefile) {
                console.log('📤 StorageManager.save 被调用');
                var result = originalSave.call(this, savefile);
                
                // 保存后立即从 _data 提取
                var fileId = savefile.savefileId || savefile.id || 1;
                
                // 延迟 300ms 后从 _data 读取
                setTimeout(function() {
                    try {
                        if (StorageManager._data) {
                            var data = StorageManager._data;
                            var key = 'file' + fileId;
                            if (data[key]) {
                                var jsonData = JSON.stringify(data[key]);
                                if (jsonData && jsonData.length > 100 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveData) {
                                    window.webkit.messageHandlers.saveData.postMessage({
                                        fileId: fileId,
                                        data: jsonData
                                    });
                                    console.log('📤 从 _data 提取存档成功，长度: ' + jsonData.length);
                                }
                            }
                        }
                    } catch(e) {
                        console.error('提取失败:', e);
                    }
                }, 300);
                
                return result;
            };

            // ⭐ 拦截 localStorage.setItem
            var originalSetItem = localStorage.setItem;
            localStorage.setItem = function(key, value) {
                originalSetItem.call(this, key, value);
                if (key && key.indexOf('RPG File') === 0) {
                    console.log('📤 localStorage.setItem: ' + key + ', 长度: ' + (value ? value.length : 0));
                }
            };

            console.log('✅ RPG Maker MZ 桥接注入完成');
        })();
        """
    }
}
