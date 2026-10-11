#if os(iOS)
import SwiftUI
import WebKit
import Combine

/// 歌词页时钟的下发策略常量。
///
/// 独立成 `enum` 而非散落在 `Coordinator` 里的字面量，一是让三条阈值各有名字、
/// 二是可以在单元测试里锁死契约（这些数值直接决定「拖动后歌词是否偏移」）。
enum AMLLClockPolicy {
    /// 「位置是否真的在走」的判定阈值（毫秒）。
    ///
    /// 低于它就认为播放器停在原地（加载 / 缓冲 / 卡顿），此时不再告诉页面「继续走」——
    /// 否则页面会从上一个样本一路外推，等真实位置追上来时就会跳一下，
    /// 也就是切歌时的抖动。
    static let movementThresholdMs = 30

    /// 同值去重阈值（毫秒）。
    ///
    /// 与已发送值相差不足这个数就不下发，省掉一次 JS 调用 + 一次跨进程消息。
    /// 取 5ms 远小于 100ms 的推送周期与 30ms 的移动判定：正常播放每拍变化都在 100ms 上下，
    /// 一定会被发出；能被拦掉的只有「重复读到同一位置」这类真正的冗余。
    static let dedupeThresholdMs = 5

    /// 硬校准的触发阈值（毫秒）。
    ///
    /// 目标位置与页面当前所在位置相差不足这个数时跳过校准，避免无谓地重置外推纪元。
    /// 比去重阈值宽一些：校准本身带一次 `setCurrentTime`，代价高于普通 `sync`，
    /// 为几毫秒去重置一次不划算。
    static let calibrationThresholdMs = 30

    /// 拖动收尾补校准的延迟（秒）。
    ///
    /// `seek(to:toleranceBefore:toleranceAfter:)` 的完成回调与 `@Published isScrubbing`
    /// 的派发顺序没有保证，让出一个 runloop 再读位置更稳；对用户完全不可感知。
    static let settleDelay: TimeInterval = 0.06
}

/// The original Apple Music-like Lyrics player (https://github.com/amll-dev/applemusic-like-lyrics, AGPL-3.0), running in a
/// web view. The lyric lines and clock samples are pushed in; the page animates with AMLL's own spring layout, blur and
/// word highlight and reports taps on a line back so the song can jump there.
struct AMLLWebLyricsView: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @AppStorage("wellmusic.lyricOffset") private var lyricOffset = 0.0

    /// 是否使用 Apple Music 独立的 AMLL 设置（和沉浸模式v2分开）
    var useAppleMusicSettings: Bool = false

    /// 硬校准触发器：每 +1 表示「播放位置被外力改写了（拖动结束 / 跳转），请立刻校准歌词页时钟」。
    ///
    /// 参考 RN 版的 `seekCommand = { seq, time }`：用**自增序号 + 目标时间**表达一次离散事件。
    /// 为什么不能只看 `player.clock.progress`：那个值在拖动结束的乐观更新里被写成目标值，
    /// 但正常情况下它每 50ms 都在变，`onChange` 无法区分「自然推进」与「被 seek 改写」；
    /// 而且它来自 `displayTime`，无损音质下松手瞬间可能滞后。这里传的是**精确**目标时间
    /// （`PlayerService.precisePlaybackTime`），并只在真正发生 seek 时递增。
    /// - 0 表示「尚未有事件」，避免首次 `onChange` 把页面误校准到 0。
    @State private var calibrationSeq = 0
    @State private var calibrationTime: TimeInterval = 0

    /// The lyrics of the song that is playing (empty while they load). The web view itself is never torn down between
    /// songs: rebuilding it reloads the whole page, which is what made the lyrics flash on every song change.
    private var lyrics: ParsedLyrics { player.lyrics ?? ParsedLyrics() }

    /// The page relies on CSS nesting and registered custom properties (WebKit 16.4+).
    static var isSupported: Bool {
        if #available(iOS 16.4, *) { return true }
        return false
    }

    private var currentFontSize: CGFloat {
        ScreenAdapter.h(CGFloat(useAppleMusicSettings ? settings.appleMusicAmllFontSize : settings.amllFontSize))
    }

    private var currentFontWeight: Int {
        useAppleMusicSettings ? settings.appleMusicAmllFontWeight : settings.amllFontWeight
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            AMLLWebRepresentable(
                lyrics: lyrics,
                showsTranslation: settings.showLyricsTranslation,
                showsRomaji: settings.lyricsAnnotation == .romaji,
                fontSize: currentFontSize,
                fontWeight: currentFontWeight,
                calibrationSeq: calibrationSeq,
                calibrationTime: calibrationTime
            )
            .frame(width: width, height: geometry.size.height)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.08),
                        .init(color: .black, location: 0.9),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
        .overlay { stateOverlay }
        // 拖动**结束**时立刻硬校准。
        // `isScrubbing` 由 true → false 只发生在拖动收尾（或兜底超时），
        // 正是 RN 版 `emitSeek` 唯一的触发点；拖动过程中不触发，避免高频重置外推纪元。
        .onReceive(PlayerCore.shared.$isScrubbing.removeDuplicates()) { isScrubbing in
            guard !isScrubbing else { return }
            requestCalibration()
        }
        // 歌词行被点击时（页面 `line-click` → `PlayerService.seek`）同样需要硬校准。
        // 这里监听 `PlayerCore.currentTime`（`PlayerService` 上并没有暴露 `core`）。
        .onReceive(PlayerCore.shared.$currentTime) { _ in
            guard !PlayerCore.shared.isScrubbing else { return }
            requestCalibration()
        }
    }

    /// 记下一次硬校准请求。读取的是**精确**位置，而不是 `displayTime`——
    /// 后者在松手瞬间可能还停留在轮询缓存里的旧值上。
    private func requestCalibration() {
        let precise = player.precisePlaybackTime
        guard precise.isFinite, precise >= 0 else { return }
        calibrationTime = precise
        calibrationSeq &+= 1
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if player.lyrics == nil {
            ProgressView().controlSize(.small).tint(.white)
        } else if player.lyrics?.isInstrumental == true {
            VStack(spacing: 10) {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
                Text("纯音乐，请欣赏")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }
        } else if player.lyrics?.isEmpty == true {
            VStack(spacing: 10) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
                Text("暂无歌词")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }
}

