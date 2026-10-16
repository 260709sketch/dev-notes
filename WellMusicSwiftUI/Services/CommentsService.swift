import Foundation

/// 单条歌曲评论（跨平台归一化）
struct SongComment: Identifiable {
    let id: String
    let nickname: String
    let avatarURL: String?
    let content: String
    let timeText: String
    let likedCount: Int

    /// 空评论占位（无头像/无内容时的兜底）
    static let empty = SongComment(id: UUID().uuidString, nickname: "", avatarURL: nil, content: "", timeText: "", likedCount: 0)
}

/// 一页评论：热门 + 最新 + 总数 + 是否还有更多
struct CommentPage {
    var hot: [SongComment]
    var latest: [SongComment]
    var total: Int
    var hasMore: Bool
}

/// 多平台歌曲评论（照参考源码 `getCommentsByPlatform` 的平台回退链实现）：
/// 请求顺序 = 本曲平台优先，失败/无评论则顺延其他平台。
enum CommentsAPI {

    /// 拉取一页评论。
    /// - Parameters:
    ///   - platform: 歌曲所属平台（netease/qq/kugou/kuwo），nil 时按 netease 优先
    ///   - songId: 平台歌曲 id（网易云数字 id / QQ songmid / 酷狗 hash）
    static func fetch(platform: String?, songId: String, page: Int, pageSize: Int = 20) async -> CommentPage? {
        let order: [String]
        switch (platform ?? "").lowercased() {
        case "netease", "wy": order = ["netease", "qq", "kugou", "kuwo"]
        case "qq", "tx": order = ["qq", "netease", "kugou", "kuwo"]
        case "kugou", "kg": order = ["kugou", "qq", "netease", "kuwo"]
        case "kuwo", "kw": order = ["kuwo", "qq", "netease", "kugou"]
        default: order = ["netease", "qq", "kugou", "kuwo"]
        }
        // 本曲平台优先，其余顺延；拿到有内容的页即返回
        for p in order {
            let page: CommentPage? = await {
                switch p {
                case "netease": return await fetchNetease(songId: songId, page: page, pageSize: pageSize)
                case "qq": return await fetchQQ(songId: songId, page: page, pageSize: pageSize)
                case "kugou": return await fetchKugou(songId: songId, page: page, pageSize: pageSize)
                default: return nil
                }
            }()
            if let page, !(page.hot.isEmpty && page.latest.isEmpty) {
                return page
            }
        }
        return nil
    }

    // MARK: - 网易云（明文 api/v1/resource/comments，实测可用，无需 weapi）

    private static func fetchNetease(songId: String, page: Int, pageSize: Int) async -> CommentPage? {
        guard let id = neteaseNumericId(songId), !id.isEmpty else { return nil }
        let offset = (page - 1) * pageSize
        let url = "https://music.163.com/api/v1/resource/comments/R_SO_4_\(id)?limit=\(pageSize)&offset=\(offset)"
        guard let json = await getJSON(url, referer: "https://music.163.com/") else { return nil }
        guard (json["code"] as? Int) == 200 else { return nil }

        func map(_ list: [[String: Any]]) -> [SongComment] {
            list.compactMap { c in
                let content = (c["content"] as? String) ?? ""
                guard !content.isEmpty else { return nil }
                let user = c["user"] as? [String: Any]
                let commentId = (c["commentId"] as? NSNumber)?.stringValue ?? UUID().uuidString
                return SongComment(
                    id: "nc_\(commentId)",
                    nickname: (user?["nickname"] as? String) ?? "未知用户",
                    avatarURL: user?["avatarUrl"] as? String,
                    content: content,
                    timeText: (c["timeStr"] as? String) ?? "",
                    likedCount: (c["likedCount"] as? Int) ?? 0
                )
            }
        }
        let hot = map(json["hotComments"] as? [[String: Any]] ?? [])
        let latest = map(json["comments"] as? [[String: Any]] ?? [])
        let total = (json["total"] as? Int) ?? 0
        let more = (json["more"] as? Bool) ?? false
        guard !(hot.isEmpty && latest.isEmpty) else { return nil }
        return CommentPage(hot: hot, latest: latest, total: total, hasMore: more)
    }

    // MARK: - 酷狗（mcomment getCommentWithLike：热门 weightList / 最新 list）

