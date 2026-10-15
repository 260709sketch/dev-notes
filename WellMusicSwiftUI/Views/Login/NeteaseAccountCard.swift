import SwiftUI

/// 「我的」页顶部的网易云账号卡片（用户 2026-10-15 定稿版式）。
///
/// 未登录时是登录入口（点击弹出 `NeteaseLoginSheet`）；
/// 已登录时显示**网易云头像 + 昵称 + 昵称旁的 VIP 标识**，
/// 右侧一个**设置图标**（点击进入设置页；退出登录在「设置 → 账号」里）。
///
/// 卡片自己持有登录面板与设置页的呈现状态 —— 登录态是全局的（`NeteaseSession`），
/// 但「面板开不开」纯粹是这一处的局部 UI 状态，没必要往上提。
@MainActor
struct NeteaseAccountCard: View {
    @ObservedObject private var session = NeteaseSession.shared
    @State private var showingLogin = false
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

    var body: some View {
        Group {
            if let account = session.account, session.isLoggedIn {
                loggedIn(account)
            } else {
                loggedOut
            }
        }
        .sheet(isPresented: $showingLogin) {
            NeteaseLoginSheet()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    // MARK: 未登录

    private var loggedOut: some View {
        Button {
            showingLogin = true
        } label: {
            HStack(spacing: 14) {
                brandBadge(size: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text("登录网易云音乐")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("扫码即可，同步歌单与每日推荐")
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
                    vipBadge
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
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .task {
            // 进页面时顺手校验一次票据：过期就自动回到未登录态，
            // 而不是让用户点进歌单才发现什么都加载不出来。
            await session.refreshAccount()
        }
    }

    /// VIP 标识：描边胶囊 + VIP 字样（与网易云音乐会员角标同款语言）。
    private var vipBadge: some View {
        Text("VIP")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 2)
            .overlay(
                Capsule().strokeBorder(AppTheme.accent, lineWidth: 0.8)
            )
    }

    // MARK: 零件

    /// 头像：加载失败或没有头像时退回品牌色徽标。
    private func avatar(_ account: NeteaseAccount) -> some View {
        ZStack {
            brandBadge(size: 52)
            if let urlString = account.avatarURL, let url = URL(string: urlString), !urlString.isEmpty {
                WellAsyncImage(url: url) {
                    brandBadge(size: 52)
                }
                .frame(width: 52, height: 52)
                .clipShape(Circle())
            }
        }
        .frame(width: 52, height: 52)
        .overlay {
            Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func brandBadge(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(brandGradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}
