import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 游戏数据模型
struct GameItem: Identifiable, Codable {
    let id = UUID()
    var name: String
    var localPath: String
    var lastPlayed: Date?
}

// MARK: - 解压进度状态
enum ImportState {
    case idle
    case importing
    case unzipping(progress: Double)
    case processing
    case done
    case failed(String)
}

// MARK: - 强制横屏的 UIViewController
class GameViewController: UIViewController {
    var folderURL: URL?
    var onExit: (() -> Void)?
    private var hostingController: UIHostingController<RPGWebView>?
    private var gearButton: UIButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        guard let folderURL = folderURL else { return }
        
        let webView = RPGWebView(folderURL: folderURL)
        let host = UIHostingController(rootView: webView)
        host.view.backgroundColor = .black
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        hostingController = host
        
        gearButton = UIButton(type: .system)
        gearButton.setImage(UIImage(systemName: "gear"), for: .normal)
        gearButton.tintColor = .white
        gearButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        gearButton.layer.cornerRadius = 20
        gearButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gearButton)
        NSLayoutConstraint.activate([
            gearButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            gearButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            gearButton.widthAnchor.constraint(equalToConstant: 40),
            gearButton.heightAnchor.constraint(equalToConstant: 40)
        ])
        gearButton.addTarget(self, action: #selector(exitTapped), for: .touchUpInside)
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return .landscapeRight
    }
    override var shouldAutorotate: Bool {
        return true
    }
    
    @objc private func exitTapped() {
        onExit?()
    }
    
    deinit {
        hostingController?.willMove(toParent: nil)
        hostingController?.view.removeFromSuperview()
        hostingController?.removeFromParent()
    }
}

// MARK: - UIViewControllerRepresentable
struct GameView: UIViewControllerRepresentable {
    let folderURL: URL
    let onExit: () -> Void
    
    func makeUIViewController(context: Context) -> GameViewController {
        let vc = GameViewController()
        vc.folderURL = folderURL
        vc.onExit = onExit
        return vc
    }
    
    func updateUIViewController(_ uiViewController: GameViewController, context: Context) {}
}

// MARK: - 全屏覆盖工具
class GameOverlayManager {
    static let shared = GameOverlayManager()
    private var gameWindow: UIWindow?
    private var gameVC: GameViewController?
    
