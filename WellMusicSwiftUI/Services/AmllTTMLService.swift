import Foundation

/// 在线 TTML 歌词（AMLL TTML DB 生态）。
///
/// 抓取语义（与 SPlayer-Next 的实现约定对齐）：
/// - 设置项 `lyric.enableOnlineTTMLLyric`（总开关，默认开）
/// - 设置项 `lyric.amllDbServer`（URL 模板，必须同时包含 `%p` 与 `%s`；
///   `%p` = 平台目录名，`%s` = 歌曲 id）
/// - 8 秒超时；HTTP 200 + 空 body 与 404 都写**负缓存**（72 小时内不再请求）；
///   正常内容写**正缓存**（长期有效）；其它状态码（如 5xx）不缓存，下次重试
/// - 同 key 并发请求去重（inflight 合并）
@MainActor
enum AmllTTMLService {
    /// 默认的 AMLL TTML DB 地址模板。
    static let defaultTemplate = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/refs/heads/main/%p/%s.ttml"
    static let enabledKey = "lyric.enableOnlineTTMLLyric"
    static let serverKey = "lyric.amllDbServer"

    private static let negativeTTL: TimeInterval = 72 * 3600

    /// AMLL DB 的平台目录 + 候选 id（DB 只覆盖网易云 / QQ 与我们对应的两个目录）。
    static func candidates(for item: MusicItem) -> (path: String, ids: [String])? {
        switch item.source {
        case .netease:
            guard let id = item.neteaseId, !id.isEmpty else { return nil }
            return ("ncm-lyrics", [id])
        case .qq:
            guard let mid = item.qqSongMid, !mid.isEmpty else { return nil }
            return ("qq-lyrics", [mid])
        default:
            return nil
        }
    }

    // MARK: 内存态（缓存 + 并发去重）

    private static var memoryCache: [String: String] = [:]
    private static var negativeCache: [String: Date] = [:]
    private static var inflight: [String: Task<String?, Never>] = [:]

    // MARK: 对外入口

    /// 依次尝试多个候选 id，命中即停。开关关闭 / 模板不合法时直接返回 nil（零网络成本）。
    static func fetch(platformPath: String, ids: [String]) async -> String? {
        let defaults = UserDefaults.standard
        let enabled = (defaults.object(forKey: enabledKey) as? Bool) ?? true
        guard enabled else { return nil }
        let rawTemplate = defaults.string(forKey: serverKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let template = (rawTemplate?.isEmpty == false ? rawTemplate! : defaultTemplate)
        guard template.contains("%p"), template.contains("%s") else { return nil }

        for id in ids where !id.isEmpty {
            if let content = await fetchOne(template: template, platformPath: platformPath, id: id) {
                return content
            }
        }
        return nil
    }

    // MARK: 单 id 抓取（缓存 + 去重）

    private static func fetchOne(template: String, platformPath: String, id: String) async -> String? {
        let key = "\(platformPath):\(id)"

        if let cached = memoryCache[key] { return cached }

        // 磁盘正缓存
        if let cached = readDiskCache(key: key) {
            memoryCache[key] = cached
            return cached
        }
        // 磁盘负缓存（72 小时内不重试）
        if let missAt = readNegativeStamp(key: key),
           Date().timeIntervalSince(missAt) < negativeTTL {
            return nil
        }
        // 并发去重
        if let task = inflight[key] { return await task.value }

        let task = Task<String?, Never> {
            guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: template
                    .replacingOccurrences(of: "%p", with: platformPath)
                    .replacingOccurrences(of: "%s", with: encoded)) else {
                return nil
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if status == 200 {
                    let content = String(data: data, encoding: .utf8) ?? ""
                    if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        writeNegativeStamp(key: key)   // 200 + 空 body → 负缓存
                        return nil
                    }
                    memoryCache[key] = content
                    writeDiskCache(key: key, content: content)
                    return content
                }
                if status == 404 {
                    writeNegativeStamp(key: key)
                    return nil
                }
                return nil   // 其它状态码不缓存，下次重试
            } catch {
                return nil
            }
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        return result
    }

    // MARK: 磁盘缓存（Caches/amll-ttml/）

