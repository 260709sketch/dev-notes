#if os(iOS)
import SwiftUI
import WebKit
import Combine

/// The original Apple Music-like Lyrics player (https://github.com/amll-dev/applemusic-like-lyrics, AGPL-3.0), running in a
/// web view. The lyric lines and clock samples are pushed in; the page animates with AMLL's own spring layout, blur and
/// word highlight and reports taps on a line back so the song can jump there.
struct AMLLWebLyricsView: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @AppStorage("wellmusic.lyricOffset") private var lyricOffset = 0.0
    /// ★ 第十一轮问题6：歌词对齐（0 居中 / 1 左 / 2 右；播放器调整页分段控制）
    @AppStorage("wellmusic.appleMusic.lyricAlignment") private var lyricAlignment: Int = 0
    /// ★ 低性能歌词模式（关模糊 + 关弹簧；AMLL 官方性能标注）
    @AppStorage("wellmusic.appleMusic.amllLowPerf") private var amllLowPerf = false

    /// 是否使用 Apple Music 独立的 AMLL 设置（和沉浸模式v2分开）
    var useAppleMusicSettings: Bool = false

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
                textAlignment: lyricAlignment,
                lowPerformance: amllLowPerf
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
        .task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            nilGraceElapsed = true
        }
    }

    /// 无歌词宽限期是否已过（3 秒内没好歌词 → 显示「暂无歌词」而不是一直转圈）
    @State private var nilGraceElapsed = false

    @ViewBuilder
    private var stateOverlay: some View {
        if player.lyrics == nil {
            // ★ 2026-10-16 第十轮问题8：无歌词歌曲原来永远转圈 —— 给 3 秒宽限，
            //   过后仍是 nil 就按「暂无歌词」展示（kumone 同款体验）。
            if nilGraceElapsed {
                VStack(spacing: 10) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("暂无歌词")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.65))
                }
            } else {
                ProgressView().controlSize(.small).tint(.white)
            }
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
    /// ★ 第十一轮问题6：歌词对齐（0 居中 / 1 左 / 2 右；设置里的分段控制）
    var textAlignment: Int = 0
    /// ★ 低性能歌词模式（隐藏模糊/弹簧动画；桥：AMLLBridge.setBlur/setSpring）
    var lowPerformance: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // ★ 问题6：注入对齐 CSS（变量由 updateUIView 实时改；页面重绘的行也跟随）
        // ★★ 2026-10-16 根因修复（用户实测「选居左仍居中」）：此前初始值写死
        //   center，真实值靠 applyAlignment 一次性下发；而 updateUIView 会**先于
        //   页面加载**执行（打在空白页上），之后一次性门控拦住重发 → 永远居中。
        //   现在把**当前设置值直接拼进 documentStart 脚本**，首载即正确；
        //   后续变化再由 applyAlignment 补发（已去门控）+ ready 后强制重发。
        let initialAlignCSS: String
        let initialJustifyCSS: String
        let initialDotsCSS: String
        switch textAlignment {
        case 1:
            initialAlignCSS = "left"
            initialJustifyCSS = "flex-start"
            initialDotsCSS = "--wellDotsLeft:0;--wellDotsRight:auto;--wellDotsML:0;--wellDotsMR:0"
        case 2:
            initialAlignCSS = "right"
            initialJustifyCSS = "flex-end"
            initialDotsCSS = "--wellDotsLeft:auto;--wellDotsRight:0;--wellDotsML:0;--wellDotsMR:0"
        default:
            initialAlignCSS = "center"
            initialJustifyCSS = "center"
            initialDotsCSS = "--wellDotsLeft:0;--wellDotsRight:0;--wellDotsML:auto;--wellDotsMR:auto"
        }
        let alignScript = """
        (function(){
          var st = document.createElement('style');
          st.textContent = ':root{--wellLyricAlign:\(initialAlignCSS);--wellJustify:\(initialJustifyCSS);\(initialDotsCSS)}'
            + '[class*="lyricMainLine"],[class*="lyricSubLine"],[class*="lyricTranslationLine"]'
            + '{text-align:var(--wellLyricAlign)!important;justify-content:var(--wellJustify)!important}'
            // ★ 间奏点：官方组件由 JS 每次布局写**内联 style** 定位 —— 只有带
            //   !important 的样式表能压过它。位置由 CSS 变量驱动，随对齐设置变化。
            + '.interludeDots{left:var(--wellDotsLeft)!important;right:var(--wellDotsRight)!important;'
            + 'margin-left:var(--wellDotsML)!important;margin-right:var(--wellDotsMR)!important}';
          document.documentElement.appendChild(st);
        })();
        """
        configuration.userContentController.addUserScript(
            WKUserScript(source: alignScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
                                   fontSize: fontSize, fontWeight: fontWeight)
        // ★ 问题6：对齐实时生效（值不变时不重复下 JS）
        context.coordinator.applyAlignment(textAlignment, web: web)
        // ★ 低性能模式（值不变不重复下发）
        context.coordinator.applyLowPerformance(lowPerformance, web: web)
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
        /// 上次下发的歌词对齐（-1 = 未下发过；现已去门控，仅作记录）
        private var lastAlignment: Int = -1
        /// 目标对齐值（ready 后强制补发用）
        private var lastAlignmentValue = 0
        /// 上次下发的低性能模式（nil = 未下发过）
        private var lastLowPerf: Bool? = nil
        /// 目标低性能值（ready 后补发用）
        private var lastLowPerfValue = false

        /// ★ 低性能歌词模式：桥内建 setBlur / setSpring（官方性能标注：
        ///   blur 开销「较高」；关 spring 对低配机器友好、回退 CSS 过渡）。
        func applyLowPerformance(_ lowPerf: Bool, web: WKWebView) {
            lastLowPerfValue = lowPerf
            guard lastLowPerf != lowPerf else { return }
            lastLowPerf = lowPerf
            let blur = lowPerf ? "false" : "true"
            let spring = lowPerf ? "false" : "true"
            web.evaluateJavaScript("""
            try {
              if (window.AMLLBridge && window.AMLLBridge.setBlur) window.AMLLBridge.setBlur(\(blur));
              if (window.AMLLBridge && window.AMLLBridge.setSpring) window.AMLLBridge.setSpring(\(spring));
            } catch (e) {}
            """, completionHandler: nil)
        }

        /// ★ 问题6/间奏点（2026-10-16 三定案，参照 AMLL 官方组件机制）：
        /// 官方组件每次布局都用 JS **内联 style** 定位间奏点 —— 任何「给它写内联
        /// 样式」的改法都会在下一帧被官方 JS 覆盖（此前两次失败的原因）。
        /// 唯一稳的做法：把定位抽成 **CSS 变量**，由带 `!important` 的样式表消费
        /// （样式表 !important 压过页面的内联写入）。只设置变量，不碰元素本体。
        func applyAlignment(_ alignment: Int, web: WKWebView) {
            // ★ 根因修复：**不再门控**。此前一次性下发 + 页面未加载时打在空白页上
            //   = 设置永远不生效。每次下发幂等，代价一次 JS 调用。
            lastAlignment = alignment
            lastAlignmentValue = alignment
            let css: String
            let justify: String
            switch alignment {
            case 1: css = "left"; justify = "flex-start"
            case 2: css = "right"; justify = "flex-end"
            default: css = "center"; justify = "center"
            }
            // 间奏点四变量：居中=左右都 0 + 双 auto 外边距；右=靠右；左=靠左
            let dotsLeft: String
            let dotsRight: String
            let dotsML: String
            let dotsMR: String
            switch alignment {
            case 1:
                dotsLeft = "0"; dotsRight = "auto"; dotsML = "0"; dotsMR = "0"
            case 2:
                dotsLeft = "auto"; dotsRight = "0"; dotsML = "0"; dotsMR = "0"
            default:
                dotsLeft = "0"; dotsRight = "0"; dotsML = "auto"; dotsMR = "auto"
            }
            let js = """
            (function(){
              var r = document.documentElement.style;
              r.setProperty('--wellLyricAlign','\(css)');
              r.setProperty('--wellJustify','\(justify)');
              r.setProperty('--wellDotsLeft','\(dotsLeft)');
              r.setProperty('--wellDotsRight','\(dotsRight)');
              r.setProperty('--wellDotsML','\(dotsML)');
              r.setProperty('--wellDotsMR','\(dotsMR)');
            })();
            """
            web.evaluateJavaScript(js, completionHandler: nil)
        }
        private var timer: Timer?
        /// 订阅 `PlayerCore.isScrubbing`，用于拖动收尾的精确重锚。
        private var scrubObserver: AnyCancellable?
        /// 订阅 `PlayerCore.scrubTime`，拖动中逐次跟手推送。
        private var scrubTimeObserver: AnyCancellable?
        /// 拖动的收尾重锚：`isScrubbing` 转 false 的那次回调可能发生在 seek
        /// 真正落地**之前**，所以让出一个 runloop 再读位置。
        private var settleWork: DispatchWorkItem?

        func attach(_ web: WKWebView) {
            self.web = web
            // 常态采样：页面会在两次采样之间做线性外推，所以 10Hz 就足够精确，
            // 不必每次都用跨进程的 `evaluateJavaScript` 去骚扰页面。
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pushClock() }
            }

            // ★ 拖动中：手指每移动一次就立刻推一次（频率 = 手指事件频率，约 60Hz）。
            //
            // 这是「拖进度条时歌词不跟手」的关键补丁。常态播放下 10Hz 完全看不出问题，
            // 因为页面能自己线性外推；但**手指的移动没有规律可外推** —— 仍按 10Hz 推，
            // 歌词就会一跳一跳、明显落后手指。
            // 原版（Sollin/Flutter AppleMusic2 的 `_uiTicker`、RN 版的 rAF 循环）就是
            // **每帧直读播放器真实位置**，这才是它拖动时严丝合缝的原因。
            //
            // 这里不引入逐帧定时器，而是订阅 `scrubTime`：频率天然等于手指事件频率，
            // 空闲时零开销，也不会像 rAF 那样在 120Hz 屏上白跑一倍。
            scrubTimeObserver = PlayerCore.shared.$scrubTime
                .removeDuplicates()
                .sink { [weak self] newValue in
                    MainActor.assumeIsolated {
                        guard let self, PlayerCore.shared.isScrubbing else { return }
                        self.pushClock(secondsOverride: newValue)
                    }
                }

            // 拖动收尾：用**同步即时**的精确位置重锚一次页面时钟。
            // 详见 `syncPrecisePosition()` 的说明。
            scrubObserver = PlayerCore.shared.$isScrubbing
                .removeDuplicates()
                .sink { [weak self] isScrubbing in
                    guard !isScrubbing else { return }
                    guard let self else { return }
                    self.settleWork?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        MainActor.assumeIsolated { self?.syncPrecisePosition() }
                    }
                    self.settleWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
                }

            // ★ seek 落地（音频真的从新位置开始渲染，由周期观察者判定）：
            // 用落地那一刻的**渲染时间**硬锚一次。这是「拖完进度条歌词永久脱节」
            // 修复的另一半 —— 落地时的渲染时间是 AVPlayer 报告的音频真实位置。
            landingObserver = NotificationCenter.default.addObserver(
                forName: PlayerCore.seekDidLandNotification, object: nil, queue: .main
            ) { [weak self] note in
                let renderTime = (note.userInfo?["time"] as? NSNumber)?.doubleValue
                MainActor.assumeIsolated { self?.syncPrecisePosition(renderTime: renderTime) }
            }
        }

        func detach() {
            timer?.invalidate()
            timer = nil
            scrubObserver?.cancel()
            scrubObserver = nil
            scrubTimeObserver?.cancel()
            scrubTimeObserver = nil
            settleWork?.cancel()
            settleWork = nil
            if let landingObserver {
                NotificationCenter.default.removeObserver(landingObserver)
            }
            landingObserver = nil
            web?.configuration.userContentController.removeScriptMessageHandler(forName: "amll")
        }

        func update(lyrics: ParsedLyrics, showsTranslation: Bool, showsRomaji: Bool, fontSize: CGFloat, fontWeight: Int) {
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

        /// 歌词时钟相对**播放器位置**的净偏移（秒）= 用户微调 − 输出延迟。
        ///
        /// 为什么要减输出延迟：播放器报告的 `position` 是「已经喂给输出」的位置，
        /// 而你**听到**的声音还要过一遍输出缓冲 —— 内建扬声器 / 有线 10–30ms（可忽略），
        /// **蓝牙 A2DP 常见 150–250ms，AirPlay 可达 1–2 秒**。歌词跟着晚一点才和耳朵对上。
        /// 这是硬件/系统缓冲，**换任何播放内核都一样**；iOS 用
        /// `AVAudioSession.outputLatency` 把实测值给了我们，所以不必让用户手动猜。
        private var lyricTimeShift: TimeInterval {
            // 生效偏移（调整过的歌用专属值，否则全局）+ 输出延迟补偿
            PlayerService.shared.effectiveLyricOffset
                - PlayerService.shared.liveLatency
        }

        private func currentSeconds() -> TimeInterval {
            return PlayerService.shared.livePlaybackTime + lyricTimeShift
        }

        private var lastSampleMs = 0
        /// 最近一次「位置确实在推进」的时刻（秒，`timeIntervalSinceReferenceDate`）。
        /// 用于以滑动窗口判定是否在走，见 `pushClock()`。
        private var lastMovementAt: TimeInterval = 0
        /// seek 落地通知的订阅（见 `PlayerCore.beginSeekLandingMonitor`）
        private var landingObserver: NSObjectProtocol?

        /// 把当前播放位置推给歌词页。
        ///
        /// ## 关于 `running`（页面时钟的播放/暂停）
        ///
        /// 页面收到 `running = false` 会**暂停自己的时钟**（`Nt.pause()`），
        /// 此时歌词只能靠下一次推送硬跳。所以这个标志一旦被误判成 false，
        /// 听感就是「歌词比歌声慢一点、而且发顿」。
        ///
        /// ⚠️ 早先的实现用**相邻两次采样**判断是否在走（`abs(ms - last) >= 30`）。
        /// 但时间源在无损 / Hi-Res 文件上本身就有抖动，单次采样不前进很常见，
        /// 于是一秒钟里会被误判好几次。现在改成**滑动窗口**：
        /// 只要最近 0.5 秒内位置推进过，就认为在走。真正的缓冲卡顿
        /// （位置连续 0.5 秒纹丝不动）依然会被正确识别。
        ///
        /// ## `isRenderingAudio`（拖动后脱节的关键闸门）
        ///
        /// `AVPlayer.timeControlStatus == .playing` 是「音频此刻真的在渲染」的
        /// 权威信号；`.waitingToPlayAtSpecifiedRate`（seek 后重新拉流 / 卡顿）期间
        /// **耳朵听不到任何声音在走**，此时页面时钟必须冻结 —— 否则它会从
        /// 「seek 目标」继续外推，把缓冲空窗的时长全部变成歌词的提前量。
        private func pushClock(secondsOverride: TimeInterval? = nil) {
            guard ready else { return }
            let scrubbing = PlayerCore.shared.isScrubbing

            let seconds: TimeInterval
            if let secondsOverride {
                seconds = max(0, secondsOverride) + lyricTimeShift
            } else {
                seconds = currentSeconds()
            }
            let ms = Int(seconds * 1000)

            let now = Date().timeIntervalSinceReferenceDate
            if lastMovementAt == 0 { lastMovementAt = now }
            if abs(ms - lastSampleMs) >= 30 {
                lastMovementAt = now
            }
            lastSampleMs = ms

            let moving = (now - lastMovementAt) < 0.5
            // ⚠️ 拖动中一律 `running = false`：这时位置由**手指**决定，页面必须停在推给它的
            // 那个值上。若还说「在播放」，页面会从该值继续向前外推 —— 歌词就跑到手指前面去了
            // （表现是「拖着歌词，歌词自己往前溜」）。
            //
            // seek 缓冲空窗期同理：`isRenderingAudio`（timeControlStatus != .playing）本身
            // 就已经是「音频没在渲染」的权威信号，缓冲空窗它必然为 false → running=false，
            // 页面时钟冻结。**不再额外叠加 `!isAwaitingSeekLanding`**：那个标志是落地
            // 监测的内部状态，和「音频在不在渲染」不同步，叠加只会造成落地信号发出后、
            // isRenderingAudio 尚未翻转的瞬间多冻结一拍，引入新的滞后。
            let running = !scrubbing && PlayerCore.shared.isRenderingAudio && moving
            run("AMLLBridge.sync(\(ms), \(running), 1.0)")
        }

        /// 拖动收尾时用**同步即时**的播放位置重锚页面时钟。
        ///
        /// ## 为什么需要这一步（「无损音质以上拖动进度条后歌词慢半拍」的根因）
        ///
        /// 页面时钟是「采样点 + 线性外推」：
        ///
        /// ```js
        /// sync(ms, running, rate) { co = ms; _l = now; }      // 记下基准点
        /// 当前位置 = playing ? co + (now - _l) * rate : co    // 基准点之间自己外推
        /// ```
        ///
        /// 也就是说，**给它一个滞后的基准，它就会带着这个滞后一路走下去**，不会被
        /// 后续采样自动纠正。而常态采样的时间源 `livePlaybackTime` 走的是
        /// `PlayerCore.currentTime` —— 那个值由 `addPeriodicTimeObserver` 的周期回调
        /// 维护，**无损 / Hi-Res 大文件上回调间隔被明显拉长**，松手瞬间它可能还停在
        /// 上百毫秒之前。页面拿到这个滞后值当新基准，于是「歌词和歌声错开」。
        ///
        /// 修法与 RN 版 `emitSeek` 一致：拖动结束的那一刻，改用
        /// `PlayerService.precisePlaybackTime` —— 它直接读 `AVPlayer.currentTime()`，
        /// **同步、即时、不经过轮询缓存**。页面的 `sync` 会无条件把 `co` 置为该值并
        /// 重置纪元 `_l`，等价于一次硬校准，误差当场清零。
        ///
        /// 为什么不在拖动**过程中**下发：高频注入会不断重置外推纪元、挤掉最终那次
        /// 校准，反而导致松手后彻底脱节（RN 源码里明确记录过这个坑）。
        private func syncPrecisePosition(renderTime: TimeInterval? = nil) {
            guard ready else { return }
            // 优先用落地通知带来的**渲染时间**（观察者报告的音频真实位置）；
            // 其余时刻读同步即时的播放位置。
            let precise = renderTime ?? PlayerService.shared.precisePlaybackTime
            guard precise.isFinite, precise >= 0 else { return }
            let ms = Int(((precise + lyricTimeShift) * 1000).rounded())
            lastSampleMs = ms
            lastMovementAt = Date().timeIntervalSinceReferenceDate
            // 落地信号来的时候音频确实在渲染；以权威信号为准，不再叠加落地标志。
            let running = PlayerCore.shared.isRenderingAudio
            run("AMLLBridge.sync(\(ms), \(running), 1.0)")
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
                // 页面就绪后补发一次低性能模式（首帧时桥可能尚未定义）
                if let w = web {
                    lastLowPerf = nil
                    applyLowPerformance(lastLowPerfValue, web: w)
                    // ★ 根因修复：页面就绪后强制补发对齐（首载 docStart 已带正确初值，
                    //   这里再兜一层，覆盖页面重载/设置中途变更的一切时序）
                    lastAlignment = -1
                    applyAlignment(lastAlignmentValue, web: w)
                }
                flushPending()
            case "fps":
                let fps = (body["fps"] as? NSNumber)?.intValue ?? 0
                print("[AMLL] 歌词页实测帧率: \(fps) fps（屏幕最高 \(UIScreen.main.maximumFramesPerSecond) Hz）")
            case "clock":
                // 歌词页回报自己的时钟（4Hz）：与播放器位置做端到端对照，
                // 见 `LyricSyncProbe` 的说明 —— 这是「要不要换内核」的判据。
                guard let page = (body["page"] as? NSNumber)?.doubleValue,
                      let anchor = (body["anchor"] as? NSNumber)?.doubleValue else { return }
                let running = (body["running"] as? NSNumber)?.intValue == 1
                LyricSyncProbe.shared.ingest(
                    pageMs: page, anchorMs: anchor, pageRunning: running,
                    lyricShift: lyricTimeShift
                )
            case "seek":
                guard let milliseconds = (body["time"] as? NSNumber)?.doubleValue else { return }
                // 页面给的是**歌词时间**（= 播放位置 + 净偏移）：反向减掉得到一个播放位置。
                PlayerService.shared.seek(to: max(0, milliseconds / 1000 - lyricTimeShift))
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
