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
        contentController.add(context.coordinator, name: "injectData")

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

        init(gamePath: URL) {
            self.gamePath = gamePath
            self.saveDir = gamePath.appendingPathComponent("save")
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.logFileURL = docs.appendingPathComponent("bridge_log.txt")
            super.init()
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            log("===== Bridge 初始化 (延迟注入版) =====")
            log("游戏路径: \(gamePath.path)")
            log("存档目录: \(saveDir.path)")
            
            // 预加载数据到内存
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
            case "injectData":
                handleInjectData()
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
                    // 更新待注入数据
                    pendingData.append((fileId, dataString))
                } catch {
                    log("❌ 保存失败: \(error)")
                }
            } else {
                log("⚠️ 数据过小 (\(dataString.count) 字节)")
            }
        }

        // MARK: - 加载待注入数据
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
                                log("📄 加载待注入数据: file\(fileId) (\(data.count) 字节)")
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

        // MARK: - ⭐ 处理注入数据（由 JS 触发）
        private func handleInjectData() {
            log("📦 开始注入存档数据到 StorageManager")
            
            guard let webView = webView else {
                log("❌ webView 不可用")
                return
            }
            
            if pendingData.isEmpty {
                log("📭 没有待注入的数据")
                return
            }
            
            var scripts: [String] = []
            for (fileId, data) in pendingData {
                let base64Data = data.data(using: .utf8)?.base64EncodedString() ?? ""
                let script = """
                (function() {
                    try {
                        // 解码数据
                        var decoded = atob('\(base64Data)');
                        
                        // 写入 localStorage
                        var key = 'RPG File\(fileId)';
                        localStorage.setItem(key, decoded);
                        
                        // ⭐ 写入 StorageManager._data
                        if (typeof StorageManager !== 'undefined') {
                            if (!StorageManager._data) {
                                StorageManager._data = {};
                            }
                            var fileKey = 'file' + \(fileId);
                            try {
                                var parsedData = JSON.parse(decoded);
                                StorageManager._data[fileKey] = parsedData;
                                console.log('✅ StorageManager._data[fileKey] 注入成功');
                            } catch(e) {
                                console.error('解析数据失败:', e);
                                StorageManager._data[fileKey] = decoded;
                            }
                        }
                        
                        // 触发存档列表刷新
                        try {
                            if (typeof SceneManager !== 'undefined' && SceneManager._scene) {
                                var scene = SceneManager._scene;
                                if (scene && scene.refresh) {
                                    scene.refresh();
                                }
                            }
                        } catch(e) {}
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
                    
                    // 验证注入结果
                    let verifyScript = """
                    (function() {
                        var result = {};
                        try {
                            if (typeof StorageManager !== 'undefined' && StorageManager._data) {
                                for (var key in StorageManager._data) {
                                    if (key.indexOf('file') === 0) {
                                        result[key] = StorageManager._data[key] ? '存在' : '空';
                                    }
                                }
                            }
                        } catch(e) {}
                        var msg = 'StorageManager._data: ' + JSON.stringify(result);
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                            window.webkit.messageHandlers.debugLog.postMessage(msg);
                        }
                    })();
                    """
                    webView.evaluateJavaScript(verifyScript, completionHandler: nil)
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
            
            // ⭐ 延迟 1 秒后注入数据（等待 StorageManager 初始化完成）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.handleInjectData()
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
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始 (延迟注入版)');
            }

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
            
            // ⭐ 通知 Native 可以注入数据了
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.injectData) {
                window.webkit.messageHandlers.injectData.postMessage('ready');
            }

            console.log('✅ 延迟注入版已启动');
        })();
        """
    }
}
