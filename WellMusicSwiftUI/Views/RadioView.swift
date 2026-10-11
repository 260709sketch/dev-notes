import SwiftUI

/// 电台 Tab：接入四大平台的歌单/榜单推荐（后续轮次填充搜索与加载）
///
/// ⚠️ 本视图**不带 `NavigationStack`**。导航容器由 `MainTabView` 统一提供
/// （见 `MainTabView.page(_:_:)` 的说明）：四个 Tab 的导航栈必须稳定存在于
/// 切换层之外，否则切换时四个导航栏会一起重新测量，大标题与整页都会跳一下。
/// 这里只返回内容并设置标题即可。
struct RadioView: View {
    @EnvironmentObject private var appState: AppState
    @State private var recommended: [RemotePlaylist] = []

    var body: some View {
        List {
            if recommended.isEmpty {
                if #available(iOS 17.0, *) {
                    ContentUnavailableView("电台内容开发中", systemImage: "dot.radiowaves.left.and.right",
                                           description: Text("后续接入平台推荐歌单与每日推荐"))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("电台内容开发中").font(.headline)
                        Text("后续接入平台推荐歌单与每日推荐").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            } else {
                ForEach(recommended) { pl in
                    HStack(spacing: 12) {
                        ArtworkView(url: pl.coverURL, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pl.name).font(.body).lineLimit(1)
                            Text("\(pl.trackCount) 首 · \(pl.source.displayName)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("发现")
    }
}

#Preview {
    NavigationStack { RadioView() }
}
