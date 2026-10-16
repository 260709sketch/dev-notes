import SwiftUI

/// 「我的」→「我的歌单」里点开一个歌单后用的详情页。
///
/// 版式按用户 2026-10-14 的截图（IMG_3957）标定。截图是 iPhone 393pt 屏 @3x（1179×2129），
/// 逐像素量出来的真值：
///   * 左右边距 **22pt**（红按钮左右各 22pt，对称）
///   * 头部封面 **120×120pt**、圆角 12、封面顶距 **18pt**
///   * 「播放全部」胶囊 **高 34pt**、满宽（`393 - 22×2 = 349pt`）
///   * 歌曲行封面 **46×46pt**、行间距 **64pt**（= 46 + 上下各 9）
///
/// ⚠️ 与 `WellPlaylistDetailView`（平台歌单/专辑：居中 304pt 大封面 + 主色底 + 白色播放胶囊）
/// **刻意并存**，不合并：用户明确这个版式「只用于我的歌单」，另一边是 10-14 刚标定好的。
///
/// ⚠️ 按用户 2026-10-14 要求，歌单里的歌曲行**不显示 VIP 角标**
/// （与 `WellArtistHomeView` 同一条约束）。
///
/// ⚠️ 性能铁律：不 `@EnvironmentObject` 订阅 `PlayerCore` —— `currentTime` 是 20Hz 广播，
/// 订阅了整页每秒重算 20 次，滚动必卡。「正在播放」那一行的高亮走 `$currentIndex` 投影，
/// 它只在**换歌**时发一次（与 `MainTabView` 用 `$hasActiveTrack` 同理）。
struct WellMyPlaylistDetailView: View {
    let source: WellMyPlaylistSource

    // MARK: 版式常量（全部来自截图实测，改之前先重新量）

    private enum Metrics {
        static let horizontal: CGFloat = 22
        static let coverSide: CGFloat = 120
        static let coverRadius: CGFloat = 12
        static let headerTop: CGFloat = 18
        static let coverTextGap: CGFloat = 14
        static let playAllHeight: CGFloat = 34
        static let rowCover: CGFloat = 46
        static let rowCoverRadius: CGFloat = 8
        static let rowVertical: CGFloat = 9
    }

    /// 页面主色（网易云红）
    private static let accent = Color(red: 0.925, green: 0.255, blue: 0.255)   // #EC4141
    /// 「播放全部」胶囊渐变（取自参考实现的原值）
    private static let playAllGradient = [
        Color(red: 1.00, green: 0.42, blue: 0.42),   // #FF6B6B
        Color(red: 0.84, green: 0.19, blue: 0.19),   // #D63031
    ]

    // MARK: 内容（本地歌单在 init 就绪；网易云歌单异步拉）

    @State private var tracks: [MusicItem]
    @State private var title: String
    @State private var coverURL: String?
    /// 有值 = 显示平台行（本地自建歌单没有这个行）。
    /// 行首图标按平台名取对应 App 图标，见 `platformMark`。
    @State private var creatorName: String?
    /// 总曲目数：网易云歌单元数据里的总数可能大于已加载条数
    @State private var trackTotal: Int
    @State private var playlistDescription: String? = nil
    /// 创建者头像（用户 2026-10-16 问题2：标题下要显示网易云创建者的头像 + 昵称）。
    /// 有值 → 平台行用头像替代平台 App 图标；nil → 沿用平台图标。
    @State private var creatorAvatarURL: String?

    @State private var isLoading: Bool
    @State private var failed = false

    /// 正在播放曲目的 `keyOf`（只在换歌时更新，见类型注释）
    @State private var playingKey: String? = nil

