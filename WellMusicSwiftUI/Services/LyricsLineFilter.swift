import Foundation

/// 歌词「非演唱行」过滤器（内置规则集：796 条关键词 + 8 条严格正则 + 判定算法）。
///
/// ## 为什么需要它（用户 2026-10-14 反馈）
/// 「每次刚听歌打开歌词界面歌词**全是艺术家名字**」——
/// 网易云的 LRC / YRC **开头**是一串带**正常时间戳**的职员表行，例如：
/// ```
/// [00:00.00] 作词 : Justin Bieber/Khalid/…
/// [00:00.00] 作曲 : …
/// [00:00.00] 编曲 : …
/// ```
/// 它们时间戳为 0，会抢在真正的第一句前面霸屏，看起来就是「整屏都是人名」。
/// 逐字 YRC 变体是 `[0,1000](0,1000,0) 作词 : …`（行时长**非 0**），
/// 所以 `LyricParser.parseYRC` 里现有的「零时长行」过滤**漏掉**了它们 ——
/// 本过滤器按**文本**判定、与时长为 0 无关，两者互补，后者保留不动。
///
/// ## 参考实现里它是怎么用的
/// `components/AMLLLyrics.tsx` 第 115 行：
/// `const filteredLyrics = useMemo(() => stripLyricMetadataLines(lyrics), [lyrics])`
/// —— 即「AMLL 歌词规则」的本体就是 `stripLyricMetadataLines`，本文件逐条对齐它：
/// 1. 严格正则命中（音乐人标签 / 未经授权 / 纯音乐占位 / DJ 音乐 / TME AI 字幕 / 邮箱水印…）；
/// 2. 含冒号：冒号**左侧职务 Key** 命中关键词库（支持单字/多字/复合双语）；
/// 3. 无冒号：整行等于多字关键词，或以多字关键词开头并紧跟合法分隔符；
/// 4. `matchMetadata`：前 5 行有效内容内匹配「歌曲名 + 歌手」的行（参考 API 里是可选开关，
///    本项目在 `LyricsService` 唯一收口点里打开 —— 它只会剔除**同时**含歌名与歌手名的行，
///    不会误伤真歌词）；
/// 5. 有效正文区间：剔除正文开唱前 / 结束后的空白与元数据行。
///
/// 过滤严格等于内置规则集，不做额外扩展 —— 规则之外的任何行一律保留。
///
/// ⚠️ 只按行过滤、**不动任何时间轴**（时间戳原样保留），对歌词同步零副作用。
/// ⚠️ 本项目模型没有 `isBG` 字段，故参考实现里的「背景行联动剔除」这一步不适用。
enum LyricsLineFilter {

    // MARK: - 对外入口（`LyricsService` 唯一收口点调用）

    /// 逐行歌词过滤（按 `text` 判定）。
    static func filter(_ lines: [LrcLine], item: MusicItem) -> [LrcLine] {
        let texts = lines.map(\.text)
        let excluded = excludedIndices(texts: texts, title: item.title, artist: item.artist)
        guard !excluded.isEmpty else { return lines }
        return lines.enumerated().filter { !excluded.contains($0.offset) }.map(\.element)
    }

    /// 逐字歌词过滤（文本 = 各字拼接，与参考实现 `getLineText` 等价）。
    static func filter(_ lines: [WordLyricLine], item: MusicItem) -> [WordLyricLine] {
        let texts = lines.map { $0.words.map(\.char).joined().trimmingCharacters(in: .whitespaces) }
        let excluded = excludedIndices(texts: texts, title: item.title, artist: item.artist)
        guard !excluded.isEmpty else { return lines }
        return lines.enumerated().filter { !excluded.contains($0.offset) }.map(\.element)
    }

    // MARK: - 核心：算出要剔除的下标集合

    private static func excludedIndices(texts: [String], title: String, artist: String?) -> Set<Int> {
        guard !texts.isEmpty else { return [] }
        var excluded = Set<Int>()

        // 第一阶段：制作人 / 版权 / 段落标记 / 人名串 —— 逐行精准判定
        for (idx, text) in texts.enumerated() where !text.isEmpty {
            if isMetadataLine(text) { excluded.insert(idx) }
        }

        // 第二阶段：歌名 + 歌手匹配（只在**前 5 行有效内容**内扫，与参考实现一致）
        let artists = splitArtists(artist)
        let lowerTitle = title.trimmingCharacters(in: .whitespaces).lowercased()
        if !lowerTitle.isEmpty, !artists.isEmpty {
            var scanned = 0
            for idx in texts.indices where scanned < 5 {
                if excluded.contains(idx) { continue }
                let text = texts[idx]
                if text.isEmpty { continue }
                scanned += 1
                let lower = text.lowercased()
                if lower.contains(lowerTitle),
                   artists.contains(where: { lower.contains($0) }) {
                    excluded.insert(idx)
                }
            }
        }

        // 第三阶段：定位有效正文区间 —— 正文开唱前 / 结束后的空白与元数据行整段剔除
        guard let firstContent = texts.indices.first(where: { !excluded.contains($0) && !texts[$0].isEmpty }) else {
            return Set(texts.indices)   // 整篇都是元数据 → 全部剔除
        }
        var lastContent = firstContent
        for idx in stride(from: texts.count - 1, through: firstContent, by: -1)
        where !excluded.contains(idx) && !texts[idx].isEmpty {
            lastContent = idx
            break
        }
        for idx in 0..<firstContent { excluded.insert(idx) }
        for idx in (lastContent + 1)..<texts.count { excluded.insert(idx) }

        return excluded
    }

