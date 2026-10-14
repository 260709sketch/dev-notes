import Foundation
import zlib

/// QQ 音乐逐字 QRC 歌词解密器。
///
/// 管线：hex 解码 → 非标准 3DES 解密（key1/2/3 + 预计算查找表）→ zlib 解压
/// → UTF-8 / GB-18030 解码 → QRC 文本。
/// 仅用于歌词互操作。
enum QQQrcDecoder {
    // MARK: - 常量表
    private static let key1 = [UInt8]("!@#)(*$%".utf8)
    private static let key2 = [UInt8]("123ZXC!@".utf8)
    private static let key3 = [UInt8]("!@#)(NHL".utf8)

    private static let sBoxes: [[UInt8]] = [
        [14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7, 0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8, 4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0, 15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],
        [15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10, 3,13,4,7,15,2,8,15,12,0,1,10,6,9,11,5, 0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15, 13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],
        [10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8, 13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1, 13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7, 1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],
        [7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15, 13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9, 10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4, 3,15,0,6,10,10,13,8,9,4,5,11,12,7,2,14],
        [2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9, 14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6, 4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14, 11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],
        [12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11, 10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8, 9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6, 4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],
        [4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1, 13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6, 1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2, 6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],
        [13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7, 1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2, 7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8, 2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11]
    ]

    private static let pBox: [Int] = [16,7,20,21,29,12,28,17,1,15,23,26,5,18,31,10,2,8,24,14,32,27,3,9,19,13,30,6,22,11,4,25]

    private static let eBoxTable: [Int] = [32,1,2,3,4,5,4,5,6,7,8,9,8,9,10,11,12,13,12,13,14,15,16,17,16,17,18,19,20,21,20,21,22,23,24,25,24,25,26,27,28,29,28,29,30,31,32,1]

    private static let keyRndShift: [Int] = [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1]

    private static let keyPermC: [Int] = [56,48,40,32,24,16,8,0,57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35]
    private static let keyPermD: [Int] = [62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,60,52,44,36,28,20,12,4,27,19,11,3]

    private static let keyCompression: [Int] = [13,16,10,23,0,4,2,27,14,5,20,9,22,18,11,3,25,7,15,6,26,19,12,1,40,51,30,36,46,54,29,39,50,44,32,47,43,48,38,55,33,52,45,41,49,35,28,31]

    private static let ipRule: [Int] = [34,42,50,58,2,10,18,26,36,44,52,60,4,12,20,28,38,46,54,62,6,14,22,30,40,48,56,64,8,16,24,32,33,41,49,57,1,9,17,25,35,43,51,59,3,11,19,27,37,45,53,61,5,13,21,29,39,47,55,63,7,15,23,31]
    private static let invIpRule: [Int] = [37,5,45,13,53,21,61,29,38,6,46,14,54,22,62,30,39,7,47,15,55,23,63,31,40,8,48,16,56,24,64,32,33,1,41,9,49,17,57,25,34,2,42,10,50,18,58,26,35,3,43,11,51,19,59,27,36,4,44,12,52,20,60,28]

