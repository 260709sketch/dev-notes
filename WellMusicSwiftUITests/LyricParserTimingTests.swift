import XCTest
@testable import WellMusicSwiftUI

/// 歌词解析器的数值正确性锁死测试。
///
/// 这些用例全部来自**实测数据**（2026-10 直接打各平台接口取的样本）：
/// * 网易云 `lrc`：79/79 行三位小数（毫秒）
/// * QQ `lyric`：63/63 行两位小数（百分秒）+ 固定 `[offset:0]` 头
/// * 网易云 `yrc`：字时间戳为绝对毫秒，行头 start == 首字 start，
///   头部有一批 `[0,0](0,0,0) 制作人 : xxx` 行
final class LyricParserTimingTests: XCTestCase {

    // MARK: 小数位缩放

    func testTwoDigitCentisecondsAreHundredths() {
        // QQ「晴天」实测行：[00:02.25] → 2.25 秒（不是 2.025）
        let lines = LyricParser.parseLRC("[00:02.25]词：周杰伦\n[00:04.50]曲：周杰伦")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].time, 2.25, accuracy: 0.0005)
        XCTAssertEqual(lines[1].time, 4.50, accuracy: 0.0005)
    }

    func testThreeDigitMillisecondsStayMilliseconds() {
        // 网易云实测行：[00:22.290] → 22.290 秒
        let lines = LyricParser.parseLRC("[00:22.290]都 是勇敢的")
        XCTAssertEqual(lines[0].time, 22.290, accuracy: 0.0005)
    }

    func testOneDigitIsTenthOfASecond() {
        let lines = LyricParser.parseLRC("[00:12.3]测试")
        XCTAssertEqual(lines[0].time, 12.3, accuracy: 0.0005)
    }

    /// 早先的 bug：两位小数一律按 /1000 处理 → 每行提前最多 0.891 秒。
    /// 这条测试锁住「整首不提前」。
    func testTwoDigitLinesAreNotShiftedEarly() {
        let text = (0..<20).map { i in
            String(format: "[00:%02d.%02d]第%d行", i, (i * 17) % 100, i)
        }.joined(separator: "\n")
        let lines = LyricParser.parseLRC(text)
        for (i, line) in lines.enumerated() {
            let frac = Double((i * 17) % 100) / 100
            let expected = Double(i) + frac
            XCTAssertEqual(line.time, expected, accuracy: 0.0005,
                           "第 \(i) 行被提前了 \(expected - line.time) 秒")
        }
    }

    // MARK: [offset:] 元信息

    func testOffsetTagIsParsedAndApplied() {
        // LRC 约定：正值 = 歌词提前（显示时间 = 时间戳 − offset）
        let result = LyricParser.parseLRCWithMeta("[offset:500]\n[00:10.000]一句\n[00:20.000]两句")
        XCTAssertEqual(result.offsetMs, 500)
        XCTAssertEqual(result.lines[0].time, 9.5, accuracy: 0.0005)
        XCTAssertEqual(result.lines[1].time, 19.5, accuracy: 0.0005)
    }

    func testOffsetZeroIsHarmless() {
        // QQ 固定写 [offset:0]，必须零影响
        let result = LyricParser.parseLRCWithMeta("[ti:晴天]\n[offset:0]\n[00:02.25]词：周杰伦")
        XCTAssertEqual(result.offsetMs, 0)
        XCTAssertEqual(result.lines[0].time, 2.25, accuracy: 0.0005)
    }

    func testNegativeOffsetDelays() {
        let result = LyricParser.parseLRCWithMeta("[offset:-500]\n[00:10.000]一句")
        XCTAssertEqual(result.lines[0].time, 10.5, accuracy: 0.0005)
    }

    func testTranslationMergesWithOffsetApplied() {
        // 歌词行与翻译行都必须平移同样的 offset，字典 key 才能对上
        var lrc = LyricParser.parseLRCWithMeta("[offset:500]\n[00:10.000]hello").lines
        XCTAssertNil(lrc[0].translated)
        LyricParser.mergeTranslation(&lrc, translation: "[offset:500]\n[00:10.000]你好", offsetMs: 500)
        XCTAssertEqual(lrc[0].translated, "你好")
    }

    // MARK: YRC

    func testYRCWordTimestampsAreAbsolute() {
        // 网易云实测行：[22310,4300](22310,180,0)都(22490,340,0) 是(28320,300,0)勇(28620,180,0)敢(28800,170,0)的
        // 行头 start == 首字 start；字时间为绝对毫秒
        let yrc = "[22310,4300](22310,180,0)都(22490,340,0)是(28320,300,0)勇(28620,180,0)敢(28800,170,0)的"
        let lines = LyricParser.parseYRC(yrc)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].start, 22.31, accuracy: 0.0005)
        XCTAssertEqual(lines[0].words.count, 5)
        XCTAssertEqual(lines[0].words[0].start, 22.31, accuracy: 0.0005)
        XCTAssertEqual(lines[0].words[2].start, 28.32, accuracy: 0.0005)
    }

    func testYRCCreditLinesAreFiltered() {
        // 网易云 yrc 头部实测：[0,0](0,0,0) 制作人 : 钱雷 —— 行时长 0、字时长 0
        let yrc = "[0,0](0,0,0) 制作人 : 钱雷\n[0,0](0,0,0) 吉他 : 高飞\n" +
            "[22310,4300](22310,180,0)都(22490,340,0)是"
        let lines = LyricParser.parseYRC(yrc)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].words.map { $0.char }.joined(), "都是")
    }

    // MARK: 端到端：解析结果喂给 AMLL payload 的行时间

    func testParsedLyricsPrefersWordLineTimes() {
        // 有 yrc 时行时间取 yrc 行头（与字同源），翻译按时间就近挂靠
        let lrc = [LrcLine(time: 22.29, text: "都 是勇敢的", translated: "Be brave")]
        let word = [WordLyricLine(
            start: 22.31, end: 26.61,
            words: [WordLyricLine.Word(char: "都", start: 22.31, end: 22.49)]
        )]
        let parsed = ParsedLyrics.from(lrc: lrc, wordLyric: word)
        XCTAssertEqual(parsed.lines.count, 1)
        XCTAssertEqual(parsed.lines[0].time, 22.31, accuracy: 0.0005)
        XCTAssertEqual(parsed.lines[0].translation, "Be brave")
    }

    // MARK: seek 落地监测的常量

    func testSeekLandingTimeoutIsBounded() {
        // 兜底超时必须存在且有限：否则观察者丢失时进度条/歌词会被永久钉死
        XCTAssertGreaterThan(PlayerCore.seekLandingTimeoutSeconds, 0)
        XCTAssertLessThan(PlayerCore.seekLandingTimeoutSeconds, 10)
    }
}
