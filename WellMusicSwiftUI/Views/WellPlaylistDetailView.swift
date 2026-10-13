import SwiftUI

/// 歌单 / 专辑 / 歌手详情页 —— 对齐 Beans `PlaylistView` 的页面结构，代码按本项目重写。
///
/// 结构：大 header（封面96 + 名称 + 创建者/歌手 + 播放量）
/// → 播放全部 / 随机播放 双按钮
/// → 歌单内搜索框 + 排序菜单（默认 / 歌名 / 时长）
/// → 无分隔线歌曲列表（46 封面、行高 64）。
///
/// ⭐ Beans 同款细节：**搜索与排序只改变可见列表，点击歌曲后的播放队列
/// 仍按排序后的完整顺序走**（`orderedTracks` 是队列，`displayedTracks` 只是滤镜）。
struct WellPlaylistDetailView: View {
    let source: WellSearchDetailSource
    var coverURL: String?
    /// 创建者名（歌单页显示；专辑/歌手页传空）
    var creatorName: String?
    /// 播放量（歌单页显示）
    var playCount: Int = 0

    /// 歌单内排序方式（Beans 同款）
    enum SortMode: String, CaseIterable, Identifiable {
        case original = "默认"
        case name = "歌名"
        case duration = "时长"
        var id: String { rawValue }
    }

    @State private var tracks: [MusicItem] = []
    @State private var isLoading = true
    @State private var failed = false
    @State private var searchText = ""
    @State private var sortMode: SortMode = .original

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                songsSection
                Color.clear.frame(height: 170)
            }
            .padding(.top, 12)
        }
        .background(AppTheme.background)
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && tracks.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed && tracks.isEmpty {
                retryState
            }
        }
        .task {
            guard tracks.isEmpty else { return }
            await load()
        }
    }

    // MARK: - Header（Beans 同款布局）

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                WellRemoteImage(url: coverURL, displaySize: 96)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(source.title)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(2)
                    if let creatorName, !creatorName.isEmpty {
                        Text(creatorName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Text("\(tracks.count) 首")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if playCount > 0 {
                        Text("播放 \(playCountText)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            // 播放全部 / 随机播放（Beans 双按钮）
            HStack(spacing: 10) {
                Button {
                    guard !orderedTracks.isEmpty else { return }
                    PlayerCore.shared.play(queue: orderedTracks, startIndex: 0)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AppTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(orderedTracks.isEmpty)

                Button {
                    guard !orderedTracks.isEmpty else { return }
                    PlayerCore.shared.play(queue: orderedTracks,
                                           startIndex: Int.random(in: 0..<orderedTracks.count))
                } label: {
                    Label("随机播放", systemImage: "shuffle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AppTheme.secondaryBackground, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(orderedTracks.isEmpty)
            }

            // 歌单内搜索 + 排序（ Beans 同款：只过滤显示，不改播放队列）
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    TextField("搜索歌单内歌曲", text: $searchText)
                        .font(.system(size: 14))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(AppTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Menu {
                    Picker("排序", selection: $sortMode) {
                        ForEach(SortMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 38, height: 38)
                        .background(AppTheme.secondaryBackground, in: Circle())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    // MARK: - 歌曲列表

    @ViewBuilder
    private var songsSection: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 300)
        } else if displayedTracks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text(searchText.isEmpty ? "暂无歌曲" : "没有匹配的歌曲")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            // ⚠️ 无分隔线（Beans 同款干净列表）
            VStack(spacing: 0) {
                ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { _, item in
                    Button {
                        PlayerCore.shared.play(queue: orderedTracks,
                                               startIndex: playbackIndex(for: item))
                    } label: {
                        WellDetailSongRow(item: item)
                            .padding(.horizontal, 20)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var retryState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text("内容加载失败")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task { await load() }
            } label: {
                Text("重新加载")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(AppTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 数据逻辑（Beans 同款：排序作用于队列，搜索只过滤显示）

    /// 排序后的完整顺序 = 播放队列
    private var orderedTracks: [MusicItem] {
        var list = tracks
        switch sortMode {
        case .original: break
        case .name:
            list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .duration:
            list.sort { $0.duration < $1.duration }
        }
        return list
    }

    /// 搜索只改可见列表
    private var displayedTracks: [MusicItem] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return orderedTracks }
        return orderedTracks.filter { item in
            item.title.lowercased().contains(kw)
                || (item.artist ?? "").lowercased().contains(kw)
                || (item.album ?? "").lowercased().contains(kw)
        }
    }

    private func playbackIndex(for item: MusicItem) -> Int {
        orderedTracks.firstIndex { $0.id == item.id } ?? 0
    }

    private var playCountText: String {
        if playCount >= 100_000_000 { return String(format: "%.1f亿", Double(playCount) / 100_000_000) }
        if playCount >= 10_000 { return String(format: "%.1f万", Double(playCount) / 10_000) }
        return "\(playCount)"
    }

    private func load() async {
        isLoading = true
        failed = false
        let fetched = await SearchService.shared.detailTracks(for: source)
        tracks = fetched
        failed = fetched.isEmpty
        isLoading = false
    }
}

// MARK: - 详情歌曲行

/// 详情页歌曲行（Beans 同款：46 封面 + 歌名/歌手 + 右侧时长，行高 64，无分隔线）。
struct WellDetailSongRow: View {
    let item: MusicItem

    var body: some View {
        HStack(spacing: 12) {
            WellRemoteImage(url: item.albumCoverURL, displaySize: 46)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.artist ?? "未知歌手")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.durationText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(height: 64)
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        WellPlaylistDetailView(
            source: .playlist(id: "1", platform: .netease, name: "示例歌单"),
            coverURL: nil, creatorName: "创建者", playCount: 12345)
    }
}
