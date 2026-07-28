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
        contentController.add(context.coordinator, name: "indexedDBData")
        contentController.add(context.coordinator, name: "captureArchive")

        // ⭐ 专家模式：在页面加载前注入完整的代理脚本
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
        private var saveTimers: [Int: Timer] = [:]
        private var pendingData: [Int: String] = [:]

        init(gamePath: URL) {
            self.gamePath = gamePath
            self.saveDir = gamePath.appendingPathComponent("save")
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.logFileURL = docs.appendingPathComponent("bridge_log.txt")
            super.init()
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            log("===== Bridge 初始化 (专家模式) =====")
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
            case "indexedDBData":
                handleIndexedDBData(message: message)
            case "captureArchive":
                handleCaptureArchive(message: message)
            default:
                log("⚠️ 未知消息: \(message.name)")
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
            
            if data.count > 100 {
                let fileName = "file\(fileId).rpgsave"
                let fileURL = saveDir.appendingPathComponent(fileName)
                
                do {
                    try data.write(to: fileURL, atomically: true, encoding: .utf8)
                    log("✅ 存档保存成功: \(fileName)")
                    
                    // 更新 localStorage 缓存
                    let escapedData = data.replacingOccurrences(of: "\\", with: "\\\\")
                                             .replacingOccurrences(of: "'", with: "\\'")
                                             .replacingOccurrences(of: "\n", with: "\\n")
                                             .replacingOccurrences(of: "\r", with: "\\r")
                    let script = "localStorage.setItem('RPG File\(fileId)', '\(escapedData)');"
                    webView?.evaluateJavaScript(script, completionHandler: nil)
                    
                    probeGameStorage()
                } catch {
                    log("❌ 保存失败: \(error)")
                }
            }
        }

        // MARK: - 处理 IndexedDB 数据
        private func handleIndexedDBData(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let fileId = dict["fileId"] as? Int,
                  let data = dict["data"] as? String else {
                log("⚠️ IndexedDB 数据格式错误")
                return
            }
            
            log("💾 IndexedDB 数据: file\(fileId), 长度: \(data.count)")
            
            if data.count > 100 {
                let fileName = "file\(fileId).rpgsave"
                let fileURL = saveDir.appendingPathComponent(fileName)
                
                do {
                    try data.write(to: fileURL, atomically: true, encoding: .utf8)
                    log("✅ IndexedDB 保存成功: \(fileName)")
                    
                    let escapedData = data.replacingOccurrences(of: "\\", with: "\\\\")
                                             .replacingOccurrences(of: "'", with: "\\'")
                                             .replacingOccurrences(of: "\n", with: "\\n")
                                             .replacingOccurrences(of: "\r", with: "\\r")
                    let script = "localStorage.setItem('RPG File\(fileId)', '\(escapedData)');"
                    webView?.evaluateJavaScript(script, completionHandler: nil)
                    
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
            
            // 延迟后从 IndexedDB 获取数据
            saveTimers[fileId]?.invalidate()
            let timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                self?.forceCaptureArchive(fileId: fileId)
                self?.saveTimers.removeValue(forKey: fileId)
            }
            saveTimers[fileId] = timer
        }

        // MARK: - 强制捕获存档
        private func forceCaptureArchive(fileId: Int) {
            guard let webView = webView else {
                log("❌ webView 不可用")
                return
            }
            
            log("🔍 强制捕获存档, fileId: \(fileId)")
            
            // 使用多种方式尝试获取存档数据
            let script = """
            (function() {
                var data = null;
                var fileId = \(fileId);
                
                // 方式1: 从 localStorage 获取
                var key = 'RPG File' + fileId;
                data = localStorage.getItem(key);
                if (data && data.length > 100) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.captureArchive) {
                        window.webkit.messageHandlers.captureArchive.postMessage({
                            fileId: fileId,
                            data: data
                        });
                        return;
                    }
                }
                
                // 方式2: 从 StorageManager 获取
                if (typeof StorageManager !== 'undefined' && StorageManager.load) {
                    try {
                        var saveData = StorageManager.load(fileId);
                        if (saveData) {
                            data = JSON.stringify(saveData);
                            if (data && data.length > 100 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.captureArchive) {
                                window.webkit.messageHandlers.captureArchive.postMessage({
                                    fileId: fileId,
                                    data: data
                                });
                                return;
                            }
                        }
                    } catch(e) {}
                }
                
                // 方式3: 从 IndexedDB 获取
                var dbNames = ['RPG_Data', 'SaveData', 'GameData', 'RPGMaker'];
                var storeNames = ['savefiles', 'saves', 'files', 'archive'];
                
                function tryDB(dbName, storeName) {
                    try {
                        var request = indexedDB.open(dbName);
                        request.onsuccess = function(event) {
                            var db = event.target.result;
                            if (!db.objectStoreNames.contains(storeName)) return;
                            var tx = db.transaction(storeName, 'readonly');
                            var store = tx.objectStore(storeName);
                            var getReq = store.get('file' + fileId);
                            getReq.onsuccess = function(e) {
                                var result = e.target.result;
                                if (result) {
                                    var jsonData = JSON.stringify(result);
                                    if (jsonData && jsonData.length > 100 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.captureArchive) {
                                        window.webkit.messageHandlers.captureArchive.postMessage({
                                            fileId: fileId,
                                            data: jsonData
                                        });
                                    }
                                }
                            };
                        };
                    } catch(e) {}
                }
                
                for (var d of dbNames) {
                    for (var s of storeNames) {
                        tryDB(d, s);
                    }
                }
                
                // 方式4: 从全局对象获取
                var globalKeys = ['saveData', '_saveData', 'SaveData', 'savefile', 'SaveFile'];
                for (var g of globalKeys) {
                    if (window[g]) {
                        try {
                            var jsonData = JSON.stringify(window[g]);
                            if (jsonData && jsonData.length > 100 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.captureArchive) {
                                window.webkit.messageHandlers.captureArchive.postMessage({
                                    fileId: fileId,
                                    data: jsonData
                                });
                                return;
                            }
                        } catch(e) {}
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
            
            if dataString.count > 100 {
                do {
                    try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
                    log("✅ 存档保存成功: \(fileName)")
                    
                    let escapedData = dataString.replacingOccurrences(of: "\\", with: "\\\\")
                                                   .replacingOccurrences(of: "'", with: "\\'")
                                                   .replacingOccurrences(of: "\n", with: "\\n")
                                                   .replacingOccurrences(of: "\r", with: "\\r")
                    let script = "localStorage.setItem('RPG File\(fileId)', '\(escapedData)');"
                    webView?.evaluateJavaScript(script, completionHandler: nil)
                    
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
                
                // 检查全局对象
                var globalKeys = ['saveData', '_saveData', 'SaveData', 'savefile', 'SaveFile'];
                globalKeys.forEach(function(key) {
                    if (window[key] !== undefined) {
                        info['window.' + key] = typeof window[key];
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

    // MARK: - 专家模式 JavaScript 桥接
    private static func expertBridgeJavaScript() -> String {
        return """
        (function() {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始 (专家模式)');
            }

            // ==========================================
            // 1. 拦截 IndexedDB - 在页面加载前注入
            // ==========================================
            if (typeof indexedDB !== 'undefined') {
                var originalOpen = indexedDB.open;
                indexedDB.open = function(name, version) {
                    console.log('📂 IndexedDB.open: ' + name);
                    return originalOpen.call(this, name, version);
                };
            }

            // 拦截 IDBObjectStore 的方法
            if (typeof IDBObjectStore !== 'undefined') {
                var originalPut = IDBObjectStore.prototype.put;
                IDBObjectStore.prototype.put = function(value, key) {
                    console.log('📝 IndexedDB.put: ' + this.name + ', key: ' + key);
                    // 尝试捕获数据
                    if (key && typeof key === 'string' && key.indexOf('file') === 0) {
                        var fileId = parseInt(key.replace('file', ''));
                        if (!isNaN(fileId)) {
                            try {
                                var jsonData = JSON.stringify(value);
                                if (jsonData && jsonData.length > 100 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.indexedDBData) {
                                    window.webkit.messageHandlers.indexedDBData.postMessage({
                                        fileId: fileId,
                                        data: jsonData
                                    });
                                }
                            } catch(e) {}
                        }
                    }
                    return originalPut.call(this, value, key);
                };
            }

            // ==========================================
            // 2. 拦截 localStorage
            // ==========================================
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

            // ==========================================
            // 3. 拦截 StorageManager
            // ==========================================
            if (typeof StorageManager !== 'undefined') {
                var originalSave = StorageManager.save;
                StorageManager.save = function(savefile) {
                    var result = originalSave.call(this, savefile);
                    var fileId = savefile.savefileId || savefile.id || 1;
                    
                    // 延迟后尝试捕获完整数据
                    setTimeout(function() {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.captureArchive) {
                            window.webkit.messageHandlers.captureArchive.postMessage({
                                fileId: fileId,
                                data: JSON.stringify(savefile)
                            });
                        }
                    }, 100);
                    
                    return result;
                };
            }

            // ==========================================
            // 4. 添加全局捕获函数
            // ==========================================
            window._captureArchive = function(fileId, data) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.captureArchive) {
                    window.webkit.messageHandlers.captureArchive.postMessage({
                        fileId: fileId,
                        data: data
                    });
                }
            };

            console.log('✅ 专家模式拦截已启动');
        })();
        """
    }
}
