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

// MARK: - 强制横屏的 UIViewController（含桥接）
class GameViewController: UIViewController, WKScriptMessageHandler {
    var folderURL: URL?
    var onExit: (() -> Void)?
    var gameId: UUID?
    
    private var hostingController: UIHostingController<RPGWebView>?
    private var gearButton: UIButton!
    private var webViewRef: WKWebView?
    
    // MARK: - 桥接脚本（JavaScript）
    private let bridgeScript = """
        (function() {
            if (window.__bridgeInitialized) return;
            window.__bridgeInitialized = true;

            // 桥接对象
            const bridge = {
                save: function(fileName, data) {
                    return new Promise((resolve, reject) => {
                        if (!window.webkit || !window.webkit.messageHandlers) {
                            reject(new Error('原生桥接未就绪'));
                            return;
                        }
                        let dataStr = typeof data === 'string' ? data : JSON.stringify(data);
                        let base64 = btoa(unescape(encodeURIComponent(dataStr)));
                        window.webkit.messageHandlers.save.postMessage({
                            fileName: fileName,
                            data: base64
                        });
                        resolve();
                    });
                },
                load: function(fileName) {
                    return new Promise((resolve, reject) => {
                        if (!window.webkit || !window.webkit.messageHandlers) {
                            reject(new Error('原生桥接未就绪'));
                            return;
                        }
                        let callbackId = Date.now() + '_' + Math.random();
                        window.webkit.messageHandlers.load.postMessage({
                            fileName: fileName,
                            callbackId: callbackId
                        });
                        let handler = function(event) {
                            if (event.data && event.data.callbackId === callbackId) {
                                window.removeEventListener('message', handler);
                                if (event.data.error) {
                                    reject(new Error(event.data.error));
                                } else {
                                    resolve(event.data.data);
                                }
                            }
                        };
                        window.addEventListener('message', handler);
                    });
                },
                list: function() {
                    return new Promise((resolve, reject) => {
                        if (!window.webkit || !window.webkit.messageHandlers) {
                            reject(new Error('原生桥接未就绪'));
                            return;
                        }
                        let callbackId = Date.now() + '_list';
                        window.webkit.messageHandlers.list.postMessage({
                            callbackId: callbackId
                        });
                        let handler = function(event) {
                            if (event.data && event.data.callbackId === callbackId) {
                                window.removeEventListener('message', handler);
                                if (event.data.error) {
                                    reject(new Error(event.data.error));
                                } else {
                                    resolve(event.data.files);
                                }
                            }
                        };
                        window.addEventListener('message', handler);
                    });
                }
            };

            // 拦截 RPG Maker MV/MZ 的 StorageManager
            if (typeof StorageManager !== 'undefined') {
                let originalSave = StorageManager.save;
                StorageManager.save = function() {
                    let result = originalSave.apply(this, arguments);
                    try {
                        let key = 'RPG Maker';
                        let data = localStorage.getItem(key);
                        if (data) {
                            bridge.save('save.rpgsave', data).catch(e => console.warn('桥接保存失败:', e));
                        }
                    } catch (e) {
                        console.warn('桥接保存异常:', e);
                    }
                    return result;
                };
            }

            // 暴露全局方法
            window.restoreSaveFromNative = function(fileName) {
                return bridge.load(fileName).then(data => {
                    let key = 'RPG Maker';
                    localStorage.setItem(key, data);
                    // 触发游戏刷新
                    if (typeof SceneManager !== 'undefined') {
                        SceneManager._scene?.load?.(data);
                    }
                    return data;
                }).catch(err => console.warn('从原生恢复存档失败:', err));
            };
            window.listNativeSaves = function() {
                return bridge.list();
            };

            console.log('✅ 桥接脚本已注入');
        })();
        """
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        guard let folderURL = folderURL else { return }
        
