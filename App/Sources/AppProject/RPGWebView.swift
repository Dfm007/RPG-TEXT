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
        contentController.add(context.coordinator, name: "localStorageReport")
        contentController.add(context.coordinator, name: "requestLoadArchive")

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
            case "localStorageReport":
                log("📦 \(message.body)")
            case "requestLoadArchive":
                handleRequestLoadArchive(message: message)
            default:
                log("⚠️ 未知消息: \(message.name)")
            }
        }

        private func handleSave(message: WKScriptMessage) {
            log("📩 收到 saveGameFile")
            guard let dict = message.body as? [String: Any],
                  let fileName = dict["fileName"] as? String,
                  let dataString = dict["data"] as? String else {
                log("⚠️ 格式错误: \(message.body)")
                return
            }
            log("📄 文件名: \(fileName), 数据长度: \(dataString.count)")
            let fileURL = saveDir.appendingPathComponent(fileName)
            do {
                try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
                log("✅ 写入成功: \(fileURL.lastPathComponent)")
            } catch {
                log("❌ 写入失败: \(error)")
            }
        }

        private func handleLoad(message: WKScriptMessage) {
            log("📥 \(message.body)")
        }

        private func handleRequestLoadArchive(message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let fileId = body["fileId"] as? Int,
                  let callbackId = body["callbackId"] as? String else {
                log("⚠️ 加载请求格式错误: \(message.body)")
                return
            }

            log("📥 请求加载存档 ID: \(fileId)")
            let fileName = "file\(fileId).rpgsave"
            let fileURL = saveDir.appendingPathComponent(fileName)

            var dataString: String?
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    dataString = try String(contentsOf: fileURL, encoding: .utf8)
                    log("✅ 读取成功: \(fileName), 长度: \(dataString?.count ?? 0)")
                } catch {
                    log("❌ 读取文件失败: \(error)")
                }
            } else {
                log("⚠️ 文件不存在: \(fileName)")
            }

            // 回调给 JS
            if let webView = webView {
                // 安全转义
                let escapedData = dataString?.replacingOccurrences(of: "'", with: "\\'") ?? ""
                let jsCallback = """
                (function() {
                    if (window.archiveLoadCallbacks && window.archiveLoadCallbacks['\(callbackId)']) {
                        window.archiveLoadCallbacks['\(callbackId)']('\(escapedData)');
                        delete window.archiveLoadCallbacks['\(callbackId)'];
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

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                webView.evaluateJavaScript(script) { _, error in
                    if let error = error {
                        self.log("❌ 延迟注入失败: \(error)")
                    } else {
                        self.log("✅ 延迟注入成功")
                    }
                }
                let checkScript = """
                (function() {
                    var status = '未定义';
                    if (typeof StorageManager !== 'undefined') {
                        status = '已定义，save方法' + (StorageManager.save ? '已覆盖' : '未覆盖');
                        status += ', load方法' + (StorageManager.load ? '已覆盖' : '未覆盖');
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

    // MARK: - Static JavaScript
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

            var originalSave = StorageManager.save;
            var originalLoad = StorageManager.load;

            window.archiveLoadCallbacks = {};

            StorageManager.save = function(savefile) {
                var result = originalSave.call(this, savefile);
                var fileId = savefile.savefileId || 1;
                var storageKey = "RPG File" + fileId;
                var data = localStorage.getItem(storageKey);
                if (data) {
                    var fileName = 'file' + fileId + '.rpgsave';
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveGameFile) {
                        try {
                            window.webkit.messageHandlers.saveGameFile.postMessage({
                                fileName: fileName,
                                data: data
                            });
                            console.log('📤 存档已发送到 Native：' + fileName + ' 长度: ' + data.length);
                        } catch (e) {
                            console.error('发送存档失败:', e);
                        }
                    }
                } else {
                    console.warn('localStorage 中没有 key: ' + storageKey);
                }
                return result;
            };

            StorageManager.load = function(savefileId) {
                var callbackId = 'load_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
                return new Promise(function(resolve, reject) {
                    window.archiveLoadCallbacks[callbackId] = function(data) {
                        if (data) {
                            var key = "RPG File" + savefileId;
                            localStorage.setItem(key, data);
                            console.log('✅ 加载成功: ' + key + ' 长度: ' + data.length);
                            var result = originalLoad.call(StorageManager, savefileId);
                            resolve(result);
                        } else {
                            console.warn('加载存档失败，使用原始方法');
                            var result = originalLoad.call(StorageManager, savefileId);
                            resolve(result);
                        }
                    };
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.requestLoadArchive) {
                        window.webkit.messageHandlers.requestLoadArchive.postMessage({
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
            console.log('✅ 桥接注入完成');
        })();
        """
    }
}
