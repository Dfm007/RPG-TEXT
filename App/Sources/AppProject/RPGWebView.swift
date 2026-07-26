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

        // 注册消息处理器
        contentController.add(context.coordinator, name: "saveGameFile")
        contentController.add(context.coordinator, name: "loadGameFile")
        contentController.add(context.coordinator, name: "bridgeReady") // 新增：用于接收JS确认

        // 注入桥接 JS（页面加载前）
        let bridgeScript = WKUserScript(
            source: getBridgeJavaScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(bridgeScript)

        config.userContentController = contentController

        // 允许从文件URL访问其他文件（解决加载data/目录的问题）
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        let indexURL = gamePath.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            webView.loadFileURL(indexURL, allowingReadAccessTo: gamePath)
            context.coordinator.log("✅ 加载 index.html: \(indexURL.path)")
        } else {
            context.coordinator.log("❌ 未找到 index.html")
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

        override init() {
            fatalError("use init(gamePath:)")
        }

        init(gamePath: URL) {
            self.gamePath = gamePath
            self.saveDir = gamePath.appendingPathComponent("save")
            // 日志文件放在 Documents 目录下
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.logFileURL = docs.appendingPathComponent("bridge_log.txt")
            super.init()
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            // 清空旧日志（可选）
            // try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
            log("===== Bridge 初始化 =====")
            log("游戏路径: \(gamePath.path)")
            log("存档目录: \(saveDir.path)")
        }

        // 写入日志（追加）
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

        // 接收来自 JS 的消息
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "saveGameFile":
                handleSaveGameFile(message: message)
            case "loadGameFile":
                handleLoadGameFile(message: message)
            case "bridgeReady":
                handleBridgeReady(message: message)
            default:
                log("⚠️ 未知消息: \(message.name)")
            }
        }

        // 保存存档
        private func handleSaveGameFile(message: WKScriptMessage) {
            log("📩 收到 saveGameFile 消息")
            guard let dict = message.body as? [String: Any],
                  let fileName = dict["fileName"] as? String,
                  let dataString = dict["data"] as? String else {
                log("⚠️ 保存消息格式错误: \(message.body)")
                return
            }
            log("📄 文件名: \(fileName), 数据长度: \(dataString.count)")
            let fileURL = saveDir.appendingPathComponent(fileName)
            do {
                try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
                log("✅ 存档已写入: \(fileURL.lastPathComponent)")
            } catch {
                log("❌ 写入存档失败: \(error)")
            }
        }

        private func handleLoadGameFile(message: WKScriptMessage) {
            // 暂不实现
        }

        // 接收 JS 桥接就绪确认
        private func handleBridgeReady(message: WKScriptMessage) {
            log("✅ JS 桥接已就绪: \(message.body)")
        }

        // 页面加载完成
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            log("🌐 页面加载完成")
            // 注入额外的检测脚本，确认 StorageManager 是否被覆盖
            let checkScript = """
            (function() {
                if (typeof StorageManager !== 'undefined' && StorageManager.save !== undefined) {
                    var msg = 'StorageManager 存在，save 方法已覆盖';
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                        window.webkit.messageHandlers.bridgeReady.postMessage(msg);
                    }
                } else {
                    var msg = 'StorageManager 不存在或 save 未覆盖';
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                        window.webkit.messageHandlers.bridgeReady.postMessage(msg);
                    }
                }
            })();
            """
            webView.evaluateJavaScript(checkScript) { _, error in
                if let error = error {
                    self.log("❌ 检测脚本执行失败: \(error)")
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log("❌ 页面加载失败: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            log("❌ 页面加载（临时）失败: \(error)")
        }
    }

    // MARK: - 桥接 JavaScript
    private func getBridgeJavaScript() -> String {
        return """
        (function() {
            // 先通知 Native 脚本已执行
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 脚本已注入开始');
            }

            if (typeof StorageManager === 'undefined') {
                console.warn('StorageManager not found, bridge may not work.');
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                    window.webkit.messageHandlers.bridgeReady.postMessage('StorageManager 未定义');
                }
                return;
            }

            var originalSave = StorageManager.save;
            StorageManager.save = function(savefile) {
                var fileId = savefile.savefileId || 1;
                var fileName = 'file' + fileId + '.rpgsave';
                var data = JSON.stringify(savefile);

                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveGameFile) {
                    try {
                        window.webkit.messageHandlers.saveGameFile.postMessage({
                            fileName: fileName,
                            data: data
                        });
                        console.log('📤 存档已发送到 Native：' + fileName);
                    } catch (e) {
                        console.error('发送存档失败:', e);
                    }
                } else {
                    console.warn('Native bridge not available, fallback to localStorage');
                }

                // 仍然调用原始方法
                return originalSave.call(this, savefile);
            };

            // 通知 Native 桥接成功
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('桥接已成功覆盖 StorageManager.save');
            }
            console.log('✅ RPG Maker 文件桥接已注入 (保存拦截)');
        })();
        """
    }
}
