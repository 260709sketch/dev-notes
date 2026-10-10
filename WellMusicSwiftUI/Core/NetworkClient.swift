import Foundation

/// 统一网络层（替代原 helpers 内各 API 的 fetch/axios 封装）
final class NetworkClient {
    static let shared = NetworkClient()

    private let session: URLSession
    private let commonHeaders: [String: String] = [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
        "Accept": "*/*",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Connection": "keep-alive",
    ]

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    struct Response {
        let data: Data
        let statusCode: Int
        var string: String? { String(data: data, encoding: .utf8) ?? CryptoUtils.gbkString(data) }
    }

    enum NetworkError: LocalizedError {
        case invalidURL
        case badStatus(Int)
        case noData

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "无效的 URL"
            case .badStatus(let code): return "网络请求失败 (\(code))"
            case .noData: return "没有返回数据"
            }
        }
    }

    func get(_ url: String, headers: [String: String] = [:]) async throws -> Response {
        guard let u = URL(string: url) else { throw NetworkError.invalidURL }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        applyHeaders(&req, headers)
        return try await send(req)
    }

    /// 表单 POST（application/x-www-form-urlencoded）
    func postForm(_ url: String, form: [String: String], headers: [String: String] = [:]) async throws -> Response {
        guard let u = URL(string: url) else { throw NetworkError.invalidURL }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = comps.query?.data(using: .utf8)
        applyHeaders(&req, headers)
        return try await send(req)
    }

    /// JSON POST
    func postJSON(_ url: String, body: [String: Any], headers: [String: String] = [:]) async throws -> Response {
        guard let u = URL(string: url) else { throw NetworkError.invalidURL }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        applyHeaders(&req, headers)
        return try await send(req)
    }

    /// 原始 body POST（网易云参数形式）
    func postRaw(_ url: String, body: Data, contentType: String = "application/x-www-form-urlencoded",
                 headers: [String: String] = [:]) async throws -> Response {
        guard let u = URL(string: url) else { throw NetworkError.invalidURL }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        applyHeaders(&req, headers)
        return try await send(req)
    }

    private func applyHeaders(_ req: inout URLRequest, _ extra: [String: String]) {
        commonHeaders.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        extra.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
    }

    private func send(_ req: URLRequest) async throws -> Response {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
        return Response(data: data, statusCode: code)
    }

    // MARK: JSON 解析助手

    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}