        // 1. 创建自定义配置
        let config = WKWebViewConfiguration()
        let userController = WKUserContentController()
        userController.add(self, name: "save")
        userController.add(self, name: "load")
        userController.add(self, name: "list")
        // 注入桥接脚本
        let userScript = WKUserScript(source: bridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        userController.addUserScript(userScript)
        config.userContentController = userController
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        
        // 2. 创建 RPGWebView（使用自定义配置）
        let webView = RPGWebView(
            folderURL: folderURL,
            configuration: config,
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
        
        // 齿轮按钮（菜单）
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
        
        // 音频恢复通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 横屏强制
        UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
    }
    
    // MARK: - 齿轮菜单
    @objc private func gearButtonTapped() {
        let alertController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        
        let saveAction = UIAlertAction(title: "保存游戏", style: .default) { [weak self] _ in
            self?.saveGame()
        }
        let exitAction = UIAlertAction(title: "返回主界面", style: .destructive) { [weak self] _ in
            self?.onExit?()
        }
        let cancelAction = UIAlertAction(title: "取消", style: .cancel)
        
        alertController.addAction(saveAction)
        alertController.addAction(exitAction)
        alertController.addAction(cancelAction)
        
        if let popover = alertController.popoverPresentationController {
            popover.sourceView = gearButton
            popover.sourceRect = gearButton.bounds
        }
        present(alertController, animated: true)
    }
    
    // MARK: - 保存游戏（手动触发）
    @objc private func saveGame() {
        guard let gameId = gameId, let folderURL = folderURL else {
            showAlert(title: "保存失败", message: "无法获取游戏信息")
            return
        }
        // 在游戏目录下创建 save 文件夹（如果不存在）
        let saveDir = folderURL.appendingPathComponent("save")
        if !FileManager.default.fileExists(atPath: saveDir.path) {
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        }
        // 调用桥接的保存方法（通过 JS 触发游戏内保存）
        webViewRef?.evaluateJavaScript("""
            if (typeof StorageManager !== 'undefined' && StorageManager.save) {
                StorageManager.save();
                '保存请求已发送';
            } else {
                '未找到 StorageManager';
            }
        """) { [weak self] result, error in
            if let error = error {
                self?.showAlert(title: "保存失败", message: error.localizedDescription)
            } else {
                self?.showAlert(title: "✅ 保存成功", message: "存档已保存至 GameSaves 和游戏目录")
            }
        }
    }
    
    // MARK: - WKScriptMessageHandler 处理
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let gameId = gameId, let folderURL = folderURL else { return }
        let manager = SaveFileManager.shared
        
        switch message.name {
        case "save":
            guard let body = message.body as? [String: Any],
                  let fileName = body["fileName"] as? String,
                  let base64 = body["data"] as? String,
                  let data = Data(base64Encoded: base64) else {
                print("❌ 保存消息格式错误")
                return
            }
            // 写入 GameSaves/
            manager.writeSave(gameId: gameId, fileName: fileName, data: data)
            // 同时写入游戏目录的 save/
            let saveDir = folderURL.appendingPathComponent("save")
            if !FileManager.default.fileExists(atPath: saveDir.path) {
                try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            }
            let fileURL = saveDir.appendingPathComponent(fileName)
            try? data.write(to: fileURL)
            print("✅ 桥接保存成功: \(fileName)")
            
        case "load":
            guard let body = message.body as? [String: Any],
                  let fileName = body["fileName"] as? String,
                  let callbackId = body["callbackId"] as? String else {
                return
            }
            // 先从 GameSaves 读取，若没有则从游戏目录 save/ 读取
            var loadedData = manager.readSave(gameId: gameId, fileName: fileName)
            if loadedData == nil {
                let saveDir = folderURL.appendingPathComponent("save")
                let fileURL = saveDir.appendingPathComponent(fileName)
                loadedData = try? Data(contentsOf: fileURL)
            }
            if let data = loadedData {
                let base64 = data.base64EncodedString()
                let script = """
                    window.dispatchEvent(new MessageEvent('message', {
                        data: { callbackId: '\(callbackId)', data: '\(base64)' }
                    }));
                """
                webViewRef?.evaluateJavaScript(script, completionHandler: nil)
            } else {
                let script = """
                    window.dispatchEvent(new MessageEvent('message', {
                        data: { callbackId: '\(callbackId)', error: '存档不存在' }
                    }));
                """
                webViewRef?.evaluateJavaScript(script, completionHandler: nil)
            }
            
        case "list":
            guard let body = message.body as? [String: Any],
                  let callbackId = body["callbackId"] as? String else {
                return
            }
            let files = manager.listSaves(gameId: gameId)
            let fileNames = files.map { $0.fileName }
            let script = """
                window.dispatchEvent(new MessageEvent('message', {
                    data: { callbackId: '\(callbackId)', files: \(fileNames) }
                }));
            """
            webViewRef?.evaluateJavaScript(script, completionHandler: nil)
            
        default:
            break
        }
    }
    
