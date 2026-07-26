import SwiftUI
import WebKit

struct RPGWebView: UIViewRepresentable {
    let gamePath: URL          // 游戏根目录（解压后的文件夹）
    @Binding var isLoading: Bool // 可选，用于加载状态

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        
        // 注册消息处理器（名称必须与 JS 端一致）
        contentController.add(context.coordinator, name: "saveGameFile")
        contentController.add(context.coordinator, name: "loadGameFile") // 为后续读取做准备
        
        // 注入桥接 JS 脚本（在页面加载前执行）
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
        
        // 读取存档（为以后实现“从外部加载”做准备，可先留空）
        private func handleLoadGameFile(message: WKScriptMessage) {
            // 暂不实现，留作扩展
        }
        
        // 可选：页面加载完成后注入额外脚本
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 可以通知 JS 已经准备好，或者注入其他脚本
        }
    }

    // MARK: - 注入的 JavaScript 桥接代码
    private func getBridgeJavaScript() -> String {
        return """
        (function() {
            // 确保 StorageManager 存在
            if (typeof StorageManager === 'undefined') {
                console.warn('StorageManager not found, bridge may not work.');
                return;
            }
            
            // 保存原始方法
            var originalSave = StorageManager.save;
            var originalLoad = StorageManager.load;
            
            // 重写 save
            StorageManager.save = function(savefile) {
                // 获取存档槽位（savefileId 通常为 1~N）
                var fileId = savefile.savefileId || 1;
                var fileName = 'file' + fileId + '.rpgsave';
                // 将存档对象转为 JSON 字符串（与 .rpgsave 内容一致）
                var data = JSON.stringify(savefile);
                
                // 发送给 Native
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveGameFile) {
                    window.webkit.messageHandlers.saveGameFile.postMessage({
                        fileName: fileName,
                        data: data
                    });
                    console.log('📤 存档已发送到 Native：' + fileName);
                } else {
                    console.warn('Native bridge not available, fallback to localStorage');
                }
                
                // 仍然调用原始方法以保持 localStorage 同步（防止游戏代码检查）
                return originalSave.call(this, savefile);
            };
            
            // 重写 load（可扩展为从 Native 读取，但为了简化，这里保持原样，让游戏使用 localStorage）
            // 如果你想实现“外部导入后游戏内自动加载”，可在这里添加逻辑，但我们先不覆盖。
            console.log('✅ RPG Maker 文件桥接已注入 (保存拦截)');
        })();
        """
    }
}
