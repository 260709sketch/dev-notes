import Foundation
import CoreML

/// 节拍分析服务（★ 2026-10-16 第一期：从 MeloX AutoMix 管线移植，先做分析+展示）。
///
/// 管线：音频（远端先落盘）→ AVFoundation 解码 → vDSP 特征（BeatNetFeatureExtractor，
/// 32s 窗 × 272 维）→ CoreML BeatNetBDA 模型 → 逐段合并成整轨
/// `AutoMixTrackAnalysis`（BPM / 置信度 / 节拍表 / 下拍表 / 频段能量）。
/// 后续期数会把它接到双 deck 智能过渡上（AutoMix）。
@MainActor
final class WellBeatAnalysisService: ObservableObject {
    static let shared = WellBeatAnalysisService()

    enum Phase: Equatable {
        case idle
        case analyzing
        case done(bpm: Double, confidence: Double, beatCount: Int, downbeatCount: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// 最近一次成功的分析（一期仅展示；二期用于智能过渡）
    private(set) var lastAnalysis: AutoMixTrackAnalysis?

    private let analyzer = AutoMixAudioAnalyzer()
    private var task: Task<Void, Never>?

    func analyze(songID: Int, url: URL, duration: TimeInterval) {
        task?.cancel()
        phase = .analyzing
        let request = AutoMixAnalysisRequest(
            songID: songID,
            source: PlaybackSource(url: url),
            duration: duration,
            isDownloaded: url.isFileURL
        )
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let analysis = try await self.analyzer.analyzeFullTrack(request)
                guard !Task.isCancelled else { return }
                self.lastAnalysis = analysis
                self.phase = .done(
                    bpm: analysis.bpm,
                    confidence: analysis.confidence,
                    beatCount: analysis.beats.count,
                    downbeatCount: analysis.downbeats.count
                )
            } catch is CancellationError {
                // 用户取消/切歌：保持状态不变
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }
}
