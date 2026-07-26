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

    // 便利初始化（匹配 ContentView 中的调用）
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

        // 注入桥接 JS
        let bridgeScript = WKUserScript(
            source: getBridgeJavaScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(bridgeScript)
        config.userContentController = contentController

        // ⭐ 关键：允许从文件 URL 访问其他文件
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // 打印路径以帮助调试
        print("📂 游戏路径: \(gamePath.path)")
        let indexURL = gamePath.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            print("✅ index.html 存在")
            webView.loadFileURL(indexURL, allowingReadAccessTo: gamePath)
        } else {
            print("❌ index.html 不存在于: \(indexURL.path)")
        }

        // 回调
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

        init(gamePath: URL) {
            self.gamePath = gamePath
            self.saveDir = gamePath.appendingPathComponent("save")
            super.init()
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "saveGameFile":
                handleSave(message: message)
            case "loadGameFile":
                handleLoad(message: message)
            default:
                break
            }
        }

        private func handleSave(message: WKScriptMessage) {
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

        private func handleLoad(message: WKScriptMessage) {
            // 预留
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 可注入额外脚本
        }
    }

    // MARK: - 桥接 JS
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
                }
                return originalSave.call(this, savefile);
            };
            console.log('✅ RPG Maker 文件桥接已注入');
        })();
        """
    }
}
