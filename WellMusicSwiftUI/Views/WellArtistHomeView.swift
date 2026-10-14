import SwiftUI

/// 歌手主页 —— 界面代码按本项目架构重写。
///
/// 结构：Header（72pt 圆形头像 + 名字 + 统计）
/// → 热门歌曲（序号前 3 高亮 / 40pt 封面 / 歌名 + 专辑名，播放全部按钮，页内搜索过滤）
/// → 专辑 / EP 与单曲 两个横滑货架（160pt 封面 + 名称 + 中文发行日期）。
///
/// 数据：`artistTopSongs`（热门歌曲，平台返回多少显示多少，不人为截断）
/// + `artistAlbums`（专辑，offset 翻页拉全量；类型中英混合需一并识别）。
/// 专辑点击 → 歌单页样式详情（WellPlaylistDetailView）。
struct WellArtistHomeView: View {
    let artistId: String
    let artistName: String
    var coverURL: String?
    /// ★★ 2026-10-14：歌手所属平台。原先本页**只查网易云**，从播放页点歌手名
    /// 跳进来（QQ / 酷狗歌）必然全空 —— 见 `load()` 里的根因说明。
    var platform: MusicSource = .netease

    @State private var resolvedName: String = ""
    @State private var resolvedCover: String?
    @State private var hotSongs: [MusicItem] = []
    @State private var albums: [WellAlbumSummary] = []
    /// 平台侧专辑总数（`artist.albumSize`，如周杰伦 = 44）。
    /// 头部统计行优先显示它；接口没给时回落到 `albums.count`。
    @State private var platformAlbumCount: Int?
    @State private var isLoading = true
    @State private var failed = false
    @State private var searchText = ""

