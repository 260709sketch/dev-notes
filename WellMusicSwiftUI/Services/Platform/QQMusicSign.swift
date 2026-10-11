import Foundation

/// QQ 音乐 zzcSign 签名（对齐 LX Music / LX-Y Music 移动端实现）。
///
/// 移动端 `musics.fcg` 接口要求 `sign=zzc...`，签名基于请求体 JSON 的 SHA1：
///   1. 取 SHA1 十六进制串（40 位）
///   2. 按固定索引抽出 part1 / part2
///   3. 用 SCRAMBLE 值逐字节异或后做「去填充」Base64，得到 part3
///   4. 拼接 `zzc{part1}{part3}{part2}` 并转小写
enum QQMusicSign {

    private static let part1Indexes = [23, 14, 6, 36, 16, 40, 7, 19]
    private static let part2Indexes = [16, 1, 32, 12, 19, 27, 8, 5]
    private static let scrambleValues: [UInt8] = [
        89, 39, 179, 150, 218, 82, 58, 252, 177, 52,
        186, 123, 120, 64, 242, 133, 143, 161, 121, 179,
    ]
    private static let base64Chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    /// 生成 zzcSign。
    /// - Parameter text: 即将发送的请求体 JSON 字符串（必须与实际发出的字节完全一致）。
    static func sign(_ text: String) -> String {
        let hash = CryptoUtils.sha1(text)          // 40 位小写十六进制
        let hashChars = Array(hash)

        func pick(_ indexes: [Int]) -> String {
            String(indexes.compactMap { $0 < hashChars.count ? hashChars[$0] : nil })
        }

        let part1 = pick(part1Indexes)
        let part2 = pick(part2Indexes)

        // part3：scramble[i] XOR hash[i*2 ..< i*2+2]（16 进制解析）
        var part3 = [UInt8]()
        part3.reserveCapacity(scrambleValues.count)
        for (i, value) in scrambleValues.enumerated() {
            let start = i * 2
            guard start + 2 <= hashChars.count else { break }
            let hexPair = String(hashChars[start..<(start + 2)])
            let byte = UInt8(hexPair, radix: 16) ?? 0
            part3.append(value ^ byte)
        }

        let b64 = base64NoPad(part3)
        return "zzc\(part1)\(b64)\(part2)".lowercased()
    }

    /// 自定义 Base64：不做 `=` 填充，且移除 `/` `+` `=`（与 JS 实现一致）。
    private static func base64NoPad(_ bytes: [UInt8]) -> String {
        var result = ""
        var i = 0
        while i < bytes.count {
            let b1 = Int(bytes[i])
            let b2 = i + 1 < bytes.count ? Int(bytes[i + 1]) : 0
            let b3 = i + 2 < bytes.count ? Int(bytes[i + 2]) : 0

            result.append(base64Chars[b1 >> 2])
            result.append(base64Chars[((b1 & 3) << 4) | (b2 >> 4)])
            result.append(i + 1 < bytes.count ? base64Chars[((b2 & 15) << 2) | (b3 >> 6)] : "=")
            result.append(i + 2 < bytes.count ? base64Chars[b3 & 63] : "=")
            i += 3
        }
        return result
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "=", with: "")
    }
}
