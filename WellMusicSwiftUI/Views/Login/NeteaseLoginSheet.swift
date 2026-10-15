import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// 网易云登录面板：扫码 / 手机号 / Cookie 三种方式。
///
/// 三种方式最后都收敛到同一件事 —— 把服务端下发的 `MUSIC_U` 票据交给
/// `NeteaseSession`（扫码与手机号由接口自动吸收 `Set-Cookie`，
/// Cookie 方式是用户手动粘贴），所以这里不各自维护登录状态，
/// 只负责交互与错误提示。
///
/// `@MainActor`：本页有二维码轮询等 `Task` 在跑，用主 actor 隔离把
/// 状态读写钉在主线程上，避免后台线程改 `@State` 带来的偶发不刷新。
@MainActor
struct NeteaseLoginSheet: View {

    /// 登录方式。
    private enum Mode: String, CaseIterable, Identifiable {
        case qr = "扫码"
        case phone = "手机号"
        case cookie = "Cookie"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .qr: return "qrcode"
            case .phone: return "iphone"
            case .cookie: return "doc.text"
            }
        }
    }

    /// 二维码轮询状态。
    private enum QRPhase: Equatable {
        case loading
        case waiting
        case scanned(String?)
        case expired
        case failed(String)
    }

    /// 手机号登录的两种凭据。
    private enum PhoneCredential: String, CaseIterable, Identifiable {
        case captcha = "验证码"
        case password = "密码"

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var session = NeteaseSession.shared

    @State private var mode: Mode = .qr
    @Namespace private var pickerNamespace

    // 扫码
    @State private var qrPhase: QRPhase = .loading
    @State private var qrImage: UIImage?
    @State private var unikey: String?
    @State private var pollTask: Task<Void, Never>?

    // 手机号
    @State private var credential: PhoneCredential = .captcha
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var cooldown = 0
    @State private var sendingCode = false
    @State private var phoneBusy = false
    @State private var phoneMessage: String?
    @State private var cooldownTask: Task<Void, Never>?

    // Cookie
    @State private var cookieText = ""
    @State private var cookieBusy = false
    @State private var cookieMessage: String?

    private var brandGradient: LinearGradient {
        LinearGradient(colors: [AppTheme.accent, AppTheme.accent.opacity(0.72)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            modePicker
                .padding(.top, 18)
                .padding(.horizontal, 24)

            ScrollView {
                Group {
                    switch mode {
                    case .qr: qrSection
                    case .phone: phoneSection
                    case .cookie: cookieSection
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 28)
            }

            Spacer(minLength: 0)
        }
        .background(sheetBackground)
        .onAppear { startQRLogin() }
        .onDisappear {
            pollTask?.cancel()
            cooldownTask?.cancel()
        }
        .onChange(of: mode) { newValue in
            // 扫到一半切去别的页签、再切回来：二维码还是同一个，不该让用户重扫。
            // 只有「压根没拿到二维码」或「已失效 / 轮询失败」时才重新申请。
            guard newValue == .qr else { return }
            if unikey == nil {
                startQRLogin()
                return
            }
            switch qrPhase {
            case .expired, .failed: startQRLogin()
            case .loading, .waiting, .scanned: break
            }
        }
    }

    // MARK: 顶部

    private var header: some View {
        VStack(spacing: 14) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(brandGradient)
                    .frame(width: 62, height: 62)
                    .shadow(color: AppTheme.accent.opacity(0.35), radius: 14, y: 6)
                Image(systemName: "music.note")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 5) {
                Text("登录网易云音乐")
                    .font(.system(size: 19, weight: .bold))
                Text("同步歌单、我喜欢与每日推荐")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .frame(maxWidth: .infinity)
    }

    /// 自定义分段控件：胶囊底 + 选中项白底滑块（比系统 Picker 更贴合本 App 的观感）。
    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases) { item in
                let selected = item == mode
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        mode = item
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12, weight: .semibold))
                        Text(item.rawValue)
                            .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    }
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color(uiColor: .secondarySystemBackground))
                                .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
                                .matchedGeometryEffect(id: "loginModePill", in: pickerNamespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background {
            Capsule().fill(Color.primary.opacity(0.06))
        }
    }

    private var sheetBackground: some View {
        // sheet 底色跟主页面同一套条件色，避免与系统 sheet 融合时出现色差
        Group {
            if colorScheme == .dark {
                Color.black.ignoresSafeArea()
            } else {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            }
        }
    }

    // MARK: 扫码

    private var qrSection: some View {
        VStack(spacing: 18) {
            Text("使用网易云音乐 App 扫码登录")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white)
                    .frame(width: 214, height: 214)
                    .shadow(color: .black.opacity(0.10), radius: 16, y: 6)

                if let qrImage {
                    Image(uiImage: qrImage)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 178, height: 178)
                        .opacity(qrOverlayVisible ? 0.28 : 1)
                } else {
                    ProgressView().controlSize(.large)
                }

                if qrOverlayVisible {
                    qrOverlay
                        .padding(14)
                        .background(.regularMaterial,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(16)
                }
            }
            .frame(width: 214, height: 214)

            qrStatusText

            VStack(spacing: 4) {
                Text("只有一台设备？")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("截图二维码，到网易云音乐 App 的扫一扫里选相册识别，再回到这里即可")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }

            if case .failed = qrPhase {
                Button {
                    startQRLogin()
                } label: {
                    primaryLabel("重新获取二维码", enabled: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var qrOverlayVisible: Bool {
        if case .expired = qrPhase { return true }
        if case .scanned = qrPhase { return true }
        return false
    }

    @ViewBuilder
    private var qrOverlay: some View {
        VStack(spacing: 9) {
            switch qrPhase {
            case .expired:
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(AppTheme.accent)
                Text("二维码已失效")
                    .font(.system(size: 12.5, weight: .medium))
                Button("刷新") { startQRLogin() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(brandGradient))
                    .buttonStyle(.plain)
            case .scanned(let nickname):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)
                Text("已扫码")
                    .font(.system(size: 13, weight: .semibold))
                Text(nickname.map { "\($0)，请在手机上确认" } ?? "请在手机上确认登录")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            default:
                EmptyView()
            }
        }
        .frame(width: 152)
    }

    @ViewBuilder
    private var qrStatusText: some View {
        Group {
            switch qrPhase {
            case .loading: Text("正在获取二维码…")
            case .waiting: Text("打开网易云音乐 App，扫一扫登录")
            case .scanned: Text("等待手机确认…")
            case .expired: Text("二维码已失效，请刷新")
            case .failed(let message): Text(message).foregroundStyle(AppTheme.accent)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    /// 申请二维码并开始轮询。
    ///
    /// 轮询对**偶发网络错误**容忍（连续失败若干次才放弃）—— 用户扫码时往往要切到
    /// 网易云 App，回来时可能刚好赶上一次请求超时，直接判失败体验很差。
    private func startQRLogin() {
        pollTask?.cancel()
        qrPhase = .loading
        qrImage = nil
        unikey = nil

        pollTask = Task {
            do {
                let key = try await NeteaseMusicAPI.shared.qrLoginKey()
                guard !Task.isCancelled else { return }
                unikey = key
                qrImage = Self.makeQRImage(from: NeteaseMusicAPI.qrLoginURL(unikey: key))
                qrPhase = .waiting

                var consecutiveErrors = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled else { return }

                    let state: NeteaseMusicAPI.NeteaseQRState
                    do {
                        state = try await NeteaseMusicAPI.shared.qrLoginCheck(key: key)
                        consecutiveErrors = 0
                    } catch {
                        consecutiveErrors += 1
                        if consecutiveErrors >= 8 {
                            qrPhase = .failed("二维码状态获取失败，请刷新重试")
                            return
                        }
                        continue
                    }

                    switch state {
                    case .waiting:
                        if qrPhase != .waiting { qrPhase = .waiting }
                    case .scanned(let nickname):
                        qrPhase = .scanned(nickname)
                    case .expired:
                        qrPhase = .expired
                        return
                    case .confirmed:
                        if await completeLogin() { return }
                        qrPhase = .failed("登录确认失败，请刷新二维码重试")
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    qrPhase = .failed(Self.message(for: error))
                }
            }
        }
    }

    // MARK: 手机号

    private var phoneSection: some View {
        VStack(spacing: 16) {
            noticeBar(symbol: "exclamationmark.triangle.fill",
                      text: "短信通道可能被网易云风控拦截；若收不到验证码，请改用扫码或 Cookie 登录",
                      tint: .orange)

            // 验证码 / 密码
            HStack(spacing: 8) {
                ForEach(PhoneCredential.allCases) { item in
                    let selected = item == credential
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { credential = item }
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? AppTheme.accent : Color.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background {
                                Capsule().fill(selected
                                    ? AppTheme.accent.opacity(0.12)
                                    : Color.primary.opacity(0.05))
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            VStack(spacing: 12) {
                field {
                    HStack(spacing: 10) {
                        Image(systemName: "iphone")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text("+86")
                            .font(.system(size: 15, weight: .medium))
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 1, height: 20)
                        TextField("手机号", text: $phone)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                    }
                }

                switch credential {
                case .captcha:
                    field {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            TextField("验证码", text: $code)
                                .textFieldStyle(.plain)
                                .font(.system(size: 15))
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                            Button {
                                sendCode()
                            } label: {
                                Group {
                                    if sendingCode {
                                        ProgressView().controlSize(.small)
                                    } else if cooldown > 0 {
                                        Text("\(cooldown) s").monospacedDigit()
                                    } else {
                                        Text("获取验证码")
                                    }
                                }
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(canSendCode ? AppTheme.accent : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(!canSendCode)
                        }
                    }
                case .password:
                    field {
                        HStack(spacing: 10) {
                            Image(systemName: "key")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            SecureField("密码", text: $password)
                                .textFieldStyle(.plain)
                                .font(.system(size: 15))
                        }
                    }
                }
            }

            if let phoneMessage {
                Text(phoneMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.accent)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            Button {
                loginWithPhone()
            } label: {
                primaryLabel("登录", enabled: canSubmitPhone)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmitPhone)
        }
    }

    private var canSendCode: Bool {
        !sendingCode && cooldown == 0 && phone.trimmingCharacters(in: .whitespaces).count >= 11
    }

    private var canSubmitPhone: Bool {
        guard !phoneBusy, phone.trimmingCharacters(in: .whitespaces).count >= 11 else { return false }
        switch credential {
        case .captcha: return code.trimmingCharacters(in: .whitespaces).count >= 4
        case .password: return password.count >= 6
        }
    }

    private func sendCode() {
        let number = phone.trimmingCharacters(in: .whitespaces)
        sendingCode = true
        phoneMessage = nil
        Task {
            defer { sendingCode = false }
            do {
                try await NeteaseMusicAPI.shared.sendLoginSMSCode(phone: number)
                phoneMessage = "验证码已发送"
                cooldown = 60
                cooldownTask?.cancel()
                cooldownTask = Task {
                    while cooldown > 0, !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if Task.isCancelled { return }
                        cooldown -= 1
                    }
                }
            } catch {
                phoneMessage = Self.message(for: error)
            }
        }
    }

    private func loginWithPhone() {
        let number = phone.trimmingCharacters(in: .whitespaces)
        phoneBusy = true
        phoneMessage = nil
        Task {
            defer { phoneBusy = false }
            do {
                switch credential {
                case .captcha:
                    try await NeteaseMusicAPI.shared.loginCellphone(
                        phone: number, captcha: code.trimmingCharacters(in: .whitespaces))
                case .password:
                    try await NeteaseMusicAPI.shared.loginCellphone(
                        phone: number, password: password)
                }
                if await completeLogin() { return }
                phoneMessage = "登录失败：未能获取账号信息，请重试或改用扫码 / Cookie 登录"
            } catch {
                phoneMessage = Self.message(for: error)
            }
        }
    }

    // MARK: Cookie

    private var cookieSection: some View {
        VStack(spacing: 16) {
            noticeBar(symbol: "info.circle.fill",
                      text: "在浏览器里登录网易云音乐网页版，复制整条 Cookie 粘贴到下面（含 MUSIC_U 即可）",
                      tint: .secondary)

            TextEditor(text: $cookieText)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 104)
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .overlay(alignment: .topLeading) {
                    if cookieText.isEmpty {
                        Text("MUSIC_U=…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

            if let cookieMessage {
                Text(cookieMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.accent)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            Button {
                loginWithCookie()
            } label: {
                primaryLabel("登录", enabled: canSubmitCookie)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmitCookie)
        }
    }

    private var canSubmitCookie: Bool {
        !cookieBusy && cookieText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 16
    }

    private func loginWithCookie() {
        let raw = cookieText.trimmingCharacters(in: .whitespacesAndNewlines)
        cookieBusy = true
        cookieMessage = nil
        Task {
            defer { cookieBusy = false }
            NeteaseSession.shared.ingest(cookieString: raw)
            guard NeteaseSession.shared.isLoggedIn else {
                cookieMessage = "没找到 MUSIC_U 字段，请确认复制的是完整 Cookie"
                return
            }
            // 票据对不对，以「能否拉到账号资料」为准
            if await session.refreshAccount() {
                ToastCenter.shared.show("欢迎回来，\(session.account?.nickname ?? "")")
                dismiss()
            } else {
                cookieMessage = "Cookie 无效或已过期，请重新获取"
                session.clearAuth()
            }
        }
    }

    // MARK: 公共部分

    /// 收尾：拉账号资料 → 真的拿到了才提示并关闭。
    ///
    /// 以前这里无视 `refreshAccount()` 的返回值，账号没拉到也弹「欢迎回来」并关面板，
    /// 而登录卡片要求 `account != nil` 才渲染已登录态 —— 用户看到的就是
    /// 「提示登陆了但界面没变化」。现在按「资料到手 / 只有票据 / 什么都没有」
    /// 三档分别处理，失败时把面板留着让用户重试。
    @discardableResult
    private func completeLogin() async -> Bool {
        pollTask?.cancel()
        var fetched = await session.refreshAccount()
        // 刚登录成功时账号资料接口偶发超时；票据已到手就再试两次，别急着下结论
        var attempt = 0
        while !fetched, session.isLoggedIn, attempt < 2 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            fetched = await session.refreshAccount()
            attempt += 1
        }
        guard fetched || session.isLoggedIn else { return false }
        if fetched, let nickname = session.account?.nickname {
            ToastCenter.shared.show("欢迎回来，\(nickname)")
        } else {
            // 票据有效但资料没拉到：不清登录态，进入「我的」页还会再拉一次
            ToastCenter.shared.show("已登录，账号信息稍后自动刷新")
        }
        dismiss()
        return true
    }

    /// 主按钮：渐变胶囊，禁用时灰掉。
    private func primaryLabel(_ title: String, enabled: Bool) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background {
                Capsule().fill(enabled
                    ? AnyShapeStyle(brandGradient)
                    : AnyShapeStyle(Color.secondary.opacity(0.25)))
            }
    }

    /// 输入框外框（图标 + 输入区共用一个圆角卡片）。
    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }

    private func noticeBar(symbol: String, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11.5))
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((tint == .secondary ? Color.primary.opacity(0.06) : tint.opacity(0.12)))
        }
    }

    /// 把错误转成能直接给用户看的文案。
    private static func message(for error: Error) -> String {
        if let netease = error as? NeteaseAPIError { return netease.message }
        return error.localizedDescription
    }

    /// 本地生成二维码（不依赖任何在线二维码服务）。
    private static func makeQRImage(from text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
