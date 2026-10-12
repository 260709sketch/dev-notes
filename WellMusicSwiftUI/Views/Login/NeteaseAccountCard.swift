import SwiftUI

/// 「我的」页顶部的网易云账号卡片。
///
/// 未登录时是登录入口（点击弹出 `NeteaseLoginSheet`），
/// 已登录时显示昵称头像，并提供一个带确认的退出入口。
///
/// 卡片自己持有登录面板的呈现状态 —— 登录态是全局的（`NeteaseSession`），
/// 但「面板开不开」纯粹是这一处的局部 UI 状态，没必要往上提。
@MainActor
struct NeteaseAccountCard: View {
    @ObservedObject private var session = NeteaseSession.shared
    @State private var showingLogin = false
    @State private var showingLogoutConfirm = false

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
        .confirmationDialog("确定退出网易云账号？", isPresented: $showingLogoutConfirm, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                Task {
                    await NeteaseMusicAPI.shared.logout()
                    session.clearAuth()
                    ToastCenter.shared.show("已退出网易云账号")
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后我的歌单、我喜欢等在线内容将不可用，本地歌曲不受影响")
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
                Text(account.nickname)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.accent)
                    Text("网易云音乐已登录")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 6)

            Button("退出") {
                showingLogoutConfirm = true
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
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