    func showGame(folderURL: URL, onExit: @escaping () -> Void) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return
        }
        
        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .black
        
        let vc = GameViewController()
        vc.folderURL = folderURL
        vc.onExit = { [weak self] in
            self?.hideGame()
            onExit()
        }
        window.rootViewController = vc
        window.makeKeyAndVisible()
        
        UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
        
        self.gameWindow = window
        self.gameVC = vc
    }
    
    func hideGame() {
        gameWindow?.isHidden = true
        gameWindow = nil
        gameVC = nil
        
        UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

// MARK: - 主界面
struct ContentView: View {
    @State private var games: [GameItem] = []
    @State private var showImporter = false
    @State private var selectedGame: GameItem?
    @State private var importError: String?
    @State private var showErrorAlert = false
    
    @State private var importState: ImportState = .idle
    @State private var progressValue: Double = 0
    @State private var statusText: String = ""
    
    @State private var editingGameId: UUID?
    @State private var editingName: String = ""
    @State private var showRenameAlert = false
    
    @State private var showEditMenu = false
    @State private var menuGameId: UUID?
    
    @State private var showIconPicker = false
    @State private var pickerGameId: UUID?
    
    @State private var refreshID = UUID()
    
    // ⭐ 存档管理器导航
    @State private var archiveManagerGame: GameItem?
    
    private let saveKey = "GameLibrary"
    private let fileManager = FileManager.default
    
    var body: some View {
        NavigationStack {
            ZStack {
                if let game = selectedGame {
                    Color.clear
                        .onAppear {
                            GameOverlayManager.shared.showGame(folderURL: getLocalGameURL(for: game)) {
                                selectedGame = nil
                            }
                        }
                        .onDisappear {
                            GameOverlayManager.shared.hideGame()
                        }
                        .ignoresSafeArea()
                } else if let game = archiveManagerGame {
                    // ⭐ 存档管理器视图
                    ArchiveManagerView(game: game, gameURL: getLocalGameURL(for: game))
                        .navigationTitle("\(game.name) - 存档")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("返回") {
                                    archiveManagerGame = nil
                                }
                            }
                        }
                } else {
                    VStack {
                        if games.isEmpty {
                            VStack(spacing: 20) {
                                Image(systemName: "gamecontroller")
                                    .font(.system(size: 60))
                                    .foregroundColor(.gray)
                                Text("无")
                                    .font(.title)
                                    .foregroundColor(.gray)
                                Text("点击右上角「导入」添加游戏文件")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("支持 .zip 和 .apk 格式")
                                    .font(.caption2)
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
                                        
                                        // ⭐ 存档管理按钮（文件夹图标）
                                        Button {
                                            archiveManagerGame = game
                                        } label: {
                                            Image(systemName: "folder")
                                                .font(.title3)
                                                .foregroundColor(.blue)
                                        }
                                        .buttonStyle(.plain)
                                        
                                        Button {
                                            menuGameId = game.id
                                            showEditMenu = true
                                        } label: {
                                            Image(systemName: "square.and.pencil")
                                                .font(.title3)
                                                .foregroundColor(.gray)
                                        }
                                        .buttonStyle(.plain)
                                        
                                        Image(systemName: "play.circle")
                                            .font(.title3)
                                            .foregroundColor(.gray)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedGame = game
                                        updateLastPlayed(for: game.id)
                                    }
                                    .contextMenu {
                                        Button("修改图标") {
                                            pickerGameId = game.id
                                            showIconPicker = true
                                        }
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
                            .id(refreshID)
                            .environment(\.locale, Locale(identifier: "zh-Hans"))
                        }
                    }
                    .navigationTitle("游戏库")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            if case .importing = importState {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            } else {
                                Button(action: { showImporter = true }) {
                                    Image(systemName: "folder.badge.plus")
                                }
                            }
                        }
                    }
                    .overlay {
                        if case .unzipping(let progress) = importState {
                            VStack(spacing: 16) {
                                ProgressView(value: progress, total: 1.0)
                                    .progressViewStyle(.linear)
                                    .frame(width: 200)
                                Text("解压中... \(Int(progress * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(24)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(.systemBackground))
                                    .shadow(radius: 10)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
                            )
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.zip, .apk],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let selectedURL = urls.first else { return }
                importGameArchive(from: selectedURL)
            case .failure(let error):
                importError = "选择文件失败: \(error.localizedDescription)"
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
                    refreshID = UUID()
                }
                editingGameId = nil
            }
            Button("取消", role: .cancel) {
                editingGameId = nil
            }
        }
        .confirmationDialog("编辑游戏", isPresented: $showEditMenu, titleVisibility: .visible) {
            Button("修改图标") {
                if let id = menuGameId {
                    pickerGameId = id
                    showIconPicker = true
                }
            }
            Button("重命名") {
                if let id = menuGameId,
                   let game = games.first(where: { $0.id == id }) {
                    editingGameId = id
                    editingName = game.name
                    showRenameAlert = true
                }
            }
            Button("取消", role: .cancel) { }
        }
        .sheet(isPresented: $showIconPicker) {
            ImagePicker(selectedImageData: { data in
                guard let id = pickerGameId else { return }
                saveIcon(data: data, for: id)
                pickerGameId = nil
                refreshID = UUID()
            })
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
    
    // MARK: - 写日志到文件（用于调试）
    private func writeLog(_ message: String) {
        let logURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("import_log.txt")
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if fileManager.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }
    
    // MARK: - 导入并解压 .zip / .apk
    
    private func importGameArchive(from sourceURL: URL) {
        importState = .importing
        writeLog("开始导入文件：\(sourceURL.lastPathComponent)")
        
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            importError = "无法访问应用目录"
            showErrorAlert = true
            importState = .idle
            writeLog("错误：无法访问 Documents 目录")
            return
        }
        
        let archiveName = sourceURL.lastPathComponent
        let gameName = (archiveName as NSString).deletingPathExtension
        
        if games.contains(where: { $0.name == gameName }) {
            importError = "已存在同名游戏「\(gameName)」，请先删除再导入"
            showErrorAlert = true
            importState = .idle
            writeLog("错误：已存在同名游戏 \(gameName)")
            return
        }
        
        let destURL = documents.appendingPathComponent(gameName)
        if fileManager.fileExists(atPath: destURL.path) {
            try? fileManager.removeItem(at: destURL)
        }
        
        Task {
            do {
                let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccessing {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }
                
                let tempDir = fileManager.temporaryDirectory
                let tempFile = tempDir.appendingPathComponent(archiveName)
                if fileManager.fileExists(atPath: tempFile.path) {
                    try fileManager.removeItem(at: tempFile)
                }
                try fileManager.copyItem(at: sourceURL, to: tempFile)
                writeLog("已复制到临时目录：\(tempFile.path)")
                
                try fileManager.createDirectory(at: destURL, withIntermediateDirectories: true)
                
                let progress = Progress(totalUnitCount: 0)
                let observation = progress.observe(\.fractionCompleted) { prog, _ in
                    DispatchQueue.main.async {
                        importState = .unzipping(progress: prog.fractionCompleted)
                    }
                }
                try fileManager.unzipItem(at: tempFile, to: destURL, progress: progress)
                observation.invalidate()
                writeLog("解压完成，目标目录：\(destURL.path)")
                
                try? fileManager.removeItem(at: tempFile)
                
                let finalGameURL = try await findAndFlattenGameDirectory(at: destURL)
                writeLog("最终游戏目录：\(finalGameURL.path)")
                
                let indexURL = finalGameURL.appendingPathComponent("index.html")
                if !fileManager.fileExists(atPath: indexURL.path) {
                    if let found = findIndexHTML(in: finalGameURL) {
                        writeLog("在子目录中找到 index.html：\(found.path)")
                        let parent = found.deletingLastPathComponent()
                        let contents = try fileManager.contentsOfDirectory(atPath: found.path)
                        for item in contents {
                            let src = found.appendingPathComponent(item)
                            let dst = parent.appendingPathComponent(item)
                            try fileManager.moveItem(at: src, to: dst)
                        }
                        try fileManager.removeItem(at: found)
                        if fileManager.fileExists(atPath: parent.appendingPathComponent("index.html").path) {
                            writeLog("index.html 已移动到根目录")
                        } else {
                            throw NSError(domain: "GameImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到 index.html"])
                        }
                    } else {
                        throw NSError(domain: "GameImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到 index.html"])
                    }
                }
                
                let relativePath = finalGameURL.lastPathComponent
                let newGame = GameItem(name: gameName, localPath: relativePath, lastPlayed: nil)
                
                await MainActor.run {
                    games.append(newGame)
                    saveGames()
                    importState = .idle
                    refreshID = UUID()
                    writeLog("✅ 游戏添加成功：\(gameName)")
                }
                
            } catch {
                try? fileManager.removeItem(at: destURL)
                await MainActor.run {
                    importError = "导入失败：\(error.localizedDescription)"
                    showErrorAlert = true
                    importState = .idle
                    writeLog("❌ 导入失败：\(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - 递归查找 index.html
    
    private func findIndexHTML(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "index.html" {
                return fileURL
            }
        }
        return nil
    }
    
    // MARK: - 扁平化目录
    
    private func findAndFlattenGameDirectory(at url: URL) async throws -> URL {
        let contents = try fileManager.contentsOfDirectory(atPath: url.path)
        
        if contents.contains("index.html") {
            return url
        }
        
        if contents.count == 1 {
            let subPath = url.appendingPathComponent(contents[0])
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: subPath.path, isDirectory: &isDir),
               isDir.boolValue {
                let subContents = try fileManager.contentsOfDirectory(atPath: subPath.path)
                if subContents.contains("index.html") {
                    for item in subContents {
                        let src = subPath.appendingPathComponent(item)
                        let dst = url.appendingPathComponent(item)
                        try fileManager.moveItem(at: src, to: dst)
                    }
                    try fileManager.removeItem(at: subPath)
                    return url
                }
            }
        }
        
        for item in contents {
            let subPath = url.appendingPathComponent(item)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: subPath.path, isDirectory: &isDir),
               isDir.boolValue {
                if let found = findIndexHTML(in: subPath) {
                    let parent = found.deletingLastPathComponent()
                    let moveContents = try fileManager.contentsOfDirectory(atPath: parent.path)
                    for moveItem in moveContents {
                        let src = parent.appendingPathComponent(moveItem)
                        let dst = url.appendingPathComponent(moveItem)
                        try fileManager.moveItem(at: src, to: dst)
                    }
                    try fileManager.removeItem(at: parent)
                    return url
                }
            }
        }
        
        return url
    }
    
    // MARK: - 保存图标
    private func saveIcon(data: Data, for gameId: UUID) {
        guard let game = games.first(where: { $0.id == gameId }) else { return }
        let gameURL = getLocalGameURL(for: game)
        let iconDir = gameURL.appendingPathComponent("icon")
        
        do {
            if !fileManager.fileExists(atPath: iconDir.path) {
                try fileManager.createDirectory(at: iconDir, withIntermediateDirectories: true)
            }
            let fileURL = iconDir.appendingPathComponent("icon.png")
            try data.write(to: fileURL)
            refreshID = UUID()
        } catch {
            importError = "保存图标失败：\(error.localizedDescription)"
            showErrorAlert = true
        }
    }
    
    // MARK: - 更新游玩时间
    private func updateLastPlayed(for id: UUID) {
        if let index = games.firstIndex(where: { $0.id == id }) {
            games[index].lastPlayed = Date()
            saveGames()
        }
    }
    
    // MARK: - 删除游戏
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
        refreshID = UUID()
    }
    
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

// MARK: - ⭐ 存档管理器视图
struct ArchiveManagerView: View {
    let game: GameItem
    let gameURL: URL
    
    @State private var archiveFiles: [ArchiveFile] = []
    @State private var showImportPicker = false
    @State private var importError: String?
    @State private var showErrorAlert = false
    @State private var refreshID = UUID()
    
    private let fileManager = FileManager.default
    private let archiveExtensions = ["rpgsave", "rvdata2", "rxdata", "sav", "save", "dat"]
    
    struct ArchiveFile: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let size: Int64
        let modificationDate: Date
        
        var sizeFormatted: String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: size)
        }
        
        var dateFormatted: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: modificationDate)
        }
    }
    
    var body: some View {
        List {
            if archiveFiles.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 44))
                            .foregroundColor(.gray)
                        Text("暂无存档文件")
                            .font(.headline)
                            .foregroundColor(.gray)
                        Text("点击右上角「导入」添加存档")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 40)
                    Spacer()
                }
            } else {
                ForEach(archiveFiles) { file in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name)
                                .font(.headline)
                            HStack(spacing: 16) {
                                Text(file.sizeFormatted)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(file.dateFormatted)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
                .onDelete(perform: deleteArchives)
            }
        }
        .listStyle(.plain)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showImportPicker = true }) {
                    Image(systemName: "square.and.arrow.down")
                }
            }
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let selectedURL = urls.first else { return }
                importArchive(from: selectedURL)
            case .failure(let error):
                importError = "选择文件失败: \(error.localizedDescription)"
                showErrorAlert = true
            }
        }
        .alert("导入错误", isPresented: $showErrorAlert, presenting: importError) { _ in
            Button("确定") { }
        } message: { error in
            Text(error)
        }
        .onAppear {
            scanArchives()
        }
        .id(refreshID)
    }
    
