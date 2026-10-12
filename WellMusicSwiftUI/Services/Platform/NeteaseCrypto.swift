import Foundation

/// 网易云 weapi 加密（替代原 neteaseCrypto.js）
enum NeteaseCrypto {

    static let pubKey = "010001"
    static let modulus = "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7"
    static let nonce = "0CoJUm6Qyw8W8jud"

    /// 生成 weapi 请求体（form 编码：params=...&encSecKey=...）
    static func makeBody(_ params: [String: Any]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
        let secKey = CryptoUtils.randomString(length: 16)
        // 与原版 JS aesEncrypt 对齐：第一层输出 base64 字符串，第二层再对该字符串加密
        guard let enc1 = CryptoUtils.aesEncryptNetease(String(data: json, encoding: .utf8) ?? "{}", key: nonce),
              let enc2 = CryptoUtils.aesEncryptCBC(Data(enc1.base64EncodedString().utf8),
                                                   key: Data(secKey.utf8),
                                                   iv: Data("0102030405060708".utf8)) else {
            return ""
        }
        let params = enc2.base64EncodedString()
        // RSA 加密随机 key（PKCS1）
        let secKeyHex = rsaEncrypt(secKey)
        return "params=\(urlEncode(params))&encSecKey=\(urlEncode(secKeyHex))"
    }

    private static func rsaEncrypt(_ secKey: String) -> String {
        guard let encrypted = CryptoUtils.rsaEncryptPKCS1(Data(secKey.utf8),
                                                          modulusHex: modulus,
                                                          exponent: 65537) else {
            return ""
        }
        return CryptoUtils.toHex(encrypted)
    }

    private static func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    /// weapi POST
    static func weapi<T: Decodable>(_ path: String, params: [String: Any], type: T.Type) async throws -> T {
        let url = "https://music.163.com/\(path)"
        let body = makeBody(params)
        guard let data = body.data(using: .utf8) else { throw NetworkClient.NetworkError.invalidURL }
        let resp = try await NetworkClient.shared.postRaw(url, body: data, contentType: "application/x-www-form-urlencoded", headers: [
            "Referer": "https://music.163.com/",
            "Origin": "https://music.163.com",
        ])
        guard let decoded = NetworkClient.decode(type, from: resp.data) else {
            throw NetworkClient.NetworkError.noData
        }
        return decoded
    }

    // MARK: - eapi（网易云 EAPI 通道）

    /// eapi 加密。
    ///
    /// 部分接口（如动态封面 `/api/songplay/dynamic-cover`）**weapi 恒返回 500**，
    /// 必须走 eapi。算法（与参考实现逐字段对齐）：
    ///
    /// ```
    /// digest = MD5("nobody" + path + "use" + json + "md5forencrypt")
    /// plain  = path + "-36cd479b6b5-" + json + "-36cd479b6b5-" + digest
    /// cipher = AES-128-ECB(plain, key = "e82ckenh8dichen8", PKCS7)
    /// 输出   = hex(cipher) 大写
    /// ```
    ///
    /// 服务端解密后按同样规则重算摘要校验，因此 json 的字段顺序不影响正确性
    /// （摘要是对**我们加密的同一份文本**算的）。
    static func eapiEncrypt(path: String, params: [String: Any]) -> String? {
        guard let json = (try? JSONSerialization.data(withJSONObject: params))
            .flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        let digest = CryptoUtils.md5("nobody\(path)use\(json)md5forencrypt")
        let plain = "\(path)-36cd479b6b5-\(json)-36cd479b6b5-\(digest)"
        guard let cipher = CryptoUtils.aesEncryptECB(Data(plain.utf8), key: Data("e82ckenh8dichen8".utf8)) else {
            return nil
        }
        return CryptoUtils.toHex(cipher).uppercased()
    }

    /// eapi 请求体（form 表单：`params=<hex>`）
    static func makeEapiBody(path: String, params: [String: Any]) -> String? {
        guard let hex = eapiEncrypt(path: path, params: params) else { return nil }
        return "params=\(hex)"
    }

    /// 构造 eapi 加密 payload 内的客户端 header。
    ///
    /// eapi 接口必须在**加密 body 内**携带客户端 header，否则服务端静默忽略请求。
    /// 特征对齐参考实现（os=pc 桌面网页客户端会话），MUSIC_U / __csrf 从登录
    /// Cookie 提取塞入。
    static func eapiHeaderPayload(cookie: String) -> [String: Any] {
        var header: [String: Any] = [
            "os": "pc",
            "appver": "3.1.17",
            "osver": "Version 14.0 (Build 23A344)",
            "deviceId": "wellmusic",
            "requestId": String(Int.random(in: 20_000_000..<30_000_000)),
            "clientSign": "",
            "versioncode": "140",
            "buildver": String(Int(Date().timeIntervalSince1970)),
            "resolution": "1920x1080",
            "channel": "",
        ]
        if let musicU = cookieValue(cookie, named: "MUSIC_U") { header["MUSIC_U"] = musicU }
        if let csrf = cookieValue(cookie, named: "__csrf") { header["__csrf"] = csrf }
        return header
    }

    /// 从 Cookie 字符串提取 `name=value` 的 value
    private static func cookieValue(_ cookie: String, named name: String) -> String? {
        guard let re = try? NSRegularExpression(
            pattern: "\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*([^;]+)"
        ) else { return nil }
        let ns = cookie as NSString
        guard let m = re.firstMatch(in: cookie, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
    }
}