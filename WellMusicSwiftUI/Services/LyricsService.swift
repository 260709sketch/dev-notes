import Foundation

/// 歌词服务：按「歌词来源」优先取词 + 逐行/逐字解析 + 单曲缓存（防重复拉取）
@MainActor
final class LyricsService {
    static let shared = LyricsService()
    private init() {}

    /// 单曲歌词缓存：key = item.keyOf，value = 拉取结果（含来源）
    private var cache: [String: LyricResult] = [:]
    /// 缓存上限，防止无限增长
    private let cacheLimit = 200

    struct LyricResult {
        var lrc: [LrcLine]
        var wordLyric: [WordLyricLine]?
        var source: MusicSource
    }

    // MARK: 对外入口

    /// 为当前歌曲拉取歌词（按 AppState.lyricSource 优先）
    /// - 若指定来源失败，回退到其余平台兜底
    /// - 同 key 命中缓存时直接返回，避免听同一首时重复请求
    func lyrics(for item: MusicItem) async -> LyricResult? {
        let key = item.keyOf
        if let cached = cache[key] { return cached }

        let preferred = AppState.shared.lyricSource
        let fallbacks: [MusicSource] = {
            switch preferred {
            case .auto: return [.netease, .qq, .kugou, .kuwo]
            default:
                var list = [preferred]
                for s in [MusicSource.qq, .netease, .kugou, .kuwo] where s != preferred {
                    list.append(s)
                }
                return list
            }
        }()

        for source in fallbacks {
            if let result = await fetchFrom(source, item: item), !result.lrc.isEmpty {
                // 顺序去重 + 上限裁剪
                if cache.count >= cacheLimit { cache.removeValue(forKey: cache.keys.first ?? key) }
                cache[key] = result
                return result
            }
        }
        return nil
    }

    /// 清除指定歌曲缓存（切歌时由 PlayerCore 调用，保证换歌必重新拉取）
    func clearCache(for item: MusicItem) {
        cache.removeValue(forKey: item.keyOf)
    }

    // MARK: 平台拉取

    private func fetchFrom(_ source: MusicSource, item: MusicItem) async -> LyricResult? {
        do {
            switch source {
            case .qq: return try await fetchQQ(item: item)
            case .netease: return try await fetchNetease(item: item)
            case .kugou: return try await fetchKugou(item: item)
            case .kuwo: return try await fetchKuwo(item: item)
            case .auto: return nil
            }
        } catch {
            return nil
        }
    }

    // MARK: QQ 音乐（lyric + yrc 逐字）

    private func fetchQQ(item: MusicItem) async throws -> LyricResult? {
        guard let mid = item.qqSongMid ?? item.platformId else { return nil }
        let url = "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?" +
            "format=json&nobase64=1&songmid=\(mid)"
        let resp = try await NetworkClient.shared.get(url, headers: ["Referer": "https://y.qq.com/"])
        guard let json = NetworkClient.jsonObject(resp.data) else { return nil }
        let lrcText = json["lyric"] as? String ?? ""
        let lrc = LyricParser.parseLRC(lrcText)
        if lrc.isEmpty { return nil }
        var word: [WordLyricLine]?
        if AppState.shared.karaokeEnabled,
           let yrcText = json["yrc"] as? String, !yrcText.isEmpty {
            word = LyricParser.parseYRC(yrcText)
        }
        return LyricResult(lrc: lrc, wordLyric: word, source: .qq)
    }

    // MARK: 网易云（lrc + tlyric 翻译 + yrc 逐字）

