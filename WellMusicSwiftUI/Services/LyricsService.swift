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

    /// 为当前歌曲拉取歌词：固定按「网易云 → QQ → 酷狗 → 酷我」顺序取，命中即返回。
    /// - 歌词来源已在设置页移除，统一用这条内置优先级链
    /// - 同 key 命中缓存时直接返回，避免听同一首时重复请求
    func lyrics(for item: MusicItem) async -> LyricResult? {
        let key = item.keyOf
        if let cached = cache[key] { return cached }

        let fallbacks: [MusicSource] = [.netease, .qq, .kugou, .kuwo]

        // 优先要**逐字**结果。
        //
        // 酷狗 / 酷我根本不提供逐字，QQ / 网易云只对部分歌曲提供。若像以前那样
        // 「第一个有歌词的源就返回」，首个源只给到逐行时就会直接定稿，
        // 后面明明有逐字的源也不会再问 —— 表现就是「这首歌永远没有逐字」。
        //
        // 现在：逐行结果先留着兜底，继续往后找带逐字的源；全都只有逐行时再用兜底。
        var lineOnlyFallback: LyricResult?

        for source in fallbacks {
            guard let result = await fetchFrom(source, item: item), !result.lrc.isEmpty else { continue }
            if let word = result.wordLyric, !word.isEmpty {
                store(result, for: key)
                return result
            }
            if lineOnlyFallback == nil { lineOnlyFallback = result }
        }

        if let fallback = lineOnlyFallback {
            store(fallback, for: key)
            return fallback
        }
        return nil
    }

    /// 写入缓存（顺序去重 + 上限裁剪）。
    private func store(_ result: LyricResult, for key: String) {
        if cache.count >= cacheLimit { cache.removeValue(forKey: cache.keys.first ?? key) }
        cache[key] = result
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
            case .lx:
                // 自定义音源条目：还原成底层平台条目后再按平台取词
                let unwrapped = item.unwrappedFromCustomSource()
                return await fetchFrom(unwrapped.source, item: unwrapped)
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
        // 逐字歌词（卡拉OK）固定开启：有 YRC 就用，没有则退回逐行 LRC
        if let yrcText = json["yrc"] as? String, !yrcText.isEmpty {
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
        // 逐字歌词（卡拉OK）固定开启：有 YRC 就用，没有则退回逐行 LRC
        if let yrcText = (json["yrc"] as? [String: Any])?["lyric"] as? String,
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

    // MARK: 逐字 YRC

    /// 解析网易云 / QQ 音乐的逐字歌词（YRC）。
    ///
    /// ## 真实格式
    ///
    /// ```
    /// [行起始毫秒,行时长毫秒](字起始毫秒,字时长毫秒,标志)字(…)字
    /// ```
    ///
    /// 例如：`[0,1830](0,380,0)作(380,300,0)词(680,200,0)：`
    ///
    /// ## ⚠️ 曾经的错误（「AMLL 歌词没有逐字」的根因）
    ///
    /// 早先这里按 LRC 的 `<mm:ss.xxx>` 去匹配时间标签，而 YRC 的标签里是
    /// **纯毫秒整数**、且用的是圆括号 —— 两个正则都永远匹配不到，
    /// `parseYRC` 于是对每首歌都返回空数组。空数组会让 `ParsedLyrics.from`
    /// 走「逐行歌词」分支，表现就是「歌词只有整行高亮，没有逐字」。
    ///
    /// 返回的 `WordLyricLine.start/end` 单位是**秒**（与模型一致；
    /// `ParsedLyrics.from` 再乘 1000 转成毫秒喂给歌词页）。
    static func parseYRC(_ text: String) -> [WordLyricLine] {
        var result: [WordLyricLine] = []
        // 行头必须是 `[数字,数字]`；顶部那些 JSON 元信息（credits）行不匹配，会被跳过。
        guard let lineRE = try? NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#),
              let wordRE = try? NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)([^(]*)"#)
        else { return [] }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)

            guard let head = lineRE.firstMatch(in: line, range: full),
                  head.numberOfRanges >= 3 else { continue }
            let lineStartMs = Double(ns.substring(with: head.range(at: 1))) ?? 0

            var words: [WordLyricLine.Word] = []
            var composed = ""
            for m in wordRE.matches(in: line, range: full) {
                guard m.numberOfRanges >= 4 else { continue }
                let startMs = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let durationMs = Double(ns.substring(with: m.range(at: 2))) ?? 0
                let piece = ns.substring(with: m.range(at: 3))
                guard !piece.isEmpty else { continue }
                let start = startMs / 1000
                // 时长为 0 时至少给 1ms，避免下游出现 end == start 的零宽片段
                let end = (startMs + max(durationMs, 1)) / 1000
                words.append(WordLyricLine.Word(char: piece, start: start, end: end))
                composed += piece
            }
            guard !words.isEmpty, !composed.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            result.append(WordLyricLine(
                start: lineStartMs / 1000,
                end: words.last?.end ?? lineStartMs / 1000,
                words: words
            ))
        }
        return result.sorted { $0.start < $1.start }
    }

    // MARK: 酷我 LRC（行内 [mm:ss.xx] 与标准一致，但可能带 [offset] 等）

    static func parseKuwoLRC(_ text: String) -> [LrcLine] {
        parseLRC(text)
    }
}