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

    // MARK: - 酷狗（明文 mcomment 接口）

    private static func fetchKugou(songId: String, page: Int, pageSize: Int) async -> CommentPage? {
        let hash = songId
        guard !hash.isEmpty, hash.count >= 8 else { return nil }
        let url = "https://mcomment.kugou.com/index.php?r=commentsv2/getCommentWithLike" +
            "&code=fc4be23b4e972707f36b8a828a93ba8a&extdata=\(hash)&p=\(page)&pagesize=\(pageSize)"
        guard let json = await getJSON(url, referer: "https://www.kugou.com/") else { return nil }
        guard let data = json["data"] as? [String: Any],
              let list = (data["lists"] as? [[String: Any]]) else { return nil }

        let comments: [SongComment] = list.compactMap { c in
            let content = (c["content"] as? String) ?? ""
            guard !content.isEmpty else { return nil }
            let like = (c["likecount"] as? NSNumber) ?? (c["like_count"] as? NSNumber)
            return SongComment(
                id: "kg_\(String(describing: (c["comment_id"] as? String) ?? UUID().uuidString))",
                nickname: (c["nick"] as? String) ?? "未知用户",
                avatarURL: c["user_avatar"] as? String,
                content: content,
                timeText: (c["addtime"] as? String) ?? "",
                likedCount: like?.intValue ?? 0
            )
        }
        guard !comments.isEmpty else { return nil }
        return CommentPage(hot: [], latest: comments, total: comments.count, hasMore: comments.count >= pageSize)
    }

    // MARK: - QQ（两步：song_detail 取数字 id -> 全量评论接口）

    private static func fetchQQ(songId: String, page: Int, pageSize: Int) async -> CommentPage? {
        guard !songId.isEmpty else { return nil }
        // 1) songmid -> 数字 topid
        let infoData = "{\"comm\":{\"ct\":24,\"cv\":0},\"songInfo\":{\"module\":\"music.pf_song_detail_svr\",\"method\":\"get_song_detail_yqq\",\"param\":{\"song_mid\":\"\(songId)\"}}}"
        guard let infoJSON = await getJSON(
            "https://u.y.qq.com/cgi-bin/musicu.fcg?data=\(infoData.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? infoData)",
            referer: "https://y.qq.com/") else { return nil }
        let trackInfo = ((infoJSON["songInfo"] as? [String: Any])?["data"] as? [String: Any])?["track_info"] as? [String: Any]
        guard let numId = (trackInfo?["id"] as? NSNumber)?.stringValue, numId != "0" else { return nil }

        // 2) 全量评论
        let pageNum = page - 1
        let cUrl = "https://c.y.qq.com/base/fcgi-bin/fcg_global_comment_h5.fcg?g_tk=5381&loginUin=0&hostUin=0" +
            "&format=json&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0&cid=205360772" +
            "&reqtype=2&biztype=1&topid=\(numId)&cmd=8&needmusiccrit=0&pagenum=\(pageNum)&pagesize=\(pageSize)" +
            "&lasthotcommentid=&domain=qq.com&ct=24&cv=10101010"
        guard let cJSON = await getJSON(cUrl, referer: "https://y.qq.com/") else { return nil }
        let commentRoot = cJSON["comment"] as? [String: Any]
        let list = (commentRoot?["commentlist"] as? [[String: Any]]) ?? []

        let comments: [SongComment] = list.compactMap { c in
            let content = (c["rootcontent"] as? String) ?? (c["content"] as? String) ?? ""
            guard !content.isEmpty else { return nil }
            return SongComment(
                id: "qq_\(String(describing: (c["comment_id"] as? String) ?? UUID().uuidString))",
                nickname: (c["nick"] as? String) ?? "未知用户",
                avatarURL: (c["avatarurl"] as? String) ?? (c["headurl"] as? String),
                content: content,
                timeText: (c["time"] as? String) ?? "",
                likedCount: Int((c["praiseNum"] as? String) ?? "0") ?? 0
            )
        }
        guard !comments.isEmpty else { return nil }
        let total = (commentRoot?["commenttotal"] as? Int) ?? 0
        return CommentPage(hot: [], latest: comments, total: total, hasMore: comments.count >= pageSize)
    }

    // MARK: - 工具

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
