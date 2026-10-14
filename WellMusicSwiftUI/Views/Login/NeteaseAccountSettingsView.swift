import SwiftUI

/// 设置 → 账号 → NetEase Cloud ID 的二级页面。
///
/// 2026-10-14 用户：设置页播放分组上方新增「账号」分组，其中一项「NetEase Cloud ID」
/// 点击跳下一级用来登录网易云。本页就是那一级 —— 展示登录态 + 登录/退出入口。
/// 用户明确「登录后后续会增加功能你暂时先别动」，所以这里只做登录/退出，不塞别的。
struct NeteaseAccountSettingsView: View {
    @ObservedObject private var session = NeteaseSession.shared
    @State private var showingLogin = false
    @State private var showingLogoutConfirm = false

    var body: some View {
        List {
            if let account = session.account, session.isLoggedIn {
                Section {
                    HStack(spacing: 14) {
                        if let urlString = account.avatarURL, let url = URL(string: urlString), !urlString.isEmpty {
                            WellAsyncImage(url: url) {
                                Image(systemName: "person.crop.circle")
                                    .font(.system(size: 28))
                            }
                            .frame(width: 52, height: 52)
                            .clipShape(Circle())
                        } else {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 28))
                                .frame(width: 52, height: 52)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.nickname)
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                            Text("ID: \(account.userId)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Button(role: .destructive) {
                        showingLogoutConfirm = true
                    } label: {
                        Text("退出登录")
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                Section {
                    Button {
                        showingLogin = true
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 20))
                            Text("登录网易云音乐")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } footer: {
                    Text("登录后同步我喜欢的音乐、歌单与每日推荐")
                }
            }
        }
        .navigationTitle("NetEase Cloud ID")
        .navigationBarTitleDisplayMode(.inline)
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
        }
        .task {
            if session.isLoggedIn { await session.refreshAccount() }
        }
    }
}
