import Foundation

/// 登录网易云后**自动把「我喜欢的音乐」导入为本地歌单**（与 RN 版 v90 行为一致）。
///
/// 触发点：`NeteaseSession.refreshAccount()` 成功之后（登录完成 / 冷启动校验）。
/// 同一个账号只自动导入一次（UserDefaults 记录 uid）；换号登录会为新号再导入一次。
/// 失败（网络抖动）不写标记，下次触发会重试。
enum NeteaseLikedAutoImporter {
    /// 已自动导入过的账号 uid（防止重复导入 / 覆盖用户改动）
    private static let markerKey = "wellmusic.netease.likedAutoImportedUid"

    static func importIfNeeded() async {
        guard NeteaseSession.shared.isLoggedIn,
              let uid = NeteaseSession.shared.account?.userId else { return }
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: markerKey) != uid else { return }

        // 网易云老规矩：「我喜欢的音乐」歌单 id == 用户 uid
        guard let imported = try? await NeteaseMusicAPI.shared.playlistForImport(id: "\(uid)"),
              !imported.tracks.isEmpty else { return }
        let name = imported.name.isEmpty ? "我喜欢的音乐" : imported.name

        await MainActor.run {
            var playlist = Playlist(name: name)
            playlist.coverURL = imported.coverURL
            playlist.tracks = imported.tracks
            let state = AppState.shared
            if let index = state.playlists.firstIndex(where: { $0.name == name }) {
                // 同名歌单（上一次导入的）整体替换为最新
                state.playlists[index] = playlist
            } else {
                state.playlists.insert(playlist, at: 0)
            }
            defaults.set(uid, forKey: markerKey)
            ToastCenter.shared.show("已自动导入「\(name)」共 \(imported.tracks.count) 首")
        }
    }
}
