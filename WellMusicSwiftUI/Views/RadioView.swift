import SwiftUI

/// 电台 Tab：接入四大平台的歌单/榜单推荐（后续轮次填充搜索与加载）
struct RadioView: View {
    @EnvironmentObject private var appState: AppState
    @State private var recommended: [RemotePlaylist] = []

    var body: some View {
        NavigationStack {
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
            .navigationTitle("电台")
        }
    }
}

#Preview {
    RadioView()
}