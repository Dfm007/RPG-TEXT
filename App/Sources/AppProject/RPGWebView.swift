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
        contentController.add(context.coordinator, name: "loadGameFile")
        contentController.add(context.coordinator, name: "bridgeReady")
        contentController.add(context.coordinator, name: "listArchives")

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
            case "loadGameFile":
                handleLoad(message: message)
            case "bridgeReady":
                log("📨 \(message.body)")
            case "listArchives":
                handleListArchives(message: message)
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

        // MARK: - 加载存档
        private func handleLoad(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let fileId = dict["fileId"] as? Int,
                  let callbackId = dict["callbackId"] as? String else {
                log("⚠️ 加载消息格式错误: \(message.body)")
                return
            }
            
            let fileName = "file\(fileId).rpgsave"
            let fileURL = saveDir.appendingPathComponent(fileName)
            
            log("📖 加载存档 ID: \(fileId)")
            
            var dataString = ""
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    dataString = try String(contentsOf: fileURL, encoding: .utf8)
                    log("✅ 读取成功: \(fileName), 长度: \(dataString.count)")
                } catch {
                    log("❌ 读取文件失败: \(error)")
                }
            } else {
                log("⚠️ 文件不存在: \(fileName)")
            }
            
            // 回调 JS
            if let webView = webView {
                // 转义特殊字符
                let escapedData = dataString.replacingOccurrences(of: "\\", with: "\\\\")
                                             .replacingOccurrences(of: "'", with: "\\'")
                                             .replacingOccurrences(of: "\n", with: "\\n")
                                             .replacingOccurrences(of: "\r", with: "\\r")
                
                let jsCallback = """
                (function() {
                    if (window._loadCallbacks && window._loadCallbacks['\(callbackId)']) {
                        window._loadCallbacks['\(callbackId)']('\(escapedData)');
                        delete window._loadCallbacks['\(callbackId)'];
                    }
                })();
                """
                webView.evaluateJavaScript(jsCallback, completionHandler: { _, error in
                    if let error = error {
                        self.log("❌ 回调 JS 失败: \(error)")
                    }
                })
            }
        }

        // MARK: - 列出所有存档
        private func handleListArchives(message: WKScriptMessage) {
            log("📋 列出所有存档")
            
            guard let webView = webView,
                  let dict = message.body as? [String: Any],
                  let callbackId = dict["callbackId"] as? String else {
                return
            }
            
            do {
                let files = try FileManager.default.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil)
                var archiveList: [[String: Any]] = []
                
                for fileURL in files {
                    let fileName = fileURL.lastPathComponent
                    if fileName.hasPrefix("file") && fileName.hasSuffix(".rpgsave") {
                        let fileIdStr = fileName.replacingOccurrences(of: "file", with: "").replacingOccurrences(of: ".rpgsave", with: "")
                        if let fileId = Int(fileIdStr) {
                            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                            let modDate = attrs[.modificationDate] as? Date ?? Date()
                            archiveList.append([
                                "fileId": fileId,
                                "fileName": fileName,
                                "modified": modDate.timeIntervalSince1970
                            ])
                        }
                    }
                }
                
                // 排序
                archiveList.sort { ($0["fileId"] as? Int ?? 0) < ($1["fileId"] as? Int ?? 0) }
                
                // 转换为 JSON
                if let jsonData = try? JSONSerialization.data(withJSONObject: archiveList),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    let jsCallback = """
                    (function() {
                        if (window._listCallbacks && window._listCallbacks['\(callbackId)']) {
                            window._listCallbacks['\(callbackId)'](\(jsonString));
                            delete window._listCallbacks['\(callbackId)'];
                        }
                    })();
                    """
                    webView.evaluateJavaScript(jsCallback, completionHandler: nil)
                    log("✅ 列出 \(archiveList.count) 个存档")
                }
            } catch {
                log("❌ 列出存档失败: \(error)")
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
                // 检查注入状态
                let checkScript = """
                (function() {
                    var status = '未定义';
                    if (typeof StorageManager !== 'undefined') {
                        status = '已定义';
                        if (StorageManager.save) status += ', save已覆盖';
                        if (StorageManager.load) status += ', load已覆盖';
                    }
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                        window.webkit.messageHandlers.bridgeReady.postMessage('StorageManager: ' + status);
                    }
                })();
                """
                webView.evaluateJavaScript(checkScript, completionHandler: nil)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log("❌ 导航失败: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            log("❌ 临时加载失败: \(error)")
        }
    }

    // MARK: - JavaScript 桥接（完全同步）
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

            // 保存原始方法
            var originalSave = StorageManager.save;
            var originalLoad = StorageManager.load;

            // 回调管理
            window._loadCallbacks = {};
            window._listCallbacks = {};

            // ========== 重写 save（同步） ==========
            StorageManager.save = function(savefile) {
                var fileId = savefile.savefileId || 1;
                var data = JSON.stringify(savefile);
                
                // 发送给 Native 保存
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveGameFile) {
                    window.webkit.messageHandlers.saveGameFile.postMessage({
                        fileId: fileId,
                        data: data
                    });
                    console.log('📤 存档已发送到 Native，ID: ' + fileId + ', 长度: ' + data.length);
                }
                
                // 仍然调用原始方法更新 localStorage（保持兼容）
                return originalSave.call(this, savefile);
            };

            // ========== 重写 load（异步转同步，使用 Promise） ==========
            StorageManager.load = function(savefileId) {
                var callbackId = 'load_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
                
                return new Promise(function(resolve, reject) {
                    // 超时处理（3秒）
                    var timeout = setTimeout(function() {
                        console.warn('加载存档超时，使用 localStorage 回退');
                        var result = originalLoad.call(StorageManager, savefileId);
                        resolve(result);
                    }, 3000);

                    window._loadCallbacks[callbackId] = function(dataString) {
                        clearTimeout(timeout);
                        if (dataString && dataString !== '') {
                            try {
                                var savefile = JSON.parse(dataString);
                                // 写入 localStorage 保持缓存一致
                                var key = "RPG File" + savefileId;
                                localStorage.setItem(key, dataString);
                                console.log('✅ 加载成功，ID: ' + savefileId);
                                resolve(savefile);
                            } catch (e) {
                                console.error('解析存档数据失败:', e);
                                var result = originalLoad.call(StorageManager, savefileId);
                                resolve(result);
                            }
                        } else {
                            console.warn('存档不存在，使用 localStorage 回退');
                            var result = originalLoad.call(StorageManager, savefileId);
                            resolve(result);
                        }
                    };

                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.loadGameFile) {
                        window.webkit.messageHandlers.loadGameFile.postMessage({
                            fileId: savefileId,
                            callbackId: callbackId
                        });
                        console.log('📤 请求加载存档 ID: ' + savefileId);
                    } else {
                        console.warn('Native 不可用，使用原始方法');
                        var result = originalLoad.call(StorageManager, savefileId);
                        resolve(result);
                    }
                });
            };

            // ========== 重写 exists（检查存档是否存在） ==========
            if (StorageManager.exists) {
                var originalExists = StorageManager.exists;
                StorageManager.exists = function(savefileId) {
                    var key = "RPG File" + savefileId;
                    return localStorage.getItem(key) !== null;
                };
            }

            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('✅ StorageManager 已完全覆盖');
            }
            console.log('✅ 桥接注入完成 - 文件读写模式');
        })();
        """
    }
}
