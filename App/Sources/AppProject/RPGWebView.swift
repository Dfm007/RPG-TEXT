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
        contentController.add(context.coordinator, name: "debugLog")  // 新增调试

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
            log("===== Bridge 初始化 =====")
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
            default:
                log("⚠️ 未知消息: \(message.name)")
            }
        }

        // MARK: - 保存存档
        private func handleSave(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let fileId = dict["fileId"] as? Int,
                  let dataString = dict["data"] as? String else {
                log("⚠️ 保存消息格式错误: \(message.body)")
                return
            }
            
            let fileName = "file\(fileId).rpgsave"
            let fileURL = saveDir.appendingPathComponent(fileName)
            
            log("📝 保存存档 ID: \(fileId), 数据长度: \(dataString.count)")
            do {
                try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
                log("✅ 写入成功: \(fileName)")
            } catch {
                log("❌ 写入失败: \(error)")
            }
        }

        // MARK: - 预加载存档到 localStorage
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

            let script = RPGWebView.bridgeJavaScript()
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    self.log("❌ 重新注入失败: \(error)")
                } else {
                    self.log("✅ 重新注入成功")
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // 触发预加载
                let triggerScript = """
                (function() {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.preloadArchives) {
                        window.webkit.messageHandlers.preloadArchives.postMessage('preload');
                    }
                })();
                """
                webView.evaluateJavaScript(triggerScript, completionHandler: nil)
            }
            
            // 持续监控 localStorage 变化（用于调试）
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                let checkStorageScript = """
                (function() {
                    var keys = [];
                    for (var i = 0; i < localStorage.length; i++) {
                        var key = localStorage.key(i);
                        if (key && key.indexOf('RPG') !== -1) {
                            keys.push(key + ':' + localStorage.getItem(key).length);
                        }
                    }
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                        window.webkit.messageHandlers.debugLog.postMessage('localStorage 内容: ' + keys.join(', '));
                    }
                })();
                """
                webView.evaluateJavaScript(checkStorageScript, completionHandler: nil)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log("❌ 导航失败: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            log("❌ 临时加载失败: \(error)")
        }
    }

    // MARK: - JavaScript 桥接（增强日志版）
    private static func bridgeJavaScript() -> String {
        return """
        (function() {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始');
            }

            if (typeof StorageManager === 'undefined') {
                console.warn('StorageManager not found');
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                    window.webkit.messageHandlers.bridgeReady.postMessage('StorageManager 未定义');
                }
                return;
            }

            // ========== 拦截所有可能的保存方法 ==========
            var originalSave = StorageManager.save;
            
            // 1. 拦截 StorageManager.save
            StorageManager.save = function(savefile) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                    window.webkit.messageHandlers.debugLog.postMessage('StorageManager.save 被调用, fileId: ' + (savefile.savefileId || '未知'));
                }
                
                var result = originalSave.call(this, savefile);
                
                var fileId = savefile.savefileId || 1;
                var key = "RPG File" + fileId;
                var data = localStorage.getItem(key);
                
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                    window.webkit.messageHandlers.debugLog.postMessage('从 localStorage 读取: ' + key + ', 长度: ' + (data ? data.length : 0));
                }
                
                if (data && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveGameFile) {
                    window.webkit.messageHandlers.saveGameFile.postMessage({
                        fileId: fileId,
                        data: data
                    });
                    console.log('📤 存档已发送到 Native，ID: ' + fileId);
                }
                
                return result;
            };

            // 2. 拦截可能的直接 localStorage 操作（通过监控 setItem）
            var originalSetItem = localStorage.setItem;
            localStorage.setItem = function(key, value) {
                originalSetItem.call(this, key, value);
                
                // 如果设置的是 RPG File 相关的 key
                if (key && key.indexOf('RPG File') === 0) {
                    var fileId = parseInt(key.replace('RPG File', ''));
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                        window.webkit.messageHandlers.debugLog.postMessage('localStorage.setItem: ' + key + ', 长度: ' + value.length);
                    }
                    
                    // 同时保存到文件
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveGameFile) {
                        window.webkit.messageHandlers.saveGameFile.postMessage({
                            fileId: fileId,
                            data: value
                        });
                        console.log('📤 localStorage 变化已备份，ID: ' + fileId);
                    }
                }
            };

            // 3. 保存原始 load（不修改）
            // 游戏直接从 localStorage 读取

            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('✅ 桥接注入完成（增强监控版）');
            }
            console.log('✅ 桥接注入完成 - 增强监控版');
        })();
        """
    }
}
