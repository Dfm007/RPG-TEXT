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
        contentController.add(context.coordinator, name: "captureArchive")
        contentController.add(context.coordinator, name: "forceCapture")

        let bridgeScript = WKUserScript(
            source: RPGWebView.expertBridgeJavaScript(),
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
            log("===== Bridge 初始化 (修复版) =====")
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
            case "captureArchive":
                handleCaptureArchive(message: message)
            case "forceCapture":
                handleForceCapture(message: message)
            default:
                log("⚠️ 未知消息: \(message.name)")
            }
        }

        // MARK: - 强制捕获（从内存中提取）
        private func handleForceCapture(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let fileId = dict["fileId"] as? Int else {
                log("⚠️ 强制捕获数据格式错误")
                return
            }
            
            // 如果 data 是字符串，直接处理
            if let data = dict["data"] as? String {
                log("💾 强制捕获: file\(fileId), 长度: \(data.count)")
                
                if data.count > 1000 {
                    let fileName = "file\(fileId).rpgsave"
                    let fileURL = saveDir.appendingPathComponent(fileName)
                    
                    do {
                        try data.write(to: fileURL, atomically: true, encoding: .utf8)
                        log("✅ 强制捕获保存成功: \(fileName)")
                        
                        // 更新 localStorage
                        let escapedData = data.replacingOccurrences(of: "\\", with: "\\\\")
                                                 .replacingOccurrences(of: "'", with: "\\'")
                                                 .replacingOccurrences(of: "\n", with: "\\n")
                                                 .replacingOccurrences(of: "\r", with: "\\r")
                        let script = "localStorage.setItem('RPG File\(fileId)', '\(escapedData)');"
                        webView?.evaluateJavaScript(script, completionHandler: nil)
                        
                        probeGameStorage()
                    } catch {
                        log("❌ 强制捕获保存失败: \(error)")
                    }
                } else {
                    log("⚠️ 数据过小 (\(data.count) 字节)，可能不是完整存档")
                }
            } else if let dataDict = dict["data"] as? [String: Any] {
                // 如果是字典，序列化后保存
                do {
                    let jsonData = try JSONSerialization.data(withJSONObject: dataDict, options: [])
                    if let data = String(data: jsonData, encoding: .utf8) {
                        log("💾 强制捕获(字典): file\(fileId), 长度: \(data.count)")
                        
                        if data.count > 1000 {
                            let fileName = "file\(fileId).rpgsave"
                            let fileURL = saveDir.appendingPathComponent(fileName)
                            try data.write(to: fileURL, atomically: true, encoding: .utf8)
                            log("✅ 强制捕获保存成功: \(fileName)")
                            probeGameStorage()
                        }
                    }
                } catch {
                    log("❌ 序列化失败: \(error)")
                }
            } else {
                log("⚠️ 未知数据格式: \(type(of: dict["data"]))")
            }
        }

        // MARK: - 处理捕获的存档数据
        private func handleCaptureArchive(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let fileId = dict["fileId"] as? Int,
                  let data = dict["data"] as? String else {
                log("⚠️ 捕获数据格式错误")
                return
            }
            
            log("🎯 捕获存档: file\(fileId), 长度: \(data.count)")
            
            if data.count > 1000 {
                let fileName = "file\(fileId).rpgsave"
                let fileURL = saveDir.appendingPathComponent(fileName)
                
                do {
                    try data.write(to: fileURL, atomically: true, encoding: .utf8)
                    log("✅ 存档保存成功: \(fileName)")
                    probeGameStorage()
                } catch {
                    log("❌ 保存失败: \(error)")
                }
            }
        }

        // MARK: - 处理保存请求
        private func handleSave(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let key = dict["key"] as? String else {
                log("⚠️ 保存消息格式错误")
                return
            }
            
            let fileIdStr = key.replacingOccurrences(of: "RPG File", with: "")
            guard let fileId = Int(fileIdStr) else {
                log("⚠️ 无法解析 fileId: \(key)")
                return
            }
            
            log("📝 收到保存请求: \(key), fileId: \(fileId)")
            
            // 延迟后强制从内存捕获
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.forceCaptureFromMemory(fileId: fileId)
            }
        }

        // MARK: - ⭐ 核心方法：从内存强制捕获
        private func forceCaptureFromMemory(fileId: Int) {
            guard let webView = webView else {
                log("❌ webView 不可用")
                return
            }
            
            log("🔍 从内存强制捕获存档, fileId: \(fileId)")
            
            let script = """
            (function() {
                var fileId = \(fileId);
                var data = null;
                var dataSources = [];
                
                // ========== 1. 检查 StorageManager ==========
                if (typeof StorageManager !== 'undefined') {
                    try {
                        if (StorageManager.load) {
                            var result = StorageManager.load(fileId);
                            if (result !== null && result !== undefined) {
                                var json = JSON.stringify(result);
                                if (json && json.length > 100) {
                                    dataSources.push('StorageManager.load: ' + json.length);
                                    data = json;
                                    // ⭐ 立即发送给 Native
                                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.forceCapture) {
                                        window.webkit.messageHandlers.forceCapture.postMessage({
                                            fileId: fileId,
                                            data: json
                                        });
                                        console.log('📤 StorageManager.load 数据已发送，长度: ' + json.length);
                                        return;
                                    }
                                }
                            }
                        }
                        if (StorageManager._data) {
                            var json = JSON.stringify(StorageManager._data);
                            if (json && json.length > 100) {
                                dataSources.push('StorageManager._data: ' + json.length);
                                if (!data || json.length > data.length) {
                                    data = json;
                                }
                            }
                        }
                    } catch(e) {
                        console.error('StorageManager 错误:', e);
                    }
                }
                
                // ========== 2. 检查所有可能的全局变量 ==========
                var globalKeys = [
                    'saveData', '_saveData', 'SaveData', 'savefile', 'SaveFile',
                    'savedata', 'Save', 'save', 'archive', 'Archive',
                    'RPG', 'RPG_data', 'RPGData', 'gameData', 'GameData',
                    'player', 'Player', 'playerData', 'PlayerData',
                    'storage', 'Storage', 'store', 'Store'
                ];
                
                for (var key of globalKeys) {
                    if (window[key] !== undefined) {
                        try {
                            var value = window[key];
                            if (value !== null && typeof value === 'object') {
                                var json = JSON.stringify(value);
                                if (json && json.length > 100) {
                                    dataSources.push(key + ': ' + json.length);
                                    if (!data || json.length > data.length) {
                                        data = json;
                                    }
                                }
                            }
                        } catch(e) {}
                    }
                }
                
                // ========== 3. 检查 localStorage ==========
                try {
                    var key = 'RPG File' + fileId;
                    var value = localStorage.getItem(key);
                    if (value && value.length > 100) {
                        dataSources.push('localStorage: ' + value.length);
                        if (!data || value.length > data.length) {
                            data = value;
                        }
                    }
                } catch(e) {}
                
                // ========== 4. 如果有数据，发送给 Native ==========
                if (data && data.length > 100 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.forceCapture) {
                    window.webkit.messageHandlers.forceCapture.postMessage({
                        fileId: fileId,
                        data: data
                    });
                    console.log('📤 强制捕获成功，数据来源:', dataSources.join(', '));
                } else {
                    console.warn('⚠️ 未找到存档数据');
                    // 发送空数据通知 Native
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                        window.webkit.messageHandlers.debugLog.postMessage('⚠️ 未找到存档数据, 尝试的数据源: ' + dataSources.join(', '));
                    }
                }
            })();
            """
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        // MARK: - 接收存档数据
        private func handleSaveArchiveData(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let fileId = dict["fileId"] as? Int,
                  let dataString = dict["data"] as? String else {
                log("⚠️ 存档数据格式错误")
                return
            }
            
            let fileName = "file\(fileId).rpgsave"
            let fileURL = saveDir.appendingPathComponent(fileName)
            
            log("📦 收到存档: file\(fileId), 长度: \(dataString.count)")
            
            if dataString.count > 1000 {
                do {
                    try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
                    log("✅ 存档保存成功: \(fileName)")
                    probeGameStorage()
                } catch {
                    log("❌ 保存失败: \(error)")
                }
            }
        }

        // MARK: - 探测游戏存储
        private func probeGameStorage() {
            guard let webView = webView else { return }
            
            let probeScript = """
            (function() {
                var info = {};
                
                if (typeof StorageManager !== 'undefined') {
                    info.StorageManager = '存在';
                    if (StorageManager.save) info.StorageManager_save = '存在';
                    if (StorageManager.load) info.StorageManager_load = '存在';
                }
                
                var keys = [];
                for (var i = 0; i < localStorage.length; i++) {
                    var key = localStorage.key(i);
                    if (key && key.indexOf('RPG') !== -1) {
                        var value = localStorage.getItem(key);
                        keys.push(key + ':' + (value ? value.length : 0));
                    }
                }
                info.localStorage = keys.join(', ');
                info.IndexedDB = window.indexedDB ? '存在' : '不存在';
                
                // 检查全局变量
                var globalKeys = ['saveData', '_saveData', 'SaveData', 'savefile', 'SaveFile', 'RPG'];
                globalKeys.forEach(function(key) {
                    if (window[key] !== undefined) {
                        try {
                            var json = JSON.stringify(window[key]);
                            info['window.' + key] = (json ? json.length : 0) + '字节';
                        } catch(e) {
                            info['window.' + key] = '存在(无法序列化)';
                        }
                    }
                });
                
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                    window.webkit.messageHandlers.debugLog.postMessage('📊 存储探测: ' + JSON.stringify(info));
                }
            })();
            """
            webView.evaluateJavaScript(probeScript, completionHandler: nil)
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
                            self.probeGameStorage()
                        }
                    }
                } else {
                    log("📭 没有找到存档文件")
                    // 尝试从内存恢复
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.forceCaptureFromMemory(fileId: 1)
                    }
                    probeGameStorage()
                }
            } catch {
                log("❌ 扫描存档目录失败: \(error)")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            log("🌐 页面加载完成")

            let script = RPGWebView.expertBridgeJavaScript()
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
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.probeGameStorage()
                // 尝试从内存捕获所有可能的存档
                for i in 1...5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.3) {
                        self.forceCaptureFromMemory(fileId: i)
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

    // MARK: - 专家模式 JavaScript 桥接
    private static func expertBridgeJavaScript() -> String {
        return """
        (function() {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始 (修复版)');
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
                    }
                }
            };

            // 拦截 StorageManager.save
            if (typeof StorageManager !== 'undefined') {
                var originalSave = StorageManager.save;
                StorageManager.save = function(savefile) {
                    var result = originalSave.call(this, savefile);
                    var fileId = savefile.savefileId || savefile.id || 1;
                    
                    // 延迟后从内存捕获
                    setTimeout(function() {
                        try {
                            // 从 StorageManager.load 获取数据
                            if (StorageManager.load) {
                                var loadData = StorageManager.load(fileId);
                                if (loadData !== null && loadData !== undefined) {
                                    var json = JSON.stringify(loadData);
                                    if (json && json.length > 100 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.forceCapture) {
                                        window.webkit.messageHandlers.forceCapture.postMessage({
                                            fileId: fileId,
                                            data: json
                                        });
                                        console.log('📤 StorageManager.save 捕获成功，长度:', json.length);
                                        return;
                                    }
                                }
                            }
                        } catch(e) {
                            console.error('StorageManager.save 捕获失败:', e);
                        }
                    }, 300);
                    
                    return result;
                };
            }

            console.log('✅ 修复版已启动');
        })();
        """
    }
}
