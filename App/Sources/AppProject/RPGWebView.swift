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
        contentController.add(context.coordinator, name: "debugLog")
        contentController.add(context.coordinator, name: "saveData")
        contentController.add(context.coordinator, name: "gameReady")

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
        private var pendingData: [(fileId: Int, data: String)] = []
        private var hasAttemptedLoad = false

        init(gamePath: URL) {
            self.gamePath = gamePath
            self.saveDir = gamePath.appendingPathComponent("save")
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.logFileURL = docs.appendingPathComponent("bridge_log.txt")
            super.init()
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            log("===== Bridge 初始化 (自动读档版) =====")
            log("游戏路径: \(gamePath.path)")
            log("存档目录: \(saveDir.path)")
            loadPendingData()
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
            case "debugLog":
                log("🐛 \(message.body)")
            case "saveData":
                handleSaveData(message: message)
            case "gameReady":
                handleGameReady()
            default:
                log("⚠️ 未知消息: \(message.name)")
            }
        }

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
                    if let index = pendingData.firstIndex(where: { $0.fileId == fileId }) {
                        pendingData[index].data = dataString
                    } else {
                        pendingData.append((fileId, dataString))
                    }
                } catch {
                    log("❌ 保存失败: \(error)")
                }
            } else {
                log("⚠️ 数据过小 (\(dataString.count) 字节)")
            }
        }

        private func loadPendingData() {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: saveDir.path) else {
                log("📭 save 目录不存在")
                return
            }
            
            do {
                let files = try fileManager.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil)
                for fileURL in files {
                    let fileName = fileURL.lastPathComponent
                    if fileName.hasPrefix("file") && fileName.hasSuffix(".rpgsave") {
                        let fileIdStr = fileName.replacingOccurrences(of: "file", with: "").replacingOccurrences(of: ".rpgsave", with: "")
                        if let fileId = Int(fileIdStr) {
                            do {
                                let data = try String(contentsOf: fileURL, encoding: .utf8)
                                pendingData.append((fileId, data))
                                log("📄 加载存档: file\(fileId) (\(data.count) 字节)")
                            } catch {
                                log("⚠️ 读取文件失败: \(fileName)")
                            }
                        }
                    }
                }
            } catch {
                log("❌ 扫描存档目录失败: \(error)")
            }
        }

        // MARK: - ⭐ 游戏就绪后尝试自动读档
        private func handleGameReady() {
            log("🎮 游戏已就绪，尝试自动读档...")
            
            guard let webView = webView else {
                log("❌ webView 不可用")
                return
            }
            
            // 先注入数据
            injectData()
            
            // 延迟后尝试模拟点击读档
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.tryLoadGame()
            }
        }

        // MARK: - 注入数据到 StorageManager
        private func injectData() {
            guard let webView = webView, !pendingData.isEmpty else {
                return
            }
            
            log("📦 注入存档数据到 StorageManager")
            
            var scripts: [String] = []
            for (fileId, data) in pendingData {
                let base64Data = data.data(using: .utf8)?.base64EncodedString() ?? ""
                let script = """
                (function() {
                    try {
                        var decoded = atob('\(base64Data)');
                        localStorage.setItem('RPG File\(fileId)', decoded);
                        if (typeof StorageManager !== 'undefined') {
                            if (!StorageManager._data) {
                                StorageManager._data = {};
                            }
                            try {
                                StorageManager._data['file\(fileId)'] = JSON.parse(decoded);
                            } catch(e) {
                                StorageManager._data['file\(fileId)'] = decoded;
                            }
                        }
                        console.log('✅ 数据注入成功: file\(fileId)');
                    } catch(e) {
                        console.error('注入失败:', e);
                    }
                })();
                """
                scripts.append(script)
            }
            
            let combinedScript = scripts.joined(separator: " ")
            webView.evaluateJavaScript(combinedScript) { _, error in
                if let error = error {
                    self.log("❌ 注入失败: \(error)")
                } else {
                    self.log("✅ 数据注入成功 (\(self.pendingData.count) 个存档)")
                }
            }
        }

        // MARK: - ⭐ 尝试加载游戏
        private func tryLoadGame() {
            guard let webView = webView, !hasAttemptedLoad else {
                return
            }
            hasAttemptedLoad = true
            
            log("🔄 尝试加载存档...")
            
            let script = """
            (function() {
                try {
                    // 尝试通过 DataManager 加载游戏
                    if (typeof DataManager !== 'undefined' && DataManager.loadGame) {
                        var result = DataManager.loadGame(1);
                        if (result) {
                            console.log('✅ DataManager.loadGame(1) 成功');
                            // 尝试进入游戏场景
                            if (typeof SceneManager !== 'undefined') {
                                SceneManager.goto(Scene_Map);
                                console.log('✅ 已切换到游戏场景');
                            }
                            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                                window.webkit.messageHandlers.debugLog.postMessage('✅ 自动读档成功');
                            }
                            return;
                        }
                    }
                    
                    // 备用方法：通过 StorageManager.load
                    if (typeof StorageManager !== 'undefined' && StorageManager.load) {
                        var saveData = StorageManager.load(1);
                        if (saveData) {
                            console.log('✅ StorageManager.load(1) 成功');
                            // 尝试恢复游戏
                            if (typeof DataManager !== 'undefined' && DataManager.setupNewGame) {
                                // 不执行新游戏，尝试恢复
                            }
                            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                                window.webkit.messageHandlers.debugLog.postMessage('✅ StorageManager 数据存在');
                            }
                        }
                    }
                } catch(e) {
                    console.error('自动读档失败:', e);
                }
            })();
            """
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    self.log("❌ 自动读档失败: \(error)")
                }
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
            
            // 延迟后注入数据
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.injectData()
            }
            
            // 延迟后通知游戏就绪
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let webView = self.webView {
                    let readyScript = """
                    (function() {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.gameReady) {
                            window.webkit.messageHandlers.gameReady.postMessage('ready');
                        }
                    })();
                    """
                    webView.evaluateJavaScript(readyScript, completionHandler: nil)
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
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始 (自动读档版)');
            }

            // 拦截保存
            if (typeof StorageManager !== 'undefined') {
                var originalSave = StorageManager.save;
                StorageManager.save = function(savefile) {
                    var result = originalSave.call(this, savefile);
                    var fileId = savefile.savefileId || savefile.id || 1;
                    setTimeout(function() {
                        try {
                            var key = 'RPG File' + fileId;
                            var data = localStorage.getItem(key);
                            if (data && data.length > 100 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveData) {
                                window.webkit.messageHandlers.saveData.postMessage({
                                    fileId: fileId,
                                    data: data
                                });
                            }
                        } catch(e) {}
                    }, 500);
                    return result;
                };
            }

            // 拦截 localStorage.setItem
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
                    }
                }
            };

            console.log('✅ 自动读档版已启动');
        })();
        """
    }
}
