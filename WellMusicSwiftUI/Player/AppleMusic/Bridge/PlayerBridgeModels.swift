import Foundation
import SwiftUI

// MARK: - ArtistRef
struct ArtistRef: Hashable, Codable {
    let id: Int
    let name: String
    let singerMid: String?
}

// MARK: - Album
struct Album: Hashable, Codable {
    let id: Int
    let name: String
    let picUrl: String?
    let albumMid: String?
}

// MARK: - ArtistSummary / AlbumSummary (for Destination)
struct ArtistSummary: Hashable, Codable {
    let id: Int
    let name: String
    let picUrl: String?
    let sourcePlatform: String?
    let singerMid: String?
}

struct AlbumSummary: Hashable, Codable {
    let id: Int
    let name: String
    let picUrl: String?
    let sourcePlatform: String?
    let albumMid: String?
}

// MARK: - Track
/// 适配 AppleMusicPlayerView 的 Track 模型。基于 MusicItem 桥接生成。
struct Track: Hashable, Codable, Identifiable {
    let id: Int
    let name: String
    let artistNames: String
    let artists: [ArtistRef]
    let album: Album
    let duration: TimeInterval
    let sourcePlatform: String?
    /// fee == 1 || fee == 4 判定为 VIP；桥接层默认为 0
    let fee: Int
    let platformSongId: String?

    /// 从 MusicItem 构造 Track。id 使用稳定哈希（MusicItem 的 keyOf 的 hashValue 取正）。
    /// 由于 UI 侧队列使用 id: \.element.id，需保证同一首歌 id 一致。
    static func from(musicItem: MusicItem) -> Track {
        let stableId = abs(musicItem.keyOf.hashValue) % (Int.max / 2)

        let artistName = musicItem.artist ?? "未知艺术家"
        let artists = musicItem.artist?.split(separator: "/").enumerated().map { (idx, nameStr) -> ArtistRef in
            let trimmed = nameStr.trimmingCharacters(in: .whitespaces)
            let subId = abs("\(musicItem.keyOf)_artist_\(idx)".hashValue) % (Int.max / 2)
            return ArtistRef(id: subId, name: String(trimmed), singerMid: musicItem.qqSongMid)
        } ?? []

        let albumId = abs("\(musicItem.keyOf)_album".hashValue) % (Int.max / 2)
        let album = Album(
            id: albumId,
            name: musicItem.album ?? "未知专辑",
            picUrl: musicItem.albumCoverURL,
            albumMid: musicItem.qqSongMid
        )

        return Track(
            id: stableId,
            name: musicItem.title,
            artistNames: artistName,
            artists: artists.isEmpty ? [ArtistRef(id: stableId, name: artistName, singerMid: musicItem.qqSongMid)] : artists,
            album: album,
            duration: musicItem.duration,
            sourcePlatform: musicItem.source.rawValue,
            fee: 0,
            platformSongId: musicItem.platformId
        )
    }
}

// MARK: - LyricLine
struct LyricLine: Hashable, Identifiable {
    let id: Int?
    let time: TimeInterval
    let text: String
    let translation: String?
    let romaji: String?
    /// 逐字歌词：[(char, startTimeMs, endTimeMs)]
    let words: [(String, Int, Int)]?

    init(id: Int? = nil, time: TimeInterval, text: String,
         translation: String? = nil, romaji: String? = nil,
         words: [(String, Int, Int)]? = nil) {
        self.id = id
        self.time = time
        self.text = text
        self.translation = translation
        self.romaji = romaji
        self.words = words
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(time)
        hasher.combine(text)
    }

    static func == (lhs: LyricLine, rhs: LyricLine) -> Bool {
        lhs.time == rhs.time && lhs.text == rhs.text
    }
}

// MARK: - ParsedLyrics
struct ParsedLyrics: Equatable {
    let lines: [LyricLine]
    let isInstrumental: Bool
    let isEmpty: Bool

    init() {
        self.lines = []
        self.isInstrumental = false
        self.isEmpty = true
    }

    init(lines: [LyricLine], isInstrumental: Bool = false, isEmpty: Bool = false) {
        self.lines = lines
        self.isInstrumental = isInstrumental
        self.isEmpty = isEmpty
    }

    static let empty = ParsedLyrics(lines: [], isInstrumental: false, isEmpty: true)

    /// 从 LrcLine + WordLyricLine 数组构造
    static func from(lrc: [LrcLine], wordLyric: [WordLyricLine]) -> ParsedLyrics {
        if lrc.isEmpty && wordLyric.isEmpty {
            return .empty
        }

        // 优先逐字歌词；否则用逐行歌词
        if !wordLyric.isEmpty {
            let lines = wordLyric.enumerated().map { (idx, wl) -> LyricLine in
                let words: [(String, Int, Int)] = wl.words.map { word in
                    (word.char, Int(word.start * 1000), Int(word.end * 1000))
                }
                // 尝试从 lrc 中找匹配的翻译行
                let translation = lrc.first(where: { abs($0.time - wl.start) < 0.3 })?.translated
                return LyricLine(
                    id: idx,
                    time: wl.start,
                    text: wl.words.map { $0.char }.joined(),
                    translation: translation,
                    romaji: nil,
                    words: words
                )
            }
            return ParsedLyrics(lines: lines, isInstrumental: false, isEmpty: false)
        } else {
            let lines = lrc.enumerated().map { (idx, line) -> LyricLine in
                LyricLine(
                    id: idx,
                    time: line.time,
                    text: line.text,
                    translation: line.translated,
                    romaji: nil,
                    words: nil
                )
            }
            return ParsedLyrics(lines: lines, isInstrumental: false, isEmpty: false)
        }
    }
}

// MARK: - Destination
/// 导航目标枚举（简化版，仅满足 AppleMusicPlayerView 使用）
enum Destination: Hashable {
    case artist(Int)
    case artistWithMid(Int, String, ArtistSummary)
    case album(Int)
    case albumWithMid(Int, String, AlbumSummary)
}

// MARK: - RepeatMode (scoped for PlayerService)
enum RepeatMode: String, Codable {
    case off
    case all
    case one
}

// MARK: - PlaySource
/// 播放来源枚举（UI 使用 source: .none）
enum PlaySource: Int {
    case none = 0
    case search = 1
    case favorite = 2
    case playlist = 3
}
