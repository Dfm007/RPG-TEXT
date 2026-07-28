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
        contentController.add(context.coordinator, name: "saveArchiveData")

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
        private var saveTimer: Timer?

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
            case "saveArchiveData":
                handleSaveArchiveData(message: message)
            default:
                log("⚠️ 未知消息: \(message.name)")
            }
        }

        // MARK: - 保存存档
        private func handleSave(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let key = dict["key"] as? String,
                  let dataString = dict["data"] as? String else {
                log("⚠️ 保存消息格式错误")
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
            
            // 如果数据是占位符（0 或 1），等待完整数据
            if dataString == "0" || dataString == "1" || dataString.count < 10 {
                log("⏳ 检测到占位数据，等待完整存档...")
                // 启动定时器，每 2 秒尝试获取完整数据，最多 5 次
                var attempts = 0
                saveTimer?.invalidate()
                saveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
                    attempts += 1
                    if attempts > 5 {
                        timer.invalidate()
                        self.log("❌ 等待超时，放弃获取完整存档")
                        return
                    }
                    self.log("🔄 尝试获取完整数据 (第 \(attempts) 次)...")
                    
                    // 尝试从游戏获取完整存档
                    let getScript = """
                    (function() {
                        var data = null;
                        // 尝试多种方式获取存档数据
                        try {
                            // 方式1: 从 StorageManager 获取
                            if (typeof StorageManager !== 'undefined') {
                                var saveData = StorageManager.load(\(fileId));
                                if (saveData) {
                                    data = JSON.stringify(saveData);
                                }
                            }
                        } catch(e) {}
                        
                        // 方式2: 从 localStorage 获取（如果存在完整数据）
                        if (!data || data === 'null' || data.length < 10) {
                            try {
                                var storageData = localStorage.getItem('RPG File\(fileId)');
                                if (storageData && storageData.length > 10) {
                                    data = storageData;
                                }
                            } catch(e) {}
                        }
                        
                        // 方式3: 从全局变量获取（某些游戏会暴露存档数据）
                        if (!data || data === 'null' || data.length < 10) {
                            try {
                                if (window._saveData) {
                                    data = JSON.stringify(window._saveData);
                                }
                            } catch(e) {}
                        }
                        
                        if (data && data.length > 10 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveArchiveData) {
                            window.webkit.messageHandlers.saveArchiveData.postMessage({
                                fileId: \(fileId),
                                data: data
                            });
                            console.log('📤 完整存档已获取，长度: ' + data.length);
                        } else {
                            console.warn('无法获取完整存档数据');
                        }
                    })();
                    """
                    self.webView?.evaluateJavaScript(getScript, completionHandler: nil)
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

        // MARK: - 接收完整存档数据
        private func handleSaveArchiveData(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let fileId = dict["fileId"] as? Int,
                  let dataString = dict["data"] as? String else {
                log("⚠️ 存档数据格式错误")
                return
            }
            
            let fileName = "file\(fileId).rpgsave"
            let fileURL = saveDir.appendingPathComponent(fileName)
            
            log("📦 收到完整存档: file\(fileId), 长度: \(dataString.count)")
            let preview = String(dataString.prefix(100))
            log("📄 数据预览: \(preview)...")
            
            if dataString.count > 10 {
                do {
                    try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
                    log("✅ 完整存档保存成功: \(fileName)")
                    saveTimer?.invalidate()
                    saveTimer = nil
                } catch {
                    log("❌ 保存失败: \(error)")
                }
            } else {
                log("⚠️ 数据仍然不完整（长度: \(dataString.count)），可能是占位数据")
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
            
            // 探测游戏内部存储结构
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let probeScript = """
                (function() {
                    var info = {};
                    
                    // 检查 StorageManager
                    if (typeof StorageManager !== 'undefined') {
                        info.StorageManager = '存在';
                        if (StorageManager.save) info.StorageManager_save = '存在';
                        if (StorageManager.load) info.StorageManager_load = '存在';
                        if (StorageManager._data) info.StorageManager_data = '存在';
                    }
                    
                    // 检查 window 上的存档相关变量
                    var saveKeys = ['saveData', '_saveData', 'savefile', 'SaveData', 'SaveFile', 'RPG'];
                    saveKeys.forEach(function(key) {
                        if (window[key] !== undefined) {
                            info['window.' + key] = typeof window[key];
                        }
                    });
                    
                    // 检查 localStorage 所有 RPG 相关的 key
                    var keys = [];
                    for (var i = 0; i < localStorage.length; i++) {
                        var key = localStorage.key(i);
                        if (key && key.indexOf('RPG') !== -1) {
                            keys.push(key + ':' + localStorage.getItem(key).length);
                        }
                    }
                    info.localStorage = keys.join(', ');
                    
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                        window.webkit.messageHandlers.debugLog.postMessage('游戏存储探测: ' + JSON.stringify(info));
                    }
                })();
                """
                webView.evaluateJavaScript(probeScript, completionHandler: nil)
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

            // 拦截 localStorage.setItem
            var originalSetItem = localStorage.setItem;
            localStorage.setItem = function(key, value) {
                originalSetItem.call(this, key, value);
                
                if (key && key.indexOf('RPG File') === 0) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveGameFile) {
                        window.webkit.messageHandlers.saveGameFile.postMessage({
                            key: key,
                            data: value || ''
                        });
                        console.log('📤 localStorage 已备份: ' + key);
                    }
                }
            };

            console.log('✅ 全方位拦截已启动');
        })();
        """
    }
}
