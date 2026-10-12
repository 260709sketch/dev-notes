import Foundation
import Libmpv

/// libmpv 播放内核（MPVKit 提供预编译 xcframework）。
///
/// ## 为什么从 AVPlayer 换到 MPV
///
/// 歌词同步问题的最终定位（2026-10-12）：歌词时钟与 `AVPlayer.currentTime()`
/// 完全一致（端到端 Δ ≈ −3ms），但**耳朵听到的人声与 `currentTime()` 差几秒**。
/// 即 AVPlayer 的位置报告在 seek（尤其远距离）后与实际渲染的音频脱节 —— 这是
/// 内核级行为，应用层无解。MPV 的 `time-pos` 由**音频输出时钟**驱动
/// （ao → 解码 → 渲染同一时钟域），耳朵听到哪、time-pos 就报哪，天然与
/// 可闻音频对齐 —— 这是换内核要买的那一个东西。
///
/// ## 线程模型
///
/// * libmpv 的 C API 线程安全：主线程直接下发命令/读属性；
/// * 事件循环跑在独立串行队列，`mpv_wait_event` 阻塞等待，
///   只处理 `END_FILE`（曲目自然播完）并回调主线程；
/// * 位置/时长/缓冲态由 PlayerCore 的 0.05s tick 直读（C 调用，极便宜）。
///
/// ## 音频输出
///
/// MPVKit 的 iOS 构建自带 avfoundation/audiounit 音频输出，走 AVAudioSession，
/// 所以本项目的后台播放 / 静音键 / 音量体系保持不变（`AudioSessionManager`
/// 照常设置 `.playback` category 即可）。
final class MPVEngine: @unchecked Sendable {

