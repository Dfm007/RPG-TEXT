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

        let preloadScript = context.coordinator.buildPreloadScript()
        if !preloadScript.isEmpty {
            let preloadUserScript = WKUserScript(
                source: preloadScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            contentController.addUserScript(preloadUserScript)
            context.coordinator.log("📦 StorageManager 预加载脚本已注入")
        }

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
            log("===== Bridge 初始化 (StorageManager直接注入版) =====")
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
            case "debugLog":
                log("🐛 \(message.body)")
            case "saveData":
                handleSaveData(message: message)
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
                } catch {
                    log("❌ 保存失败: \(error)")
                }
            } else {
                log("⚠️ 数据过小 (\(dataString.count) 字节)")
            }
        }

        // MARK: - ⭐ 构建直接注入 StorageManager._data 的脚本
        func buildPreloadScript() -> String {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: saveDir.path) else {
                return ""
            }
            
            do {
                let files = try fileManager.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil)
                var scripts: [String] = []
                
                for fileURL in files {
                    let fileName = fileURL.lastPathComponent
                    if fileName.hasPrefix("file") && fileName.hasSuffix(".rpgsave") {
                        let fileIdStr = fileName.replacingOccurrences(of: "file", with: "").replacingOccurrences(of: ".rpgsave", with: "")
                        if let fileId = Int(fileIdStr) {
                            do {
                                let data = try String(contentsOf: fileURL, encoding: .utf8)
                                let base64Data = data.data(using: .utf8)?.base64EncodedString() ?? ""
                                let key = "RPG File\(fileId)"
                                
                                // ⭐ 同时注入 localStorage 和 StorageManager._data
                                let script = """
                                (function() {
                                    try {
                                        // 1. 解码数据
                                        var decoded = atob('\(base64Data)');
                                        
                                        // 2. 写入 localStorage
                                        localStorage.setItem('\(key)', decoded);
                                        
                                        // 3. ⭐ 直接写入 StorageManager._data
                                        if (typeof StorageManager !== 'undefined') {
                                            if (!StorageManager._data) {
                                                StorageManager._data = {};
                                            }
                                            var fileKey = 'file' + \(fileId);
                                            try {
                                                var parsedData = JSON.parse(decoded);
                                                StorageManager._data[fileKey] = parsedData;
                                                console.log('✅ 直接注入 StorageManager._data[fileKey] 成功');
                                            } catch(e) {
                                                console.error('解析数据失败:', e);
                                                // 如果解析失败，直接存储字符串
                                                StorageManager._data[fileKey] = decoded;
                                            }
                                        }
                                    } catch(e) {
                                        console.error('预加载失败:', e);
                                    }
                                })();
                                """
                                scripts.append(script)
                                log("📄 预加载脚本: \(key) (\(data.count) 字节)")
                            } catch {
                                log("⚠️ 读取文件失败: \(fileName)")
                            }
                        }
                    }
                }
                
                return scripts.joined(separator: " ")
            } catch {
                log("❌ 扫描存档目录失败: \(error)")
                return ""
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
            
            // ⭐ 验证 StorageManager._data
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let verifyScript = """
                (function() {
                    var result = {};
                    try {
                        if (typeof StorageManager !== 'undefined' && StorageManager._data) {
                            for (var key in StorageManager._data) {
                                if (key.indexOf('file') === 0) {
                                    var data = StorageManager._data[key];
                                    result[key] = data ? '存在' : '空';
                                }
                            }
                        }
                    } catch(e) {}
                    
                    var msg = 'StorageManager._data: ' + JSON.stringify(result);
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                        window.webkit.messageHandlers.debugLog.postMessage(msg);
                    }
                    
                    // ⭐ 尝试触发存档列表刷新
                    try {
                        if (typeof SceneManager !== 'undefined' && SceneManager._scene) {
                            var scene = SceneManager._scene;
                            if (scene && scene.refresh) {
                                scene.refresh();
                                console.log('✅ 已触发场景刷新');
                            }
                        }
                    } catch(e) {}
                })();
                """
                webView.evaluateJavaScript(verifyScript, completionHandler: nil)
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
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始 (StorageManager直接注入版)');
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

            console.log('✅ StorageManager直接注入版已启动');
        })();
        """
    }
}