    init(source: WellMyPlaylistSource,
         introText: String? = nil,
         creatorAvatarURL: String? = nil) {
        self.source = source
        _creatorAvatarURL = State(initialValue: creatorAvatarURL)
        // 简介：调用方注入优先（问题10：我喜欢页「来自你的网易云音乐」）；
        // .netease 源的 load() 会用服务端简介覆盖（那是真简介，优先级更高）
        _playlistDescription = State(initialValue: introText)
        switch source {
        case .local(let playlist):
            _tracks = State(initialValue: playlist.tracks)
            _title = State(initialValue: playlist.name)
            _coverURL = State(initialValue: playlist.coverURL)
            // 导入的歌单带平台来源（netease / qq）→ 显示平台行 + 对应 App 图标；
            // 用户自建歌单（sourcePlatform == nil）不显示平台行。
            // ★ 2026-10-16 用户（问题4）：「导入的QQ音乐歌单不会有QQ音乐标识，
            //   网易云的都有」。sourcePlatform 字段是后加的，之前导入的歌单
            //   持久化数据里没有它 → 按曲目来源兜底推断（见 platformDisplayName），
            //   旧导入自动补上标识，不用用户重新导入。
            _creatorName = State(initialValue: Self.platformDisplayName(playlist))
            _trackTotal = State(initialValue: playlist.tracks.count)
            _isLoading = State(initialValue: false)
        case .netease(_, let name, let cover, let creator):
            _tracks = State(initialValue: [])
            _title = State(initialValue: name)
            _coverURL = State(initialValue: cover)
            _creatorName = State(initialValue: creator)
            _trackTotal = State(initialValue: 0)
            _isLoading = State(initialValue: true)
        case .tracks(let name, let cover, let creator, let list):
            _tracks = State(initialValue: list)
            _title = State(initialValue: name)
            _coverURL = State(initialValue: cover)
            _creatorName = State(initialValue: creator)
            _trackTotal = State(initialValue: list.count)
            _isLoading = State(initialValue: false)
        }
    }

    /// 本地歌单的平台显示名（detail 页标题下的平台行；nil = 不显示该行）。
    ///
    /// * `sourcePlatform` 有值（新导入）→ 直接映射；
    /// * 没有（2026-10-16 之前导入的旧歌单）→ 按曲目来源兜底推断：
    ///   **整本曲目全部来自同一平台**才认（混源 / 空歌单不猜，返回 nil）。
    private static func platformDisplayName(_ playlist: Playlist) -> String? {
        if let sp = playlist.sourcePlatform, !sp.isEmpty {
            return sp == "qq" ? "QQ音乐" : "网易云音乐"
        }
        guard !playlist.tracks.isEmpty else { return nil }
        let sources = Set(playlist.tracks.map(\.source))
        guard sources.count == 1, let only = sources.first else { return nil }
        switch only {
        case .qq: return "QQ音乐"
        case .netease: return "网易云音乐"
        default: return nil
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed {
                failureView
            } else {
                content
            }
        }
        // 导航栏：不显示歌单名，且按 iOS 原生语义「顶部透明 / 滚动后毛玻璃」
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(NativeNavigationBarBackground())
        .onReceive(PlayerCore.shared.$currentIndex) { index in
            let key: String? = {
                guard let index, PlayerCore.shared.queue.indices.contains(index) else { return nil }
                return PlayerCore.shared.queue[index].keyOf
            }()
            if playingKey != key { playingKey = key }
        }
        .task { await load() }
    }

    // MARK: 主体

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header

