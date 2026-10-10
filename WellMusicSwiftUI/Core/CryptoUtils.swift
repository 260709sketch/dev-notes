import Foundation
import CryptoKit
import CommonCrypto
import zlib

/// 加密与编解码工具（替代 react-native-quick-crypto / crypto-js / pako / iconv-lite）
enum CryptoUtils {

    // MARK: MD5 / SHA / Base64 / Hex

    static func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func md5Data(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    static func sha1(_ string: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func base64Encode(_ data: Data) -> String { data.base64EncodedString() }

    static func base64Encode(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
    }

    static func base64Decode(_ string: String) -> Data? {
        Data(base64Encoded: string.replacingOccurrences(of: "\n", with: ""))
    }

    static func toHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func hexToData(_ hex: String) -> Data {
        var clean = hex.replacingOccurrences(of: "0x", with: "")
        clean = clean.replacingOccurrences(of: " ", with: "")
        clean = clean.replacingOccurrences(of: "\n", with: "")
        clean = clean.replacingOccurrences(of: ":", with: "")
        var data = Data()
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
            if let byte = UInt8(clean[idx..<next], radix: 16) {
                data.append(byte)
            }
            idx = next
        }
        return data
    }

    /// 随机字符串（网易云 encSecKey 等）
    static func randomString(length: Int, charset: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") -> String {
        String((0..<length).map { _ in charset.randomElement()! })
    }

    // MARK: AES-CBC / ECB（CommonCrypto）

    static func aesEncryptCBC(_ data: Data, key: Data, iv: Data) -> Data? {
        crypt(data, key: key, iv: iv, operation: CCOperation(kCCEncrypt), padding: true)
    }

    static func aesDecryptCBC(_ data: Data, key: Data, iv: Data) -> Data? {
        crypt(data, key: key, iv: iv, operation: CCOperation(kCCDecrypt), padding: true)
    }

    /// AES-128-ECB（Pkcs7），LX 音源脚本的 aes-128-ecb 模式使用
    static func aesEncryptECB(_ data: Data, key: Data) -> Data? {
        let dataLength = data.count
        let buffSize = dataLength + kCCBlockSizeAES128
        var buff = [UInt8](repeating: 0, count: buffSize)
        var numBytes = 0
        let options = CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode)
        let status = key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
                        keyBytes.baseAddress, key.count, nil,
                        dataBytes.baseAddress, dataLength, &buff, buffSize, &numBytes)
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(bytes: buff, count: numBytes)
    }

    /// 网易云 AES-128-CBC（Pkcs7），key 固定取前 16 字节
    static func aesEncryptNetease(_ plain: String, key: String) -> Data? {
        let keyData = Data(key.utf8).prefix(16)
        let ivData = Data("0102030405060708".utf8)
        return aesEncryptCBC(Data(plain.utf8), key: Data(keyData), iv: ivData)
    }

    private static func crypt(_ data: Data, key: Data, iv: Data?, operation: CCOperation, padding: Bool) -> Data? {
        let dataLength = data.count
        let buffSize = dataLength + kCCBlockSizeAES128
        var buff = [UInt8](repeating: 0, count: buffSize)
        var numBytesEncrypted = 0
        let options: CCOptions = padding ? CCOptions(kCCOptionPKCS7Padding) : CCOptions(kCCOptionECBMode)
        let status = key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                if let ivBytes = iv?.withUnsafeBytes({ $0.baseAddress }) {
                    return CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options,
                                   keyBytes.baseAddress, key.count,
                                   ivBytes,
                                   dataBytes.baseAddress, dataLength,
                                   &buff, buffSize, &numBytesEncrypted)
                } else {
                    return CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options,
                                   keyBytes.baseAddress, key.count,
                                   nil,
                                   dataBytes.baseAddress, dataLength,
                                   &buff, buffSize, &numBytesEncrypted)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(bytes: buff, count: numBytesEncrypted)
    }

    // MARK: RSA 公钥加密（替代 jsencrypt，PKCS#1 v1.5）

    /// modulusHex 为 16 进制大数；exponent 一般为 65537
    static func rsaEncryptPKCS1(_ plain: Data, modulusHex: String, exponent: UInt32 = 65537) -> Data? {
        var n = hexToData(modulusHex)
        if let first = n.first, first & 0x80 != 0 { n.insert(0, at: 0) }
        var e = withUnsafeBytes(of: exponent.bigEndian) { Data($0) }
        while let first = e.first, first == 0 { e.removeFirst() }
        if e.first! & 0x80 != 0 { e.insert(0, at: 0) }

        func integer(_ body: Data) -> Data {
            var out = Data()
            out.append(0x02)
            if body.count >= 0x80 {
                out.append(contentsOf: [0x81, UInt8(body.count)])
            } else {
                out.append(UInt8(body.count))
            }
            out.append(body)
            return out
        }
        let inner = integer(e)
        let content = integer(n) + inner
        var der = Data([0x30])
        der.append(UInt8(content.count))
        der.append(content)

        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        guard let secKey = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil) else { return nil }
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(secKey, .rsaEncryptionPKCS1, plain as CFData, &error) else {
            return nil
        }
        return encrypted as Data
    }

    // MARK: zlib inflate（替代 pako.inflate，用于歌词解密）

    static func inflate(_ data: Data) -> Data? {
        var stream = z_stream()
        let status: Int32 = data.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            return inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        }
        guard status == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var finished = false
        while !finished {
            buffer.withUnsafeMutableBytes { buf in
                stream.next_out = buf.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(buffer.count)
            }
            let ret = zlib.inflate(&stream, Z_NO_FLUSH)
            guard ret != Z_STREAM_ERROR else { return nil }
            let produced = buffer.count - Int(stream.avail_out)
            if produced > 0 { result.append(buffer, count: produced) }
            if ret == Z_STREAM_END {
                finished = true
            } else if ret != Z_OK {
                return nil
            } else if stream.avail_out > 0 {
                finished = true
            }
        }
        return result
    }

    // MARK: iconv 替代（GBK 歌词转 UTF-8）

    /// 将 GB18030/GBK 编码 Data 转成 String
    static func gbkString(_ data: Data) -> String? {
        let encoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return String(data: data, encoding: String.Encoding(rawValue: encoding))
    }
}