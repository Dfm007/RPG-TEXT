import SwiftUI

// MARK: - 游戏数据模型
struct GameItem: Identifiable, Codable {
    let id = UUID()
    var name: String
    var localPath: String
    var lastPlayed: Date?
}

// MARK: - 主界面
struct ContentView: View {
    @State private var games: [GameItem] = []
    @State private var showImporter = false
    @State private var selectedGame: GameItem?
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showErrorAlert = false
    
    @State private var editingGameId: UUID?
    @State private var editingName: String = ""
    @State private var showRenameAlert = false
    
    // 用于控制屏幕方向
    @State private var isLandscape = false
    
    private let saveKey = "GameLibrary"
    private let fileManager = FileManager.default
    
    var body: some View {
        NavigationStack {
            ZStack {
                if let game = selectedGame {
                    let gameURL = getLocalGameURL(for: game)
                    RPGWebView(folderURL: gameURL)
                        .ignoresSafeArea()
                        .navigationTitle(game.name)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button {
                                    // 退出游戏，恢复竖屏
                                    isLandscape = false
                                    forceOrientation(.portrait)
                                    selectedGame = nil
                                } label: {
                                    Image(systemName: "gear")
                                        .font(.title2)
                                }
                            }
                        }
                        // ⭐ 进入游戏时强制横屏
                        .onAppear {
                            isLandscape = true
                            forceOrientation(.landscapeRight)
                        }
                        // ⭐ 退出游戏时恢复竖屏（以防万一）
                        .onDisappear {
                            isLandscape = false
                            forceOrientation(.portrait)
                        }
                } else {
                    // 游戏库列表（和之前一样）
                    VStack {
                        if games.isEmpty {
                            VStack(spacing: 20) {
                                Image(systemName: "gamecontroller")
                                    .font(.system(size: 60))
                                    .foregroundColor(.gray)
                                Text("无")
                                    .font(.title)
                                    .foregroundColor(.gray)
                                Text("点击右上角「导入」添加游戏文件夹")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List {
                                ForEach(games) { game in
                                    HStack(spacing: 12) {
                                        gameIcon(for: game)
                                            .resizable()
                                            .frame(width: 50, height: 50)
                                            .cornerRadius(8)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
                                            )
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(game.name)
                                                .font(.headline)
                                            if let last = game.lastPlayed {
                                                Text("将从 \(formattedTime(last)) 继续")
                                                    .font(.caption)
                                                    .foregroundColor(.blue)
                                            } else {
                                                Text("等待首次启动")
                                                    .font(.caption)
                                                    .foregroundColor(.orange)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.gray)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedGame = game
                                        updateLastPlayed(for: game.id)
                                    }
                                    .contextMenu {
                                        Button("重命名") {
                                            editingGameId = game.id
                                            editingName = game.name
                                            showRenameAlert = true
                                        }
                                        Button("删除", role: .destructive) {
                                            if let index = games.firstIndex(where: { $0.id == game.id }) {
                                                deleteGame(at: index)
                                            }
                                        }
                                    }
                                }
                                .onDelete(perform: deleteGames)
                            }
                            .listStyle(.plain)
                        }
                    }
                    .navigationTitle("游戏库")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            if isImporting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            } else {
                                Button(action: { showImporter = true }) {
                                    Image(systemName: "folder.badge.plus")
                                }
                            }
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let selectedURL = urls.first else { return }
                importGameFolder(from: selectedURL)
            case .failure(let error):
                importError = "选择文件夹失败: \(error.localizedDescription)"
                showErrorAlert = true
            }
        }
        .alert("导入错误", isPresented: $showErrorAlert, presenting: importError) { _ in
            Button("确定") { }
        } message: { error in
            Text(error)
        }
        .alert("重命名游戏", isPresented: $showRenameAlert) {
            TextField("新名称", text: $editingName)
            Button("确定") {
                if let id = editingGameId,
                   let index = games.firstIndex(where: { $0.id == id }) {
                    games[index].name = editingName
                    saveGames()
                }
                editingGameId = nil
            }
            Button("取消", role: .cancel) {
                editingGameId = nil
            }
        }
        .onAppear {
            loadGames()
        }
    }
    
    // MARK: - 辅助函数
    
    private func getLocalGameURL(for game: GameItem) -> URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent(game.localPath)
    }
    
    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    private func gameIcon(for game: GameItem) -> Image {
        let gameURL = getLocalGameURL(for: game)
        let iconDir = gameURL.appendingPathComponent("icon")
        let possibleExtensions = ["png", "jpg", "jpeg", "icon"]
        
        for ext in possibleExtensions {
            let fileURL = iconDir.appendingPathExtension(ext)
            if fileManager.fileExists(atPath: fileURL.path) {
                if let uiImage = UIImage(contentsOfFile: fileURL.path) {
                    return Image(uiImage: uiImage)
                }
            }
        }
        return Image(systemName: "gamecontroller.fill")
    }
    
    // MARK: - ⭐ 强制横屏/竖屏（使用 UIWindowScene 方式）
    private func forceOrientation(_ orientation: UIInterfaceOrientation) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return
        }
        
        // 设置支持的方向
        let supportedOrientations: UIInterfaceOrientationMask
        switch orientation {
        case .portrait:
            supportedOrientations = .portrait
        case .landscapeLeft, .landscapeRight:
            supportedOrientations = .landscape
        default:
            supportedOrientations = .portrait
        }
        
        // 通过 UIWindowScene 请求几何更新
        let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(
            interfaceOrientations: supportedOrientations
        )
        
        windowScene.requestGeometryUpdate(geometryPreferences) { error in
            print("横屏切换失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - 导入逻辑
    private func importGameFolder(from sourceURL: URL) {
        isImporting = true
        
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            importError = "无法访问应用目录"
            showErrorAlert = true
            isImporting = false
            return
        }
        
        let folderName = sourceURL.lastPathComponent
        let destURL = documents.appendingPathComponent(folderName)
        
        if games.contains(where: { $0.name == folderName }) {
            importError = "已存在同名游戏「\(folderName)」，请先删除再导入"
            showErrorAlert = true
            isImporting = false
            return
        }
        
        Task {
            do {
                let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccessing {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }
                
                if fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.removeItem(at: destURL)
                }
                
                try fileManager.copyItem(at: sourceURL, to: destURL)
                
                let relativePath = destURL.lastPathComponent
                let newGame = GameItem(name: folderName, localPath: relativePath, lastPlayed: nil)
                
                await MainActor.run {
                    games.append(newGame)
                    saveGames()
                    isImporting = false
                }
            } catch {
                await MainActor.run {
                    importError = "复制游戏失败: \(error.localizedDescription)"
                    showErrorAlert = true
                    isImporting = false
                }
            }
        }
    }
    
    // MARK: - 更新游玩时间
    private func updateLastPlayed(for id: UUID) {
        if let index = games.firstIndex(where: { $0.id == id }) {
            games[index].lastPlayed = Date()
            saveGames()
        }
    }
    
    // MARK: - 删除游戏（单个）
    private func deleteGame(at index: Int) {
        let game = games[index]
        let gameURL = getLocalGameURL(for: game)
        do {
            if fileManager.fileExists(atPath: gameURL.path) {
                try fileManager.removeItem(at: gameURL)
            }
        } catch {
            print("删除游戏文件夹失败: \(error)")
        }
        games.remove(at: index)
        saveGames()
    }
    
    // MARK: - 删除游戏（批量）
    private func deleteGames(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            deleteGame(at: index)
        }
    }
    
    // MARK: - 持久化
    private func saveGames() {
        if let data = try? JSONEncoder().encode(games) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }
    
    private func loadGames() {
        guard let data = UserDefaults.standard.data(forKey: saveKey) else { return }
        if let decoded = try? JSONDecoder().decode([GameItem].self, from: data) {
            games = decoded
        }
    }
}
