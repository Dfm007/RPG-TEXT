import SwiftUI

struct GameHomeView: View {
    @State private var searchText = ""
    @State private var gameCount = 0
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶部区域
                VStack(spacing: 0) {
                    // 标题栏
                    HStack {
                        Text("我的游戏")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.black)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    
                    // 搜索栏
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                            .frame(width: 20)
                        
                        TextField("搜索游戏", text: $searchText)
                            .foregroundColor(.gray)
                            .textFieldStyle(RoundedTextFieldStyle())
                    
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    
                    // 导航标签栏
                    HStack {
                        HStack(spacing: 4) {
                            Image(systemName: "list")
                                .font(.system(size: 14))
                            Text("最近游玩")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding(.leading, 12)
                        
                        Spacer()
                        
                        Text("\(gameCount) 个游戏")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .padding(.trailing, 16)
                    }
                    .frame(height: 44)
                    .background(Color(.systemGray6))
                }
                .background(Color(.systemBackground))
                
                // 添加按钮（右上角）
                Button(action: {
                    // 添加游戏逻辑
                }) {
                    Image(systemName: "plus")
                        .font(.title3)
                        .foregroundColor(.blue)
                }
                .padding(.trailing, 16)
                .padding(.top, 8)
                .background(Color(.systemBackground))
                
                // 中间内容区
                if gameCount == 0 {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "gamecontroller")
                            .font(.system(size: 80))
                            .foregroundColor(.gray)
                        
                        Text("暂无游戏")
                            .font(.headline)
                            .foregroundColor(.black)
                        
                        Text("添加游戏")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    Spacer()
                } else {
                    // 游戏列表（当有游戏时显示）
                    List {
                        ForEach(0..<gameCount) { index in
                            HStack {
                                Text("游戏 \(index + 1)")
                                    .foregroundColor(.black)
                                Spacer()
                                Text("今天")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    .listStyle(PlainListStyle())
                }
                
                // 添加游戏按钮
                Button(action: {
                    // 添加游戏逻辑
                }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.white)
                        Text("添加游戏")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                    .frame(width: 280, height: 50)
                    .background(Color.blue)
                    .cornerRadius(12)
                }
                .padding()
                
                Spacer()
            }
            .navigationTitle("")
            .navigationBarHidden(false)
            .toolbar {
                // 底部导航栏
                ToolbarItem(placement: .bottomBar) {
                    Button(action: {
                        // 游戏页面逻辑
                    }) {
                        VStack {
                            Image(systemName: "gamecontroller")
                                .font(.system(size: 20))
                            Text("游戏")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                }
                
                Spacer()
                
                ToolbarItem(placement: .bottomBar) {
                    Button(action: {
                        // 设置页面逻辑
                    }) {
                        VStack {
                            Image(systemName: "gear")
                                .font(.system(size: 20))
                            Text("设置")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.light)
    }
}

struct GameHomeView_Previews: PreviewProvider {
    static var somePreview: some View {
        GameHomeView()
    }
}
