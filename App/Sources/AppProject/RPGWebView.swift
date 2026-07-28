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
        contentController.add(context.coordinator, name: "extractResult")

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
        private var extractButton: UIButton?

        init(gamePath: URL) {
            self.gamePath = gamePath
            self.saveDir = gamePath.appendingPathComponent("save")
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.logFileURL = docs.appendingPathComponent("bridge_log.txt")
            super.init()
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            log("===== Bridge 初始化 (手动提取版) =====")
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
            case "extractResult":
                handleExtractResult(message: message)
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

        // MARK: - 接收提取结果
        private func handleExtractResult(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let result = dict["result"] as? String else {
                log("⚠️ 提取结果格式错误")
                return
            }
            log("📊 提取结果: \(result)")
        }

        // MARK: - 手动提取存档
        private func manualExtract() {
            guard let webView = webView else {
                log("❌ webView 不可用")
                return
            }
            
            log("🔍 手动提取存档...")
            
            let script = """
            (function() {
                var result = {};
                var found = false;
                
                // 1. 从 StorageManager._data 提取
                try {
                    if (typeof StorageManager !== 'undefined' && StorageManager._data) {
                        var data = StorageManager._data;
                        for (var key in data) {
                            if (key.indexOf('file') === 0) {
                                var fileId = parseInt(key.replace('file', ''));
                                if (!isNaN(fileId) && data[key]) {
                                    var jsonData = JSON.stringify(data[key]);
                                    if (jsonData && jsonData.length > 100) {
                                        result[key] = jsonData.length;
                                        found = true;
                                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveData) {
                                            window.webkit.messageHandlers.saveData.postMessage({
                                                fileId: fileId,
                                                data: jsonData
                                            });
                                        }
                                    }
                                }
                            }
                        }
                    }
                } catch(e) {
                    console.error('_data 提取失败:', e);
                }
                
                // 2. 如果 _data 没有，从 localStorage 提取
                if (!found) {
                    try {
                        for (var i = 0; i < localStorage.length; i++) {
                            var key = localStorage.key(i);
                            if (key && key.indexOf('RPG File') === 0) {
                                var value = localStorage.getItem(key);
                                if (value && value.length > 100) {
                                    var fileId = parseInt(key.replace('RPG File', ''));
                                    if (!isNaN(fileId)) {
                                        result[key] = value.length;
                                        found = true;
                                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveData) {
                                            window.webkit.messageHandlers.saveData.postMessage({
                                                fileId: fileId,
                                                data: value
                                            });
                                        }
                                    }
                                }
                            }
                        }
                    } catch(e) {}
                }
                
                // 3. 如果 _data 和 localStorage 都没有，尝试调用 StorageManager.load
                if (!found) {
                    try {
                        for (var i = 1; i <= 5; i++) {
                            if (typeof StorageManager !== 'undefined' && StorageManager.load) {
                                var loadData = StorageManager.load(i);
                                if (loadData) {
                                    var jsonData = JSON.stringify(loadData);
                                    if (jsonData && jsonData.length > 100) {
                                        result['load_' + i] = jsonData.length;
                                        found = true;
                                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveData) {
                                            window.webkit.messageHandlers.saveData.postMessage({
                                                fileId: i,
                                                data: jsonData
                                            });
                                        }
                                    }
                                }
                            }
                        }
                    } catch(e) {}
                }
                
                // 发送结果报告
                var msg = found ? '✅ 找到存档: ' + JSON.stringify(result) : '❌ 未找到任何存档数据';
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.extractResult) {
                    window.webkit.messageHandlers.extractResult.postMessage({ result: msg });
                }
                console.log(msg);
            })();
            """
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        // MARK: - 添加提取按钮到 WebView
        private func addExtractButton(to webView: WKWebView) {
            // 创建按钮
            let button = UIButton(type: .system)
            button.setTitle("💾 提取存档", for: .normal)
            button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.9)
            button.setTitleColor(.white, for: .normal)
            button.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
            button.layer.cornerRadius = 8
            button.translatesAutoresizingMaskIntoConstraints = false
            
            // 添加点击事件
            button.addTarget(self, action: #selector(extractButtonTapped), for: .touchUpInside)
            
            // 添加到 WebView
            webView.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: webView.trailingAnchor, constant: -20),
                button.bottomAnchor.constraint(equalTo: webView.bottomAnchor, constant: -100),
                button.widthAnchor.constraint(equalToConstant: 120),
                button.heightAnchor.constraint(equalToConstant: 44)
            ])
            
            extractButton = button
            log("✅ 提取按钮已添加")
        }

        @objc private func extractButtonTapped() {
            log("🔄 用户点击提取按钮")
            manualExtract()
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

            // 注入桥接
            let script = RPGWebView.bridgeJavaScript()
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    self.log("❌ 注入失败: \(error)")
                } else {
                    self.log("✅ 桥接注入成功")
                }
            }

            // 延迟预加载
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
            
            // ⭐ 添加提取按钮
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.addExtractButton(to: webView)
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
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始 (手动提取版)');
            }

            // ==========================================
            // 拦截 StorageManager.save（备份）
            // ==========================================
            if (typeof StorageManager !== 'undefined') {
                var originalSave = StorageManager.save;
                StorageManager.save = function(savefile) {
                    console.log('📤 StorageManager.save 被调用');
                    var result = originalSave.call(this, savefile);
                    
                    setTimeout(function() {
                        try {
                            if (StorageManager._data) {
                                var fileId = savefile.savefileId || savefile.id || 1;
                                var key = 'file' + fileId;
                                if (StorageManager._data[key]) {
                                    var jsonData = JSON.stringify(StorageManager._data[key]);
                                    if (jsonData && jsonData.length > 100 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveData) {
                                        window.webkit.messageHandlers.saveData.postMessage({
                                            fileId: fileId,
                                            data: jsonData
                                        });
                                        console.log('📤 StorageManager.save 数据已发送');
                                    }
                                }
                            }
                        } catch(e) {}
                    }, 300);
                    
                    return result;
                };
            }

            // ==========================================
            // 拦截 localStorage.setItem
            // ==========================================
            var originalSetItem = localStorage.setItem;
            localStorage.setItem = function(key, value) {
                originalSetItem.call(this, key, value);
                if (key && key.indexOf('RPG File') === 0) {
                    console.log('📤 localStorage.setItem: ' + key + ', 长度: ' + (value ? value.length : 0));
                }
            };

            console.log('✅ 手动提取版已启动');
            console.log('💡 点击右下角「提取存档」按钮手动保存存档');
        })();
        """
    }
}
