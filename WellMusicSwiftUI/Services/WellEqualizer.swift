import Foundation

/// 均衡器预置（10 段增益表，单位 dB，±12）。
/// 频段与增益数据与预置表来自通用音频标准（31Hz~16kHz 倍频程）。
enum EQPreset: String, CaseIterable, Identifiable {
    case flat, bass, vocal, pop, rock, classical, jazz, electronic
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flat: return "默认"
        case .bass: return "低音增强"
        case .vocal: return "人声"
        case .pop: return "流行"
        case .rock: return "摇滚"
        case .classical: return "古典"
        case .jazz: return "爵士"
        case .electronic: return "电子"
        }
    }

    /// 10 段增益（dB），顺序对应 `WellEqualizer.bandFrequencies`。
    var gains: [Double] {
        switch self {
        case .flat: return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass: return [6, 5, 3, 1, 0, 0, -1, -1, 0, 0]
        case .vocal: return [-2, -1, 0, 2, 4, 4, 3, 2, 0, -1]
        case .pop: return [2, 2, 1, 0, 2, 3, 2, 1, 2, 2]
        case .rock: return [5, 4, 2, -1, -2, 1, 3, 4, 5, 4]
        case .classical: return [3, 2, 1, 0, 0, 1, 2, 3, 4, 4]
        case .jazz: return [3, 2, 1, 2, -1, -1, 0, 2, 3, 3]
        case .electronic: return [5, 4, 1, -2, -1, 2, 4, 3, 5, 4]
        }
    }
}

/// 自定义均衡器预设（可命名保存 / 删除）。
struct EQCustomPreset: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var gains: [Double]
}

/// 均衡器状态（单例）。
///
/// 实现走 **MPV 音频滤镜链**（`af add lavfi=equalifier=...`，10 段）：
/// 播放内核是 MPV，不能像 AVFoundation 那样挂 AVAudioUnitEQ，但 mpv 的 lavfi
/// 滤镜提供等价的倍频程均衡器，且对正在播放的曲目实时生效。
@MainActor
final class WellEqualizer: ObservableObject {
    static let shared = WellEqualizer()

    /// 10 段频点（Hz）。
    static let bandFrequencies: [Double] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    /// 单段增益上限（dB）。
    static let maximumGain: Double = 12

    @Published private(set) var isEnabled: Bool
    @Published private(set) var bandGains: [Double]
    @Published private(set) var selectedPreset: EQPreset
    @Published private(set) var customPresets: [EQCustomPreset]

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: "wellmusic.eq.enabled")
        let stored = defaults.array(forKey: "wellmusic.eq.bandGains") as? [Double] ?? []
        bandGains = Self.normalize(stored)
        let presetRaw = defaults.string(forKey: "wellmusic.eq.preset") ?? EQPreset.flat.rawValue
        selectedPreset = EQPreset(rawValue: presetRaw) ?? .flat
        if let data = defaults.data(forKey: "wellmusic.eq.customPresets"),
           let decoded = try? JSONDecoder().decode([EQCustomPreset].self, from: data) {
            customPresets = decoded.map { p in
                EQCustomPreset(id: p.id, name: p.name, gains: Self.normalize(p.gains))
            }
        } else {
            customPresets = []
        }
    }

    /// 归一化到 10 段 / ±12dB。
    static func normalize(_ gains: [Double]) -> [Double] {
        var out = Array(repeating: 0.0, count: bandFrequencies.count)
        for i in 0..<out.count where i < gains.count {
            out[i] = min(max(gains[i], -maximumGain), maximumGain)
        }
        return out
    }

    // MARK: 操作

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "wellmusic.eq.enabled")
        applyToEngine()
    }

    func applyPreset(_ preset: EQPreset) {
        selectedPreset = preset
        bandGains = preset.gains
        UserDefaults.standard.set(preset.rawValue, forKey: "wellmusic.eq.preset")
        UserDefaults.standard.set(bandGains, forKey: "wellmusic.eq.bandGains")
        applyToEngine()
    }

    func setBandGain(at index: Int, to gain: Double) {
        guard bandGains.indices.contains(index) else { return }
        let value = min(max(gain, -Self.maximumGain), Self.maximumGain)
        guard bandGains[index] != value else { return }
        bandGains[index] = value
        selectedPreset = .flat   // 手动调过即视为自定义（增益表以 bandGains 为准）
        UserDefaults.standard.set(bandGains, forKey: "wellmusic.eq.bandGains")
        applyToEngine()
    }

    func saveCustomPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = EQCustomPreset(name: trimmed, gains: bandGains)
        customPresets.removeAll { $0.name == trimmed }
        customPresets.insert(preset, at: 0)
        persistCustomPresets()
    }

    func applyCustomPreset(_ preset: EQCustomPreset) {
        bandGains = Self.normalize(preset.gains)
        UserDefaults.standard.set(bandGains, forKey: "wellmusic.eq.bandGains")
        applyToEngine()
    }

    func deleteCustomPreset(_ preset: EQCustomPreset) {
        customPresets.removeAll { $0.id == preset.id }
        persistCustomPresets()
    }

    private func persistCustomPresets() {
        if let data = try? JSONEncoder().encode(customPresets) {
            UserDefaults.standard.set(data, forKey: "wellmusic.eq.customPresets")
        }
    }

    // MARK: 下发播放内核

    private func applyToEngine() {
        PlayerCore.shared.applyEqualizer(enabled: isEnabled, gains: bandGains)
    }
}