private struct AMLLWebRepresentable: UIViewRepresentable {
    let lyrics: ParsedLyrics
    let showsTranslation: Bool
    let showsRomaji: Bool
    let fontSize: CGFloat
    let fontWeight: Int
    /// 硬校准事件的自增序号与目标时间，见 `AMLLWebLyricsView.calibrationSeq`。
    let calibrationSeq: Int
    let calibrationTime: TimeInterval

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // WebKit paces page animation near 60 fps by default (requestAnimationFrame included). The lyrics should follow the
        // display, 120 Hz on ProMotion phones, so that pacing feature is switched off. This goes through WebKit's internal
        // feature switch (not public API), so every step is checked and the outcome is logged.
        let switched = Self.disableNear60FPSPacing(configuration.preferences)
        Task { @MainActor in
            print("[AMLL] 歌词帧率设置 - 60帧限制已解除：\(switched)，屏幕最高 \(UIScreen.main.maximumFramesPerSecond) Hz")
        }
        configuration.userContentController.add(WeakScriptHandler(context.coordinator), name: "amll")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.alpha = 0
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        // AMLL scrolls and flicks the lyrics itself from the touch events.
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.attach(web)
        if let url = Bundle.main.url(forResource: "AMLLLyricsPage", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    /// `WKPreferences` keeps an internal list of feature flags; "PreferPageRenderingUpdatesNear60FPSEnabled" is the one that
    /// holds page animation near 60 fps.
    private static func disableNear60FPSPacing(_ preferences: WKPreferences) -> Bool {
        let featuresSelector = NSSelectorFromString("_features")
        let setSelector = NSSelectorFromString("_setEnabled:forFeature:")
        guard WKPreferences.responds(to: featuresSelector), preferences.responds(to: setSelector),
              let list = (WKPreferences.self as AnyObject).perform(featuresSelector)?.takeUnretainedValue() as? [AnyObject]
        else { return false }
        for feature in list {
            guard let key = feature.value(forKey: "key") as? String,
                  key == "PreferPageRenderingUpdatesNear60FPSEnabled" else { continue }
            typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
            let implementation = preferences.method(for: setSelector)
            unsafeBitCast(implementation, to: SetEnabled.self)(preferences, setSelector, false, feature)
            return true
        }
        return false
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.update(lyrics: lyrics, showsTranslation: showsTranslation, showsRomaji: showsRomaji,
                                   fontSize: fontSize, fontWeight: fontWeight,
                                   calibrationSeq: calibrationSeq, calibrationTime: calibrationTime)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        private weak var web: WKWebView?
        private var ready = false
        private var loadedSignature: Int?
        private var pending: (lyrics: ParsedLyrics, translation: Bool, romaji: Bool, signature: Int)?
        private var fontSize: CGFloat = 30
        private var fontWeight: Int = 600
        private var timer: Timer?
        /// 上一次**真正下发**给歌词页的毫秒数。
        ///
        /// 用它做两件事：
        /// 1. `pushClock` 的同值去重（阈值见 `AMLLClockPolicy`）；
        /// 2. 判断是否需要硬校准——seek 之后若目标值与已发送值几乎相同，
        ///    说明页面时钟刚好在那里，硬校准是多余的。
        private var lastSentMs = Int.min
        /// 已处理过的硬校准事件序号（见 `AMLLWebLyricsView.calibrationSeq`）。
        private var lastCalibrationSeq = 0
        /// 拖动的收尾校准：`isScrubbing` 转 false 的那次回调必然发生在 seek **回调之前**，
        /// 所以这里等回调落地后再补一次，把「乐观值 vs 精确值」的残差抹平。
        private var scrubbingWasActive = false
        private var settleCalibrationWork: DispatchWorkItem?
        /// 订阅 `PlayerCore.isScrubbing`，用于拖动收尾的补校准。
        private var scrubObserver: AnyCancellable?

        func attach(_ web: WKWebView) {
            self.web = web
            // The page extrapolates the clock between samples, so ten a second keep it exact without a call per frame.
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pushClock() }
            }
            // 拖动收尾的补校准：seek 回调里 `isScrubbing` 才真正落回 false，
            // 而那之后 `PlayerCore.currentTime` 变成了播放器回报的精确值。
            scrubObserver = PlayerCore.shared.$isScrubbing
                .removeDuplicates()
                .sink { [weak self] isScrubbing in
                    MainActor.assumeIsolated { self?.handleScrubbingChange(isScrubbing) }
                }
        }

