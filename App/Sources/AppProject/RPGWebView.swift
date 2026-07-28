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

        // ⭐ 关键：在页面加载前注入预加载脚本
        let bridgeScript = WKUserScript(
            source: RPGWebView.bridgeJavaScript(),
            injectionTime: .atDocumentStart,  // 页面加载前执行
            forMainFrameOnly: false
        )
        contentController.addUserScript(bridgeScript)

        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        let indexURL = gamePath.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            // ⭐ 加载页面
            webView.loadFileURL(indexURL, allowingReadAccessTo: gamePath)
            context.coordinator.log("✅ 加载 index.html")
            
            // ⭐ 立即预加载存档到 localStorage（在页面加载的同时）
            context.coordinator.preloadArchivesImmediately()
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
            log("===== Bridge 初始化 (启动前预加载版) =====")
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

        // MARK: - ⭐ 立即预加载（在页面加载之前）
        func preloadArchivesImmediately() {
            log("📦 立即预加载存档（页面加载前）...")
            
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: saveDir.path) else {
                log("📭 save 目录不存在")
                return
            }
            
            do {
                let files = try fileManager.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil)
                var preloadData: [(key: String, data: String)] = []
                
                for fileURL in files {
                    let fileName = fileURL.lastPathComponent
                    if fileName.hasPrefix("file") && fileName.hasSuffix(".rpgsave") {
                        let fileIdStr = fileName.replacingOccurrences(of: "file", with: "").replacingOccurrences(of: ".rpgsave", with: "")
                        if let fileId = Int(fileIdStr) {
                            do {
                                let data = try String(contentsOf: fileURL, encoding: .utf8)
                                let key = "RPG File\(fileId)"
                                preloadData.append((key, data))
                                log("📄 预加载: \(key) (\(data.count) 字节)")
                            } catch {
                                log("⚠️ 读取文件失败: \(fileName)")
                            }
                        }
                    }
                }
                
                if !preloadData.isEmpty {
                    // ⭐ 存储到内存中，等待 webView 准备好后注入
                    self.pendingPreloadData = preloadData
                    log("✅ 已缓存 \(preloadData.count) 个存档，等待注入")
                } else {
                    log("📭 没有找到存档文件")
                }
            } catch {
                log("❌ 扫描存档目录失败: \(error)")
            }
        }
        
        // ⭐ 存储预加载数据
        private var pendingPreloadData: [(key: String, data: String)] = []

        // MARK: - 预加载存档（由 JS 触发）
        private func handlePreloadArchives() {
            log("📦 JS 触发预加载")
            
            guard let webView = webView else {
                log("❌ webView 不可用")
                return
            }
            
            // 如果有缓存的数据，立即注入
            if !pendingPreloadData.isEmpty {
                var jsScripts: [String] = []
                for (key, data) in pendingPreloadData {
                    let escapedData = data.replacingOccurrences(of: "\\", with: "\\\\")
                                             .replacingOccurrences(of: "'", with: "\\'")
                                             .replacingOccurrences(of: "\n", with: "\\n")
                                             .replacingOccurrences(of: "\r", with: "\\r")
                    let script = "localStorage.setItem('\(key)', '\(escapedData)');"
                    jsScripts.append(script)
                }
                
                let combinedScript = jsScripts.joined(separator: " ")
                webView.evaluateJavaScript(combinedScript) { _, error in
                    if let error = error {
                        self.log("❌ 注入预加载数据失败: \(error)")
                    } else {
                        self.log("✅ 预加载数据注入成功 (\(self.pendingPreloadData.count) 个存档)")
                        self.pendingPreloadData.removeAll()
                    }
                }
            } else {
                log("📭 没有缓存的预加载数据")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            log("🌐 页面加载完成")

            // 注入桥接
            let script = RPGWebView.bridgeJavaScript()
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    self.log("❌ 注入失败: \(error)")
                } else {
                    self.log("✅ 桥接注入成功")
                }
            }

            // 触发预加载
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始 (启动前预加载版)');
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

            // ==========================================
            // 在页面加载时，主动检查 localStorage 并更新 StorageManager
            // ==========================================
            try {
                if (typeof StorageManager !== 'undefined' && StorageManager.load) {
                    for (var i = 1; i <= 5; i++) {
                        var key = 'RPG File' + i;
                        var data = localStorage.getItem(key);
                        if (data && data.length > 100) {
                            console.log('📤 启动时发现存档: ' + key + ', 长度: ' + data.length);
                        }
                    }
                }
            } catch(e) {}

            console.log('✅ 启动前预加载版已启动');
        })();
        """
    }
}
