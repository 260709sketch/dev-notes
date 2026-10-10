import SwiftUI

/// 音源状态页：当前激活音源、请求统计与最近取链日志。
struct WellLXSourceStatusView: View {
    @ObservedObject private var store = WellLXSourceStore.shared

    var body: some View {
        List {
            activeSourceSection
            statisticsSection
            requestLogSection
        }
        .navigationTitle("音源状态")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: 当前音源

    private var activeSourceSection: some View {
        Section {
            if let active = store.activeSource {
                LabeledContent("音源名称", value: active.name)
                LabeledContent("版本", value: active.version)
                LabeledContent("作者", value: active.author)
                if !active.sourceDescription.isEmpty {
                    LabeledContent("描述", value: active.sourceDescription)
                }
            } else {
                Text("未激活任何音源")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("当前音源")
        }
    }

    // MARK: 请求统计

    private var statisticsSection: some View {
        Section {
            let total = store.requestLogs.count
            let success = store.requestLogs.filter { $0.success }.count
            LabeledContent("总请求数", value: "\(total)")
            LabeledContent("成功", value: "\(success)")
            LabeledContent("失败", value: "\(total - success)")
            if let average = averageDuration {
                LabeledContent("平均耗时", value: average)
            }
        } header: {
            Text("请求统计")
        }
    }

    private var averageDuration: String? {
        guard !store.requestLogs.isEmpty else { return nil }
        let average = store.requestLogs.reduce(0.0) { $0 + $1.duration } / Double(store.requestLogs.count)
        return String(format: "%.1fs", average)
    }

    // MARK: 最近请求

    private var requestLogSection: some View {
        Section {
            if store.requestLogs.isEmpty {
                Text("暂无请求记录，播放一首歌曲后自动记录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.requestLogs) { log in
                    WellLXRequestLogRow(log: log)
                }
            }
        } header: {
            HStack {
                Text("最近请求")
                Spacer()
                if !store.requestLogs.isEmpty {
                    Button(role: .destructive) {
                        store.clearLogs()
                    } label: {
                        Text("清空").font(.caption)
                    }
                }
            }
        }
    }
}

// MARK: - 日志行

private struct WellLXRequestLogRow: View {
    let log: WellLXRequestLog

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: log.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(log.success ? .green : .red)
                Text(log.trackTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(log.durationText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !log.trackArtist.isEmpty {
                Text(log.trackArtist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                Label(log.actualQuality, systemImage: "hifispeaker.fill")
                Label(log.fileSizeText, systemImage: "doc.fill")
                Label(log.requestedQuality, systemImage: "arrow.down.circle")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if log.success {
                Text(log.url)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let message = log.message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(log.success ? .secondary : .red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack { WellLXSourceStatusView() }
}