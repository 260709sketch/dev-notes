import SwiftUI

/// 设置页。
///
/// 精简原则（需求 21：彻底简化，简单设置不要说明）：只保留用户真正会调的项，
/// 去掉绝大多数解释性文字 —— 选项本身已足够自明。
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lxStore = WellLXSourceStore.shared
    /// 播放/暂停淡入淡出开关（2026-10-16 用户；未开启时不显示档位调节）
    @AppStorage(PlayerCore.fadeEnabledKey) private var fadeEnabled = false
    /// 淡入淡出时长（毫秒；300 / 500 / 1000 三档）
    /// ⚠️ 类型必须显式 `Double`：整数字面量 `500` 会被推断成 `AppStorage<Int>`，
    /// 与 `PlayFadeDuration(rawValue: Double)` 对不上（2026-10-16 CI 教训）。
    @AppStorage(PlayerCore.fadeDurationKey) private var fadeDurationMs: Double = 500

    /// 底部栏位置微调的文案（正 = 更靠下）。
    private var tabBarOffsetText: String {
        let value = settings.tabBarBottomOffset
        if abs(value) < 0.5 { return "默认" }
        return value > 0 ? "靠下 \(Int(value))pt" : "靠上 \(Int(-value))pt"
    }

    // MARK: - 检查更新（问题16）

    /// 是否正在检查。
    @State private var checkingUpdate = false
    /// 检查结果文案（「已是最新 / 有新版本」），显示在「检查更新」右侧。
    @State private var updateStatus: String?
    /// 检测到新版本时的详情（弹窗展示）。
    @State private var updateInfo: UpdateChecker.UpdateInfo?
    @State private var showingUpdateSheet = false

    private func checkForUpdates() async {
        checkingUpdate = true
        defer { checkingUpdate = false }
        switch await UpdateChecker.check() {
        case .upToDate(let remote):
            updateStatus = "已是最新（\(remote)）"
        case .newer(let info):
            updateStatus = "有新版本 \(info.version)"
            updateInfo = info
            showingUpdateSheet = true
        case .failed(let message):
            updateStatus = message
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // ★ 2026-10-14 用户：账号分组放在播放分组上面
                Section("账号") {
                    NavigationLink {
                        NeteaseAccountSettingsView()
                    } label: {
                        HStack {
                            Text("NetEase Cloud ID")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(NeteaseSession.shared.isLoggedIn ? "已登录" : "未登录")
                                .foregroundStyle(.secondary)
                        }
                    }
                    // ★ 2026-10-15 用户：「导入歌单」入口新增在此分组 ——
                    //   把原先「我的歌单」页右上角的「导入歌单 + 新建歌单」两个入口
                    //   合二为一（页内同时提供导入与新建）。
                    NavigationLink {
                        PlaylistImportView()
                    } label: {
                        Label("导入歌单", systemImage: "square.and.arrow.down")
                    }
                }

                Section("音频") {
                    // ★ 2026-10-14 用户：「设置播放音质点击之后要和三个点菜单弹窗一样」。
                    //   改成系统**原生下拉菜单**（Picker + .menu）：点一下直接弹出菜单，
                    //   不再走底部玻璃卡片 sheet。
                    Picker("播放音质", selection: $appState.audioQuality) {
                        ForEach(WellAudioQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle("断开蓝牙自动暂停", isOn: $settings.bluetoothAutoPause)
                }

                Section("播放") {
                    // 启动恢复上次播放（2026-10-14 用户要求）
                    Toggle("启动恢复上次播放", isOn: $settings.restoreLastPlayback)
                    // 预加载下一首（2026-10-14 用户要求提供开关）
                    Toggle("预加载下一首", isOn: $settings.preloadNextEnabled)
                    // 控制中心显示歌词（2026-10-15 用户：歌手名位置变成显示歌词，默认关）
                    Toggle("控制中心显示歌词", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: PlayerCore.nowPlayingLyricsKey) },
                        set: { PlayerCore.shared.setNowPlayingLyricsEnabled($0) }
                    ))
                    // 动态封面开关（2026-10-15 用户：可自选是否打开；
                    // 未登录网易云时自动隐藏 —— 动态封面数据来自账号收藏）
                    if NeteaseSession.shared.isLoggedIn {
                        Toggle("动态封面", isOn: $settings.dynamicCoverEnabled)
                    }
                    // 歌曲缓存（2026-10-15 用户：与参考项目同款的歌曲缓存）
                    Toggle("歌曲缓存", isOn: Binding(
                        get: { (UserDefaults.standard.object(forKey: AudioCacheManager.enabledKey) as? Bool) ?? true },
                        set: { UserDefaults.standard.set($0, forKey: AudioCacheManager.enabledKey) }
                    ))
                    // 播放/暂停淡入淡出（2026-10-16 用户：未开启时不显示档位调节）
                    Toggle("播放淡入淡出", isOn: $fadeEnabled)
                    if fadeEnabled {
                        // ⚠️ 形状对齐上面「缓存上限」Picker（该形状在 CI 工具链上
                        // 验证过可编译）：getter 多语句 + 显式 return、setter 用具名
                        // 参数（不要 $0 简写 + 单表达式闭包）—— 2026-10-16 首版用
                        // `get: { X ?? .ms500 }` + `set: { v = $0.rawValue }` 编译不过：
                        // 「Cannot infer type of closure parameter 'option'」。
                        Picker("淡入淡出时长", selection: Binding(
                            get: {
                                return PlayerCore.PlayFadeDuration(rawValue: fadeDurationMs)
                                    ?? .ms500
                            },
                            set: { option in
                                fadeDurationMs = option.rawValue
                            }
                        )) {
                            ForEach(PlayerCore.PlayFadeDuration.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    }
                }

                // ★ 2026-10-16 用户问题12：「在我们设置新增高级功能，用收纳这些功能，
                //   包含现有的内置音源」。
                //   → 高级功能分组 = 内置音源开关 + 当前音源 + 自定义音源管理/状态/测试。
                Section {
                    HStack {
                        Text("当前音源")
                        Spacer()
                        Text(lxStore.activeSource?.name ?? "未启用")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // ★ 2026-10-15 用户：内置音源（默认关）。
                    //   开启后：未导入自定义音源、或全部音源解析失败时，
                    //   用官方平台通道兜底播放并提示「使用内置音源播放」。
                    Toggle("内置音源", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: MusicURLResolver.builtinSourceKey) },
                        set: { UserDefaults.standard.set($0, forKey: MusicURLResolver.builtinSourceKey) }
                    ))
                    NavigationLink {
                        WellLXSourceManageView()
                    } label: {
                        Label("自定义音源", systemImage: "square.stack.3d.up")
                    }
                    NavigationLink {
                        WellLXSourceTestView()
                    } label: {
                        Label("音源测试", systemImage: "stethoscope")
                    }
                    NavigationLink {
                        WellLXSourceStatusView()
                    } label: {
                        Label("音源状态", systemImage: "waveform.path.ecg")
                    }
                } header: {
                    Text("高级功能")
                } footer: {
                    Text("开启「内置音源」后，未导入自定义音源（或全部音源解析失败）时，自动通过第三方解析获取完整音频（含 320k 高码率）。受版权限制的个别歌曲解析不到时回退官方通道（可能仅试听 30 秒）——这类歌可导入自定义音源解决。")
                        .font(.system(size: 12))
                }

                // ★ 2026-10-16 用户问题14/15：「设置新增存储分组，数据备份和存储移出来放到
                //   存储分组里面，数据备份和缓存分开」「缓存上限也加入存储分组里面」。
                //   → 存储分组 = 缓存上限（原来在「播放」里）+ 缓存管理 + 数据备份三个入口，
                //     备份与缓存彻底分开成两个页面。
                Section {
                    // 缓存上限：歌曲 / 图片 / 歌手主页三类缓存的**合计**上限
                    Picker("缓存上限", selection: Binding(
                        get: {
                            let current = AudioCacheManager.byteLimit
                            return AudioCacheManager.LimitOption(rawValue: current)
                                ?? .gb2
                        },
                        set: { option in
                            UserDefaults.standard.set(option.rawValue, forKey: AudioCacheManager.limitKey)
                            AudioCacheManager.shared.enforceLimitNow()
                        }
                    )) {
                        ForEach(AudioCacheManager.LimitOption.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    NavigationLink {
                        WellStorageView(mode: .cache)
                    } label: {
                        Label("缓存管理", systemImage: "internaldrive")
                    }
                    NavigationLink {
                        WellStorageView(mode: .backup)
                    } label: {
                        Label("数据备份", systemImage: "externaldrive.badge.timemachine")
                    }
                } header: {
                    Text("存储")
                } footer: {
                    Text("「缓存上限」是歌曲、图片、歌手主页三类缓存的合计上限，超出后自动清理最久未使用的内容。")
                        .font(.system(size: 12))
                }

                Section("界面") {
                    // ★ 2026-10-15 用户：搜索框样式切换
                    //   开 = 旧版（系统搜索栏，进页折叠）；关 = 新版（页面顶部常驻搜索框）。
                    //   与搜索页右上角滑杆菜单为同一设置项。
                    Toggle("旧版搜索界面（系统搜索栏）", isOn: $settings.searchLegacyUI)

                    Picker("主题", selection: $settings.appTheme) {
                        ForEach(WellAppTheme.allCases) { theme in
                            Label(theme.displayName, systemImage: theme.symbolName)
                                .tag(theme)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    // 发现页「每日推荐 / 私人漫游 / 心动模式」入口卡样式（2026-10-14）
                    Picker("发现页入口卡", selection: $settings.dailyCardStyle) {
                        ForEach(WellDailyCardStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    // 歌单封面样式（2026-10-14 用户设计稿：新版居中留白 / 旧版全宽铺满）
                    Picker("歌单封面样式", selection: $settings.playlistCoverStyle) {
                        ForEach(WellPlaylistCoverStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    // 底部栏（dock + 迷你播放器）纵向位置自由微调（2026-10-14 用户要求）
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("底部栏位置")
                            Spacer()
                            Text(tabBarOffsetText)
                                .foregroundStyle(.secondary)
                        }
                        // 行程 ±100pt（2026-10-14 16:50 用户要求，原 ±30 不够用）。
                        // ⚠️ 往下受基准限制：底部栏基准位置本身距屏幕底 42pt，
                        //    所以「靠下」的有效行程约 42pt（再往下会被屏幕底边裁掉）；
                        //    「靠上」100pt 完全有效（届时距底 ≈142pt）。
                        Slider(value: $settings.tabBarBottomOffset, in: -100...100, step: 2)
                    }
                }

                // ★ 2026-10-16 用户问题16：
                //   ① 「关于」里新增「开发者」，右侧名字 Well，位置在版本**上面**；
                //   ② 新增「名称」= Well Music；
                //   ③ 「版本」只保留当前 1.0.0（原先显示「1.0.0 (SwiftUI)」）；
                //   ④ 新增「检查更新」与更新机制（从 GitHub 仓库拉取，见 `UpdateChecker`）。
                Section("关于") {
                    HStack {
                        Text("名称")
                        Spacer()
                        Text(UpdateChecker.appName)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("开发者")
                        Spacer()
                        Text("Well")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(UpdateChecker.currentVersion)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await checkForUpdates() }
                    } label: {
                        HStack {
                            Text("检查更新")
                            Spacer()
                            if checkingUpdate {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(updateStatus ?? "")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .disabled(checkingUpdate)
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            // 有新版本时的详情弹窗（含发布页入口，点「前往下载」用系统浏览器打开）
            .sheet(isPresented: $showingUpdateSheet) {
                if let info = updateInfo {
                    NavigationStack {
                        List {
                            Section("新版本") {
                                HStack {
                                    Text("版本")
                                    Spacer()
                                    Text(info.version).foregroundStyle(.secondary)
                                }
                                if !info.title.isEmpty, info.title != info.version {
                                    HStack {
                                        Text("标题")
                                        Spacer()
                                        Text(info.title).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                            if !info.notes.isEmpty {
                                Section("更新内容") {
                                    Text(info.notes)
                                        .font(.system(size: 13))
                                }
                            }
                            Section {
                                if let url = info.pageURL {
                                    Link(destination: url) {
                                        Label("前往下载", systemImage: "arrow.down.circle")
                                    }
                                } else {
                                    Text("该版本没有附带下载页，请在仓库的 Releases 里查看。")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .navigationTitle("发现新版本")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("完成") { showingUpdateSheet = false }
                            }
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
