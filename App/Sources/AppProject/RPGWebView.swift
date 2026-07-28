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
        contentController.add(context.coordinator, name: "notifyGame")

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
        private var preloadedFileIds: Set<Int> = []

        init(gamePath: URL) {
            self.gamePath = gamePath
            self.saveDir = gamePath.appendingPathComponent("save")
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.logFileURL = docs.appendingPathComponent("bridge_log.txt")
            super.init()
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            log("===== Bridge 初始化 (最终版) =====")
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
            case "notifyGame":
                handleNotifyGame(message: message)
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
                    preloadedFileIds.insert(fileId)
                } catch {
                    log("❌ 保存失败: \(error)")
                }
            } else {
                log("⚠️ 数据过小 (\(dataString.count) 字节)")
            }
        }

        // MARK: - 通知游戏有存档
        private func handleNotifyGame(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let fileId = dict["fileId"] as? Int,
                  let result = dict["result"] as? String else {
                log("⚠️ notifyGame 数据格式错误")
                return
            }
            log("📢 通知游戏结果: file\(fileId) -> \(result)")
        }

        // MARK: - 预加载存档
        private func handlePreloadArchives() {
            log("📦 预加载存档到 localStorage")
            
            guard let webView = webView else {
                log("❌ webView 不可用")
                return
            }
            
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: saveDir.path) else {
                log("📭 save 目录不存在")
                return
            }
            
            do {
                let files = try fileManager.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil)
                var jsScripts: [String] = []
                var loadedCount = 0
                var loadedFileIds: [Int] = []
                
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
                                loadedFileIds.append(fileId)
                                log("📄 预加载: \(key) (\(data.count) 字节)")
                            } catch {
                                log("⚠️ 读取文件失败: \(fileName): \(error)")
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
                            
                            // ⭐ 关键：预加载完成后，通知游戏有存档
                            for fileId in loadedFileIds {
                                self.notifyGameHasSave(fileId: fileId)
                            }
                            
                            // 验证 localStorage
                            let verifyScript = """
                            (function() {
                                var keys = [];
                                for (var i = 0; i < localStorage.length; i++) {
                                    var key = localStorage.key(i);
                                    if (key && key.indexOf('RPG File') === 0) {
                                        keys.push(key + ':' + localStorage.getItem(key).length);
                                    }
                                }
                                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                                    window.webkit.messageHandlers.debugLog.postMessage('localStorage 验证: ' + keys.join(', '));
                                }
                            })();
                            """
                            webView.evaluateJavaScript(verifyScript, completionHandler: nil)
                        }
                    }
                } else {
                    log("📭 没有找到存档文件")
                }
            } catch {
                log("❌ 扫描存档目录失败: \(error)")
            }
        }
        
        // MARK: - ⭐ 通知游戏有存档
        private func notifyGameHasSave(fileId: Int) {
            guard let webView = webView else {
                log("❌ webView 不可用")
                return
            }
            
            log("📢 通知游戏有存档: file\(fileId)")
            
            // 尝试多种方式通知游戏
            let script = """
            (function() {
                var fileId = \(fileId);
                var success = false;
                
                // 方式1: 调用 StorageManager.exists（如果存在）
                try {
                    if (typeof StorageManager !== 'undefined' && StorageManager.exists) {
                        var exists = StorageManager.exists(fileId);
                        if (exists) {
                            success = true;
                            console.log('✅ StorageManager.exists 返回 true');
                        }
                    }
                } catch(e) {}
                
                // 方式2: 直接调用 StorageManager.load 并检查结果
                try {
                    if (typeof StorageManager !== 'undefined' && StorageManager.load) {
                        var data = StorageManager.load(fileId);
                        if (data) {
                            success = true;
                            console.log('✅ StorageManager.load 返回数据');
                        }
                    }
                } catch(e) {}
                
                // 方式3: 触发游戏界面刷新
                try {
                    // 如果是 RPG Maker，触发场景刷新
                    if (typeof SceneManager !== 'undefined') {
                        // 重新检查存档
                        if (typeof DataManager !== 'undefined' && DataManager.loadGame) {
                            // 不实际加载，只是让游戏重新检查
                        }
                        success = true;
                    }
                } catch(e) {}
                
                // 通知 Native
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.notifyGame) {
                    window.webkit.messageHandlers.notifyGame.postMessage({
                        fileId: fileId,
                        result: success ? '成功' : '失败'
                    });
                }
            })();
            """
            webView.evaluateJavaScript(script, completionHandler: nil)
            
            // ⭐ 延迟后再尝试一次（给游戏时间初始化）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let retryScript = """
                (function() {
                    var fileId = \(fileId);
                    try {
                        // 尝试刷新存档列表
                        if (typeof SceneManager !== 'undefined' && SceneManager._scene) {
                            var scene = SceneManager._scene;
                            if (scene && scene.refresh) {
                                scene.refresh();
                                console.log('✅ 刷新场景');
                            }
                            if (scene && scene.createWindowLayer) {
                                // 尝试重新创建窗口
                            }
                        }
                    } catch(e) {}
                    
                    // 再次检查 StorageManager.load
                    try {
                        if (typeof StorageManager !== 'undefined' && StorageManager.load) {
                            var data = StorageManager.load(fileId);
                            if (data && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                                window.webkit.messageHandlers.debugLog.postMessage('延迟检查: StorageManager.load 成功');
                            }
                        }
                    } catch(e) {}
                })();
                """
                webView.evaluateJavaScript(retryScript, completionHandler: nil)
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

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let triggerScript = """
                (function() {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.preloadArchives) {
                        window.webkit.messageHandlers.preloadArchives.postMessage('preload');
                    }
                })();
                """
                webView.evaluateJavaScript(triggerScript, completionHandler: nil)
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
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始 (最终版)');
            }

            // ==========================================
            // 拦截 StorageManager.save
            // ==========================================
            if (typeof StorageManager !== 'undefined') {
                var originalSave = StorageManager.save;
                StorageManager.save = function(savefile) {
                    console.log('📤 StorageManager.save 被调用');
                    var result = originalSave.call(this, savefile);
                    var fileId = savefile.savefileId || savefile.id || 1;
                    
                    setTimeout(function() {
                        try {
                            var key = 'RPG File' + fileId;
                            var data = localStorage.getItem(key);
                            if (data && data.length > 100) {
                                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveData) {
                                    window.webkit.messageHandlers.saveData.postMessage({
                                        fileId: fileId,
                                        data: data
                                    });
                                    console.log('📤 从 localStorage 提取数据成功，长度: ' + data.length);
                                }
                            }
                        } catch(e) {
                            console.error('提取失败:', e);
                        }
                    }, 500);
                    
                    return result;
                };
            }

            // ==========================================
            // 拦截 localStorage.setItem
            // ==========================================
            var originalSetItem = localStorage.setItem;
            localStorage.setItem = function(key, value) {
                originalSetItem.call(this, key, value);
                
                if (key && key.indexOf('RPG File') === 0 && value && value.length > 100) {
                    var fileId = parseInt(key.replace('RPG File', ''));
                    if (!isNaN(fileId) && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveData) {
                        window.webkit.messageHandlers.saveData.postMessage({
                            fileId: fileId,
                            data: value
                        });
                        console.log('📤 localStorage.setItem 直接捕获: ' + key + ', 长度: ' + value.length);
                    }
                }
            };

            console.log('✅ 最终版已启动');
        })();
        """
    }
}
