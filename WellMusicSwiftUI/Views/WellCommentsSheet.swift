import SwiftUI

/// 歌曲评论详情页（★ 2026-10-17 新功能：排序 tab + 热评 + 楼中楼）。
/// 数据走 NeteaseMusicAPI weapi 三端点；仅网易歌曲有入口。
struct WellCommentsSheet: View {
    /// 网易数字歌曲 id（nil = 非网易歌曲，无评论）
    let songId: String?

    @Environment(\.dismiss) private var dismiss
    @State private var sortIndex = 0          // 0 推荐(99) / 1 最热(2) / 2 最新(3)
    @State private var list: [NeteaseMusicAPI.NeteaseComment] = []
    @State private var hot: [NeteaseMusicAPI.NeteaseComment] = []
    @State private var total = 0
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var failed = false
    @State private var expandedID: String?
    @State private var floors: [String: [NeteaseMusicAPI.NeteaseComment]] = [:]
    @State private var floorTotals: [String: Int] = [:]
    @State private var floorLoading = Set<String>()

    private var sortType: Int { [99, 2, 3][sortIndex] }

    var body: some View {
        NavigationStack {
            Group {
                if failed {
                    ContentUnavailableCompat(title: "评论加载失败", icon: "text.bubble")
                } else {
                    List {
                        Picker("排序", selection: $sortIndex) {
                            Text("热门评论").tag(0)
                            Text("最新评论").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if sortIndex == 0, !hot.isEmpty {
                            Section("热门评论 (\(hot.count))") {
                                ForEach(hot) { c in commentRow(c) }
                            }
                        }
                        Section {
                            ForEach(list) { c in commentRow(c) }
                            if isLoading && !list.isEmpty {
                                HStack { Spacer(); ProgressView() ; Spacer() }
                            }
                        } header: {
                            Text(total > 0 ? "全部评论 (\(total))" : "全部评论")
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }

            }
        }
        .task(id: sortIndex) { await reload() }
    }

    // MARK: - 行

    @ViewBuilder
    private func commentRow(_ c: NeteaseMusicAPI.NeteaseComment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                WellAsyncImage(url: c.avatarURL.flatMap(URL.init(string:))) {
                    Circle().fill(Color.primary.opacity(0.08))
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.nickname)
                        .font(.system(size: 13, weight: .semibold))
                    Text(c.timeText)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "hand.thumbsup")
                        .font(.system(size: 11))
                    Text("\(c.likedCount)")
                        .font(.system(size: 11).monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
            Text(c.content)
                .font(.system(size: 14.5))
                .fixedSize(horizontal: false, vertical: true)

            if c.replyCount > 0 {
                Button {
                    toggleFloor(c)
                } label: {
                    HStack(spacing: 4) {
                        Text(expandedID == c.id ? "收起回复" : "共 \(c.replyCount) 条回复 >")
                            .font(.system(size: 12, weight: .medium))
                        if floorLoading.contains(c.id) { ProgressView().controlSize(.mini) }
                    }
                    .foregroundStyle(Color.blue.opacity(0.85))
                }
                .buttonStyle(.plain)

                if expandedID == c.id {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(floors[c.id] ?? []) { r in
                            HStack(alignment: .top, spacing: 8) {
                                WellAsyncImage(url: r.avatarURL.flatMap(URL.init(string:))) {
                                    Circle().fill(Color.primary.opacity(0.08))
                                }
                                .frame(width: 24, height: 24)
                                .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(r.nickname)
                                            .font(.system(size: 12, weight: .medium))
                                        Text(r.timeText)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text(r.content)
                                        .font(.system(size: 13))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if (floorTotals[c.id] ?? 0) > (floors[c.id]?.count ?? 0) {
                            Text("仅展示前 \(floors[c.id]?.count ?? 0) 条回复")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            Divider().opacity(0.35)
        }
        .padding(.vertical, 4)
        .onAppear {
            if c.id == list.last?.id, hasMore, !isLoading {
                page += 1
                Task { await loadPage() }
            }
        }
    }

    // MARK: - 数据

    private func reload() async {
        guard let songId else { failed = true; return }
        page = 1; hasMore = false; list = []; total = 0
        failed = false
        isLoading = true
        defer { isLoading = false }
        do {
            if sortIndex == 0 {
                async let hotTask = NeteaseMusicAPI.shared.songHotComments(songId: songId)
                async let newTask = NeteaseMusicAPI.shared.songComments(songId: songId, sortType: 99, pageNo: 1)
                let (hotResult, newResult) = await (hotTask, newTask)
                hot = hotResult.comments
                list = newResult.comments
                total = newResult.total
                hasMore = newResult.hasMore
            } else {
                let result = try await NeteaseMusicAPI.shared.songComments(songId: songId, sortType: sortType, pageNo: 1)
                list = result.comments
                total = result.total
                hasMore = result.hasMore
            }
        } catch {
            failed = true
        }
        // ★ 2026-10-17 兜底：weapi 空结果时回退明文 v1（旧评论页同款，必有数据）
        if list.isEmpty, let sid = songId {
            let url = "https://music.163.com/api/v1/resource/comments/R_SO_4_\(sid)?limit=30&offset=0"
            if let data = try? await URLSession.shared.data(from: URL(string: url)!).0,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let hotList = (obj["hotComments"] as? [[String: Any]]) ?? []
                let newList = (obj["comments"] as? [[String: Any]]) ?? []
                total = (obj["total"] as? Int) ?? newList.count
                hasMore = false
                var mapped: [NeteaseMusicAPI.NeteaseComment] = []
                for c in newList {
                    guard let content = c["content"] as? String else { continue }
                    let u = c["user"] as? [String: Any]
                    let timeMs = (c["time"] as? Double) ?? 0
                    mapped.append(NeteaseMusicAPI.NeteaseComment(
                        id: String((c["commentId"] as? Int64) ?? 0),
                        nickname: u?["nickname"] as? String ?? "网易云用户",
                        avatarURL: u?["avatarUrl"] as? String,
                        content: content,
                        timeText: "",
                        likedCount: (c["likedCount"] as? Int) ?? 0,
                        replyCount: (c["replyCount"] as? Int) ?? 0))
                }
                if sortIndex == 0, !hotList.isEmpty {
                    var hotMapped: [NeteaseMusicAPI.NeteaseComment] = []
                    for c in hotList {
                        guard let content = c["content"] as? String else { continue }
                        let u = c["user"] as? [String: Any]
                        hotMapped.append(NeteaseMusicAPI.NeteaseComment(
                            id: String((c["commentId"] as? Int64) ?? 0),
                            nickname: u?["nickname"] as? String ?? "网易云用户",
                            avatarURL: u?["avatarUrl"] as? String,
                            content: content,
                            timeText: "",
                            likedCount: (c["likedCount"] as? Int) ?? 0,
                            replyCount: (c["replyCount"] as? Int) ?? 0))
                    }
                    hot = hotMapped
                }
                if !mapped.isEmpty { list = mapped }
            }
        }
    }

    private func loadPage() async {
        guard let songId, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await NeteaseMusicAPI.shared.songComments(
                songId: songId, sortType: sortType, pageNo: page)
            var seen = Set(list.map(\.id))
            list.append(contentsOf: result.comments.filter { seen.insert($0.id).inserted })
            total = result.total
            hasMore = result.hasMore
        } catch { }
    }

    private func toggleFloor(_ c: NeteaseMusicAPI.NeteaseComment) {
        if expandedID == c.id { expandedID = nil; return }
        expandedID = c.id
        guard floors[c.id] == nil, let songId, !floorLoading.contains(c.id) else { return }
        floorLoading.insert(c.id)
        Task {
            defer { floorLoading.remove(c.id) }
            if let result = try? await NeteaseMusicAPI.shared.songCommentFloor(
                songId: songId, parentCommentId: c.id) {
                floors[c.id] = result.replies
                floorTotals[c.id] = result.total
            }
        }
    }
}

/// 轻量空态（810e98ac 基线无 ContentUnavailableView 包装需求，自绘同视觉）
private struct ContentUnavailableCompat: View {
    let title: String
    let icon: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34))
            Text(title).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
