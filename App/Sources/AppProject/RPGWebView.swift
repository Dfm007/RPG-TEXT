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
        contentController.add(context.coordinator, name: "saveFromLoad")  // 新增

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
        private var pendingSaves: Set<Int> = []

        init(gamePath: URL) {
            self.gamePath = gamePath
            self.saveDir = gamePath.appendingPathComponent("save")
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.logFileURL = docs.appendingPathComponent("bridge_log.txt")
            super.init()
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            log("===== Bridge 初始化 (最终修复版) =====")
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
            case "saveFromLoad":
                handleSaveFromLoad(message: message)
            default:
                log("⚠️ 未知消息: \(message.name)")
            }
        }

        // MARK: - ⭐ 新增：从 StorageManager.load 获取数据并保存
        private func handleSaveFromLoad(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let fileId = dict["fileId"] as? Int else {
                log("⚠️ saveFromLoad 数据格式错误")
                return
            }
            
            // 如果有数据，直接处理
            if let data = dict["data"] as? String {
                log("💾 saveFromLoad: file\(fileId), 长度: \(data.count)")
                
                if data.count > 1000 {
                    let fileName = "file\(fileId).rpgsave"
                    let fileURL = saveDir.appendingPathComponent(fileName)
                    
                    do {
                        try data.write(to: fileURL, atomically: true, encoding: .utf8)
                        log("✅ saveFromLoad 保存成功: \(fileName)")
                        
                        // 更新 localStorage
                        let escapedData = data.replacingOccurrences(of: "\\", with: "\\\\")
                                                 .replacingOccurrences(of: "'", with: "\\'")
                                                 .replacingOccurrences(of: "\n", with: "\\n")
                                                 .replacingOccurrences(of: "\r", with: "\\r")
                        let script = "localStorage.setItem('RPG File\(fileId)', '\(escapedData)');"
                        webView?.evaluateJavaScript(script, completionHandler: nil)
                        
                        probeGameStorage()
                    } catch {
                        log("❌ saveFromLoad 保存失败: \(error)")
                    }
                } else {
                    log("⚠️ saveFromLoad 数据过小 (\(data.count) 字节)，可能是占位数据")
                }
            } else {
                log("⚠️ saveFromLoad 没有数据")
            }
        }

        // MARK: - 强制捕获
        private func handleForceCapture(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let fileId = dict["fileId"] as? Int else {
                log("⚠️ 强制捕获数据格式错误")
                return
            }
            
            if let data = dict["data"] as? String {
                log("💾 强制捕获: file\(fileId), 长度: \(data.count)")
                
                if data.count > 1000 {
                    let fileName = "file\(fileId).rpgsave"
                    let fileURL = saveDir.appendingPathComponent(fileName)
                    
                    do {
                        try data.write(to: fileURL, atomically: true, encoding: .utf8)
                        log("✅ 强制捕获保存成功: \(fileName)")
                        
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
                }
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
            
            // ⭐ 关键：延迟后从 StorageManager.load 获取数据
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.fetchFromStorageManagerLoad(fileId: fileId)
            }
        }

        // MARK: - ⭐ 核心方法：从 StorageManager.load 获取数据
        private func fetchFromStorageManagerLoad(fileId: Int) {
            guard let webView = webView else {
                log("❌ webView 不可用")
                return
            }
            
            log("🔄 从 StorageManager.load 获取数据, fileId: \(fileId)")
            
            let script = """
            (function() {
                var fileId = \(fileId);
                var data = null;
                
                try {
                    if (typeof StorageManager !== 'undefined' && StorageManager.load) {
                        var result = StorageManager.load(fileId);
                        if (result !== null && result !== undefined) {
                            data = JSON.stringify(result);
                            if (data && data.length > 100) {
                                console.log('📤 StorageManager.load 成功，长度: ' + data.length);
                                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveFromLoad) {
                                    window.webkit.messageHandlers.saveFromLoad.postMessage({
                                        fileId: fileId,
                                        data: data
                                    });
                                    return;
                                }
                            }
                        }
                    }
                } catch(e) {
                    console.error('StorageManager.load 错误:', e);
                }
                
                // 如果 StorageManager.load 失败，尝试从 localStorage 获取
                try {
                    var key = 'RPG File' + fileId;
                    var value = localStorage.getItem(key);
                    if (value && value.length > 100) {
                        data = value;
                        console.log('📤 localStorage 备用获取，长度: ' + data.length);
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveFromLoad) {
                            window.webkit.messageHandlers.saveFromLoad.postMessage({
                                fileId: fileId,
                                data: data
                            });
                            return;
                        }
                    }
                } catch(e) {}
                
                console.warn('⚠️ 未找到存档数据');
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
    private static func expertBridgeJavaScript() -> String {
        return """
        (function() {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始 (最终修复版)');
            }

            // ========== 拦截 localStorage.setItem ==========
            var originalSetItem = localStorage.setItem;
            localStorage.setItem = function(key, value) {
                originalSetItem.call(this, key, value);
                
                if (key && key.indexOf('RPG File') === 0) {
                    console.log('📤 localStorage.setItem: ' + key + ', 长度: ' + (value ? value.length : 0));
                    
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveGameFile) {
                        window.webkit.messageHandlers.saveGameFile.postMessage({
                            key: key,
                            data: value || ''
                        });
                    }
                }
            };

            // ========== 拦截 StorageManager.save ==========
            if (typeof StorageManager !== 'undefined') {
                var originalSave = StorageManager.save;
                StorageManager.save = function(savefile) {
                    var result = originalSave.call(this, savefile);
                    var fileId = savefile.savefileId || savefile.id || 1;
                    console.log('📤 StorageManager.save: fileId=' + fileId);
                    
                    // 延迟后从 StorageManager.load 获取数据
                    setTimeout(function() {
                        try {
                            if (StorageManager.load) {
                                var loadData = StorageManager.load(fileId);
                                if (loadData !== null && loadData !== undefined) {
                                    var json = JSON.stringify(loadData);
                                    if (json && json.length > 1000 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveFromLoad) {
                                        window.webkit.messageHandlers.saveFromLoad.postMessage({
                                            fileId: fileId,
                                            data: json
                                        });
                                        console.log('📤 StorageManager.save -> load 捕获成功，长度: ' + json.length);
                                        return;
                                    }
                                }
                            }
                        } catch(e) {
                            console.error('StorageManager.save 捕获失败:', e);
                        }
                    }, 500);
                    
                    return result;
                };
            }

            console.log('✅ 最终修复版已启动');
        })();
        """
    }
}