    // MARK: - 预计算查找表
    private static let ipLeftTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 2048)
        for bytePos in 0..<8 {
            for byteVal in 0..<256 {
                let shift = 56 - bytePos * 8
                let hi: UInt32 = shift >= 32 ? UInt32(byteVal) << (shift - 32) : 0
                let lo: UInt32 = shift < 32 ? UInt32(byteVal) << shift : 0
                let ip = permute64(hi: hi, lo: lo, rule: ipRule)
                let idx = bytePos << 8 | byteVal
                table[idx] = ip[0]
            }
        }
        return table
    }()

    private static let ipRightTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 2048)
        for bytePos in 0..<8 {
            for byteVal in 0..<256 {
                let shift = 56 - bytePos * 8
                let hi: UInt32 = shift >= 32 ? UInt32(byteVal) << (shift - 32) : 0
                let lo: UInt32 = shift < 32 ? UInt32(byteVal) << shift : 0
                let ip = permute64(hi: hi, lo: lo, rule: ipRule)
                let idx = bytePos << 8 | byteVal
                table[idx] = ip[1]
            }
        }
        return table
    }()

    private static let invIpLeftTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 2048)
        for bytePos in 0..<8 {
            for byteVal in 0..<256 {
                let shift = 56 - bytePos * 8
                let hi: UInt32 = shift >= 32 ? UInt32(byteVal) << (shift - 32) : 0
                let lo: UInt32 = shift < 32 ? UInt32(byteVal) << shift : 0
                let inv = permute64(hi: hi, lo: lo, rule: invIpRule)
                let idx = bytePos << 8 | byteVal
                table[idx] = inv[0]
            }
        }
        return table
    }()

    private static let invIpRightTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 2048)
        for bytePos in 0..<8 {
            for byteVal in 0..<256 {
                let shift = 56 - bytePos * 8
                let hi: UInt32 = shift >= 32 ? UInt32(byteVal) << (shift - 32) : 0
                let lo: UInt32 = shift < 32 ? UInt32(byteVal) << shift : 0
                let inv = permute64(hi: hi, lo: lo, rule: invIpRule)
                let idx = bytePos << 8 | byteVal
                table[idx] = inv[1]
            }
        }
        return table
    }()

    private static let spTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 512)
        for sBoxIdx in 0..<8 {
            for sBoxInput in 0..<64 {
                let sBoxIndex = sBoxIndexCalc(UInt8(sBoxInput))
                let prePBoxVal = UInt32(sBoxes[sBoxIdx][Int(sBoxIndex)]) << (28 - sBoxIdx * 4)
                table[sBoxIdx << 6 | sBoxInput] = applyQqPboxPermutation(prePBoxVal)
            }
        }
        return table
    }()

    private static let eboxHighTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 1024)
        for chunkIdx in 0..<4 {
            let shiftIn32 = (3 - chunkIdx) * 8
            for byteVal in 0..<256 {
                let input = UInt32(byteVal) << shiftIn32
                var high24: UInt32 = 0
                for i in 0..<24 {
                    if (input >> (32 - eBoxTable[i])) & 1 != 0 {
                        high24 |= 1 << (23 - i)
                    }
                }
                let tableIdx = chunkIdx << 8 | byteVal
                table[tableIdx] = high24
            }
        }
        return table
    }()

    private static let eboxLowTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 1024)
        for chunkIdx in 0..<4 {
            let shiftIn32 = (3 - chunkIdx) * 8
            for byteVal in 0..<256 {
                let input = UInt32(byteVal) << shiftIn32
                var low24: UInt32 = 0
                for i in 24..<48 {
                    if (input >> (32 - eBoxTable[i])) & 1 != 0 {
                        low24 |= 1 << (47 - i)
                    }
                }
                let tableIdx = chunkIdx << 8 | byteVal
                table[tableIdx] = low24
            }
        }
        return table
    }()

    // MARK: - 辅助函数
    private static func permute64(hi: UInt32, lo: UInt32, rule: [Int]) -> [UInt32] {
        var outHi: UInt32 = 0
        var outLo: UInt32 = 0
        for i in 0..<64 {
            let srcBit1Based = rule[i]
            let b = 64 - srcBit1Based
            let bit: UInt32 = b >= 32 ? (hi >> (b - 32)) & 1 : (lo >> b) & 1
            if bit != 0 {
                let ob = 63 - i
                if ob >= 32 { outHi |= 1 << (ob - 32) }
                else { outLo |= 1 << ob }
            }
        }
        return [outHi, outLo]
    }

    private static func sBoxIndexCalc(_ a: UInt8) -> UInt8 {
        return (a & 32) | ((a & 31) >> 1) | ((a & 1) << 4)
    }

    private static func applyQqPboxPermutation(_ input: UInt32) -> UInt32 {
        var output: UInt32 = 0
        for i in 0..<32 {
            let sourceBit1Based = pBox[i]
            let destBitMask: UInt32 = 1 << (31 - i)
            if (input & (1 << (32 - sourceBit1Based))) != 0 {
                output |= destBitMask
            }
        }
        return output
    }

    private static func permuteFromKeyBytes(_ key: [UInt8], _ table: [Int]) -> UInt32 {
        var output: UInt32 = 0
        let n = table.count
        for i in 0..<n {
            let pos = table[i]
            let wordIndex = pos >> 5
            let bitInWord = pos & 31
            let byteInWord = bitInWord >> 3
            let bitInByte = bitInWord & 7
            let bit = (key[wordIndex * 4 + 3 - byteInWord] >> (7 - bitInByte)) & 1
            if bit != 0 {
                output |= 1 << (n - 1 - i)
            }
        }
        return output
    }

    private static func rotateLeft28Bit(_ value: UInt32, _ amount: Int) -> UInt32 {
        let bits28Mask: UInt32 = 4294967280 // 0xFFFFFFF0
        let val = value & bits28Mask
        return ((val << amount) | (val >> (28 - amount))) & bits28Mask
    }

    private static func keySchedule(_ key: [UInt8], _ mode: Int) -> [UInt32] {
        var schedule = [UInt32](repeating: 0, count: 32)
        let c0 = permuteFromKeyBytes(key, keyPermC)
        let d0 = permuteFromKeyBytes(key, keyPermD)
        var c = c0 << 4
        var d = d0 << 4
        for i in 0..<16 {
            let shift = keyRndShift[i]
            c = rotateLeft28Bit(c, shift)
            d = rotateLeft28Bit(d, shift)
            let toGen = mode == 1 ? 15 - i : i
            var high24: UInt32 = 0
            var low24: UInt32 = 0
            for k in 0..<keyCompression.count {
                let pos = keyCompression[k]
                var bit: UInt32 = 0
                if pos < 28 {
                    bit = (c >> (31 - pos)) & 1
                } else {
                    bit = (d >> (31 - (pos - 27))) & 1
                }
                if bit != 0 {
                    let bitPos = 47 - k
                    if bitPos >= 24 { high24 |= 1 << (bitPos - 24) }
                    else { low24 |= 1 << bitPos }
                }
            }
            schedule[toGen * 2] = high24
            schedule[toGen * 2 + 1] = low24
        }
        return schedule
    }

    private static func fFunction(_ state: UInt32, _ keyHigh24: UInt32, _ keyLow24: UInt32) -> UInt32 {
        let b0 = (state >> 24) & 255
        let b1 = (state >> 16) & 255
        let b2 = (state >> 8) & 255
        let b3 = state & 255
        let eboxHigh24 = eboxHighTable[Int(b0)] | eboxHighTable[256 | Int(b1)] | eboxHighTable[512 | Int(b2)] | eboxHighTable[768 | Int(b3)]
        let eboxLow24 = eboxLowTable[Int(b0)] | eboxLowTable[256 | Int(b1)] | eboxLowTable[512 | Int(b2)] | eboxLowTable[768 | Int(b3)]
        let xorHigh24 = eboxHigh24 ^ keyHigh24
        let xorLow24 = eboxLow24 ^ keyLow24
        return spTable[Int((xorHigh24 >> 18) & 63)] |
               spTable[64 | Int((xorHigh24 >> 12) & 63)] |
               spTable[128 | Int((xorHigh24 >> 6) & 63)] |
               spTable[192 | Int(xorHigh24 & 63)] |
               spTable[256 | Int((xorLow24 >> 18) & 63)] |
               spTable[320 | Int((xorLow24 >> 12) & 63)] |
               spTable[384 | Int((xorLow24 >> 6) & 63)] |
               spTable[448 | Int(xorLow24 & 63)]
    }

    private static func desCrypt(_ input: [UInt8], _ output: inout [UInt8], _ keySchedule: [UInt32]) {
        var left: UInt32 = 0
        var right: UInt32 = 0
        for i in 0..<8 {
            let idx = i << 8 | Int(input[i])
            left |= ipLeftTable[idx]
            right |= ipRightTable[idx]
        }
        for i in 0..<15 {
            let temp = right
            right = (left ^ fFunction(right, keySchedule[i * 2], keySchedule[i * 2 + 1]))
            left = temp
        }
        left = left ^ fFunction(right, keySchedule[30], keySchedule[31])
        var outLeft: UInt32 = 0
        var outRight: UInt32 = 0
        for i in 0..<4 {
            let idxL = i << 8 | Int((left >> (24 - i * 8)) & 255)
            outLeft |= invIpLeftTable[idxL]
            outRight |= invIpRightTable[idxL]
            let idxR = (i + 4) << 8 | Int((right >> (24 - i * 8)) & 255)
            outLeft |= invIpLeftTable[idxR]
            outRight |= invIpRightTable[idxR]
        }
        output[0] = UInt8((outLeft >> 24) & 255)
        output[1] = UInt8((outLeft >> 16) & 255)
        output[2] = UInt8((outLeft >> 8) & 255)
        output[3] = UInt8(outLeft & 255)
        output[4] = UInt8((outRight >> 24) & 255)
        output[5] = UInt8((outRight >> 16) & 255)
        output[6] = UInt8((outRight >> 8) & 255)
        output[7] = UInt8(outRight & 255)
    }

    // MARK: - 3DES 解密
    private static let decryptSchedule: [[UInt32]] = [
        keySchedule(key3, 1), // KEY_3 解密
        keySchedule(key2, 0), // KEY_2 加密
        keySchedule(key1, 1), // KEY_1 解密
    ]

    private static func decryptBlock(_ input: [UInt8], _ output: inout [UInt8]) {
        var temp1 = [UInt8](repeating: 0, count: 8)
        var temp2 = [UInt8](repeating: 0, count: 8)
        desCrypt(input, &temp1, decryptSchedule[0])
        desCrypt(temp1, &temp2, decryptSchedule[1])
        desCrypt(temp2, &output, decryptSchedule[2])
    }

    // MARK: - hex 解码
    private static func hexToBytes(_ hex: String) -> [UInt8]? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    // MARK: - zlib 解压
    private static func decompress(_ data: [UInt8]) -> [UInt8]? {
        guard !data.isEmpty else { return nil }
        // 去掉末尾零填充（QQ音乐 3DES 用零填充，这些字节不在 zlib 流内）
        var trimmed = data
        while trimmed.count > 2 && trimmed.last == 0 {
            trimmed.removeLast()
        }
        let outputSize = trimmed.count * 20 + 1024
        var outputBuffer = [UInt8](repeating: 0, count: outputSize)
        var destLen = uLongf(outputSize)
        let result = trimmed.withUnsafeBytes { inputPtr -> Int32 in
            outputBuffer.withUnsafeMutableBytes { outputPtr -> Int32 in
                uncompress(
                    outputPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    &destLen,
                    inputPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    uLong(trimmed.count)
                )
            }
        }
        guard result == Z_OK else { return nil }
        var resultData = Array(outputBuffer.prefix(Int(destLen)))
        // 去 UTF-8 BOM
        if resultData.count >= 3 && resultData[0] == 0xEF && resultData[1] == 0xBB && resultData[2] == 0xBF {
            resultData = Array(resultData.dropFirst(3))
        }
        return resultData
    }

    // MARK: - 公开接口
    /// 解密 QQ 音乐 QRC 逐字歌词（hex 格式）→ QRC 明文
    static func decrypt(_ hexString: String) -> String? {
        guard let encryptedBytes = hexToBytes(hexString) else { return nil }
        guard !encryptedBytes.isEmpty, encryptedBytes.count % 8 == 0 else { return nil }
        var decryptedData = [UInt8](repeating: 0, count: encryptedBytes.count)
        for i in stride(from: 0, to: encryptedBytes.count, by: 8) {
            let chunk = Array(encryptedBytes[i..<(i + 8)])
            var outChunk = [UInt8](repeating: 0, count: 8)
            decryptBlock(chunk, &outChunk)
            for j in 0..<8 {
                decryptedData[i + j] = outChunk[j]
            }
        }
        guard let decompressed = decompress(decryptedData) else { return nil }
        // 先 UTF-8，失败退 GB-18030（QQ 的 QRC 可能是 GBK）
        if let utf8Str = String(bytes: decompressed, encoding: .utf8) {
            return utf8Str
        }
        let gbkEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(bytes: decompressed, encoding: gbkEncoding)
    }
}
