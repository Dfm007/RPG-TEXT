import SwiftUI
import WebKit

class CustomWKWebView: WKWebView {
    let saveDir: URL
    let coordinator: RPGWebView.Coordinator
    
    init(frame: CGRect, configuration: WKWebViewConfiguration, saveDir: URL, coordinator: RPGWebView.Coordinator) {
        self.saveDir = saveDir
        self.coordinator = coordinator
        super.init(frame: frame, configuration: configuration)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadFileURL(_ URL: URL, allowingReadAccessTo readAccessURL: URL) -> WKNavigation? {
        // ⭐ 读取 HTML 内容并注入脚本
        if let html = try? String(contentsOf: URL, encoding: .utf8) {
            // 构建注入脚本
            let injectionScript = coordinator.buildInjectionScript()
            
            // 在 </head> 之前插入脚本
            var modifiedHTML = html
            if let headRange = html.range(of: "</head>") {
                let insertScript = """
                <script>
                (function() {
                    // 预加载存档数据
                    \(injectionScript)
                })();
                </script>
                </head>
                """
                modifiedHTML = html.replacingCharacters(in: headRange, with: insertScript)
            }
            
            // 使用 loadHTMLString 加载修改后的 HTML
            return loadHTMLString(modifiedHTML, baseURL: URL.deletingLastPathComponent())
        }
        
        return super.loadFileURL(URL, allowingReadAccessTo: readAccessURL)
    }
}

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

        let bridgeScript = WKUserScript(
            source: RPGWebView.bridgeJavaScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(bridgeScript)

        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = CustomWKWebView(
            frame: .zero,
            configuration: config,
            saveDir: context.coordinator.saveDir,
            coordinator: context.coordinator
        )
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
        private var archiveData: [(fileId: Int, data: String)] = []

        init(gamePath: URL) {
            self.gamePath = gamePath
            self.saveDir = gamePath.appendingPathComponent("save")
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.logFileURL = docs.appendingPathComponent("bridge_log.txt")
            super.init()
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            log("===== Bridge 初始化 (HTML注入版) =====")
            log("游戏路径: \(gamePath.path)")
            log("存档目录: \(saveDir.path)")
            
            // 加载存档数据
            loadArchiveData()
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
                    // 更新存档数据
                    if let index = archiveData.firstIndex(where: { $0.fileId == fileId }) {
                        archiveData[index].data = dataString
                    } else {
                        archiveData.append((fileId, dataString))
                    }
                } catch {
                    log("❌ 保存失败: \(error)")
                }
            } else {
                log("⚠️ 数据过小 (\(dataString.count) 字节)")
            }
        }

        // MARK: - 加载存档数据
        private func loadArchiveData() {
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
                                archiveData.append((fileId, data))
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

        // MARK: - ⭐ 构建注入脚本（注入到 HTML 中）
        func buildInjectionScript() -> String {
            var scripts: [String] = []
            
            for (fileId, data) in archiveData {
                let base64Data = data.data(using: .utf8)?.base64EncodedString() ?? ""
                let script = """
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
                    console.log('✅ HTML注入: file\(fileId)');
                } catch(e) {
                    console.error('HTML注入失败:', e);
                }
                """
                scripts.append(script)
            }
            
            return scripts.joined(separator: "\n")
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
            
            // 验证 StorageManager._data
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let verifyScript = """
                (function() {
                    var result = {};
                    try {
                        if (typeof StorageManager !== 'undefined' && StorageManager._data) {
                            for (var key in StorageManager._data) {
                                if (key.indexOf('file') === 0) {
                                    result[key] = '存在';
                                }
                            }
                        }
                    } catch(e) {}
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                        window.webkit.messageHandlers.debugLog.postMessage('StorageManager._data: ' + JSON.stringify(result));
                    }
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
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始 (HTML注入版)');
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

            console.log('✅ HTML注入版已启动');
        })();
        """
    }
}
