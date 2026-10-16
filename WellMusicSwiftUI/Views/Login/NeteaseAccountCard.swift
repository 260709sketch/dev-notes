import SwiftUI

/// 「我的」页顶部的网易云账号卡片（用户 2026-10-15 定稿版式）。
///
/// 未登录时**整张卡就是设置卡**（用户 2026-10-16）：网易云图标位置改成蓝色设置按钮，
/// 点击进入「设置 → 账号」登录（账号是设置页第一个 Section，打开即达）。
/// 已登录时显示**网易云头像 + 昵称 + 昵称旁的 VIP 标识**，
/// 右侧一个**设置图标**（点击进入设置页；退出登录在「设置 → 账号」里）。
///
/// 卡片自己持有登录面板与设置页的呈现状态 —— 登录态是全局的（`NeteaseSession`），
/// 但「面板开不开」纯粹是这一处的局部 UI 状态，没必要往上提。
@MainActor
struct NeteaseAccountCard: View {
    @ObservedObject private var session = NeteaseSession.shared
    /// 未登录卡的唯一动作就是进设置（登录入口在「设置 → 账号」里，见 loggedOut 注释）
    @State private var showingSettings = false

    private var brandGradient: LinearGradient {
        LinearGradient(colors: [AppTheme.accent, AppTheme.accent.opacity(0.72)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 未登录卡片的背景：品牌色的淡渐变。
    ///
    /// 这里刻意不再套一层 `.opacity(_:)` —— `ShapeStyle.opacity(_:)` 是 **iOS 17** 才有的，
    /// 直接给渐变加透明度在 iOS 16 上编不过；改成在颜色上取透明度就没有版本问题。
    private var cardGradient: LinearGradient {
        LinearGradient(colors: [AppTheme.accent.opacity(0.16), AppTheme.accent.opacity(0.05)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 卡片阴影（用户 2026-10-15：登录卡与近期播放卡加阴影）。
    /// ★ 2026-10-16 用户（问题21）：原 7/0.10 太重，削减到 4/0.06。
    /// 半径/偏移刻意收敛：与下方卡片只隔 10pt，阴影别落到下一张卡上
    /// （下方卡片是不透明背景，轻微溢出也会被盖住，双保险）。
    private var cardShadow: (Color, CGFloat, CGFloat, CGFloat) {
        (Color.black.opacity(0.06), 4, 0, 1)
    }

    var body: some View {
        Group {
            if let account = session.account, session.isLoggedIn {
                loggedIn(account)
            } else {
                loggedOut
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    // MARK: 未登录（= 设置卡）

    private var loggedOut: some View {
        Button {
            // ★ 2026-10-16 用户：未登录时这张卡就是设置卡，蓝色设置按钮 →
            //   设置页（账号是第一个 Section，打开就在登录入口上）
            showingSettings = true
        } label: {
            HStack(spacing: 14) {
                // 原网易云图标位置 → 蓝色设置按钮
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.blue))

                VStack(alignment: .leading, spacing: 3) {
                    Text("设置")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("登录网易云音乐，同步歌单与每日推荐")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(15)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(cardGradient)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AppTheme.accent.opacity(0.18), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .shadow(color: cardShadow.0, radius: cardShadow.1, x: cardShadow.2, y: cardShadow.3)
    }

    // MARK: 已登录

    private func loggedIn(_ account: NeteaseAccount) -> some View {
        HStack(spacing: 14) {
            avatar(account)

            VStack(alignment: .leading, spacing: 4) {
                // 昵称 + VIP 标识（用户 2026-10-15：VIP 放昵称旁）
                HStack(spacing: 5) {
                    Text(account.nickname)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    // ⚠️ vipBadge 是 @ViewBuilder 函数、返回非 Optional 的 some View
                    //   （无 VIP 时产出 EmptyView）—— 直接调用，别用 if let 绑定
                    //   （2026-10-16 CI：「Initializer for conditional binding must
                    //   have Optional type, not 'some View'」）。
                    vipBadge(vipType: account.vipType)
                }
                Text("网易云音乐已登录")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            // ★ 2026-10-15 用户：卡片右侧设置图标 → 进入设置
            //   （退出登录在「设置 → 账号」里，与本图标同路径可达）
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(15)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.secondaryBackground)
        }
        // ★ 2026-10-16 用户（问题21）：去掉灰色描边（Color.primary.opacity(0.06)
        //   在浅色界面下是一条灰线）—— 保留 overlay 由设计决定，此处仅移除灰边
        .shadow(color: cardShadow.0, radius: cardShadow.1, x: cardShadow.2, y: cardShadow.3)
        .task {
            // 进页面时顺手校验一次票据：过期就自动回到未登录态，
            // 而不是让用户点进歌单才发现什么都加载不出来。
            await session.refreshAccount()
        }
    }

    /// VIP 标识：描边胶囊 + 档位字样（用户 2026-10-15：按网易云实际开通状态显示）。
    ///
    /// * 没开通（0 / 拿不到）→ **不显示**
    /// * 已开通（任何非零档位）→ `VIP`
    ///
    /// ★ 2026-10-16 用户（问题23）：「我在网易云是VIP怎么给我标成SVIP了」。
    ///   根因：旧逻辑只认 10/11 两个值，其余非零档位一律落 svip 分支；
    ///   而网易云官方明示 SVIP「网页端暂不支持展示」，web 接口并不按
    ///   10/11 之外的值可靠区分档位。修正：**非零即 VIP**，不再猜 svip。
    @ViewBuilder
    private func vipBadge(vipType: Int?) -> some View {
        if let vipType, vipType != 0 {
            Text("VIP")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(AppTheme.accent)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 2)
                .overlay(
                    Capsule().strokeBorder(AppTheme.accent, lineWidth: 0.8)
                )
        }
    }

    // MARK: 零件

    /// 头像：加载失败或没有头像时退回品牌色徽标。
    ///
    /// ★ 2026-10-16 用户：「网易头像怎么不是圆形的」—— 根因是回退徽标是
    /// **圆角方形**（RoundedRectangle），头像 URL 缺失/加载失败时就露出方块。
    /// 修法：徽标本身改 `Circle`，且整个 ZStack 统一 `clipShape(Circle())`，
    /// 任何状态（加载中/失败/成功）都是圆的。
    ///
    /// ★ 2026-10-16 用户（问题22）：「登录卡片的头像是不是有红色的头图标在里面？
    /// 从歌单页面退出来有时候会一直闪红色的」—— 定位到两处：
    ///   ① 加载中的占位图原来是**品牌红**的圆形徽标（红底 + 白色音符），
    ///      页面重算 / 行重建时先出这一帧，就是那下「红色的头」；
    ///      现在换成品类中性的灰圆 + 人形图标，闪也只会闪一个浅灰圆。
    ///   ② 头像地址之前直接 `URL(string:)` 就用：网易云会给 `http://` 地址，
    ///      被 ATS 拦掉 → 图永远加载不出来 → 一直停在那张红色占位图上。
    ///      现在统一走 `WellArtworkURL.resolved`（http→https + 按 52pt 要 192px 缩图），
    ///      地址稳定、缓存键也就稳定，返回页面时能直接命中缓存的真图。
    private func avatar(_ account: NeteaseAccount) -> some View {
        ZStack {
            if let url = WellArtworkURL.resolved(account.avatarURL,
                                                 pixelSize: WellArtworkURL.pixelSize(forPoints: 52)) {
                WellAsyncImage(url: url) {
                    avatarPlaceholder
                }
                .frame(width: 52, height: 52)
            } else {
                brandBadge(size: 52)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    /// 头像加载中的中性占位（刻意不用品牌色，避免「闪红色」）。
    private var avatarPlaceholder: some View {
        Circle()
            .fill(Color.primary.opacity(0.08))
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.secondary.opacity(0.7))
            }
    }

    private func brandBadge(size: CGFloat) -> some View {
        Circle()
            .fill(brandGradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}