    private var handle: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "wellmusic.mpv.events", qos: .userInitiated)
    private var loopStarted = false
    private var loopRunning = false

    /// 曲目结束回调 —— 主线程。
    ///
    /// ⚠️ **EOF ≠ 自然播完**：网易云 CDN 会在 seek 重拉或长播放后掐断连接，
    /// mpv 会把「流被断开」也报告成 END_FILE(EOF)。调用方必须结合当前位置
    /// 判断是真播完还是断流（见 `PlayerCore.handleTrackEnded`）。
    enum TrackEndReason { case eof, error, stop, other }
    var onTrackEnded: ((TrackEndReason) -> Void)?

    // MARK: 生命周期

    /// 创建并初始化 mpv 句柄。重复调用无效。
    func start() {
        guard handle == nil else { return }
        guard let h = mpv_create() else { return }
        handle = h

        // 纯音频：关视频输出与视频解码，省 CPU/内存
        mpv_set_option_string(h, "vo", "null")
        mpv_set_option_string(h, "vid", "no")
        // ⚠️ 网络流缓存：必须**开**。曾经误设 `cache=no` —— 那会让下面两个
        // demuxer 缓存参数**全部失效**，网络流零缓冲：任何 seek 都要扔掉全部
        // 已缓冲数据、重新发 Range 请求，LX 第三方 CDN 对频繁 Range 很敏感，
        // 一掐断就是 END_FILE(EOF)，表现即「点一下进度条就切歌 / 听一会就断」。
        // cache=yes + 60s 预读让网络波动被缓冲吸收，seek 优先命中缓存不回源。
        mpv_set_option_string(h, "cache", "yes")
        mpv_set_option_string(h, "demuxer-max-bytes", "96MiB")
        mpv_set_option_string(h, "demuxer-readahead-secs", "60")
        // 网络读超时：避免挂死（断流会以 END_FILE 报告，由上层恢复）
        mpv_set_option_string(h, "network-timeout", "15")
        // 播完自然结束（触发 END_FILE/EOF），不保留最后一帧
        mpv_set_option_string(h, "keep-open", "no")

        // ── 音质保障（显式声明，防止构建默认值意外）──
        // replaygain 必须关：否则带 ReplayGain 标签的文件会被自动衰减
        mpv_set_option_string(h, "replaygain", "no")
        // 不对声道做任何下混/归一化
        mpv_set_option_string(h, "audio-normalize-downmix", "no")
        // 采样率保持源文件原样（44.1k 就以 44.1k 交给系统混音器，
        // 与 AVPlayer/CoreAudio 的路径一致，不做播放器层的强制重采样）
        mpv_set_option_string(h, "audio-samplerate", "")

        // ⚠️ 默认 User-Agent：mpv 自报 "libmpv 0.x"，网易云 CDN 会识别并掐断连接
        // （表现为播放十几秒就断流切歌；QQ 的 CDN 无此策略）。伪装成浏览器。
        // 官方平台 URL 的 headers 为空（ResolvePlayback 仅自定义音源带头），
        // 所以这个默认值对网易云是**必需**的；loadfile 时可被 headers 覆盖。
        mpv_set_option_string(h, "user-agent",
                              "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15")
        // 静音检测的音画同步阈值放宽对纯音频无意义，保持默认

        guard mpv_initialize(h) >= 0 else {
            mpv_terminate_destroy(h)
            handle = nil
            return
        }

        loopRunning = true
        startEventLoop()
    }

    /// 是否已成功初始化
    var isReady: Bool { handle != nil }

    // MARK: 状态读取（PlayerCore 的 0.05s tick 直读）

    /// 当前播放位置（秒）。未加载/不可用时返回 nil。
    /// 这是**音频输出时钟**驱动的渲染真值 —— 与耳朵听到的位置对齐。
    var timePos: Double? {
        guard let h = handle else { return nil }
        var d: CDouble = 0
        guard mpv_get_property(h, "time-pos", MPV_FORMAT_DOUBLE, &d) >= 0, d.isFinite else { return nil }
        return d
    }

    /// 当前曲目时长（秒）。不可用时返回 nil。
    var duration: Double? {
        guard let h = handle else { return nil }
        var d: CDouble = 0
        guard mpv_get_property(h, "duration", MPV_FORMAT_DOUBLE, &d) >= 0, d.isFinite, d > 0 else { return nil }
        return d
    }

    /// 是否处于「暂停」态（用户主动暂停）
    var isPaused: Bool {
        guard let h = handle else { return true }
        var v: CInt = 1
        guard mpv_get_property(h, "pause", MPV_FORMAT_FLAG, &v) >= 0 else { return true }
        return v != 0
    }

    /// 是否处于「缓冲等待」态（seek 后重拉 / 网络卡顿）
    var isBuffering: Bool {
        guard let h = handle else { return false }
        var v: CInt = 0
        // paused-for-cache：true = 缓冲不足暂停播放
        guard mpv_get_property(h, "paused-for-cache", MPV_FORMAT_FLAG, &v) >= 0 else { return false }
        return v != 0
    }

    /// 是否空闲（没有活跃的播放链路；加载中/播完/出错都会是 true）
    var isCoreIdle: Bool {
        guard let h = handle else { return true }
        var v: CInt = 1
        guard mpv_get_property(h, "core-idle", MPV_FORMAT_FLAG, &v) >= 0 else { return true }
        return v != 0
    }

    // MARK: 控制

    /// 加载曲目。`headers` 作为 HTTP 请求头下发（网易云 CDN 需要 Referer 等）。
    func load(url: String, headers: [String: String], startAt: Double, autoPlay: Bool) {
        guard let h = handle else { return }
        // ⚠️ 请求头逐个用 mpv 的专用/通用选项下发，**不要**用 `http-header-fields`
        // 逗号拼接 —— 那个属性对「Name: value」带冒号的字符串解析不可靠，
        // Referer 丢了对 LX 源站的第三方 CDN 就是 403/试听/拒绝，表现即
        // 「每首歌十几秒就断」。
        var userAgent: String?
        var referer: String?
        for (k, v) in headers {
            let key = k.lowercased()
            if key == "user-agent" { userAgent = v; continue }
            if key == "referer" { referer = v; continue }
        }
        if let ua = userAgent {
            mpv_set_option_string(h, "user-agent", ua)
        }
        // ⚠️ referrer 是**全局残留**选项：上一首 LX 源设的 Referer 会一直留着，
        // 切到网易云官方 CDN（或反过来）时带着错误的 Referer 就是 403/掐流。
        // 所以「本曲没有 Referer」时必须显式清空，不能只是不设置。
        mpv_set_option_string(h, "referrer", referer ?? "")

        // 起播位置走 `start` 选项：它在文件加载时生效。
        // ❌ 不能「loadfile 之后立刻 seek」—— 文件还没加载完，seek 会被丢弃，
        // 断流重载就永远从头播（表现即「点进度条 → 歌跳回开头/换歌」）。
        if startAt > 0 {
            mpv_set_option_string(h, "start", String(format: "%.3f", max(0, startAt)))
        } else {
            mpv_set_option_string(h, "start", "0")
        }
        command("loadfile", [url, "replace"])
        setPaused(!autoPlay)
    }

    func setPaused(_ paused: Bool) {
        guard let h = handle else { return }
        var v: CInt = paused ? 1 : 0
        mpv_set_property(h, "pause", MPV_FORMAT_FLAG, &v)
    }

    /// seek 到绝对位置。mpv 的音频流每一帧都是关键帧，keyframe seek 精度
    /// 约为一帧（几十 ms），且不会像 AVPlayer 那样报告与实际渲染脱节的位置。
    func seek(to seconds: Double) {
        command("seek", [String(max(0, seconds)), "absolute"])
    }

    func setVolume(percent: Double) {
        guard let h = handle else { return }
        var d = CDouble(max(0, min(100, percent)))
        mpv_set_property(h, "volume", MPV_FORMAT_DOUBLE, &d)
    }

    func shutdown() {
        loopRunning = false
        if let h = handle {
            mpv_terminate_destroy(h)
        }
        handle = nil
    }

    // MARK: 命令下发（官方 Demo 的 strdup/free 模式）

    private func command(_ name: String, _ args: [String] = []) {
        guard let h = handle else { return }
        var strArgs = [String?]()
        strArgs.append(name)
        strArgs.append(contentsOf: args)
        strArgs.append(nil)
        var cargs = strArgs.map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer {
            for ptr in cargs where ptr != nil {
                free(UnsafeMutablePointer(mutating: ptr!))
            }
        }
        mpv_command(h, &cargs)
    }

    // MARK: 事件循环（只关心曲目自然播完）

    private func startEventLoop() {
        guard !loopStarted else { return }
        loopStarted = true
        eventQueue.async { [weak self] in
            guard let self else { return }
            while self.loopRunning, let h = self.handle {
                guard let event = mpv_wait_event(h, 0.5) else { continue }
                let id = event.pointee.event_id
                if id == MPV_EVENT_NONE { continue }
                switch id {
                case MPV_EVENT_END_FILE:
                    // reason 语义：EOF=0（自然播完**或**流被 CDN 掐断，见 onTrackEnded）、
                    // STOP=2（loadfile replace 换曲，忽略）、QUIT=3、ERROR=5（网络/解码错误）
                    guard let data = event.pointee.data else { break }
                    let p = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    let reason: TrackEndReason
                    switch p.reason {
                    case MPV_END_FILE_REASON_EOF: reason = .eof
                    case MPV_END_FILE_REASON_STOP: reason = .stop
                    case MPV_END_FILE_REASON_ERROR: reason = .error
                    default: reason = .other
                    }
                    if reason != .stop {
                        DispatchQueue.main.async { [weak self] in self?.onTrackEnded?(reason) }
                    }
                case MPV_EVENT_SHUTDOWN:
                    self.loopRunning = false
                default:
                    break
                }
            }
        }
    }
}
