import SwiftUI
import WebKit

class AutoSaveManager: ObservableObject {
    static let shared = AutoSaveManager()
    
    private let userDefaults = UserDefaults.standard
    private let saveKeyPrefix = "LastGameURL_"
    private let timestampKeyPrefix = "LastGameTimestamp_"
    
    // MARK: - 保存游戏状态（手动调用）
    
    func saveGameState(for gameId: UUID, webView: WKWebView, completion: ((Bool, String?) -> Void)? = nil) {
        // 1. 获取当前 URL
        webView.evaluateJavaScript("window.location.href") { [weak self] result, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ 获取 URL 失败: \(error.localizedDescription)")
                completion?(false, error.localizedDescription)
                return
            }
            
            guard let url = result as? String, !url.isEmpty else {
                print("❌ URL 为空")
                completion?(false, "无法获取当前页面地址")
                return
            }
            
            // 保存 URL 和时间戳
            self.userDefaults.set(url, forKey: self.saveKeyPrefix + gameId.uuidString)
            self.userDefaults.set(Date(), forKey: self.timestampKeyPrefix + gameId.uuidString)
            print("✅ URL 已保存: \(url)")
            
            // 2. 尝试调用 RPG Maker 的 StorageManager.save()
            webView.evaluateJavaScript("""
                (function() {
                    if (typeof StorageManager !== 'undefined' && StorageManager.save) {
                        StorageManager.save();
                        return 'StorageManager.save() 已执行';
                    }
                    if (typeof SceneManager !== 'undefined' && SceneManager._scene && SceneManager._scene.save) {
                        SceneManager._scene.save();
                        return 'SceneManager._scene.save() 已执行';
                    }
                    return '未找到保存方法，仅保存了页面地址';
                })();
            """) { result, error in
                let message = result as? String ?? "保存完成"
                print("📝 \(message)")
                completion?(true, message)
            }
        }
    }
    
    // MARK: - 恢复游戏状态（手动调用）
    
    func restoreGameState(for gameId: UUID, webView: WKWebView, completion: ((Bool, String?) -> Void)? = nil) {
        let key = saveKeyPrefix + gameId.uuidString
        guard let savedURL = userDefaults.string(forKey: key) else {
            print("ℹ️ 没有找到可恢复的存档")
            completion?(false, "没有找到存档")
            return
        }
        
        print("🔄 正在恢复存档: \(savedURL)")
        if let url = URL(string: savedURL) {
            // 延迟执行，确保 WebView 已准备就绪
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                webView.load(URLRequest(url: url))
                print("✅ 已加载存档页面")
                completion?(true, "已恢复存档: \(savedURL)")
            }
        } else {
            print("❌ URL 无效: \(savedURL)")
            completion?(false, "存档数据无效")
        }
    }
    
    // MARK: - 获取保存信息
    
    func getSavedInfo(for gameId: UUID) -> (url: String?, timestamp: Date?) {
        let url = userDefaults.string(forKey: saveKeyPrefix + gameId.uuidString)
        let timestamp = userDefaults.object(forKey: timestampKeyPrefix + gameId.uuidString) as? Date
        return (url, timestamp)
    }
    
    func hasSavedState(for gameId: UUID) -> Bool {
        return userDefaults.string(forKey: saveKeyPrefix + gameId.uuidString) != nil
    }
    
    // MARK: - 清除存档
    
    func clearSaveState(for gameId: UUID) {
        userDefaults.removeObject(forKey: saveKeyPrefix + gameId.uuidString)
        userDefaults.removeObject(forKey: timestampKeyPrefix + gameId.uuidString)
        print("🗑️ 已清除游戏 \(gameId) 的自动存档")
    }
    
    // MARK: - 格式化保存时间
    
    func formattedSaveTime(for gameId: UUID) -> String? {
        let (_, timestamp) = getSavedInfo(for: gameId)
        guard let timestamp = timestamp else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}
