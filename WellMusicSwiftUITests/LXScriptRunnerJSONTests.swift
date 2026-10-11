import XCTest
@testable import WellMusicSwiftUI

/// 回归测试：LX 脚本运行时的「原生 → JS」序列化。
///
/// 背景：真机崩溃
/// `+[NSJSONSerialization dataWithJSONObject:options:error:]: Invalid top-level type in JSON write`
/// 崩溃栈落在 `WellLXScriptRunner.callJSAction`。
///
/// 根因：preload 的 `set_timeout` block 到点后调用
/// `callJSAction("__set_timeout__", data: id)`，`id` 是 `Int`（桥接为 NSNumber）。
/// `JSONSerialization.data(withJSONObject:)` 要求顶层必须是数组或字典，
/// 标量会抛 **ObjC NSException**；而 Swift 的 `try?` 只能捕获 Swift `Error`，
/// 捕不到 `NSException`，于是进程直接崩溃。
///
/// 修复：`jsonText(from:)` 对 String / Bool / NSNull / NSNumber 显式分派，
/// 只把字典与数组交给 `JSONSerialization`。
final class LXScriptRunnerJSONTests: XCTestCase {

    // MARK: - 崩溃点：标量顶层

    /// 原崩溃用例：Int 必须被编码成合法 JSON 数字文本，而不是抛异常
    func testIntegerEncodesAsJSONNumber() {
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: 42), "42")
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: 0), "0")
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: -7), "-7")
    }

    /// 崩溃栈里的 block 签名是 `(NSNumber, NSNumber) -> Void`，
    /// 因此必须以 NSNumber 直接入参也能安全通过
    func testNSNumberEncodesAsJSONNumber() {
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: NSNumber(value: 123)), "123")
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: NSNumber(value: 1.5)), "1.5")
        // `id.intValue` 产生的就是 NSNumber 装箱的整数
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: NSNumber(value: Int(9))), "9")
    }

    /// 修复后必须能被脚本侧 `JSON.parse` 解析回数字
    func testScalarOutputIsParseableByJSONParse() throws {
        let text = WellLXScriptRunner.jsonText(from: 12)
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        XCTAssertEqual(parsed as? Int, 12)
    }

    // MARK: - 布尔

    /// Bool 桥接后是 __NSCFBoolean（NSNumber 子类），必须先于 NSNumber 判定，
    /// 否则会输出 "1"/"0" 而非 true/false
    func testBoolEncodesAsJSONLiteral() {
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: true), "true")
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: false), "false")
    }

    func testNSNumberBoolEncodesAsJSONLiteral() {
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: NSNumber(value: true)), "true")
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: NSNumber(value: false)), "false")
    }

    /// 关键歧义点：`NSNumber(value: 1) as? Bool` 在 Swift 桥接下会成立，
    /// 若只用 `as? Bool` 判定就会把数字 1 错编码成 "true"。
    /// 实现改用 CFGetTypeID 精确区分，这里锁死该行为。
    func testNumberOneIsNotMisencodedAsBoolTrue() {
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: NSNumber(value: 1)), "1")
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: NSNumber(value: 0)), "0")
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: 1), "1")
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: 0), "0")
    }

    // MARK: - null

    func testNullEncodesAsJSONNull() {
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: NSNull()), "null")
    }

    // MARK: - 字符串（透传契约）

    /// 字符串被视作调用方给定的 JSON 文本，原样透传（init 报文的既有契约）
    func testStringPassesThroughVerbatim() {
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: #"{"status":true}"#), #"{"status":true}"#)
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: "[]"), "[]")
    }

    // MARK: - 容器（既有行为不能回归）

    func testDictionaryEncodesAsJSONObject() throws {
        let text = WellLXScriptRunner.jsonText(from: ["b": 2, "a": 1])
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Int]
        )
        XCTAssertEqual(parsed, ["a": 1, "b": 2])
    }

    func testArrayEncodesAsJSONArray() throws {
        let text = WellLXScriptRunner.jsonText(from: [1, 2, 3])
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Int]
        )
        XCTAssertEqual(parsed, [1, 2, 3])
    }

    /// 业务动作的真实载荷形状：{requestKey, data:{action, source, info}}
    func testBusinessRequestPayloadShape() throws {
        let payload: [String: Any] = [
            "requestKey": "ABC-123",
            "data": ["action": "musicUrl", "source": "kw", "info": ["musicInfo": ["songmid": "x"]]],
        ]
        let text = WellLXScriptRunner.jsonText(from: payload)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(parsed["requestKey"] as? String, "ABC-123")
        let data = try XCTUnwrap(parsed["data"] as? [String: Any])
        XCTAssertEqual(data["action"] as? String, "musicUrl")
        XCTAssertEqual(data["source"] as? String, "kw")
    }

    /// 嵌套混合容器
    func testNestedMixedContainer() throws {
        let value: [String: Any] = [
            "status": true,
            "count": 3,
            "items": ["a", "b"],
            "none": NSNull(),
        ]
        let text = WellLXScriptRunner.jsonText(from: value)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(parsed["status"] as? Bool, true)
        XCTAssertEqual(parsed["count"] as? Int, 3)
        XCTAssertEqual(parsed["items"] as? [String], ["a", "b"])
        XCTAssertTrue(parsed["none"] is NSNull)
    }

    // MARK: - 兜底：绝不崩溃

    /// 不可序列化的自定义类型必须降级为 "null"，而不是抛 NSException 崩溃
    func testUnencodableValueFallsBackToNullWithoutCrashing() {
        struct NotEncodable {}
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: NotEncodable()), "null")
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: Date()), "null")
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: Data([1, 2, 3])), "null")
    }

    /// 字典里混入不可序列化值时，JSONSerialization 会失败 → 同样降级 null
    func testDictionaryWithUnencodableMemberFallsBackToNull() {
        struct NotEncodable {}
        let value: [String: Any] = ["bad": NotEncodable()]
        XCTAssertEqual(WellLXScriptRunner.jsonText(from: value), "null")
    }

    // MARK: - 输出恒为合法 JSON

    /// 任意输入下输出都必须是 `JSON.parse` 能接受的文本
    func testAllScalarOutputsAreValidJSONFragments() throws {
        let candidates: [Any] = [0, 1, -1, 3.25, true, false, NSNull(), "hello"]
        for value in candidates {
            let text = WellLXScriptRunner.jsonText(from: value)
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
                "value=\(value) produced invalid JSON: \(text)"
            )
        }
    }
}