    /// 热门歌曲过滤（只影响显示，点击后的队列仍按完整顺序走）
    private var displayedHotSongs: [MusicItem] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return hotSongs }
        return hotSongs.filter { item in
            item.title.lowercased().contains(kw)
                || (item.artist ?? "").lowercased().contains(kw)
                || (item.album ?? "").lowercased().contains(kw)
        }
    }

    private var studioAlbums: [WellAlbumSummary] { albums.filter { !$0.isEPOrSingle } }
    private var epsAndSingles: [WellAlbumSummary] { albums.filter(\.isEPOrSingle) }

    var body: some View {
        Group {
            if isLoading && hotSongs.isEmpty && albums.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed && hotSongs.isEmpty && albums.isEmpty {
                retryState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        artistHeader
                        hotSongsSection
                        albumsSection
                        Color.clear.frame(height: 170)
                    }
                    .padding(.top, 6)
                }
            }
        }
        .navigationTitle("歌手主页")
        .navigationBarTitleDisplayMode(.inline)
        // ★ 2026-10-14 用户：移除导航栏上的搜索框。
        //   原实现为 `.searchable(placement: .navigationBarDrawer(displayMode: .always))`
        //   —— 导航栏下方常驻一条「搜索歌手歌曲」，用户要求去掉。
        .task {
            guard hotSongs.isEmpty && albums.isEmpty else { return }
            await load()
        }
    }

    // MARK: - Header

    private var artistHeader: some View {
        HStack(spacing: 14) {
            WellRemoteImage(url: resolvedCover ?? coverURL, displaySize: 72)
                .frame(width: 72, height: 72)
                .clipShape(Circle())
                .background(Color.secondary.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(resolvedName.isEmpty ? artistName : resolvedName)
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                // 统计行：按平台实际显示（2026-10-14 用户要求）——
                // 热门歌曲数 = 接口返回条数（网易云固定 50）；
                // 专辑数 = artist.albumSize（平台真实总数，周杰伦 44）。
                Text("热门歌曲 \(hotSongs.count) 首 · 专辑 \(platformAlbumCount ?? albums.count) 张")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 热门歌曲

    private var hotSongsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("热门歌曲")
                .font(.system(size: 17, weight: .bold))
                .padding(.horizontal, 16)

            if !hotSongs.isEmpty {
                // 播放全部（长条胶囊按钮）
                Button {
                    guard !displayedHotSongs.isEmpty else { return }
                    PlayerCore.shared.play(queue: displayedHotSongs, startIndex: 0)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AppTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }

            if hotSongs.isEmpty {
                Text("暂无歌曲")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else if displayedHotSongs.isEmpty {
                Text("没有匹配的歌曲")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(displayedHotSongs.enumerated()), id: \.element.id) { index, item in
                        Button {
                            PlayerCore.shared.play(queue: displayedHotSongs, startIndex: index)
                        } label: {
                            hotSongRow(index: index, item: item)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 热门歌曲行：`[序号(前3高亮)] [封面40] 歌名 / 专辑名`
    /// （歌曲行不显示 VIP 标识 —— 2026-10-14 用户要求）
    private func hotSongRow(index: Int, item: MusicItem) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(index < 3 ? AppTheme.accent : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 32, alignment: .trailing)

            WellRemoteImage(url: item.albumCoverURL, displaySize: 40)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text(item.album ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    // MARK: - 专辑（两个货架：专辑 / EP 与单曲）

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            albumShelf(title: "专辑", albums: studioAlbums)
            albumShelf(title: "EP 与单曲", albums: epsAndSingles)
        }
    }

    @ViewBuilder
    private func albumShelf(title: String, albums: [WellAlbumSummary]) -> some View {
        if !albums.isEmpty {
            WellShelf(title: title, rowHeight: 230) {
                ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                    NavigationLink {
                        WellPlaylistDetailView(
                            source: .album(id: album.id, platform: .netease,
                                           name: album.name, artist: album.artistName),
                            coverURL: album.picURL,
                            creatorName: album.artistName)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            WellRemoteImage(url: album.picURL, displaySize: 160)
                                .frame(width: 160, height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Text(album.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(width: 160, alignment: .leading)
                            // 发行日期中文化（「2025年6月5日」）；老数据没有
                            // publishTime 时回落类型文案（2026-10-14 用户要求）。
                            Text(album.publishDateText ?? album.albumTypeText)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 160, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(WellCardEntrance(index: index, itemID: "artist-album-\(album.id)"))
                }
            }
        }
    }

    // MARK: - 状态与加载

    private var retryState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text("歌手信息加载失败")
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

    /// 本页对应的搜索平台（QQ / 酷狗 / 网易云）；酷我等其他源没有独立歌手接口，返回 nil。
    private var searchPlatform: WellSearchPlatform? {
        switch platform {
        case .qq: return .qq
        case .kugou: return .kugou
        case .netease, .lx, .auto: return .netease
        default: return nil
        }
    }

    private func load() async {
        isLoading = true
        failed = false

        // ★★ 2026-10-14 用户：「播放器界面点击歌手名字转跳后，歌手主页没有头像、
        //    没有歌曲、没有专辑、没有 EP 与单曲」。
        //
        //    根因（`PlayerBridgeModels.Track.from(musicItem:)`）：
        //      * `ArtistRef.id` 是 **`keyOf.hashValue` 拼出来的假 id**，不是平台歌手 id；
        //      * `singerMid` 被填成了 **歌曲 mid**（`musicItem.qqSongMid`）。
        //    而本页原先只按「网易云歌手 id」查 → 拿到假 id 必然查空；头像也从来没带过来。
        //
        //    修法：进页先用「歌手名 + 平台」解析一次**真实身份**（id / mid / 头像），
        //    再按平台取热门歌曲与专辑。解析不到时才退回传进来的 id。
        let sp = searchPlatform
        var realId = artistId
        var realMid: String?
        var resolvedAvatar: String?

        if let sp, !artistName.isEmpty {
            let found = await SearchService.shared
                .search(keyword: artistName, platform: sp, type: .artists, limit: 10).artists
            let exact = found.first { $0.name.caseInsensitiveCompare(artistName) == .orderedSame }
            if let match = exact ?? found.first {
                if !match.id.isEmpty { realId = match.id }
                realMid = match.mid
                resolvedAvatar = match.picURL
            }
        }

        let songsResult = await loadTopSongs(id: realId, mid: realMid)
        let albumsResult = await loadAlbums(id: realId)

        hotSongs = songsResult.songs
        albums = albumsResult.albums
        platformAlbumCount = albumsResult.count
        if resolvedName.isEmpty { resolvedName = artistName }
        if resolvedCover == nil {
            // ⚠️ 刻意**不写成一串 `??`**：`String? ?? String? ?? ...` 对 `??` 的两个重载
            //    都有解，表达式一长就会让类型检查器爆炸（本项目在 KugouMusicAPI 上
            //    踩过一次 `unable to type-check this expression in reasonable time`）。
            var candidate: String? = coverURL
            if candidate == nil { candidate = resolvedAvatar }
            if candidate == nil { candidate = songsResult.avatar }
            if candidate == nil { candidate = songsResult.songs.first?.albumCoverURL }
            resolvedCover = candidate
        }

        // 热门歌曲兜底：接口异常时用同名搜索补全（同样封顶 50 首）
        if hotSongs.isEmpty, let sp {
            hotSongs = await SearchService.shared
                .search(keyword: artistName, platform: sp, type: .songs, limit: 50).songs
        }

        failed = hotSongs.isEmpty && albums.isEmpty
        isLoading = false
    }

    /// 按平台取歌手热门歌曲；顺带带回平台给的歌手头像（酷狗 `singer/info` 有）。
    private func loadTopSongs(id: String, mid: String?) async -> (songs: [MusicItem], avatar: String?) {
        switch platform {
        case .qq:
            // QQ 歌手歌曲要的是 **singer mid**（不是歌曲 mid）
            let key = (mid?.isEmpty == false) ? (mid ?? id) : id
            if !key.isEmpty,
               let result = try? await QQMusicAPI.shared.singerSongs(singerMid: key, begin: 0, num: 50),
               !result.list.isEmpty {
                return (result.list, nil)
            }
        case .kugou:
            if !id.isEmpty,
               let detail = try? await KugouMusicAPI.shared.singerDetail(singerId: id),
               !detail.songs.isEmpty {
                return (detail.songs, detail.avatar)
            }
        default:
            if !id.isEmpty,
               let list = try? await NeteaseMusicAPI.shared.artistTopSongs(id: id),
               !list.isEmpty {
                return (list, nil)
            }
        }
        return ([], nil)
    }

    /// 按平台取歌手专辑。网易云有真实接口（含平台总数）；QQ / 酷狗退回「按歌手名搜专辑」。
    private func loadAlbums(id: String) async -> (albums: [WellAlbumSummary], count: Int?) {
        switch platform {
        case .qq, .kugou:
            break
        default:
            if !id.isEmpty,
               let result = try? await NeteaseMusicAPI.shared.artistAlbums(id: id),
               !result.albums.isEmpty {
                return (result.albums, result.platformAlbumCount)
            }
        }
        guard let sp else { return ([], nil) }
        let found = await SearchService.shared
            .search(keyword: artistName, platform: sp, type: .albums, limit: 50).albums
        return (found, nil)
    }
}

#Preview {
    // 触发构建
    NavigationStack {
        WellArtistHomeView(artistId: "6452", artistName: "示例歌手")
    }
}
