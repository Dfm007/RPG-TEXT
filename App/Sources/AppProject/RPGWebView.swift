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
        private var pendingSaves: [Int: Timer] = [:]

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
            case "saveArchiveData":
                handleSaveArchiveData(message: message)
            default:
                log("⚠️ 未知消息: \(message.name)")
            }
        }

        // MARK: - 处理保存请求（延迟读取完整数据）
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
            
            // 取消之前的定时器
            pendingSaves[fileId]?.invalidate()
            
            // 延迟 1.5 秒后从 localStorage 读取完整数据（等待游戏写入完成）
            let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                self?.fetchCompleteArchive(fileId: fileId)
                self?.pendingSaves.removeValue(forKey: fileId)
            }
            pendingSaves[fileId] = timer
        }

        // MARK: - 从 localStorage 获取完整存档数据
        private func fetchCompleteArchive(fileId: Int) {
            guard let webView = webView else {
                log("❌ webView 不可用")
                return
            }
            
            log("🔄 获取完整存档数据, fileId: \(fileId)")
            
            let script = """
            (function() {
                var key = 'RPG File\(fileId)';
                var data = localStorage.getItem(key);
                if (data && data.length > 10 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveArchiveData) {
                    window.webkit.messageHandlers.saveArchiveData.postMessage({
                        fileId: \(fileId),
                        data: data
                    });
                    console.log('📤 完整存档已获取，长度: ' + data.length);
                } else {
                    console.warn('未获取到完整存档数据');
                }
            })();
            """
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        // MARK: - 接收完整存档数据并写入文件
        private func handleSaveArchiveData(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let fileId = dict["fileId"] as? Int,
                  let dataString = dict["data"] as? String else {
                log("⚠️ 存档数据格式错误")
                return
            }
            
            let fileName = "file\(fileId).rpgsave"
            let fileURL = saveDir.appendingPathComponent(fileName)
            
            log("📦 收到完整存档: file\(fileId), 长度: \(dataString.count)")
            
            if dataString.count > 100 {
                do {
                    try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
                    log("✅ 存档保存成功: \(fileName)")
                    
                    // ⭐ 保存成功后进行存储探测
                    probeGameStorage()
                    
                    // 通知 JS 保存完成（可用于 UI 反馈）
                    webView?.evaluateJavaScript("""
                    (function() {
                        if (window._saveCompleteCallback) {
                            window._saveCompleteCallback(\(fileId));
                        }
                    })();
                    """, completionHandler: nil)
                } catch {
                    log("❌ 保存失败: \(error)")
                }
            } else {
                log("⚠️ 数据不完整（长度: \(dataString.count)），可能是占位数据")
            }
        }

        // MARK: - 探测游戏存储结构
        private func probeGameStorage() {
            guard let webView = webView else { return }
            
            let probeScript = """
            (function() {
                var info = {};
                
                // 检查 StorageManager
                if (typeof StorageManager !== 'undefined') {
                    info.StorageManager = '存在';
                    if (StorageManager.save) info.StorageManager_save = '存在';
                    if (StorageManager.load) info.StorageManager_load = '存在';
                    if (StorageManager._data) info.StorageManager_data = '存在';
                }
                
                // 检查 window 上的存档相关变量
                var saveKeys = ['saveData', '_saveData', 'savefile', 'SaveData', 'SaveFile', 'RPG'];
                saveKeys.forEach(function(key) {
                    if (window[key] !== undefined) {
                        info['window.' + key] = typeof window[key];
                    }
                });
                
                // 检查 localStorage 所有 RPG 相关的 key
                var keys = [];
                for (var i = 0; i < localStorage.length; i++) {
                    var key = localStorage.key(i);
                    if (key && key.indexOf('RPG') !== -1) {
                        var value = localStorage.getItem(key);
                        keys.push(key + ':' + (value ? value.length : 0));
                    }
                }
                info.localStorage = keys.join(', ');
                
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.debugLog) {
                    window.webkit.messageHandlers.debugLog.postMessage('📊 存储探测: ' + JSON.stringify(info));
                }
            })();
            """
            webView.evaluateJavaScript(probeScript, completionHandler: nil)
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
                            // ⭐ 预加载完成后进行存储探测
                            self.probeGameStorage()
                        }
                    }
                } else {
                    log("📭 没有找到存档文件")
                    // ⭐ 即使没有存档也进行探测
                    probeGameStorage()
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
                let triggerScript = """
                (function() {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.preloadArchives) {
                        window.webkit.messageHandlers.preloadArchives.postMessage('preload');
                    }
                })();
                """
                webView.evaluateJavaScript(triggerScript, completionHandler: nil)
            }
            
            // 延迟 2 秒后进行一次存储探测（确保游戏完全加载）
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

    // MARK: - JavaScript 桥接
    private static func bridgeJavaScript() -> String {
        return """
        (function() {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始');
            }

            if (typeof StorageManager === 'undefined') {
                console.warn('StorageManager not found');
                return;
            }

            // ========== 拦截 localStorage.setItem ==========
            var originalSetItem = localStorage.setItem;
            localStorage.setItem = function(key, value) {
                // 先调用原始方法
                originalSetItem.call(this, key, value);
                
                // 如果是 RPG File 相关的 key，通知 Native
                if (key && key.indexOf('RPG File') === 0) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveGameFile) {
                        window.webkit.messageHandlers.saveGameFile.postMessage({
                            key: key,
                            data: value || ''
                        });
                        console.log('📤 localStorage 已备份: ' + key);
                    }
                }
            };

            // ========== 拦截 StorageManager.save ==========
            var originalSave = StorageManager.save;
            StorageManager.save = function(savefile) {
                var result = originalSave.call(this, savefile);
                
                // 延迟获取完整数据
                var fileId = savefile.savefileId || savefile.id || 1;
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveGameFile) {
                    // 发送一个占位消息，触发 Native 去获取完整数据
                    setTimeout(function() {
                        var key = 'RPG File' + fileId;
                        var data = localStorage.getItem(key);
                        if (data && data.length > 10) {
                            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveArchiveData) {
                                window.webkit.messageHandlers.saveArchiveData.postMessage({
                                    fileId: fileId,
                                    data: data
                                });
                                console.log('📤 完整存档已获取，长度: ' + data.length);
                            }
                        }
                    }, 500);
                }
                
                return result;
            };

            console.log('✅ 桥接注入完成');
        })();
        """
    }
}
