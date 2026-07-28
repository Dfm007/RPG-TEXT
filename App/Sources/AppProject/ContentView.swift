import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import WebKit

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
    var gameId: UUID?
    
    private var hostingController: UIHostingController<RPGWebView>?
    private var gearButton: UIButton!
    private var webViewRef: WKWebView?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        guard let folderURL = folderURL else { return }
        
        let webView = RPGWebView(
            folderURL: folderURL,
            onWebViewCreated: { [weak self] webView in
                self?.webViewRef = webView
            }
        )
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
        gearButton.addTarget(self, action: #selector(gearButtonTapped), for: .touchUpInside)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
    }
    
    @objc private func gearButtonTapped() {
        let alertController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        
        let exitAction = UIAlertAction(title: "返回主界面", style: .destructive) { [weak self] _ in
            self?.onExit?()
        }
        let cancelAction = UIAlertAction(title: "取消", style: .cancel)
        
        alertController.addAction(exitAction)
        alertController.addAction(cancelAction)
        
        if let popover = alertController.popoverPresentationController {
            popover.sourceView = gearButton
            popover.sourceRect = gearButton.bounds
        }
        present(alertController, animated: true)
    }
    
    @objc private func handleAppDidBecomeActive() {
        guard let webView = webViewRef else { return }
        let script = """
            (function() {
                if (typeof AudioContext !== 'undefined') {
                    try { new AudioContext().resume(); } catch(e) {}
                }
                if (typeof WebAudio !== 'undefined' && WebAudio._context) {
                    try { WebAudio._context.resume(); } catch(e) {}
                }
                if (typeof AudioManager !== 'undefined' && AudioManager.resume) {
                    AudioManager.resume();
                }
            })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
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
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        hostingController?.willMove(toParent: nil)
        hostingController?.view.removeFromSuperview()
        hostingController?.removeFromParent()
    }
}

// MARK: - UIViewControllerRepresentable
struct GameView: UIViewControllerRepresentable {
    let folderURL: URL
    let gameId: UUID
    let onExit: () -> Void
    
    func makeUIViewController(context: Context) -> GameViewController {
        let vc = GameViewController()
        vc.folderURL = folderURL
        vc.gameId = gameId
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
    
    func showGame(folderURL: URL, gameId: UUID, onExit: @escaping () -> Void) {
        AppDelegate.orientationLock = .landscape
        UIViewController.attemptRotationToDeviceOrientation()
        
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return
        }
        
        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .black
        
        let vc = GameViewController()
        vc.folderURL = folderURL
        vc.gameId = gameId
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
        
        AppDelegate.orientationLock = .portrait
        UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

// MARK: - 日志查看器
struct LogViewer: View {
    @State private var logContent: String = ""
    @State private var isLoading = true
    @State private var showClearConfirmation = false
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    ProgressView("加载日志中...")
                        .padding()
                } else if logContent.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 44))
                            .foregroundColor(.gray)
                        Text("暂无日志")
                            .font(.headline)
                            .foregroundColor(.gray)
                        Text("请先在游戏中操作，然后重新打开日志")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(logContent)
                            .font(.system(.body, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationTitle("日志查看器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button("复制") {
                            UIPasteboard.general.string = logContent
                        }
                        .disabled(logContent.isEmpty)
                        
                        Button("清空") {
                            showClearConfirmation = true
                        }
                        .disabled(logContent.isEmpty)
                        
                        Button("刷新") {
                            loadLog()
                        }
                    }
                }
            }
            .alert("确认清空", isPresented: $showClearConfirmation) {
                Button("确定", role: .destructive) {
                    clearLog()
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("确定要清空所有日志吗？")
            }
        }
        .onAppear {
            loadLog()
        }
    }
    
    private func loadLog() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            let logFileURL = docs.appendingPathComponent("bridge_log.txt")
            
            var content = ""
            if fileManager.fileExists(atPath: logFileURL.path) {
                do {
                    content = try String(contentsOf: logFileURL, encoding: .utf8)
                } catch {
                    content = "读取日志失败: \(error.localizedDescription)"
                }
            }
            
            DispatchQueue.main.async {
                logContent = content
                isLoading = false
            }
        }
    }
    
    private func clearLog() {
        let fileManager = FileManager.default
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let logFileURL = docs.appendingPathComponent("bridge_log.txt")
        
        do {
            try "".write(to: logFileURL, atomically: true, encoding: .utf8)
            logContent = ""
        } catch {
            logContent = "清空日志失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - 主界面
struct ContentView: View {
    // 游戏数据
    @State private var games: [GameItem] = []
    @State private var selectedGame: GameItem?
    @State private var importError: String?
    @State private var showErrorAlert = false
    @State private var importState: ImportState = .idle
    @State private var showImporter = false
    @State private var searchText = ""
    
    // 编辑相关
    @State private var editingGameId: UUID?
    @State private var editingName: String = ""
    @State private var showRenameAlert = false
    @State private var showEditMenu = false
    @State private var menuGameId: UUID?
    @State private var showIconPicker = false
    @State private var pickerGameId: UUID?
    @State private var refreshID = UUID()
    
    // 当前页面控制
    @State private var currentTab: String = "games"
    
    // 关于弹窗
    @State private var showAboutAlert = false
    
    // 日志查看器
    @State private var showLogViewer = false
    
    private let saveKey = "GameLibrary"
    private let fileManager = FileManager.default
    
    // 过滤后的游戏列表
    private var filteredGames: [GameItem] {
        if searchText.isEmpty {
            return games
        } else {
            return games.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        ZStack {
            if let game = selectedGame {
                Color.clear
                    .onAppear {
                        GameOverlayManager.shared.showGame(
                            folderURL: getLocalGameURL(for: game),
                            gameId: game.id,
                            onExit: {
                                selectedGame = nil
                            }
                        )
                    }
                    .onDisappear {
                        GameOverlayManager.shared.hideGame()
                    }
                    .ignoresSafeArea()
            } else {
                // 主容器
                VStack(spacing: 0) {
                    Group {
                        if currentTab == "games" {
                            gamesView
                        } else {
                            settingsView
                        }
                    }
                    
                    VStack(spacing: 0) {
                        Spacer()
                            .frame(height: 20)
                        customTabBar
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
        .alert("关于", isPresented: $showAboutAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("TEXT")
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
        .sheet(isPresented: $showLogViewer) {
            LogViewer()
        }
        .onAppear {
            loadGames()
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
    
    // MARK: - 游戏列表视图
    private var gamesView: some View {
        VStack(spacing: 0) {
            // 顶部标题栏（含加号按钮）
            HStack {
                Text("我的游戏")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Spacer()
                // 加号按钮（导入游戏）
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            // 搜索框
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                TextField("搜索游戏", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            
            // 游戏列表
            if games.isEmpty {
                VStack(spacing: 20) {
                    Spacer()
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("0个游戏")
                        .font(.title2)
                        .foregroundColor(.gray)
                    Text("暂无游戏")
                        .font(.headline)
                        .foregroundColor(.gray)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !filteredGames.isEmpty {
                            Text("全部游戏")
                                .font(.headline)
                                .padding(.horizontal, 20)
                                .padding(.top, 4)
                            
                            ForEach(filteredGames) { game in
                                gameRow(for: game)
                                    .padding(.horizontal, 20)
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .navigationBarHidden(true)
    }
    
    // MARK: - 设置视图（全屏）
    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            HStack {
                Text("设置")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
            
            // 设置列表
            List {
                // 关于选项
                Button {
                    showAboutAlert = true
                } label: {
                    HStack {
                        Text("关于")
                            .font(.body)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .buttonStyle(.plain)
                
                // 查看日志选项
                Button {
                    showLogViewer = true
                } label: {
                    HStack {
                        Text("查看日志")
                            .font(.body)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .navigationBarHidden(true)
    }
    
    // MARK: - 游戏行（包含恢复存档按钮）
    @ViewBuilder
    private func gameRow(for game: GameItem) -> some View {
        HStack(spacing: 12) {
            gameIcon(for: game)
                .resizable()
                .frame(width: 56, height: 56)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .font(.headline)
                    .lineLimit(1)
                if let last = game.lastPlayed {
                    Text("上次游玩: \(formattedTime(last))")
                        .font(.caption)
                        .foregroundColor(.blue)
                } else {
                    Text("等待首次启动")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            
            Spacer()
            

            
            // 编辑按钮
            Button {
                menuGameId = game.id
                showEditMenu = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
            
            // 启动按钮
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
        .padding(.vertical, 4)
    }
    
    // MARK: - 自定义底部 Tab 栏
    private var customTabBar: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation { currentTab = "games" }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 20))
                    Text("游戏")
                        .font(.system(size: 11))
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundColor(currentTab == "games" ? .blue : .gray)
                .background(Color.clear)
            }
            .buttonStyle(.plain)
            
            Button {
                withAnimation { currentTab = "settings" }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "gear")
                        .font(.system(size: 20))
                    Text("设置")
                        .font(.system(size: 11))
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundColor(currentTab == "settings" ? .blue : .gray)
                .background(Color.clear)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 8)
        .background(Color.clear)
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
    

    
    // MARK: - 导入游戏
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

// MARK: - UTType 扩展
extension UTType {
    static var apk: UTType {
        UTType(importedAs: "application/vnd.android.package-archive")
    }
    static var zip: UTType {
        UTType(importedAs: "com.pkware.zip-archive")
    }
}
