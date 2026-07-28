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

        init(gamePath: URL) {
            self.gamePath = gamePath
            self.saveDir = gamePath.appendingPathComponent("save")
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.logFileURL = docs.appendingPathComponent("bridge_log.txt")
            super.init()
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            log("===== Bridge 初始化 (DataManager 拦截版) =====")
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
                } catch {
                    log("❌ 保存失败: \(error)")
                }
            } else {
                log("⚠️ 数据过小 (\(dataString.count) 字节)")
            }
        }

        // MARK: - 提取存档数据
        private func extractArchive() {
            guard let webView = webView else {
                log("❌ webView 不可用")
                return
            }
            
            let script = """
            (function() {
                var result = {};
                
                // 1. 从 StorageManager._data 提取
                try {
                    if (typeof StorageManager !== 'undefined' && StorageManager._data) {
                        var data = StorageManager._data;
                        for (var key in data) {
                            if (key.indexOf('file') === 0) {
                                var fileId = parseInt(key.replace('file', ''));
                                if (!isNaN(fileId) && data[key]) {
                                    var jsonData = JSON.stringify(data[key]);
                                    if (jsonData && jsonData.length > 100) {
                                        result[fileId] = jsonData;
                                        console.log('📤 从 _data 提取 file' + fileId + '，长度: ' + jsonData.length);
                                    }
                                }
                            }
                        }
                    }
                } catch(e) {}
                
                // 2. 如果 _data 没有数据，尝试从 localStorage 提取
                if (Object.keys(result).length === 0) {
                    try {
                        for (var i = 0; i < localStorage.length; i++) {
                            var key = localStorage.key(i);
                            if (key && key.indexOf('RPG File') === 0) {
                                var value = localStorage.getItem(key);
                                if (value && value.length > 100) {
                                    var fileId = parseInt(key.replace('RPG File', ''));
                                    if (!isNaN(fileId)) {
                                        result[fileId] = value;
                                        console.log('📤 从 localStorage 提取 ' + key + '，长度: ' + value.length);
                                    }
                                }
                            }
                        }
                    } catch(e) {}
                }
                
                // 3. 发送给 Native
                for (var fileId in result) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveData) {
                        window.webkit.messageHandlers.saveData.postMessage({
                            fileId: parseInt(fileId),
                            data: result[fileId]
                        });
                    }
                }
                
                if (Object.keys(result).length === 0) {
                    console.log('📭 未找到任何存档数据');
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
                            // 预加载后尝试提取存档
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.extractArchive()
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
            
            // 定时提取（每 3 秒）
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                    self?.extractArchive()
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
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始 (DataManager拦截)');
            }

            // ==========================================
            // 1. 拦截 StorageManager.save
            // ==========================================
            if (typeof StorageManager !== 'undefined') {
                var originalSave = StorageManager.save;
                StorageManager.save = function(savefile) {
                    console.log('📤 StorageManager.save 被调用');
                    var result = originalSave.call(this, savefile);
                    
                    // 延迟后提取数据
                    setTimeout(function() {
                        try {
                            if (StorageManager._data) {
                                var fileId = savefile.savefileId || savefile.id || 1;
                                var key = 'file' + fileId;
                                if (StorageManager._data[key]) {
                                    var jsonData = JSON.stringify(StorageManager._data[key]);
                                    if (jsonData && jsonData.length > 100 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveData) {
                                        window.webkit.messageHandlers.saveData.postMessage({
                                            fileId: fileId,
                                            data: jsonData
                                        });
                                        console.log('📤 StorageManager.save 数据已发送');
                                    }
                                }
                            }
                        } catch(e) {}
                    }, 200);
                    
                    return result;
                };
            }

            // ==========================================
            // 2. 拦截 DataManager.saveGame
            // ==========================================
            if (typeof DataManager !== 'undefined') {
                var originalSaveGame = DataManager.saveGame;
                DataManager.saveGame = function(savefileId) {
                    console.log('📤 DataManager.saveGame 被调用, ID: ' + savefileId);
                    var result = originalSaveGame.call(this, savefileId);
                    
                    // 延迟后从 StorageManager._data 提取
                    setTimeout(function() {
                        try {
                            if (typeof StorageManager !== 'undefined' && StorageManager._data) {
                                var key = 'file' + savefileId;
                                if (StorageManager._data[key]) {
                                    var jsonData = JSON.stringify(StorageManager._data[key]);
                                    if (jsonData && jsonData.length > 100 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveData) {
                                        window.webkit.messageHandlers.saveData.postMessage({
                                            fileId: savefileId,
                                            data: jsonData
                                        });
                                        console.log('📤 DataManager.saveGame 数据已发送');
                                    }
                                }
                            }
                        } catch(e) {}
                    }, 300);
                    
                    return result;
                };
            }

            console.log('✅ DataManager 拦截版已启动');
        })();
        """
    }
}