    private func fetchNetease(item: MusicItem) async throws -> LyricResult? {
        guard let id = item.neteaseId ?? item.platformId else { return nil }
        let url = "https://music.163.com/api/song/lyric?id=\(id)&lv=1&kv=1&tv=-1"
        let resp = try await NetworkClient.shared.get(url, headers: ["Referer": "https://music.163.com/"])
        guard let json = NetworkClient.jsonObject(resp.data) else { return nil }
        let lrcText = (json["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
        var lrc = LyricParser.parseLRC(lrcText)
        if lrc.isEmpty { return nil }
        if let tlyric = (json["tlyric"] as? [String: Any])?["lyric"] as? String,
           !tlyric.isEmpty {
            LyricParser.mergeTranslation(&lrc, translation: tlyric)
        }
        var word: [WordLyricLine]?
        if AppState.shared.karaokeEnabled,
           let yrcText = (json["yrc"] as? [String: Any])?["lyric"] as? String,
           !yrcText.isEmpty {
            word = LyricParser.parseYRC(yrcText)
        }
        return LyricResult(lrc: lrc, wordLyric: word, source: .netease)
    }

    // MARK: 酷狗（lyrics.kugou search + download）

    private func fetchKugou(item: MusicItem) async throws -> LyricResult? {
        guard let hash = item.kugouHash ?? item.platformId else { return nil }
        let keyword = "\(item.title) \(item.artist ?? "")"
        let searchURL = "https://lyrics.kugou.com/search?ver=1&man=yes&client=pc&" +
            "keyword=\(kugouEncode(keyword))&duration=\(Int(item.duration))"
        let searchResp = try await NetworkClient.shared.get(searchURL, headers: [
            "Referer": "https://www.kugou.com/",
        ])
        guard let searchJSON = NetworkClient.jsonObject(searchResp.data),
              let candidates = searchJSON["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let lrcID = first["id"] as? String,
              let accessKey = first["accesskey"] as? String else {
            // 兜底：play/getdata 接口直接带歌词
            return try? await fetchKugouFromGetdata(hash: hash, keyword: keyword)
        }
        let downURL = "https://lyrics.kugou.com/download?ver=1&client=pc&" +
            "id=\(lrcID)&accesskey=\(kugouEncode(accessKey))&fmt=lrc&charset=utf8"
        let downResp = try await NetworkClient.shared.get(downURL, headers: ["Referer": "https://www.kugou.com/"])
        guard let downJSON = NetworkClient.jsonObject(downResp.data),
              let content = downJSON["content"] as? String else {
            return try? await fetchKugouFromGetdata(hash: hash, keyword: keyword)
        }
        let lrc = LyricParser.parseLRC(content)
        guard !lrc.isEmpty else { return nil }
        return LyricResult(lrc: lrc, wordLyric: nil, source: .kugou)
    }

    /// 酷狗 getdata 兜底（该接口返回 JSON 歌词行）
    private func fetchKugouFromGetdata(hash: String, keyword: String) async throws -> LyricResult? {
        let url = "https://wwwapi.kugou.com/yy/index.php?r=play/getdata&hash=\(hash)&album_id=&mid=0&platid=4"
        let resp = try await NetworkClient.shared.get(url, headers: ["Referer": "https://www.kugou.com/"])
        guard let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let lyrics = data["lyrics"] as? String, !lyrics.isEmpty else { return nil }
        let lrc = LyricParser.parseLRC(lyrics)
        guard !lrc.isEmpty else { return nil }
        return LyricResult(lrc: lrc, wordLyric: nil, source: .kugou)
    }

    // MARK: 酷我（api/v1/www/music/lyric）

    private func fetchKuwo(item: MusicItem) async throws -> LyricResult? {
        guard let rid = item.kuwoRid ?? item.platformId else { return nil }
        let url = "https://www.kuwo.cn/api/v1/www/music/lyric?musicId=\(rid)&httpsStatus=1"
        let resp = try await NetworkClient.shared.get(url, headers: await KuwoMusicAPI.shared.kuwoHeaders())
        guard let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let lrcText = data["lrc"] as? String, !lrcText.isEmpty else { return nil }
        let lrc = LyricParser.parseKuwoLRC(lrcText)
        guard !lrc.isEmpty else { return nil }
        return LyricResult(lrc: lrc, wordLyric: nil, source: .kuwo)
    }

    private func kugouEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}

// MARK: - 歌词解析器

enum LyricParser {

    // MARK: 标准 LRC（[mm:ss.xx] 文本；支持多个时间戳）

    static func parseLRC(_ text: String) -> [LrcLine] {
        var lines: [LrcLine] = []
        var timeIndex: [TimeInterval: Int] = [:]  // 去重用
        let regex = try? NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let regex else { continue }
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            // 取最后一个时间戳之后的内容作为歌词文本（去掉元信息行）
            let contentStart = matches.last.map { NSMaxRange($0.range) } ?? 0
            let content = ns.substring(from: contentStart).trimmingCharacters(in: .whitespaces)
            if content.isEmpty { continue }
            if content.hasPrefix("[") { continue }  // 元信息（ti/ar 等）
            for m in matches {
                let minute = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let second = Double(ns.substring(with: m.range(at: 2))) ?? 0
                let fracRaw = m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3))
                let frac = Double(fracRaw) ?? 0
                let time = minute * 60 + second + frac / 1000.0
                if timeIndex[time] == nil {
                    timeIndex[time] = lines.count
                    lines.append(LrcLine(time: time, text: content))
                }
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    // MARK: 翻译合并（网易 tlyric 按时间对齐挂到同一行）

    static func mergeTranslation(_ lrc: inout [LrcLine], translation: String) {
        var map: [TimeInterval: String] = [:]
        let regex = try? NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\](.*)"#)
        for rawLine in translation.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let regex else { continue }
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let minute = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let second = Double(ns.substring(with: m.range(at: 2))) ?? 0
            let frac = Double(ns.substring(with: m.range(at: 3))) ?? 0
            let time = minute * 60 + second + frac / 1000.0
            let text = ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            map[time] = text
        }
        for i in lrc.indices {
            if let trans = map[lrc[i].time] {
                lrc[i].translated = trans
            }
        }
    }

    // MARK: 逐字 YRC（网易/QQ 的 <mm:ss.xx>字<mm:ss.xx> 结构）

    static func parseYRC(_ text: String) -> [WordLyricLine] {
        var result: [WordLyricLine] = []
        let timeTag = try? NSRegularExpression(pattern: #"<(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?>"#)
        let header = try? NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let timeTag, let header else { continue }
            let ns = line as NSString
            // 行起始时间
            guard let hm = header.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let lineStart = parseTime(m: hm, ns: ns)
            // 所有 <time> 标签
            let tags = timeTag.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !tags.isEmpty else { continue }
            var words: [WordLyricLine.Word] = []
            for i in 0..<tags.count {
                let tag = tags[i]
                let start = parseTime(m: tag, ns: ns)
                let end: TimeInterval
                let startChar = NSMaxRange(tag.range)
                if i + 1 < tags.count {
                    end = parseTime(m: tags[i + 1], ns: ns)
                } else {
                    end = start
                }
                let charEnd = i + 1 < tags.count ? tag.range.location + tags[i + 1].range.location - startChar : ns.length
                let charRange = NSRange(location: startChar, length: max(0, charEnd))
                let char = ns.substring(with: charRange).replacingOccurrences(of: "<", with: "")
                guard !char.isEmpty else { continue }
                words.append(WordLyricLine.Word(char: char, start: start, end: max(start, end)))
            }
            guard !words.isEmpty else { continue }
            result.append(WordLyricLine(
                start: lineStart,
                end: words.last?.end ?? lineStart,
                words: words
            ))
        }
        return result.sorted { $0.start < $1.start }
    }

    // MARK: 酷我 LRC（行内 [mm:ss.xx] 与标准一致，但可能带 [offset] 等）

    static func parseKuwoLRC(_ text: String) -> [LrcLine] {
        parseLRC(text)
    }

    private static func parseTime(m: NSTextCheckingResult, ns: NSString) -> TimeInterval {
        let minute = Double(ns.substring(with: m.range(at: 1))) ?? 0
        let second = Double(ns.substring(with: m.range(at: 2))) ?? 0
        let frac = Double(ns.substring(with: m.range(at: 3))) ?? 0
        // 时间戳百分位：00:12.34 → frac=34 → 0.34
        if frac >= 100 { return minute * 60 + second + frac / 1000.0 }
        if frac >= 10 { return minute * 60 + second + frac / 100.0 }
        return minute * 60 + second + frac / 1000.0
    }
}