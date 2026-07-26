import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            // 内容区域（暂空）
            VStack {
                Spacer()
                Text("设置内容将在此显示")
                    .foregroundColor(.secondary)
                Spacer()
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])  // 从底部弹出，高度为中等或大
        .presentationDragIndicator(.visible)      // 显示拖拽指示条
    }
}

#Preview {
    SettingsView()
}
