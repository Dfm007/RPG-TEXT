import SwiftUI
import UIKit
import PhotosUI

// MARK: - 游戏数据模型
struct GameItem: Identifiable, Codable {
    let id = UUID()
    var name: String
    var localPath: String
    var lastPlayed: Date?
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
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showErrorAlert = false
    
    @State private var editingGameId: UUID?
    @State private var editingName: String = ""
    @State private var showRenameAlert = false
    
    @State private var showEditMenu = false
    @State private var menuGameId: UUID?
    
    @State private var showIconPicker = false
    @State private var pickerGameId: UUID?
    
    @State private var refreshID = UUID()
    
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
                                        
                                        Button {
                                            menuGameId = game.id
                                            showEditMenu = true
                                        } label: {
                                            Image(systemName: "pencil.circle")
                                                .font(.title3)
                                                .foregroundColor(.gray)
                                        }
                                        .buttonStyle(.plain)
                                        
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
                            .id(refreshID)
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
                    refreshID = UUID()
                }
                editingGameId = nil
            }
            Button("取消", role: .cancel) {
                editingGameId = nil
            }
        }
        // ⭐ 编辑菜单 - 内容为 [修改图标] 与 [重命名]
        .confirmationDialog("编辑游戏", isPresented: $showEditMenu, titleVisibility: .visible) {
            Button("修改图标") {          // ⬅️ 点击后修改图标
                if let id = menuGameId {
                    pickerGameId = id
                    showIconPicker = true
                }
            }
            Button("重命名") {            // ⬅️ 点击后修改名称
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
    
    // MARK: - 保存图标
    private func saveIcon(data: Data, for gameId: UUID) {
        guard let game = games.first(where: { $0.id == gameId }),
              let index = games.firstIndex(where: { $0.id == gameId }) else {
            return
        }
        let gameURL = getLocalGameURL(for: game)
        let iconDir = gameURL.appendingPathComponent("icon")
        
        do {
            if !fileManager.fileExists(atPath: iconDir.path) {
                try fileManager.createDirectory(at: iconDir, withIntermediateDirectories: true)
            }
            let fileURL = iconDir.appendingPathComponent("icon.png")
            try data.write(to: fileURL)
            print("✅ 图标保存成功：\(fileURL.path)")
            refreshID = UUID()
        } catch {
            print("❌ 保存图标失败：\(error)")
            importError = "保存图标失败：\(error.localizedDescription)"
            showErrorAlert = true
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
                    refreshID = UUID()
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
        refreshID = UUID()
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