    private static var cacheDirectory: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("amll-ttml", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func cacheFileURL(key: String) -> URL? {
        guard let dir = cacheDirectory else { return nil }
        let safe = key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return dir.appendingPathComponent(safe)
    }

    private static func readDiskCache(key: String) -> String? {
        guard let url = cacheFileURL(key: key) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func writeDiskCache(key: String, content: String) {
        guard let url = cacheFileURL(key: key) else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func readNegativeStamp(key: String) -> Date? {
        guard let url = cacheFileURL(key: key)?.appendingPathExtension("miss") else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date
    }

    private static func writeNegativeStamp(key: String) {
        guard let url = cacheFileURL(key: key)?.appendingPathExtension("miss") else { return }
        try? Data().write(to: url)
    }
}

// MARK: - TTML 解析（核心子集）

/// TTML 歌词文档解析结果。
struct TTMLParseResult {
    /// 逐行歌词（行文本 = 各词拼接；翻译来自 `ttm:role="x-translation"` 片段）。
    var lines: [LrcLine]
    /// 逐字歌词（有 `begin` 的 span 才会生成；无逐字时为空数组）。
    var words: [WordLyricLine]
}

/// TTML 解析器（AMLL TTML DB 使用的结构：`<p begin end>` + `<span begin end>`）。
///
/// 只覆盖渲染需要的核心子集：行 / 词 / 行级翻译（`x-translation`）/ 背景行跳过
/// （`ttm:role="x-bg"`）。ruby、音译、agent 分组等不影响主歌词显示的部分忽略。
enum TTMLParser {
    static func parse(_ xml: String) -> TTMLParseResult {
        let delegate = Delegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.result()
    }

    /// TTML 时间字符串 → 秒。
    ///
    /// 支持：`1.5s` / `250ms` / `2m` / `1h`（带单位）、`mm:ss.xxx`、`hh:mm:ss.xxx`、
    /// `hh:mm:ss:ff`（帧，按 30fps）、纯数字（秒）。
    static func parseTime(_ value: String) -> Double {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return 0 }

        // 带单位（ms/h/m/s）
        if let range = text.range(of: #"^(\d+(?:\.\d+)?)(ms|h|m|s)$"#, options: .regularExpression) {
            let matched = String(text[range])
            if matched.hasSuffix("ms"), let v = Double(matched.dropLast(2)) { return v / 1000 }
            if matched.hasSuffix("h"), let v = Double(matched.dropLast()) { return v * 3600 }
            if matched.hasSuffix("m"), let v = Double(matched.dropLast()) { return v * 60 }
            if matched.hasSuffix("s"), let v = Double(matched.dropLast()) { return v }
        }
        // 纯数字（秒）
        if !text.contains(":"), let v = Double(text) { return v }

        let parts = text.split(separator: ":").map { Double($0) }
        guard parts.allSatisfy({ $0 != nil }) else { return 0 }
        let values = parts.compactMap { $0 }
        switch values.count {
        case 2: return values[0] * 60 + values[1]
        case 3: return values[0] * 3600 + values[1] * 60 + values[2]
        case 4: return values[0] * 3600 + values[1] * 60 + values[2] + values[3] / 30
        default: return 0
        }
    }

    // MARK: XMLParser 代理

    private final class Delegate: NSObject, XMLParserDelegate {
        private struct LineDraft {
            var begin: Double
            var end: Double
            var words: [(text: String, start: Double, end: Double)]
            var translation: String?
        }

        private var completed: [LineDraft] = []
        private var currentLine: LineDraft?
        private var spanText: String?
        private var spanStart: Double = 0
        private var spanEnd: Double = 0
        private var spanIsTranslation = false
        private var spanIsBackground = false

        func result() -> TTMLParseResult {
            var lines: [LrcLine] = []
            var wordLines: [WordLyricLine] = []
            for draft in completed {
                let text = draft.words.map(\.text).joined()
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let lineStart = draft.begin > 0 ? draft.begin : (draft.words.first?.start ?? 0)
                lines.append(LrcLine(
                    time: lineStart,
                    text: trimmed,
                    translated: draft.translation.map { $0.trimmingCharacters(in: .whitespaces) }
                        .flatMap { $0.isEmpty ? nil : $0 }))
                if !draft.words.isEmpty {
                    let words = draft.words.map { word in
                        WordLyricLine.Word(char: word.text,
                                           start: word.start,
                                           end: max(word.end, word.start + 0.001))
                    }
                    wordLines.append(WordLyricLine(
                        start: lineStart,
                        end: words.last?.end ?? lineStart,
                        words: words))
                }
            }
            // 未闭合的最后一个 <p>（异常文档）也收进来
            if let draft = currentLine {
                let text = draft.words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    let lineStart = draft.begin > 0 ? draft.begin : (draft.words.first?.start ?? 0)
                    lines.append(LrcLine(time: lineStart, text: text,
                                         translated: draft.translation?.trimmingCharacters(in: .whitespaces)))
                    if !draft.words.isEmpty {
                        wordLines.append(WordLyricLine(
                            start: lineStart,
                            end: draft.words.last?.end ?? lineStart,
                            words: draft.words.map {
                                WordLyricLine.Word(char: $0.text, start: $0.start,
                                                   end: max($0.end, $0.start + 0.001))
                            }))
                    }
                }
            }
            return TTMLParseResult(lines: lines, words: wordLines)
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch elementName {
            case "p":
                currentLine = LineDraft(
                    begin: TTMLParser.parseTime(attributeDict["begin"] ?? ""),
                    end: TTMLParser.parseTime(attributeDict["end"] ?? ""),
                    words: [], translation: nil)
            case "span":
                spanText = ""
                spanStart = TTMLParser.parseTime(attributeDict["begin"] ?? "")
                spanEnd = TTMLParser.parseTime(attributeDict["end"] ?? "")
                let role = attributeDict["ttm:role"] ?? ""
                spanIsTranslation = role.contains("translation")
                spanIsBackground = role.contains("bg")
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard spanText != nil else { return }   // span 之外的空白/缩进忽略
            spanText = (spanText ?? "") + string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "span", let text = spanText {
                if spanIsTranslation {
                    // 先读后写：`currentLine?.translation = (currentLine?.translation ?? "") + text`
                    // 会把读写叠在同一表达式里，触发「overlapping accesses」编译错误
                    let existing = currentLine?.translation ?? ""
                    currentLine?.translation = existing + text
                } else if !spanIsBackground, !text.isEmpty {
                    let start = spanStart > 0 ? spanStart : (currentLine?.begin ?? 0)
                    let end = spanEnd > 0 ? spanEnd : start + 0.001
                    currentLine?.words.append((text, start, end))
                }
                spanText = nil
            } else if elementName == "p", let line = currentLine {
                completed.append(line)
                currentLine = nil
            }
        }
    }
}
