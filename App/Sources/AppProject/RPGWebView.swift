import SwiftUI
import WebKit

struct RPGWebView: UIViewRepresentable {
    let gamePath: URL
    @Binding var isLoading: Bool
    let onWebViewCreated: ((WKWebView) -> Void)?   // 新增：获取 webView 引用

    // 主要初始化（保留原有参数）
    init(gamePath: URL, isLoading: Binding<Bool> = .constant(false), onWebViewCreated: ((WKWebView) -> Void)? = nil) {
        self.gamePath = gamePath
        self._isLoading = isLoading
        self.onWebViewCreated = onWebViewCreated
    }

    // 新增便利初始化，专门匹配 ContentView 中的调用（folderURL 标签 + 尾随闭包）
    init(folderURL: URL, onWebViewCreated: ((WKWebView) -> Void)? = nil) {
        self.gamePath = folderURL
        self._isLoading = .constant(false)   // 默认值
        self.onWebViewCreated = onWebViewCreated
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        // 注册消息处理器
        contentController.add(context.coordinator, name: "saveGameFile")
        contentController.add(context.coordinator, name: "loadGameFile")

        // 注入桥接 JS 脚本（页面加载前执行）
        let bridgeScript = WKUserScript(
            source: getBridgeJavaScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(bridgeScript)

        config.userContentController = contentController
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // 加载 index.html
        let indexURL = gamePath.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            webView.loadFileURL(indexURL, allowingReadAccessTo: gamePath)
        } else {
            print("❌ 未找到 index.html")
        }

        // 回调给外部（用于音频恢复等）
        DispatchQueue.main.async {
            self.onWebViewCreated?(webView)
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 可更新加载状态等
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(gamePath: gamePath)
    }

    // MARK: - Coordinator（处理 Native ↔ JS 通信）
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let gamePath: URL
        let saveDir: URL

        init(gamePath: URL) {
            self.gamePath = gamePath
            self.saveDir = gamePath.appendingPathComponent("save")
            super.init()
            // 确保 save 文件夹存在
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true, attributes: nil)
        }

        // 接收来自 JS 的消息
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "saveGameFile":
                handleSaveGameFile(message: message)
            case "loadGameFile":
                handleLoadGameFile(message: message)
            default:
                break
            }
        }

        // 保存存档
        private func handleSaveGameFile(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let fileName = dict["fileName"] as? String,
                  let dataString = dict["data"] as? String else {
                print("⚠️ 保存消息格式错误")
                return
            }
            let fileURL = saveDir.appendingPathComponent(fileName)
            do {
                try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
                print("✅ 存档已保存：\(fileURL.lastPathComponent)")
            } catch {
                print("❌ 写入存档失败：\(error)")
            }
        }

        // 读取存档（预留）
        private func handleLoadGameFile(message: WKScriptMessage) {
            // 暂不实现，留作扩展
        }

        // 页面加载完成（可选）
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 可以通知 JS 已经准备好，或者注入其他脚本
        }
    }

    // MARK: - 注入的 JavaScript 桥接代码
    private func getBridgeJavaScript() -> String {
        return """
        (function() {
            if (typeof StorageManager === 'undefined') {
                console.warn('StorageManager not found, bridge may not work.');
                return;
            }

            var originalSave = StorageManager.save;
            StorageManager.save = function(savefile) {
                var fileId = savefile.savefileId || 1;
                var fileName = 'file' + fileId + '.rpgsave';
                var data = JSON.stringify(savefile);

                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveGameFile) {
                    window.webkit.messageHandlers.saveGameFile.postMessage({
                        fileName: fileName,
                        data: data
                    });
                    console.log('📤 存档已发送到 Native：' + fileName);
                } else {
                    console.warn('Native bridge not available, fallback to localStorage');
                }

                return originalSave.call(this, savefile);
            };

            console.log('✅ RPG Maker 文件桥接已注入 (保存拦截)');
        })();
        """
    }
}