        func detach() {
            timer?.invalidate()
            timer = nil
            scrubObserver?.cancel()
            scrubObserver = nil
            settleCalibrationWork?.cancel()
            settleCalibrationWork = nil
            web?.configuration.userContentController.removeScriptMessageHandler(forName: "amll")
        }

        /// `isScrubbing` 落回 false = 一次精确 seek 刚刚完成。
        /// 此时再校准一次（读的是 seek 回调写入的精确位置），确保页面时钟与真实位置完全对齐。
        /// 用极小延迟而不是立刻下发：回调与 `@Published` 的派发顺序保证不了「写入已可见」，
        /// 让出一个 runloop 更稳；对用户完全不可感知。
        private func handleScrubbingChange(_ isScrubbing: Bool) {
            if isScrubbing {
                scrubbingWasActive = true
                settleCalibrationWork?.cancel()
                settleCalibrationWork = nil
                return
            }
            guard scrubbingWasActive else { return }
            scrubbingWasActive = false
            settleCalibrationWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.ready else { return }
                    self.settleCalibrationWork = nil
                    self.hardCalibrate(to: PlayerService.shared.precisePlaybackTime)
                }
            }
            settleCalibrationWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + AMLLClockPolicy.settleDelay, execute: work)
        }

        func update(lyrics: ParsedLyrics, showsTranslation: Bool, showsRomaji: Bool, fontSize: CGFloat, fontWeight: Int,
                    calibrationSeq: Int, calibrationTime: TimeInterval) {
            // 硬校准事件优先于歌词加载处理：它与歌词签名无关，且必须在本次 SwiftUI 更新里
            // 立刻下发，否则要等下一次 update 才生效（期间歌词已经跑偏）。
            if lastCalibrationSeq != calibrationSeq {
                // 首次进入（seq 从 0 变成 1）时页面可能还没 ready，
                // `hardCalibrate` 会自行挡掉；随后 `flushPending` 里会带上正确时间重新载入。
                lastCalibrationSeq = calibrationSeq
                hardCalibrate(to: calibrationTime)
            }

            // updateUIView runs on every SwiftUI update, which are many while a song loads: hashing every word of the
            // lyrics each time is wasteful, so the signature uses the line count, the ends and the middle of the lyrics.
            var hasher = Hasher()
            hasher.combine(lyrics.lines.count)
            for line in [lyrics.lines.first, lyrics.lines.last, lyrics.lines.isEmpty ? nil : lyrics.lines[lyrics.lines.count / 2]] {
                hasher.combine(line?.text)
                hasher.combine(line?.time)
                hasher.combine(line?.translation)
                hasher.combine(line?.words?.count)
            }
            hasher.combine(showsTranslation)
            hasher.combine(showsRomaji)
            let signature = hasher.finalize()
            if abs(fontSize - self.fontSize) > 0.5 {
                self.fontSize = fontSize
                if ready { run("AMLLBridge.setFontSize(\(fontSize))") }
            }
            if fontWeight != self.fontWeight {
                self.fontWeight = fontWeight
                if ready { applyFontWeight(fontWeight) }
            }
            if signature == loadedSignature {
                // The lyrics that are on the page came back (a song restarted, or the same song again) while something else
                // was waiting to be loaded - typically the empty lyrics of the moment in between. Drop the waiting load and
                // show the page again; otherwise the empty lyrics would replace them.
                if pending != nil {
                    pending = nil
                    flushWork?.cancel()
                    fade(to: loadedHasContent ? 1 : 0, duration: 0.2, delay: 0)
                }
                return
            }
            guard signature != pending?.signature else { return }
            // New lines are coming: hide the old ones at once, and wait a moment so that the several updates a song change
            // produces (loading state, a first lyric, a better one) become a single load.
            if loadedSignature != nil { fade(to: 0, duration: 0.12, delay: 0) }
            pending = (lyrics, showsTranslation, showsRomaji, signature)
            flushWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flushPending() }
            flushWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (loadedSignature == nil ? 0 : 0.3), execute: work)
        }

        private var flushWork: DispatchWorkItem?
        /// Whether the lines on the page are real lyrics (not the empty placeholder between two songs).
        private var loadedHasContent = false

        private func fade(to alpha: CGFloat, duration: TimeInterval, delay: TimeInterval) {
            guard let web else { return }
            UIView.animate(withDuration: duration, delay: delay, options: [.beginFromCurrentState, .allowUserInteraction]) {
                web.alpha = alpha
            }
        }

        private func flushPending() {
            guard ready, let pending else { return }
            self.pending = nil
            loadedSignature = pending.signature
            loadedHasContent = !pending.lyrics.isEmpty
            let payload = Self.payload(for: pending.lyrics, translation: pending.translation, romaji: pending.romaji)
            let ms = Int(currentSeconds() * 1000)
            run("AMLLBridge.setFontSize(\(fontSize)); AMLLBridge.load(\(payload), \(ms))")
            pushClock()
            // Let AMLL lay the new lines out before they show.
            fade(to: pending.lyrics.isEmpty ? 0 : 1, duration: 0.3, delay: 0.25)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "moumusic.debugAMLL") { scheduleDiagnostics() }
            #endif
        }

        #if DEBUG
        /// Debug only: what the page really rendered (text code points, font, size, errors), into the diagnostic log.
        private func scheduleDiagnostics() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                let script = """
                (function(){
                  const line = document.querySelector('[class*="lyricMainLine"]');
                  const span = line && line.querySelector('span');
                  const rect = line ? line.getBoundingClientRect() : null;
                  return JSON.stringify({
                    ua: navigator.userAgent, w: innerWidth, h: innerHeight,
                    family: span ? getComputedStyle(span).fontFamily : null,
                    size: span ? getComputedStyle(span).fontSize : null,
                    text: line ? line.textContent.slice(0, 24) : null,
                    codes: line ? Array.from(line.textContent.slice(0, 6)).map(c => c.codePointAt(0).toString(16)) : null,
                    lines: document.querySelectorAll('[class*="lyricLine"]').length,
                    rect: rect ? [Math.round(rect.width), Math.round(rect.height)] : null,
                    errors: window.__amllErrors || []
                  });
                })()
                """
                self?.web?.evaluateJavaScript(script) { result, error in
                    let text = (result as? String) ?? "error: \(String(describing: error))"
                    print("[AMLL] 页面诊断: \(text)")
                }
            }
        }
        #endif

        private func currentSeconds() -> TimeInterval {
            let offset = UserDefaults.standard.double(forKey: "wellmusic.lyricOffset")
            return PlayerService.shared.livePlaybackTime + offset
        }

        /// 上一次推给页面的时间样本（毫秒），用于「位置是否真的在走」的判定。
        private var lastSampleMs = 0

        /// 把当前播放位置推给歌词页。
        ///
        /// 关键修复（**无损 / Hi-Res 拖动进度条后歌词持续偏移**）：
        /// 歌词页的时钟是 `co + (now - _l) * rate` 的**自由外推**——一旦种下误差就会自己越走越远。
        /// 而这里的采样受两重限制：
        /// 1. `livePlaybackTime` 走的是 `displayTime` → `currentTime`，在无损大文件上
        ///    周期回调间隔被拉长，松手瞬间可能滞后上百毫秒；
        /// 2. 下面「位置没动就不上报」的判定，会让误差在启动 / 缓冲 / 卡顿期间**长期冻结**。
        /// 两者叠加，页面上的人声与歌词就「各跑各的」了。
        ///
        /// 修法与 RN 版一致：**硬校准**（见 `hardCalibrate`）负责把误差清零，
        /// 这里只负责维持正常推进，并做同值去重以免白白唤醒 WebKit。
        private func pushClock() {
            guard ready else { return }
            let player = PlayerService.shared
            let ms = Int(currentSeconds() * 1000)
            let moving = abs(ms - lastSampleMs) >= AMLLClockPolicy.movementThresholdMs
            lastSampleMs = ms
            let running = player.isPlaying && !player.isBuffering && moving
            sendClock(ms: ms, running: running)
        }

        /// 同值去重后再下发，并记录已发送值。
        ///
        /// 页面收到 `sync(ms, running, rate)` 时会无条件重置外推纪元
        /// （`_l = now; co = ms`），代价是一次 JS 调用 + 一次跨进程消息。
        /// 位置几乎没变时这次重置毫无收益，纯属浪费——按 5ms 阈值跳过。
        private func sendClock(ms: Int, running: Bool) {
            guard abs(ms - lastSentMs) >= AMLLClockPolicy.dedupeThresholdMs else { return }
            lastSentMs = ms
            run("AMLLBridge.sync(\(ms), \(running), 1.0)")
        }

        /// 把歌词页时钟**硬校准**到指定位置，并以该位置为新纪元重新开始外推。
        ///
        /// 对应 RN 版的 `emitSeek` / kumone 的 `seekCommand`：拖动结束与跳转时下发一次，
        /// 让 AMLL 立刻落到准确时间，而不是等下一次 100ms 采样慢慢追——那个追赶过程
        /// 在无损音质下可能持续很久，听感上就是「歌词和歌声错开」。
        ///
        /// 拖动过程中**不**下发：高频注入会不断重置外推纪元、挤掉最终那次校准，
        /// 反而导致松手后彻底脱节（RN 源码里明确记录过这个坑）。
        /// 拖动中的跟手由 `displayTime` → `scrubTime` 经 `pushClock` 自然驱动。
        private func hardCalibrate(to seconds: TimeInterval) {
            guard ready, seconds.isFinite else { return }
            let offset = UserDefaults.standard.double(forKey: "wellmusic.lyricOffset")
            // 页面工作在「歌词时间 = 播放位置 + 偏移」的坐标系里。
            let ms = Int(((max(0, seconds) + offset) * 1000).rounded())
            // 目标与页面当前所在位置几乎一致时无需硬校准，避免无谓的纪元重置。
            guard abs(ms - lastSentMs) >= AMLLClockPolicy.calibrationThresholdMs else { return }
            lastSentMs = ms
            lastSampleMs = ms
            let player = PlayerService.shared
            let running = player.isPlaying && !player.isBuffering
            // 两步都用「无条件落位」的路径：
            // 1. `sync` 会顺手同步播放/暂停状态（页面在切歌瞬间可能还停在旧的暂停态）；
            // 2. `hardCalibrate` 不做「偏差是否超过 600ms」的判断，无论多小都强制落位。
            //    单靠 `sync` 不够：它在偏差小于 600ms 时只改基准值而不调 `setCurrentTime`，
            //    而那正是无损音质下拖动后残留几十到几百毫秒误差的典型区间。
            run("AMLLBridge.sync(\(ms), \(running), 1.0)")
            run("AMLLBridge.hardCalibrate(\(ms))")
        }

        private func run(_ script: String) {
            web?.evaluateJavaScript(script, completionHandler: nil)
        }

        /// 注入CSS设置歌词字重
        private func applyFontWeight(_ weight: Int) {
            let script = """
            (function() {
                var old = document.getElementById('amll-font-weight-override');
                if (old) old.remove();
                var style = document.createElement('style');
                style.id = 'amll-font-weight-override';
                style.textContent = '[class*="lyric"], [class*="line"], [class*="Lyric"], [class*="Line"] { font-weight: \(weight) !important; }';
                document.head.appendChild(style);
            })();
            """
            run(script)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                flushWork?.cancel()
                applyFontWeight(fontWeight)
                flushPending()
            case "fps":
                let fps = (body["fps"] as? NSNumber)?.intValue ?? 0
                print("[AMLL] 歌词页实测帧率: \(fps) fps（屏幕最高 \(UIScreen.main.maximumFramesPerSecond) Hz）")
            case "seek":
                guard let milliseconds = (body["time"] as? NSNumber)?.doubleValue else { return }
                // The page works in lyric time (clock + offset): undo the offset to get the playback position.
                let offset = UserDefaults.standard.double(forKey: "wellmusic.lyricOffset")
                let target = max(0, milliseconds / 1000 - offset)
                PlayerService.shared.seek(to: target)
                // 页面内点歌词行跳转：不走 SwiftUI 的 `currentTime` 变化（那次跳转是异步落地的），
                // 这里直接硬校准，语义与 RN 版 `line-click` → `emitSeek` 完全一致。
                hardCalibrate(to: target)
            default:
                break
            }
        }

        /// The lyric lines in AMLL's `LyricLine` shape, as a JavaScript string literal holding the JSON.
        private static func payload(for lyrics: ParsedLyrics, translation: Bool, romaji: Bool) -> String {
            let lines = lyrics.lines
            var output: [[String: Any]] = []
            for (index, line) in lines.enumerated() {
                let startMs = Int((line.time * 1000).rounded())
                let nextStart = index + 1 < lines.count ? lines[index + 1].time : line.time + 6
                var words: [[String: Any]] = []
                if line.words != nil, let timed = line.words {
                    // words 元组: (char, startTimeMs, endTimeMs)
                    for (position, word) in timed.enumerated() {
                        let wordText = word.0
                        let startMs = word.1
                        let endMs = word.2
                        let following = position + 1 < timed.count ? timed[position + 1].1 : endMs
                        let end = max(startMs + 1, endMs > 0 ? endMs : following)
                        words.append(["startTime": startMs, "endTime": end, "word": wordText])
                    }
                } else {
                    // Line-timed lyrics: one word spanning the line, which AMLL shows as a plain (non-karaoke) line.
                    let end = Int((max(nextStart, line.time + 1) * 1000).rounded())
                    words.append(["startTime": startMs, "endTime": end, "word": line.text.isEmpty ? " " : line.text])
                }
                let endMs = (words.last?["endTime"] as? Int) ?? startMs + 1
                output.append([
                    "words": words,
                    "translatedLyric": translation ? (line.translation ?? "") : "",
                    "romanLyric": romaji ? (line.romaji ?? "") : "",
                    "startTime": startMs,
                    "endTime": max(endMs, startMs + 1),
                    "isBG": false,
                    "isDuet": false,
                ])
            }
            guard let data = try? JSONSerialization.data(withJSONObject: output),
                  let json = String(data: data, encoding: .utf8),
                  let literal = try? JSONEncoder().encode(json),
                  let text = String(data: literal, encoding: .utf8) else { return "\"[]\"" }
            return text
        }
    }
}

/// WKUserContentController retains its handlers; this keeps the coordinator from being kept alive by it.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
#endif