    private static func fetchKugou(songId: String, page: Int, pageSize: Int) async -> CommentPage? {
        let hash = songId
        guard !hash.isEmpty, hash.count >= 8 else { return nil }
        let url = "https://mcomment.kugou.com/index.php?r=commentsv2/getCommentWithLike" +
            "&code=fc4be23b4e972707f36b8a828a93ba8a&extdata=\(hash)&p=\(max(page, 1))&pagesize=\(min(max(pageSize, 1), 30))"
        guard let json = await getJSON(url, referer: "https://www.kugou.com/") else { return nil }
        var seen = Set<String>()

        // 最新评论：list（data.list 兜底）；热门评论：weightList（data.weightList 兜底）
        let rows: [[String: Any]]
        if let list = json["list"] as? [[String: Any]] {
            rows = list
        } else if let data = json["data"] as? [String: Any],
                  let list = data["list"] as? [[String: Any]] {
            rows = list
        } else {
            rows = []
        }
        let hotRows: [[String: Any]]
        if let weight = json["weightList"] as? [[String: Any]] {
            hotRows = weight
        } else if let data = json["data"] as? [String: Any],
                  let weight = data["weightList"] as? [[String: Any]] {
            hotRows = weight
        } else {
            hotRows = []
        }

        let latest = parseKugouRows(rows, seen: &seen)
        let hot = hotRows.isEmpty ? [] : parseKugouRows(hotRows, seen: &seen)
        // 热门为空时用前几条最新评论兜底（与参考实现一致）
        let hotFinal = hot.isEmpty ? Array(latest.prefix(5)) : hot
        guard !(hotFinal.isEmpty && latest.isEmpty) else { return nil }
        let total = (json["count"] as? Int) ?? (json["total"] as? Int)
            ?? ((json["data"] as? [String: Any])?["total"] as? Int) ?? latest.count
        return CommentPage(hot: hotFinal, latest: latest, total: total, hasMore: latest.count >= pageSize)
    }

    /// 酷狗行解析（参考实现的评论文本解析：字段 user_name/user_pic/comment_content/
    /// praisenum/like.likenum/addtime；addtime 可能是 Double/Int/日期字符串）。
    private static func parseKugouRows(_ rows: [[String: Any]], seen: inout Set<String>) -> [SongComment] {
        rows.compactMap { raw -> SongComment? in
            let rawID = (raw["commentid"] as? String) ?? (raw["comment_id"] as? String)
                ?? ((raw["id"] as? NSNumber)?.stringValue) ?? ""
            let content = (raw["comment_content"] as? String) ?? (raw["content"] as? String) ?? ""
            guard !content.isEmpty else { return nil }
            let nickname = (raw["user_name"] as? String) ?? (raw["nick"] as? String)
                ?? (raw["nickname"] as? String) ?? (raw["username"] as? String) ?? "酷狗用户"
            let avatar = (raw["user_pic"] as? String) ?? (raw["avatarurl"] as? String)
                ?? (raw["avatar_url"] as? String) ?? (raw["avatar"] as? String) ?? ""
            var timestamp: Double = 0
            if let addtime = raw["addtime"] as? Double {
                timestamp = addtime
            } else if let addtime = raw["addtime"] as? Int {
                timestamp = Double(addtime)
            } else if let addtimeStr = raw["addtime"] as? String {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                if let date = formatter.date(from: addtimeStr) {
                    timestamp = date.timeIntervalSince1970
                }
            } else if let time = raw["time"] as? Double {
                timestamp = time
            }
            if timestamp > 10_000_000_000 { timestamp /= 1000 } // 毫秒 → 秒
            let id = rawID.isEmpty ? "kc_\(abs(content.hashValue))" : "kc_\(rawID)"
            guard seen.insert(id).inserted else { return nil }
            var likedCount = (raw["praisenum"] as? Int) ?? (raw["like_count"] as? Int) ?? 0
            if likedCount == 0, let like = raw["like"] as? [String: Any],
               let likenum = (like["likenum"] as? Int) ?? ((like["likenum"] as? NSNumber)?.intValue) {
                likedCount = likenum
            }
            return SongComment(
                id: id,
                nickname: nickname.isEmpty ? "酷狗用户" : nickname,
                avatarURL: avatar.isEmpty ? nil : avatar,
                content: content,
                timeText: formatUnixTime(timestamp),
                likedCount: likedCount
            )
        }
    }

    // MARK: - QQ（两步：song_detail 取数字 id -> POST 全量评论接口）

