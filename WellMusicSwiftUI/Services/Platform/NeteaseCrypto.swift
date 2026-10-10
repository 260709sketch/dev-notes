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
}