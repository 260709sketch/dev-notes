import SwiftUI

// MARK: - 播放页 → 主框架的跳转请求

/// 播放页要跳转的目标（自带展示所需信息，可直接放进 `NavigationPath`）。
///
/// 为什么不用 `Destination`：那个枚举不携带名字/封面（网易云的专辑走「无 mid」分支时
/// 只剩一个数字 id），直接 push 会得到一个标题空白的详情页。这里把渲染要用的字段
/// 一次带齐，导航栈那侧就不需要再回查接口。
struct NowPlayingDestination: Hashable {
    enum Kind: Hashable {
        case artist
        case album
    }

    let kind: Kind
    /// 平台侧 id：网易云用数字 id 的字符串形式；QQ 用 mid；酷狗用 hash。
    let platformId: String
    /// 展示用名称（歌手名 / 专辑名）。
    let name: String
    let coverURL: String?
    let platform: MusicSource
    /// 专辑详情页头部的歌手名（跳歌手时为空串）。
    let artistName: String
}

extension MusicSource {
    /// 桥接层的 `sourcePlatform` 短码（"tx"/"kg"/"kw"）→ 统一枚举。
    static func fromPlatformTag(_ tag: String?) -> MusicSource {
        switch tag {
        case "tx": return .qq
        case "kg": return .kugou
        case "kw": return .kuwo
        case "lx": return .lx
        case "wy", "netease": return .netease
        default: return .netease
        }
    }
}

extension NowPlayingDestination {
    /// 由播放器的 `Track` + 某个歌手构造歌手跳转目标。
    /// QQ / 酷狗必须带 mid / hash（只有 mid 才查得到），网易云按数字 id 跳。
    static func artist(from track: Track, artist: ArtistRef) -> NowPlayingDestination? {
        let mid = artist.singerMid?.trimmingCharacters(in: .whitespaces) ?? ""
        let platformId = mid.isEmpty ? (artist.id != 0 ? String(artist.id) : "") : mid
        guard !platformId.isEmpty, !artist.name.isEmpty else { return nil }
        return NowPlayingDestination(kind: .artist,
                                     platformId: platformId,
                                     name: artist.name,
                                     coverURL: nil,
                                     platform: MusicSource.fromPlatformTag(track.sourcePlatform),
                                     artistName: "")
    }

    /// 由播放器的 `Track` 构造专辑跳转目标。
    static func album(from track: Track) -> NowPlayingDestination? {
        guard !track.album.name.isEmpty else { return nil }
        let mid = track.album.albumMid?.trimmingCharacters(in: .whitespaces) ?? ""
        let platformId = mid.isEmpty ? String(track.album.id) : mid
        guard !platformId.isEmpty else { return nil }
        return NowPlayingDestination(kind: .album,
                                     platformId: platformId,
                                     name: track.album.name,
                                     coverURL: track.album.picUrl,
                                     platform: MusicSource.fromPlatformTag(track.sourcePlatform),
                                     artistName: track.artistNames)
    }
}

// MARK: - 跳转请求通道

/// 播放页 → 主框架的单向请求通道。
///
/// 播放页是 `.fullScreenCover` 呈现的，自己不在任何 `NavigationStack` 里，
/// 所以「点歌手名 / 专辑名跳转」只能：先关掉播放页 → 再把目标 push 进当前 Tab 的导航栈。
/// 用这个极小的单例把请求传出去：
///   * 播放页调 `request(_:)`
///   * `MainTabView` 订阅 `pending`，push 完成后调 `consume()`
@MainActor
final class NowPlayingNavigator: ObservableObject {
    static let shared = NowPlayingNavigator()
    private init() {}

    /// 待处理的跳转请求。`MainTabView` 消费后置回 nil。
    @Published var pending: NowPlayingDestination?

    func request(_ destination: NowPlayingDestination) {
        pending = destination
    }

    func consume() {
        if pending != nil { pending = nil }
    }
}