// MARK: - 扫描存档文件（递归扫描所有子目录）
private func scanArchives() {
    archiveFiles.removeAll()
    
    // 支持的存档扩展名（增加更多常见格式）
    let archiveExtensions = [
        "rpgsave", "rvdata2", "rxdata", "sav", "save", "dat",
        "json", "bak", "tmp", "old", "backup",
        "glb", "bin", "txt"
    ]
    
    guard let enumerator = fileManager.enumerator(at: gameURL, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
        return
    }
    
    for case let fileURL as URL in enumerator {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { continue }
        
        let ext = fileURL.pathExtension.lowercased()
        if archiveExtensions.contains(ext) {
            // 排除系统垃圾文件
            let fileName = fileURL.lastPathComponent.lowercased()
            if fileName.hasPrefix(".") || fileName == "desktop.ini" || fileName == "thumbs.db" {
                continue
            }
            
            do {
                let attrs = try fileManager.attributesOfItem(atPath: fileURL.path)
                let size = attrs[.size] as? Int64 ?? 0
                let modDate = attrs[.modificationDate] as? Date ?? Date()
                let file = ArchiveFile(
                    url: fileURL,
                    name: fileURL.lastPathComponent,
                    size: size,
                    modificationDate: modDate
                )
                archiveFiles.append(file)
            } catch {
                print("读取文件属性失败: \(error)")
            }
        }
    }
    
    archiveFiles.sort { $0.modificationDate > $1.modificationDate }
}
    
    // MARK: - 导入存档
    
    private func importArchive(from sourceURL: URL) {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let fileName = sourceURL.lastPathComponent
        
        // 确定存档目录：优先使用 save/ 目录
        let saveDir = gameURL.appendingPathComponent("save")
        let targetDir: URL
        if fileManager.fileExists(atPath: saveDir.path) {
            targetDir = saveDir
        } else {
            targetDir = gameURL
        }
        
        let targetURL = targetDir.appendingPathComponent(fileName)
        
        // 如果同名文件已存在，添加时间戳后缀
        let finalURL: URL
        if fileManager.fileExists(atPath: targetURL.path) {
            let timestamp = Int(Date().timeIntervalSince1970)
            let nameWithoutExt = (fileName as NSString).deletingPathExtension
            let ext = (fileName as NSString).pathExtension
            let newName = "\(nameWithoutExt)_\(timestamp).\(ext)"
            finalURL = targetDir.appendingPathComponent(newName)
        } else {
            finalURL = targetURL
        }
        
        do {
            try fileManager.copyItem(at: sourceURL, to: finalURL)
            scanArchives()
            refreshID = UUID()
        } catch {
            importError = "导入失败: \(error.localizedDescription)"
            showErrorAlert = true
        }
    }
    
    // MARK: - 删除存档
    
    private func deleteArchives(at offsets: IndexSet) {
        for index in offsets {
            let file = archiveFiles[index]
            do {
                try fileManager.removeItem(at: file.url)
            } catch {
                print("删除失败: \(error)")
            }
        }
        scanArchives()
        refreshID = UUID()
    }
}

// MARK: - PHPicker 包装器
struct ImagePicker: UIViewControllerRepresentable {
    var selectedImageData: (Data) -> Void
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            
            guard let result = results.first else { return }
            result.itemProvider.loadObject(ofClass: UIImage.self) { object, error in
                if let image = object as? UIImage,
                   let data = image.pngData() {
                    DispatchQueue.main.async {
                        self.parent.selectedImageData(data)
                    }
                }
            }
        }
    }
}

// ⭐ 扩展 UTType
extension UTType {
    static var apk: UTType {
        UTType(importedAs: "application/vnd.android.package-archive")
    }
    static var zip: UTType {
        UTType(importedAs: "com.pkware.zip-archive")
    }
}