                if tracks.isEmpty {
                    Text("这个歌单还是空的")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    ForEach(tracks) { item in
                        row(item)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        // 裸 ScrollView 不自带底色，深色下会露出白底（工程里踩过这个「白边」）
        .background(AppTheme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Metrics.coverTextGap) {
                ArtworkView(url: coverURL, size: Metrics.coverSide, cornerRadius: Metrics.coverRadius)

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let creatorName, !creatorName.isEmpty {
                        HStack(spacing: 6) {
                            // ★ 2026-10-16 用户（问题2）：有创建者头像就显示头像
                            //   （圆形 18pt，与文字基线对齐），否则退回平台 App 图标
                            if let creatorAvatarURL, !creatorAvatarURL.isEmpty {
                                WellRemoteImage(url: creatorAvatarURL, displaySize: 36)
                                    .frame(width: 18, height: 18)
                                    .clipShape(Circle())
                            } else {
                                platformMark
                            }
                            Text(creatorName)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.top, 8)
                    }
                    // ★ 2026-10-16 用户（问题7）：标题下的「N 首」移除
                    //   （截图版式：封面 + 标题 + 平台行 + 红色播放全部，无数量行；
                    //    曲目数在「播放全部 (N)」按钮上已经有一份，不重复显示）
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.horizontal)
            .padding(.top, Metrics.headerTop)

            if let playlistDescription, !playlistDescription.isEmpty {
                Text(playlistDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .padding(.horizontal, Metrics.horizontal)
                    .padding(.top, 10)
            }

            playAllButton
                .padding(.horizontal, Metrics.horizontal)
                .padding(.top, 14)
                .padding(.bottom, 6)
        }
    }

    private var playAllButton: some View {
        Button {
            play(queue: tracks, startIndex: 0)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 16))
                Text("播放全部 (\(trackTotal))")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.playAllHeight)
            .background(
                LinearGradient(colors: Self.playAllGradient,
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(Capsule())
            .opacity(tracks.isEmpty ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(tracks.isEmpty)
    }

    private func row(_ item: MusicItem) -> some View {
        let isPlaying = playingKey != nil && item.keyOf == playingKey
        return Button {
            play(queue: tracks, startIndex: tracks.firstIndex(of: item) ?? 0)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(url: item.albumCoverURL, size: Metrics.rowCover,
                            cornerRadius: Metrics.rowCoverRadius)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isPlaying ? Self.accent : Color.primary)
                        .lineLimit(1)
                    Text(item.artist ?? "未知歌手")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isPlaying {
                    // ★ 2026-10-16 问题8：换成全局共享的 Apple Music 风格动画音条
                    NowPlayingIndicator(color: Self.accent)
                } else {
                    Text(Self.durationText(item.duration))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, Metrics.horizontal)
            .padding(.vertical, Metrics.rowVertical)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 平台行图标（用户 2026-10-15）：
    /// 平台名是「网易云音乐」→ 网易云 App 图标（红底白音符，PlatformNetease）；
    /// 是「QQ音乐」→ QQ 音乐 App 图标（黄底绿音符，PlatformQQMusic）；
    /// 其余（如搜索结果的用户昵称）退回原来的通用红方块，不猜平台。
    /// 尺寸沿用旧值 18×18、圆角 5，和文字基线对齐。
    @ViewBuilder
    private var platformMark: some View {
        if let creatorName {
            if creatorName.contains("网易云") {
                Image("PlatformNetease")
                    .resizable()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else if creatorName.contains("QQ") {
                Image("PlatformQQMusic")
                    .resizable()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                genericMark
            }
        } else {
            genericMark
        }
    }

    /// 通用品牌方块（红底白音符）—— 平台认不出来的行用它
    private var genericMark: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Self.accent)
            .frame(width: 18, height: 18)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            )
    }

    private var failureView: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("暂时拿不到这个歌单")
                .foregroundStyle(.secondary)
            Button("重试") { Task { await load() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 行为

    private func play(queue: [MusicItem], startIndex: Int) {
        guard !queue.isEmpty else { return }
        PlayerCore.shared.play(queue: queue, startIndex: startIndex)
    }

    private func load() async {
        guard case let .netease(id, _, _, _) = source else { return }
        isLoading = true
        failed = false
        do {
            let imported = try await NeteaseMusicAPI.shared.playlistForImport(id: id)
            tracks = imported.tracks
            trackTotal = imported.tracks.count
            if !imported.name.isEmpty { title = imported.name }
            if let cover = imported.coverURL, !cover.isEmpty { coverURL = cover }
            // 简介要单独取：playlistForImport 的返回值里不带 description
            playlistDescription = await NeteaseMusicAPI.shared.playlistDescription(id: id)
            // ★ 2026-10-16 用户（问题2）：平台行显示**真实创建者**的头像 + 昵称
            //   （playlistForImport 的返回值里已带上 creator，零额外请求）
            if let n = imported.creatorName, !n.isEmpty { creatorName = n }
            if let a = imported.creatorAvatarURL, !a.isEmpty { creatorAvatarURL = a }
        } catch {
            failed = true
        }
        isLoading = false
    }

    /// `179` → `2:59`
    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

/// 正在播放的三根小竖条。
///
/// 刻意**不做动画**：参考实现是 `CADisplayLink` 驱动的三帧循环，而本页是长列表 ——
/// 每行挂一个动画时钟会把「滑动掉帧」的老毛病带回来（详见项目里的高频轮询铁律）。
/// 「我的歌单」里一个歌单的来源。
enum WellMyPlaylistSource {
    /// 本地自建歌单（`AppState.playlists`）
    case local(Playlist)
    /// 网易云账号里的歌单（`api/user/playlist` 返回），曲目按需异步拉
    case netease(id: String, name: String, coverURL: String?, creatorName: String?)
    /// 直接吃内存里的曲目列表（「我喜欢」「最近播放」「收藏歌曲」复用同一版式）
    case tracks(name: String, coverURL: String?, creatorName: String?, tracks: [MusicItem])
}