    // MARK: - 音频恢复
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
    
    // MARK: - 辅助方法
    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
    
    // MARK: - 横屏设置
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
        // 移除消息处理器
        webViewRef?.configuration.userContentController.removeScriptMessageHandler(forName: "save")
        webViewRef?.configuration.userContentController.removeScriptMessageHandler(forName: "load")
        webViewRef?.configuration.userContentController.removeScriptMessageHandler(forName: "list")
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
        // 锁定横屏
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
        
        // 强制横屏
        UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
        
        self.gameWindow = window
        self.gameVC = vc
    }
    
    func hideGame() {
        gameWindow?.isHidden = true
        gameWindow = nil
        gameVC = nil
        
        // 恢复竖屏
        AppDelegate.orientationLock = .portrait
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
    
    @State private var showingSettings = false
    
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
    
    // 读存档相关
    @State private var showArchiveList = false
    @State private var archiveGameId: UUID?
    @State private var archiveFiles: [(fileName: String, fileSize: Int64, modificationDate: Date)] = []

    private let saveKey = "GameLibrary"
    private let fileManager = FileManager.default
    
    var body: some View {
        NavigationStack {
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
                                        
                                        // 读存档按钮
                                        Button {
                                            archiveGameId = game.id
                                            archiveFiles = SaveFileManager.shared.listSaves(gameId: game.id)
                                            if archiveFiles.isEmpty {
                                                importError = "没有找到存档，请先保存游戏"
                                                showErrorAlert = true
                                            } else {
                                                showArchiveList = true
                                            }
                                        } label: {
                                            Image(systemName: "tray.and.arrow.down")
                                                .font(.title3)
                                                .foregroundColor(.green)
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
                            HStack(spacing: 16) {
                                if case .importing = importState {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                } else {
                                    Button(action: { showImporter = true }) {
                                        Image(systemName: "folder.badge.plus")
                                    }
                                }
                                Button(action: { showingSettings = true }) {
                                    Image(systemName: "gear")
                                        .font(.title3)
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
        .confirmationDialog("选择存档", isPresented: $showArchiveList, titleVisibility: .visible) {
            ForEach(archiveFiles.indices, id: \.self) { index in
                let file = archiveFiles[index]
                let timeString = DateFormatter.localizedString(from: file.modificationDate, dateStyle: .short, timeStyle: .short)
                let sizeString = SaveFileManager.shared.formattedFileSize(file.fileSize)
                Button("\(file.fileName) (\(sizeString) \(timeString))") {
                    guard let gameId = archiveGameId,
                          let game = games.first(where: { $0.id == gameId }) else { return }
                    // 将存档复制到游戏目录
                    let gameURL = getLocalGameURL(for: game)
                    if SaveFileManager.shared.copySaveToGame(gameId: gameId, fileName: file.fileName, gameFolderURL: gameURL) {
                        // 复制成功，启动游戏
                        GameOverlayManager.shared.showGame(
                            folderURL: gameURL,
                            gameId: gameId,
                            onExit: { }
                        )
                        updateLastPlayed(for: game.id)
                    } else {
                        importError = "复制存档失败"
                        showErrorAlert = true
                    }
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
        .sheet(isPresented: $showingSettings) {
            SettingsView()
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
