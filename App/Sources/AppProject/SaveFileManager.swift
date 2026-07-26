import Foundation

class SaveFileManager {
    static let shared = SaveFileManager()
    
    private let fileManager = FileManager.default
    private let savesFolderName = "GameSaves"
    
    // 获取存档根目录
    private func getSavesRootURL() -> URL? {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let savesURL = documents.appendingPathComponent(savesFolderName)
        if !fileManager.fileExists(atPath: savesURL.path) {
            try? fileManager.createDirectory(at: savesURL, withIntermediateDirectories: true)
        }
        return savesURL
    }
    
    // 获取某游戏的存档目录
    private func getGameSavesURL(gameId: UUID) -> URL? {
        guard let root = getSavesRootURL() else { return nil }
        let gameFolder = root.appendingPathComponent(gameId.uuidString)
        if !fileManager.fileExists(atPath: gameFolder.path) {
            try? fileManager.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        }
        return gameFolder
    }
    
    // MARK: - 写入存档（透传）
    @discardableResult
    func writeSave(gameId: UUID, fileName: String, data: Data) -> Bool {
        guard let gameFolder = getGameSavesURL(gameId: gameId) else {
            print("❌ 无法获取游戏存档目录")
            return false
        }
        let fileURL = gameFolder.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL)
            print("✅ 存档写入成功: \(fileURL.path)")
            return true
        } catch {
            print("❌ 存档写入失败: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - 读取存档（透传）
    func readSave(gameId: UUID, fileName: String) -> Data? {
        guard let gameFolder = getGameSavesURL(gameId: gameId) else {
            print("❌ 无法获取游戏存档目录")
            return nil
        }
        let fileURL = gameFolder.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            print("❌ 存档文件不存在: \(fileURL.path)")
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            print("✅ 存档读取成功: \(fileURL.path)，大小: \(data.count) bytes")
            return data
        } catch {
            print("❌ 存档读取失败: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - 列出所有存档
    func listSaves(gameId: UUID) -> [(fileName: String, fileSize: Int64, modificationDate: Date)] {
        guard let gameFolder = getGameSavesURL(gameId: gameId) else {
            return []
        }
        do {
            let items = try fileManager.contentsOfDirectory(at: gameFolder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            var result: [(String, Int64, Date)] = []
            for item in items {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: item.path, isDirectory: &isDir), !isDir.boolValue else {
                    continue
                }
                let attrs = try fileManager.attributesOfItem(atPath: item.path)
                let size = attrs[.size] as? Int64 ?? 0
                let modDate = attrs[.modificationDate] as? Date ?? Date()
                result.append((item.lastPathComponent, size, modDate))
            }
            result.sort { $0.2 > $1.2 }
            return result
        } catch {
            print("❌ 列出存档失败: \(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - 删除存档
    @discardableResult
    func deleteSave(gameId: UUID, fileName: String) -> Bool {
        guard let gameFolder = getGameSavesURL(gameId: gameId) else {
            return false
        }
        let fileURL = gameFolder.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            print("❌ 存档不存在: \(fileURL.path)")
            return false
        }
        do {
            try fileManager.removeItem(at: fileURL)
            print("✅ 存档删除成功: \(fileURL.path)")
            return true
        } catch {
            print("❌ 存档删除失败: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - 复制存档到游戏目录（用于读取）
    @discardableResult
    func copySaveToGame(gameId: UUID, fileName: String, gameFolderURL: URL) -> Bool {
        guard let saveData = readSave(gameId: gameId, fileName: fileName) else {
            return false
        }
        // 检查游戏目录下是否有 save 子目录，没有则创建
        let saveDir = gameFolderURL.appendingPathComponent("save")
        if !fileManager.fileExists(atPath: saveDir.path) {
            try? fileManager.createDirectory(at: saveDir, withIntermediateDirectories: true)
        }
        let destURL = saveDir.appendingPathComponent(fileName)
        do {
            try saveData.write(to: destURL)
            print("✅ 存档已复制到游戏目录: \(destURL.path)")
            return true
        } catch {
            print("❌ 复制存档到游戏目录失败: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - 从游戏目录复制存档到 GameSaves（用于保存）
    @discardableResult
    func copySaveFromGame(gameId: UUID, fileName: String, gameFolderURL: URL) -> Bool {
        let saveDir = gameFolderURL.appendingPathComponent("save")
        let sourceURL = saveDir.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            print("❌ 游戏目录中不存在存档: \(sourceURL.path)")
            return false
        }
        do {
            let data = try Data(contentsOf: sourceURL)
            return writeSave(gameId: gameId, fileName: fileName, data: data)
        } catch {
            print("❌ 从游戏目录复制存档失败: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - 获取存档文件大小（格式化）
    func formattedFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}
