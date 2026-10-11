import SwiftUI
import CryptoKit

/// 两级（内存 + 磁盘）图片缓存，带请求合并。
///
/// 参考 missuo/kumone 的 `ImageCache.swift`：解决 `AsyncImage` 在列表滚动、
/// 视图重建时反复发起请求、闪烁占位图，以及 QQ 封面 403 时无缓存兜底的问题。
///
/// - 内存：`NSCache`（线程安全，可直接跨 actor 读取）
/// - 磁盘：Caches/WellArtwork，MD5(url) 作文件名
/// - 请求合并：同一 URL 的并发请求只发一次
actor WellImageCache {
    static let shared = WellImageCache()

    typealias CachedHandler = @MainActor @Sendable (UIImage) -> Void

    private nonisolated(unsafe) let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    private let session: URLSession
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        memory.countLimit = 300
        memory.totalCostLimit = 64 * 1024 * 1024

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("WellArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }

    /// 同步内存命中（无 actor 跳转，供视图初始化时预热）。
    nonisolated func cachedImage(for url: URL) -> UIImage? {
        memory.object(forKey: Self.cacheKey(for: url) as NSString)
    }

    /// 取图：内存 → 磁盘 → 网络。`onCachedImage` 用于先回显磁盘预览。
    func image(for url: URL, onCachedImage: CachedHandler? = nil) async -> UIImage? {
        let key = Self.cacheKey(for: url)
        if let cached = memory.object(forKey: key as NSString) { return cached }

        // 磁盘命中：先回显，避免网络等待期间空窗
        let diskImage = Self.loadFromDisk(directory: directory, key: key)
        if let diskImage {
            memory.setObject(diskImage, forKey: key as NSString,
                             cost: Self.cost(of: diskImage))
            if let onCachedImage { await onCachedImage(diskImage) }
            return diskImage
        }

        if let existing = inflight[key] { return await existing.value }

        let task = Task<UIImage?, Never> { [directory, session] in
            // 带防盗链头的请求：QQ / 酷狗图床对裸请求会 403
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                             forHTTPHeaderField: "User-Agent")
            if let referer = Self.referer(for: url) {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let image = UIImage(data: data) else { return nil }
            try? data.write(to: directory.appendingPathComponent(key), options: .atomic)
            return image
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil

        if let result {
            memory.setObject(result, forKey: key as NSString, cost: Self.cost(of: result))
        }
        return result
    }

    /// 按域名推导图片防盗链 Referer。
    private static func referer(for url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        if host.contains("gtimg") || host.contains("qq.com") || host.contains("qpic") {
            return "https://y.qq.com/"
        }
        if host.contains("kugou") { return "https://www.kugou.com/" }
        if host.contains("163") || host.contains("126") || host.contains("netease") {
            return "https://music.163.com/"
        }
        if host.contains("kuwo") { return "https://www.kuwo.cn/" }
        return nil
    }

    private static func loadFromDisk(directory: URL, key: String) -> UIImage? {
        let fileURL = directory.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }

    private static func cacheKey(for url: URL) -> String {
        let digest = Insecure.MD5.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 清空磁盘缓存（设置页「清除图片缓存」用）。
    func clear() {
        memory.removeAllObjects()
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// 当前磁盘占用字节数。
    func diskUsage() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(Int64(0)) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

/// `AsyncImage` 的替代：由 `WellImageCache` 驱动，带交叉淡入。
///
/// 关键收益：视图重建（如 iOS 26 底栏 accessory 重刷）时直接从内存拿已解码图片，
/// 不会闪回占位图；列表滚动也不会重复请求。
struct WellAsyncImage<Placeholder: View>: View {
    let url: URL?
    var animated: Bool
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var loaded: UIImage?
    @State private var loadedURL: URL?

    init(url: URL?, animated: Bool = true, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.animated = animated
        self.placeholder = placeholder
        // 用内存缓存预热，避免首帧空白
        let seeded = url.flatMap { WellImageCache.shared.cachedImage(for: $0) }
        _loaded = State(initialValue: seeded)
        _loadedURL = State(initialValue: seeded == nil ? nil : url)
    }

    var body: some View {
        ZStack {
            placeholder()
            if let image = loaded, loadedURL == url {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(animated ? .opacity.animation(.easeIn(duration: 0.22)) : .identity)
            }
        }
        .task(id: url) {
            guard let url else {
                loaded = nil
                loadedURL = nil
                return
            }
            // 同步内存命中
            if let memoryHit = WellImageCache.shared.cachedImage(for: url) {
                if loadedURL != url { loaded = memoryHit; loadedURL = url }
                return
            }
            if loadedURL != url { loaded = nil; loadedURL = url }
            let cached = await WellImageCache.shared.image(for: url) { preview in
                guard !Task.isCancelled else { return }
                loaded = preview
                loadedURL = url
            }
            guard !Task.isCancelled, let cached else { return }
            loaded = cached
            loadedURL = url
        }
    }
}

extension WellAsyncImage where Placeholder == AnyView {
    /// 默认占位：中性填充 + 音符图标。
    init(url: URL?, animated: Bool = true, cornerRadius: CGFloat = 0) {
        self.init(url: url, animated: animated) {
            AnyView(
                ZStack {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                    Image(systemName: "music.note")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            )
        }
    }
}