    /// `"A/B、C & D"` → `["a", "b", "c", "d"]`（小写，用于 `contains` 判断）。
    private static func splitArtists(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw
            .components(separatedBy: CharacterSet(charactersIn: "/、,&"))
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    // MARK: - 单行判定（严格等于内置规则集的判定算法）

    private static func isMetadataLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }

        // —— 1. 严格正则 ——
        if matchesAnyRegex(trimmed) { return true }

        // —— 2 / 3. 关键词库 ——
        let cleaned = cleanTextForCheck(trimmed)
        if let colon = cleaned.rangeOfCharacter(from: CharacterSet(charactersIn: ":：")) {
            let rawKey = String(cleaned[cleaned.startIndex..<colon.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard !rawKey.isEmpty else { return false }
            let key = normalizeKw(cleanTextForCheck(rawKey))
            guard !key.isEmpty else { return false }
            if key.count >= 1, keywordSet.contains(key) { return true }
            // 「作词+作曲」「制作人/编曲」这类复合职务：前缀命中关键词后必须紧跟连接符/字母
            for kw in keywordsStarting(with: key) where key.hasPrefix(kw) {
                guard let next = character(in: key, at: kw.count) else { continue }
                if next == "/" || next == "&" || next == "、" || next == "+"
                    || (next >= "a" && next <= "z") {
                    return true
                }
            }
            return false
        }

        let normalized = normalizeKw(cleaned)
        if normalized.count >= 2, keywordSet.contains(normalized) { return true }
        // 无冒号回退：多字关键词前缀 + 紧随合法分隔符（如「作词-青石」「编曲（林一）」）
        for kw in keywordsStarting(with: normalized) where kw.count >= 2 {
            guard normalized.hasPrefix(kw) else { continue }
            if let next = character(in: normalized, at: kw.count), noColonSeparators.contains(next) {
                return true
            }
        }
        return false
    }

    // MARK: - 关键词库（`stripLyricMetadata` 的 defaultKeywords，自动移植）

    /// 模块级：归一化后的完整关键词集合（精确匹配用，O(1)）
    private static let keywordSet: Set<String> = Set(
        LyricsMetadataKeywords.keywords.map(normalizeKw))

    /// 模块级：按**首字符**分桶的关键词表 —— 前缀匹配时只扫同首字符的那一小撮，
    /// 避免每行都对 700+ 关键词做一次 `hasPrefix`（列表滚动 / 切歌时的无谓开销）。
    private static let keywordsByFirstChar: [Character: [String]] = {
        var map: [Character: [String]] = [:]
        for kw in LyricsMetadataKeywords.keywords.map(normalizeKw) {
            guard let first = kw.first else { continue }
            map[first, default: []].append(kw)
        }
        return map
    }()

    private static func keywordsStarting(with text: String) -> [String] {
        guard let first = text.first else { return [] }
        return keywordsByFirstChar[first] ?? []
    }

    /// 无冒号回退匹配允许的分隔符（归一化后形态）。
    private static let noColonSeparators: Set<Character> = [
        ":", ",", ".", "!", "-", "_", "(", "[", "{", "【", "『", "「", "。", "·",
    ]

    // MARK: - 严格正则（内置规则集 8 条）

    private static let strictRegexes: [NSRegularExpression] =
        LyricsMetadataKeywords.regexPatterns.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }

    private static func matchesAnyRegex(_ text: String) -> Bool {
        strictRegexes.contains { $0.firstMatch(in: text) != nil }
    }

    // MARK: - 工具

    private static func normalizeKw(_ str: String) -> String {
        str.precomposedStringWithCompatibilityMapping
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    private static func character(in text: String, at offset: Int) -> Character? {
        guard offset >= 0, offset < text.count else { return nil }
        return text[text.index(text.startIndex, offsetBy: offset)]
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // 编译失败会让整条规则静默失效，所以这里用 `!` 强制暴露（内置常量，构建期就能发现）
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// 剥除文本两端的成对/预留外层包装括号（圆、方、花、书名等），最多 5 轮。
    private static let bracketPairs: [(open: String, close: String)] = [
        ("(", ")"), ("（", "）"), ("【", "】"), ("[", "]"), ("{", "}"), ("『", "』"), ("「", "」"),
    ]

    private static func cleanTextForCheck(_ text: String) -> String {
        var processed = text.trimmingCharacters(in: .whitespaces)
        var changed = true
        var loop = 0
        while changed && loop < 5 {
            changed = false
            loop += 1
            for pair in bracketPairs {
                guard processed.hasPrefix(pair.open) else { continue }
                if processed.hasSuffix(pair.close), processed.count >= pair.open.count + pair.close.count {
                    processed = String(processed.dropFirst(pair.open.count).dropLast(pair.close.count))
                        .trimmingCharacters(in: .whitespaces)
                    changed = true
                    break
                }
                let searchStart = processed.index(processed.startIndex, offsetBy: pair.open.count)
                if let closeRange = processed.range(of: pair.close, range: searchStart..<processed.endIndex) {
                    let contentAfter = String(processed[closeRange.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                    if !contentAfter.isEmpty {
                        processed = contentAfter
                        changed = true
                        break
                    }
                }
            }
        }
        return processed
    }
}

private extension NSRegularExpression {
    func firstMatch(in string: String) -> NSTextCheckingResult? {
        firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length))
    }
}