    private static func fetchQQ(songId: String, page: Int, pageSize: Int) async -> CommentPage? {
        guard !songId.isEmpty else { return nil }
        // 1) songmid -> 数字 topid
        let infoData = "{\"comm\":{\"ct\":24,\"cv\":0},\"songInfo\":{\"module\":\"music.pf_song_detail_svr\",\"method\":\"get_song_detail_yqq\",\"param\":{\"song_mid\":\"\(songId)\"}}}"
        guard let infoJSON = await getJSON(
            "https://u.y.qq.com/cgi-bin/musicu.fcg?data=\(infoData.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? infoData)",
            referer: "https://y.qq.com/") else { return nil }
        let trackInfo = ((infoJSON["songInfo"] as? [String: Any])?["data"] as? [String: Any])?["track_info"] as? [String: Any]
        guard let numId = (trackInfo?["id"] as? NSNumber)?.stringValue, numId != "0" else { return nil }

        // 2) 全量评论：⚠️ 必须 POST form（GET 同地址拿不到数据），参考实现的评论接口同款
        var comps = URLComponents(string: "https://c.y.qq.com/base/fcgi-bin/fcg_global_comment_h5.fcg")!
        comps.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "cid", value: "205360772"),
            URLQueryItem(name: "reqtype", value: "2"),
        ]
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        // pagesize 上限 25，pagenum 从 0 起
        let bodyStr = "biztype=1&topid=\(numId)&LoginUin=0&cmd=8&pagenum=\(max(page - 1, 0))&pagesize=\(min(max(pageSize, 1), 25))"
        request.httpBody = bodyStr.data(using: .utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let cJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // 热门只在第一页返回：hot_comment.commentlist；最新：comment.commentlist
        let hotRows = page <= 1
            ? (((cJSON["hot_comment"] as? [String: Any])?["commentlist"] as? [[String: Any]]) ?? [])
            : []
        let commentRoot = cJSON["comment"] as? [String: Any]
        let rows = (commentRoot?["commentlist"] as? [[String: Any]]) ?? []

        var seen = Set<String>()
        var result: [SongComment] = []
        for item in hotRows + rows {
            // 去重键：rootcommentid + commentid
            let rootID = (item["rootcommentid"] as? String)
                ?? ((item["rootcommentid"] as? NSNumber)?.stringValue) ?? ""
            let commentID = (item["commentid"] as? String)
                ?? ((item["commentid"] as? NSNumber)?.stringValue) ?? ""
            let key = rootID + "_" + commentID
            guard !key.isEmpty, !key.hasPrefix("_"), seen.insert(key).inserted else { continue }
            var content = (item["rootcommentcontent"] as? String) ?? (item["content"] as? String) ?? ""
            content = content.replacingOccurrences(of: "\\n", with: "\n")
            guard !content.isEmpty else { continue }
            var nick = (item["nick"] as? String) ?? (item["rootcommentnick"] as? String) ?? ""
            if nick.hasPrefix("@") { nick = String(nick.dropFirst()) }
            let avatar = (item["avatarurl"] as? String) ?? ""
            let time = (item["time"] as? TimeInterval) ?? ((item["time"] as? Int).map { Double($0) } ?? 0)
            let likedCount = (item["praisenum"] as? Int) ?? ((item["praisenum"] as? NSNumber)?.intValue) ?? 0
            result.append(SongComment(
                id: "qq_\(key)",
                nickname: nick.isEmpty ? "未知用户" : nick,
                avatarURL: avatar.isEmpty ? nil : avatar,
                content: content,
                timeText: time > 0 ? formatUnixTime(time) : "",
                likedCount: likedCount
            ))
        }
        guard !result.isEmpty else { return nil }
        let hotCount = min(hotRows.count, result.count)
        let hot = page <= 1 ? Array(result.prefix(hotCount)) : []
        let latest = page <= 1 ? Array(result.dropFirst(hotCount)) : result
        let total = (commentRoot?["commenttotal"] as? Int) ?? ((commentRoot?["commenttotal"] as? NSNumber)?.intValue) ?? 0
        return CommentPage(hot: hot, latest: latest, total: total, hasMore: latest.count >= pageSize)
    }

    // MARK: - 工具

    /// Unix 秒级时间戳 → 「yyyy-MM-dd HH:mm」文本。
    private static func formatUnixTime(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    /// 从可能带前缀的歌曲 id（`netease_123` / 纯数字）提取网易云数字 id
    private static func neteaseNumericId(_ songId: String) -> String? {
        let s = songId
        for prefix in ["netease_", "wy_"] where s.hasPrefix(prefix) {
            return String(s.dropFirst(prefix.count))
        }
        return Int(s) != nil ? s : nil
    }

    private static func getJSON(_ url: String, referer: String) async -> [String: Any]? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = 12
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
