import SwiftUI

// MARK: - 骨架屏（扒自 kumone：加载不转圈，用「结构镜像 + 流光」）

/// 灰色圆角块 + 从左到右扫过的高光渐变带（30fps 相位驱动）。
/// ★ 2026-10-16 用户问题18：把「每次打开转圈」换成 kumone 同款刷新动画。
struct WellSkeletonView: View {
    var cornerRadius: CGFloat = 10

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.5) / 1.5
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.5))
                .overlay(
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, .primary.opacity(0.08), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: (geo.size.width * 1.6) * phase - geo.size.width * 0.6)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

/// 货架级骨架：标题条 + 一行卡片块（与真实货架同构，加载完成不跳版）。
struct WellSkeletonShelf: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WellSkeletonView(cornerRadius: 6)
                .frame(width: 120, height: 18)
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 7) {
                        WellSkeletonView(cornerRadius: 10)
                            .frame(width: 156, height: 156)
                        WellSkeletonView(cornerRadius: 4)
                            .frame(width: 120, height: 13)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

/// 歌单/歌手详情页头部骨架（封面块 + 两行文本条）。
struct WellSkeletonHeader: View {
    var coverSide: CGFloat = 120

    var body: some View {
        HStack(spacing: 16) {
            WellSkeletonView(cornerRadius: 12)
                .frame(width: coverSide, height: coverSide)
            VStack(alignment: .leading, spacing: 10) {
                WellSkeletonView(cornerRadius: 5)
                    .frame(height: 20)
                WellSkeletonView(cornerRadius: 5)
                    .frame(height: 14)
                WellSkeletonView(cornerRadius: 5)
                    .frame(width: 140, height: 14)
            }
        }
        .padding(.horizontal, 16)
    }
}
