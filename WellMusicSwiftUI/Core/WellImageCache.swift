import SwiftUI
import CryptoKit
import ImageIO

// MARK: - 封面地址

/// 封面图地址的统一处理：换 https + 向图床要「够用尺寸」的缩图。
///
/// ⚠️ **这是货架滚动卡顿的根因所在，改动前先量一下**：
/// 网易云封面原图实测是 **1024×1024**，一张解码成位图要 **4 MB**；
/// 发现页四个货架同时铺 48 张卡 ≈ **190 MB 位图**，解码 + 常驻内存直接把滚动拖垮。
/// 而图床支持 `?param=NyN` 让服务端直接返回缩好的图 —— 同一张图带
/// `?param=384y384` 只有 15.9 KB / 0.56 MB（原图 79.6 KB / 4 MB）。
enum WellArtworkURL {

    /// 目标点尺寸 → 需要向图床请求的像素边长。
    ///
    /// 按 3x 屏算（一张 156pt 的卡片要 468px），再向上取到固定的几档 ——
    /// 固定档位是为了**提高缓存命中率**：不同页面只要尺寸落进同一档就复用同一张图。
    static func pixelSize(forPoints points: CGFloat) -> Int {
        let needed = Int((points * 3).rounded(.up))
        for bucket in [128, 192, 256, 384, 512, 640, 1024] where needed <= bucket {
            return bucket
        }
        return 1024
    }

    /// 解析出最终要请求的地址。`pixelSize` 为 nil 时只做 https 替换（原图）。
    static func resolved(_ raw: String?, pixelSize: Int? = nil) -> URL? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        // 网易云图床大量返回 http:// 地址，统一升级到 https
        if text.hasPrefix("http://") {
            text = "https://" + text.dropFirst("http://".count)
        }
        if let pixelSize, text.contains("music.126.net") {
            let param = "param=\(pixelSize)y\(pixelSize)"
            text += text.contains("?") ? "&\(param)" : "?\(param)"
        }
        return URL(string: text)
    }
}

/// 两级（内存 + 磁盘）图片缓存，带请求合并。
///
/// 自有两级图片缓存：解决 `AsyncImage` 在列表滚动、
/// 视图重建时反复发起请求、闪烁占位图，以及 QQ 封面 403 时无缓存兜底的问题。
///
/// - 内存：`NSCache`（线程安全，可直接跨 actor 读取）
/// - 磁盘：Caches/WellArtwork，MD5(url) 作文件名
/// - 请求合并：同一 URL 的并发请求只发一次
actor WellImageCache {
    static let shared = WellImageCache()

    typealias CachedHandler = @MainActor @Sendable (UIImage) -> Void

    /// 解码上限（像素）。超过就按比例缩到这个尺寸再进内存 ——
    /// 兜住那些图床不吃 `?param` 参数、只能拿原图的封面（如 QQ / 酷狗）。
    private static let maxPixelSize = 1280

    private nonisolated(unsafe) let memory = NSCache<NSString, UIImage>()

    /// 磁盘缓存目录（Caches/WellArtwork）。init 里建好后再不变更，
    /// 标 `nonisolated(unsafe)` 是为了让 `syncCachedImage(for:)` 能在
    /// 非 actor 上下文里同步读盘（见该函数的说明）。
    private nonisolated(unsafe) let directory: URL
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

    /// 同步取图（内存 → 磁盘），供视图 init 与 `.task` 首帧预热。
    ///
    /// 解决「进专辑再退出来，货架封面集体闪一下占位图」（用户 2026-10-15）：
    /// 专辑详情页会加载一批大封面，NSCache 在内存压力下把货架封面淘汰掉；
    /// 返回时行视图重建，init 只探内存必然 miss → 先渲染一帧占位图，
    /// 等 actor 跳转 + 磁盘读 + 解码回来才出真图，就是那一下「闪」。
    ///
    /// 这里把磁盘探测挪进同步路径：文件都在本地 Caches，单张
    /// `Data(contentsOf:)` + ImageIO 降采样解码 ≈ 1~2 ms，命中的话
    /// 首帧直接就是真图，没有闪跳；未命中才继续走异步网络链路。
    ///
    /// 线程安全：`memory`（NSCache）本身线程安全；磁盘读是纯本地小文件
    /// 读 + ImageIO 解码，不碰任何 actor 可变状态，可在主线程调用。
    nonisolated func syncCachedImage(for url: URL) -> UIImage? {
        let key = Self.cacheKey(for: url)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        guard let diskImage = Self.loadFromDisk(directory: directory, key: key) else { return nil }
        memory.setObject(diskImage, forKey: key as NSString, cost: Self.cost(of: diskImage))
        return diskImage
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
                  let image = Self.decode(data, maxPixelSize: Self.maxPixelSize) else { return nil }
            // 落盘存的是**原图字节**，内存里放的是缩略图：
            // 以后要按更大尺寸重新出图时还有原始数据可用。
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

    /// 用 ImageIO 按需降采样解码。
    ///
    /// 直接 `UIImage(data:)` 会把整张原图全解码进内存（1024×1024 ≈ 4 MB），
    /// 缩略图解码只产出目标尺寸的位图，耗时与内存都低一个量级。
    private static func decode(_ data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
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
        return decode(data, maxPixelSize: maxPixelSize)
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
/// 关键收益：视图重建（如 iOS 26 底栏 accessory 重刷、货架行回收再显示）时
/// 从「内存 → 同步磁盘」直接拿到已解码图片，不会闪回占位图；列表滚动也不会重复请求。
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
        // 用「内存 → 同步磁盘」预热：行被 LazyVGrid 回收再显示时，内存多半已被
        // NSCache 淘汰，只探内存会先闪一帧占位图（用户 2026-10-15 报「专辑封面闪一下」）。
        // 本地小文件同步读 ≈ 1~2 ms，命中就首帧出真图。
        let seeded = url.flatMap { WellImageCache.shared.syncCachedImage(for: $0) }
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
            // 同步命中（内存 → 磁盘）：init 已探过一次，这里通常直接命中内存、
            // 零 I/O；URL 变化（如复用视图换封面）时同步探盘，命中就不走
            // 异步链路，避免中间闪一帧占位图。
            if let syncHit = WellImageCache.shared.syncCachedImage(for: url) {
                if loadedURL != url { loaded = syncHit; loadedURL = url }
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
