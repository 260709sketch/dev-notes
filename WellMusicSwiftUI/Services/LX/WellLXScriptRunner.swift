import Foundation
import CoreFoundation
import JavaScriptCore
import CommonCrypto
import Security
import os

/// 单个 LX 音源脚本的 JavaScriptCore 运行时（镜像 wellmusic assets/ios/WellMusicUserApi.mm）
///
/// 职责：
/// - 建立隔离 JSContext（globalThis/window/self/global 别名 + console + exceptionHandler），
///   加载顺序：preload → lx_setup(scriptKey, ...) → 用户脚本
/// - 暴露 7 个原生函数（__lx_native_call__ 总入口 + 6 个 utils/set_timeout），
///   其中 request 由 Swift 侧 URLSession 完成 HTTP 代理，响应回传 __lx_native__('response', ...)
/// - 业务请求：宿主侧以 {requestKey, data:{action, source, info}} 发往脚本（handleRequest 解构），
///   脚本完成 Promise 后由 preload nativeCall('response', {requestKey, status, result}) 回投，按 requestKey 分发
///
/// 线程模型：clone 所有 JSContext 访问与内部状态都只在 `queue`（串行）上执行；
/// 对外 API（loadScript / callAction / destroy）自行派发到 queue，回调在 queue 上触发。
final class WellLXScriptRunner: @unchecked Sendable {

    // MARK: 结果类型

    /// 脚本 init 结果（lx.send('inited') 时由 preload handleInit 上报；超时也会产出一个失败结果）
    struct InitResult {
        var status: Bool
        /// init 消息的完整 JSON 载荷（上层可读取 sourceInfo 等）
        var sources: [String: Any]?
        var errorMessage: String?
    }

    // MARK: 常量

    private static let log = Logger(subsystem: "well.music.swiftui", category: "lx")
    /// 脚本初始化兜底超时（wellmusic 同为约 10s）
    private let initTimeout: TimeInterval = 10
    /// 业务请求（搜索/取链/歌词）兜底超时
    private let businessTimeout: TimeInterval = 15
    /// 脚本侧原生 HTTP 代理的 timeout 硬上限（与 preload/RN 侧一致）
    private let maxHTTPTimeout: TimeInterval = 60

    // MARK: 状态（全部只在 queue 上读写）

    private let queue = DispatchQueue(label: "well.music.swiftui.lx", qos: .userInitiated)

    private var jsContext: JSContext?
    private var scriptKey: String?
    private var scriptInfo: WellLXScriptInfo?
    private var preloadScript: String = WellLXPreload.script

    /// init 一次性标记与补发缓存（镜像 .mm initSent / lastInit*）
    private var initSent = false
    private var lastInitDataString: String?
    private var initFailTimer: DispatchWorkItem?
    private var initCompletion: ((InitResult) -> Void)?

    /// JS 运行时抛出的最近异常（createJSEnv / evaluate 用户脚本阶段检查）
    private var lastExceptionText: String?

    /// 脚本 → 宿主：原生 HTTP 代理在途任务（requestKey → task 与兜底超时）
    private var activeHTTPTasks: [String: URLSessionTask] = [:]
    private var activeHTTPTimeouts: [String: DispatchWorkItem] = [:]

    /// 宿主 → 脚本：业务请求（requestKey → 完成回调，以及兜底超时）
    private var pendingBusinessRequests: [String: (Result<Any, Error>) -> Void] = [:]
    private var pendingBusinessTimeouts: [String: DispatchWorkItem] = [:]

    /// 微任务 pump：JSC 的 Promise 回调不会在原生调用返回后自动运行，
    /// 需要周期性 evaluate 简单表达式驱动 microtask 队列（search/url 解析均依赖 Promise.then 链）
    private var isPumping = false

    /// 脚本 console 日志回调（type: log/info/warn/error）
    private var logHandler: ((String, String) -> Void)?

    // MARK: - Host API

    /// 加载脚本：销毁旧环境 → 创建 JS 环境 → evaluate 用户脚本 → 等待 init（最多 initTimeout 秒）
    func loadScript(_ info: WellLXScriptInfo,
                    onLog: ((String, String) -> Void)? = nil,
                    completion: @escaping (InitResult) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.destroyContext()
            self.scriptInfo = info
            self.logHandler = onLog
            self.initCompletion = completion

            if case .failure(let message) = self.createJSEnv(info: info) {
                self.lastExceptionText = nil
                self.emitInitFailed(message.errorDescription ?? "创建脚本环境失败")
                return
            }
            self.lastExceptionText = nil
            // evaluate 用户脚本（镜像 .mm loadScript：异常 → __run_error__ + initFailed）
            self.jsContext?.evaluateScript(info.script)
            if let exception = self.lastExceptionText {
                let message = exception
                self.lastExceptionText = nil
                self.callJSAction("__run_error__", data: nil)
                if !self.initSent {
                    self.initSent = true
                    self.emitInitFailed(message)
                }
                return
            }
            // 脚本未同步 inited 时启动兜底超时
            if !self.initSent {
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, !self.initSent else { return }
                    self.initSent = true
                    self.emitInitFailed("脚本初始化超时")
                }
                self.initFailTimer = timer
                self.queue.asyncAfter(deadline: .now() + self.initTimeout, execute: timer)
            }
        }
    }

    /// 向脚本发起一个业务动作（musicSearch / musicUrl / musicLyric…）。
    /// data 是 WellLXProtocol 构建的 `{action, source, info}` 载荷；
    /// 这里自动补充 requestKey 并包成宿主协议 `{requestKey, data}`，
    /// 脚本结果经 nativeCall('response') 回投，按 requestKey 分发到 completion。
    func callAction(_ action: String,
                    data: [String: Any],
                    timeout: TimeInterval? = nil,
                    completion: @escaping (Result<Any, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, self.jsContext != nil else {
                completion(.failure(WellLXError.notLoaded(self?.scriptInfo?.name ?? "")))
                return
            }
            let requestKey = UUID().uuidString

            var payload = data
            payload["requestKey"] = requestKey
            let resourceTimeout = min(timeout ?? self.businessTimeout, self.businessTimeout)

            let timeoutItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.finishBusiness(requestKey, result: .failure(WellLXError.timeout(self.scriptInfo?.name ?? "")))
            }
            self.pendingBusinessTimeouts[requestKey] = timeoutItem
            self.queue.asyncAfter(deadline: .now() + resourceTimeout, execute: timeoutItem)

            self.pendingBusinessRequests[requestKey] = { result in
                timeoutItem.cancel()
                self.pendingBusinessTimeouts[requestKey] = nil
                completion(result)
            }

            self.callJSAction(action, data: ["requestKey": requestKey, "data": data])
            self.startPumpingIfNeeded()
        }
    }

    /// 销毁运行时并清理一切在途任务
    func destroy() {
        queue.async { [weak self] in
            self?.destroyContext()
        }
    }

    // MARK: - 环境创建（镜像 .mm createJSEnv）

    /// 返回值：ok = 环境可继续 evaluate 用户脚本
    private func createJSEnv(info: WellLXScriptInfo) -> Result<Void, WellLXError> {
        scriptKey = UUID().uuidString
        initSent = false
        lastInitDataString = nil

        guard let context = JSContext() else {
            return .failure(.scriptError("JSContext 创建失败"))
        }
        jsContext = context

        weak var weakSelf = self
        context.exceptionHandler = { _, exception in
            let message = exception?.toString() ?? "Unknown JavaScript exception"
            weakSelf?.lastExceptionText = message
            weakSelf?.emitLog(type: "error", message: "Call script error: \(message)")
        }

        context.setObject(context.globalObject, forKeyedSubscript: "globalThis" as NSString)
        context.setObject(context.globalObject, forKeyedSubscript: "window" as NSString)
        context.setObject(context.globalObject, forKeyedSubscript: "self" as NSString)
        context.setObject(context.globalObject, forKeyedSubscript: "global" as NSString)

        // console.log/info/warn/error → 宿主日志
        guard let console = JSValue(newObjectIn: context) else {
            return .failure(.scriptError("console 创建失败"))
        }
        // 注意：必须标注 @convention(block)，否则 JavaScriptCore 无法把它桥接成可调用的
        // JS 函数，只会包装成 NSObject —— 脚本调用 console.log 时会抛
        // "console.log is not a function. (… is an instance of NSObject)"。
        let consoleLog: @convention(block) () -> Void = { [weak self] in
            self?.emitLog(type: "log", message: self?.joinJSArguments(JSContext.currentArguments()) ?? "")
        }
        console.setObject(consoleLog, forKeyedSubscript: "log" as NSString)

        let consoleInfo: @convention(block) () -> Void = { [weak self] in
            self?.emitLog(type: "info", message: self?.joinJSArguments(JSContext.currentArguments()) ?? "")
        }
        console.setObject(consoleInfo, forKeyedSubscript: "info" as NSString)

        let consoleWarn: @convention(block) () -> Void = { [weak self] in
            self?.emitLog(type: "warn", message: self?.joinJSArguments(JSContext.currentArguments()) ?? "")
        }
        console.setObject(consoleWarn, forKeyedSubscript: "warn" as NSString)

        let consoleError: @convention(block) () -> Void = { [weak self] in
            self?.emitLog(type: "error", message: self?.joinJSArguments(JSContext.currentArguments()) ?? "")
        }
        console.setObject(consoleError, forKeyedSubscript: "error" as NSString)

        console.setObject(consoleLog, forKeyedSubscript: "debug" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        registerNativeBlocks(in: context)

        // preload
        lastExceptionText = nil
        context.evaluateScript(preloadScript)
        if let exception = lastExceptionText {
            return .failure(.scriptError(exception))
        }

        // lx_setup(key, id, name, description, version, author, homepage, rawScript)
        guard let setup = context.objectForKeyedSubscript("lx_setup"),
              !setup.isUndefined else {
            return .failure(.scriptError("preload 未定义 lx_setup"))
        }
        lastExceptionText = nil
        _ = setup.call(withArguments: [
            scriptKey ?? "",
            info.id,
            info.name,
            info.description,
            info.version,
            info.author,
            info.homepage,
            info.script,
        ])
        if let exception = lastExceptionText {
            return .failure(.scriptError(exception))
        }
        return .success(())
    }

    private func destroyContext() {
        for task in activeHTTPTasks.values { task.cancel() }
        activeHTTPTasks.removeAll()
        for item in activeHTTPTimeouts.values { item.cancel() }
        activeHTTPTimeouts.removeAll()
        for item in pendingBusinessTimeouts.values { item.cancel() }
        pendingBusinessTimeouts.removeAll()
        for (_, completion) in pendingBusinessRequests {
            completion(.failure(WellLXError.scriptError("运行时已销毁")))
        }
        pendingBusinessRequests.removeAll()
        initFailTimer?.cancel()
        initFailTimer = nil
        initCompletion = nil
        isPumping = false

        jsContext = nil
        scriptKey = nil
        scriptInfo = nil
        initSent = false
        lastInitDataString = nil
        lastExceptionText = nil
    }

    // MARK: - 原生 → JS

    /// 调用 preload 的 `__lx_native__(key, action, dataJSON? from:Any)`
    private func callJSAction(_ action: String, data: Any?) {
        guard let ctx = jsContext,
              let scriptKey,
              let fn = ctx.objectForKeyedSubscript("__lx_native__"),
              !fn.isUndefined else { return }
        var args: [Any] = [scriptKey, action]
        if let data {
            args.append(Self.jsonText(from: data))
        }
        _ = fn.call(withArguments: args)
    }

    /// 把任意值序列化成脚本侧 `JSON.parse` 能吃下的 JSON 文本。
    ///
    /// 注意：`JSONSerialization.data(withJSONObject:)` 要求顶层是 **数组或字典**，
    /// 传 `NSNumber` / `Bool` / `String` 等标量会抛 ObjC 异常
    /// （`Invalid top-level type in JSON write`），而 `try?` 只捕获 Swift `Error`，
    /// 捕不到 `NSException`，结果是**进程直接崩溃**。
    /// 因此这里先做显式类型判定，标量单独编码，绝不把非容器类型交给 `JSONSerialization`。
    /// 可见性为 internal（而非 private）以便单元测试直接覆盖该纯函数。
    static func jsonText(from value: Any) -> String {
        // 已是字符串时视为调用方给定的 JSON 文本（如 init 原始报文），原样透传。
        // 现存调用点均为字典 / Int，传字符串只为兼容旧契约。
        if let s = value as? String { return s }

        // 先转成 AnyObject 再判定：只有能被桥接成 ObjC 对象的类型才安全做 CF 类型判断。
        // 直接 `value as CFTypeRef` 对自定义 struct / enum 会运行时 trap，
        // 那会引入一个新的崩溃点（本函数的存在意义恰恰是「绝不崩溃」）。
        if let object = value as AnyObject? {
            let cfTypeID = CFGetTypeID(object)
            if cfTypeID == CFBooleanGetTypeID() {
                return (object as? Bool) == true ? "true" : "false"
            }
            if cfTypeID == CFNullGetTypeID() {
                return "null"
            }
            if cfTypeID == CFNumberGetTypeID() {
                return (object as? NSNumber)?.stringValue ?? "null"
            }
        }

        // 字典 / 数组：常规路径
        guard JSONSerialization.isValidJSONObject(value),
              let jsonData = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: jsonData, encoding: .utf8) else {
            // 兜底：无法序列化的类型（如自定义结构体 / Date / Data）降级为 null
            return "null"
        }
        return text
    }

    // MARK: - 原生 blocks（镜像 .mm createJSEnv 的 7 个注册）

    private func registerNativeBlocks(in context: JSContext) {
        weak var weakSelf = self

        // 1) 总入口 __lx_native_call__(key, action, dataJSON)
        let nativeCall: @convention(block) (String?, String?, String?) -> Void = { (key, action, data) in
            guard let weakSelf, let key, key == weakSelf.scriptKey else { return }
            let act = action ?? ""
            switch act {
            case "init":
                weakSelf.handleInitFromScript(data: data)
            case "request":
                weakSelf.handleNativeHTTPRequest(jsonString: data)
            case "cancelRequest":
                weakSelf.handleCancelHTTPRequest(jsonString: data)
            case "response":
                weakSelf.handleBusinessResponse(jsonString: data)
            case "showUpdateAlert":
                weakSelf.emitLog(type: "warn", message: "LX 音源提示更新：\(data ?? "")")
            case "log":
                weakSelf.emitLog(type: "info", message: data ?? "")
            default:
                weakSelf.emitLog(type: "log", message: "unknown native call: \(act)")
            }
        }
        context.setObject(nativeCall, forKeyedSubscript: "__lx_native_call__" as NSString)

        // 2) utils_str2b64：UTF-8 → base64
        let str2b64: @convention(block) (String) -> String = { input in
            input.data(using: .utf8)?.base64EncodedString() ?? ""
        }
        context.setObject(str2b64, forKeyedSubscript: "__lx_native_call__utils_str2b64" as NSString)

        // 3) utils_b642buf：base64 → 字节数组 JSON 字符串（如 "[49,50,51]"）
        let b642buf: @convention(block) (String) -> String = { input in
            let data = Data(base64Encoded: input) ?? Data()
            let values = data.map { $0 as UInt8 }
            let list = values.map { NSNumber(value: Int($0)) }
            if let jsonData = try? JSONSerialization.data(withJSONObject: list),
               let json = String(data: jsonData, encoding: .utf8) {
                return json
            }
            return "[]"
        }
        context.setObject(b642buf, forKeyedSubscript: "__lx_native_call__utils_b642buf" as NSString)

        // 4) utils_str2md5：先 percent-decode 再 UTF-8 → MD5 小写 hex
        let str2md5: @convention(block) (String) -> String = { input in
            let decoded = input.removingPercentEncoding ?? input
            let digest = CryptoUtils.md5Data(Data(decoded.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        context.setObject(str2md5, forKeyedSubscript: "__lx_native_call__utils_str2md5" as NSString)

        // 5) utils_aes_encrypt(textB64, keyB64, ivB64, mode)：CBC(AES/CBC/PKCS7Padding) / ECB(AES)，全部 PKCS7
        let aesEncrypt: @convention(block) (String, String, String, String) -> String = { text, key, iv, mode in
            weakSelf?.lxAESEncrypt(textBase64: text, keyBase64: key, ivBase64: iv, mode: mode) ?? ""
        }
        context.setObject(aesEncrypt, forKeyedSubscript: "__lx_native_call__utils_aes_encrypt" as NSString)

        // 6) utils_rsa_encrypt(textB64, keyB64, padding)：PEM SPKI → DER 剥离 → SecKey，Raw / OAEP-SHA1
        let rsaEncrypt: @convention(block) (String, String, String) -> String = { text, key, padding in
            weakSelf?.lxRSAEncrypt(textBase64: text, keyBase64: key, padding: padding) ?? ""
        }
        context.setObject(rsaEncrypt, forKeyedSubscript: "__lx_native_call__utils_rsa_encrypt" as NSString)

        // 7) set_timeout(id, ms)：到点回投 __set_timeout__
        let setTimeout: @convention(block) (NSNumber, NSNumber) -> Void = { identifier, timeout in
            let id = identifier.intValue
            let ms = max(timeout.doubleValue, 0)
            weakSelf?.queue.asyncAfter(deadline: .now() + ms / 1000.0) { [weak weakSelf] in
                weakSelf?.callJSAction("__set_timeout__", data: id)
            }
        }
        context.setObject(setTimeout, forKeyedSubscript: "__lx_native_call__set_timeout" as NSString)
    }

    // MARK: - init 一次性标记（镜像 .mm __lx_native_call__ 的 init 分支）

    private func handleInitFromScript(data: String?) {
        guard !initSent else { return }
        initSent = true
        lastInitDataString = data ?? ""
        initFailTimer?.cancel()
        initFailTimer = nil

        var result = InitResult(status: false, sources: nil, errorMessage: nil)
        if let dict = jsonToValue(data) as? [String: Any] {
            result.sources = dict
            result.status = dict["status"] as? Bool ?? true
            result.errorMessage = dict["errorMessage"] as? String
        } else {
            result.status = true
        }
        emitInitResult(result)
    }

    private func emitInitFailed(_ message: String) {
        emitLog(type: "error", message: message)
        emitInitResult(InitResult(status: false, sources: [
            "status": false,
            "info": NSNull(),
            "errorMessage": message,
        ], errorMessage: message))
    }

    private func emitInitResult(_ result: InitResult) {
        let completion = initCompletion
        initCompletion = nil
        completion?(result)
    }

    // MARK: - 业务响应分发（脚本 nativeCall('response', {requestKey, status, result|errorMessage})）

    private func handleBusinessResponse(jsonString: String?) {
        guard let dict = jsonToValue(jsonString) as? [String: Any],
              let requestKey = dict["requestKey"] as? String else { return }
        let status = dict["status"] as? Bool ?? false
        if status, let result = dict["result"] {
            finishBusiness(requestKey, result: .success(result))
        } else {
            let message = (dict["errorMessage"] as? String) ?? "unknown script error"
            finishBusiness(requestKey, result: .failure(WellLXError.scriptError(message)))
        }
    }

    private func finishBusiness(_ requestKey: String, result: Result<Any, Error>) {
        guard let completion = pendingBusinessRequests.removeValue(forKey: requestKey) else { return }
        pendingBusinessTimeouts.removeValue(forKey: requestKey)?.cancel()
        completion(result)
    }

    // MARK: - 原生 HTTP 代理（脚本 lx.request → nativeCall('request', {requestKey, url, options})）

    private func handleNativeHTTPRequest(jsonString: String?) {
        guard let dict = jsonToValue(jsonString) as? [String: Any],
              let requestKey = dict["requestKey"] as? String,
              let urlString = dict["url"] as? String,
              let url = URL(string: urlString) else {
            return
        }
        let options = (dict["options"] as? [String: Any]) ?? [:]

        var request = URLRequest(url: url)
        request.timeoutInterval = min((options["timeout"] as? Double ?? 0) / 1000.0, maxHTTPTimeout)

        if let method = options["method"] as? String, !method.isEmpty {
            request.httpMethod = method
        } else {
            request.httpMethod = "GET"
        }

        var httpBody: Data?
        var contentType: String?

        if let form = options["form"] as? [String: Any] {
            var components = URLComponents()
            components.queryItems = form.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
            httpBody = components.query?.data(using: .utf8)
            contentType = "application/x-www-form-urlencoded"
        } else if let body = options["body"] as? String {
            httpBody = body.data(using: .utf8)
        } else if let formData = options["formData"] as? [String: Any],
                  let binary = lxString(formData["binary"]) {
            httpBody = Data(base64Encoded: binary)
        } else if let binary = lxString(options["binary"]) {
            httpBody = Data(base64Encoded: binary)
        }
        if let httpBody { request.httpBody = httpBody }
        if let contentType, request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let headers = options["headers"] as? [String: Any] {
            for (key, value) in headers {
                request.setValue(lxString(value) ?? "\(value)", forHTTPHeaderField: key)
            }
        }

        // options.binary == true → 响应 body 以 base64 字符串回传（镜像 lx-music-mobile）
        let respondBinary = (options["binary"] as? Bool) == true
        let httpTimeout = min((options["timeout"] as? Double ?? 0) / 1000.0, maxHTTPTimeout)

        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.activeHTTPTimeouts.removeValue(forKey: requestKey)
            self.activeHTTPTasks.removeValue(forKey: requestKey)?.cancel()
            self.deliverHTTPResponse(requestKey: requestKey,
                                     error: "HTTP request timeout",
                                     response: nil,
                                     respondBinary: respondBinary)
        }
        activeHTTPTimeouts[requestKey] = timeoutItem
        queue.asyncAfter(deadline: .now() + httpTimeout, execute: timeoutItem)

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            self?.queue.async {
                guard let self else { return }
                self.activeHTTPTimeouts.removeValue(forKey: requestKey)?.cancel()
                if let error {
                    self.deliverHTTPResponse(requestKey: requestKey,
                                             error: error.localizedDescription,
                                             response: nil,
                                             respondBinary: respondBinary)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.deliverHTTPResponse(requestKey: requestKey,
                                             error: "No HTTP response",
                                             response: nil,
                                             respondBinary: respondBinary)
                    return
                }
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    headers["\(key)"] = "\(value)"
                }
                let body: String = respondBinary
                    ? (data ?? Data()).base64EncodedString()
                    : WellLXScriptRunner.decodeBody(data)
                self.deliverHTTPResponse(requestKey: requestKey, error: nil, response: [
                    "statusCode": http.statusCode,
                    "statusMessage": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                    "headers": headers,
                    "body": body,
                ], respondBinary: respondBinary)
            }
        }
        activeHTTPTasks[requestKey] = task
        task.resume()
    }

    /// 投递原生 HTTP 结果回脚本（preload handleNativeResponse 按 requestQueue 匹配 callback；
    /// 重复投递由 JS 侧 Map 删除逻辑自然去重）
    private func deliverHTTPResponse(requestKey: String, error: String?, response: [String: Any]?, respondBinary: Bool) {
        activeHTTPTasks.removeValue(forKey: requestKey)
        var payload: [String: Any] = ["requestKey": requestKey]
        if let error {
            payload["error"] = error
            payload["response"] = NSNull()
        } else {
            payload["error"] = NSNull()
            payload["response"] = response ?? NSNull()
        }
        callJSAction("response", data: payload)
    }

    /// 脚本 abort() → nativeCall('cancelRequest', requestKey)
    private func handleCancelHTTPRequest(jsonString: String?) {
        guard let requestKey = jsonToValue(jsonString) as? String else { return }
        activeHTTPTimeouts.removeValue(forKey: requestKey)?.cancel()
        activeHTTPTasks.removeValue(forKey: requestKey)?.cancel()
        deliverHTTPResponse(requestKey: requestKey, error: "canceled", response: nil, respondBinary: false)
    }

    // MARK: - 加密工具（镜像 .mm LXAES / LXRSAEncrypt 及其 DER 辅助）

    /// AES 加密：base64 进（text/key/iv）→ base64 出；
    /// CBC（AES/CBC/PKCS7Padding）带 PKCS7；ECB（AES，安卓模式）为 NoPadding，iv 补零/超出截断
    private func lxAESEncrypt(textBase64: String, keyBase64: String, ivBase64: String, mode: String) -> String {
        guard let data = Data(base64Encoded: textBase64),
              let key = Data(base64Encoded: keyBase64),
              !key.isEmpty else { return "" }
        let isCBC = mode == "AES/CBC/PKCS7Padding"
        var options: CCOptions = 0
        if isCBC { options |= CCOptions(kCCOptionPKCS7Padding) }
        if !isCBC { options |= CCOptions(kCCOptionECBMode) }

        var ivBuffer = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        if isCBC, let iv = Data(base64Encoded: ivBase64), !iv.isEmpty {
            let bytes = [UInt8](iv)
            for i in 0..<min(bytes.count, kCCBlockSizeAES128) {
                ivBuffer[i] = bytes[i]
            }
        }

        var outputLength = data.count + kCCBlockSizeAES128
        var output = Data(count: outputLength)
        var moved = 0
        let ivPointer: UnsafeRawPointer? = isCBC ? ivBuffer.withUnsafeBytes { $0.baseAddress } : nil
        let status = key.withUnsafeBytes { (keyRaw: UnsafeRawBufferPointer) -> CCCryptorStatus in
            data.withUnsafeBytes { (dataRaw: UnsafeRawBufferPointer) -> CCCryptorStatus in
                output.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) -> CCCryptorStatus in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        options,
                        keyRaw.baseAddress, key.count,
                        ivPointer,
                        dataRaw.baseAddress, data.count,
                        outRaw.baseAddress, outputLength,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { return "" }
        return output.prefix(moved).base64EncodedString()
    }

    /// RSA 加密：base64 进（text/key）→ base64 出；
    /// PEM SPKI → DER → 剥离头部（LXStripPublicKeyHeader）→ SecKeyCreateWithData，
    /// padding 为 RSA/ECB/OAEPWithSHA1AndMGF1Padding 用 OAEP-SHA1，否则 Raw（NoPadding）
    private func lxRSAEncrypt(textBase64: String, keyBase64: String, padding: String) -> String {
        guard let fullKey = Data(base64Encoded: keyBase64),
              let plain = Data(base64Encoded: textBase64) else { return "" }
        let stripped = lxStripPublicKeyHeader(fullKey)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var createError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(stripped as CFData, attributes as CFDictionary, &createError) else {
            return ""
        }
        let algorithm: SecKeyAlgorithm = padding == "RSA/ECB/OAEPWithSHA1AndMGF1Padding"
            ? .rsaEncryptionOAEPSHA1
            : .rsaEncryptionRaw
        guard SecKeyIsAlgorithmSupported(key, .encrypt, algorithm) else { return "" }
        var encryptError: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(key, algorithm, plain as CFData, &encryptError) as Data? else {
            return ""
        }
        return encrypted.base64EncodedString()
    }

    // MARK: DER 辅助（镜像 .mm LXDERLength / LXDERWrap / LXReadASN1Length）

    private func lxDERLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        var out = Data()
        out.append(UInt8(0x80 | bytes.count))
        out.append(contentsOf: bytes)
        return out
    }

    private func lxDERWrap(_ tag: UInt8, _ value: Data) -> Data {
        var out = Data([tag])
        out.append(lxDERLength(value.count))
        out.append(value)
        return out
    }

    private func lxReadASN1Length(_ data: Data, index: inout Int) -> (ok: Bool, length: Int) {
        guard index < data.count else { return (false, 0) }
        let bytes = [UInt8](data)
        let byte = bytes[index]
        index += 1
        if byte & 0x80 == 0 {
            let length = Int(byte)
            return (index + length <= data.count, length)
        }
        let byteCount = Int(byte & 0x7F)
        guard byteCount > 0, index + byteCount <= data.count else { return (false, 0) }
        var value = 0
        for offset in 0..<byteCount {
            value = (value << 8) | Int(bytes[index + offset])
        }
        index += byteCount
        return (index + value <= data.count, value)
    }

    /// PEAP SPKI 头部剥离：30 SEQUENCE → AlgorithmIdentifier(30 …) → BIT STRING(03 …) → 裸 RSA key
    private func lxStripPublicKeyHeader(_ data: Data) -> Data {
        guard data.count >= 1 else { return data }
        let bytes = [UInt8](data)
        var index = 0
        guard bytes[index] == 0x30 else { return data }
        index += 1
        var result = lxReadASN1Length(data, index: &index)
        guard result.ok, index < data.count else { return data }
        if bytes[index] == 0x02 { return data }
        guard bytes[index] == 0x30 else { return data }
        index += 1
        result = lxReadASN1Length(data, index: &index)
        guard result.ok else { return data }
        index += result.length
        guard index < data.count, bytes[index] == 0x03 else { return data }
        index += 1
        result = lxReadASN1Length(data, index: &index)
        guard result.ok, index < data.count else { return data }
        guard bytes[index] == 0x00 else { return data }
        index += 1
        guard index <= data.count else { return data }
        return data.subdata(in: index..<data.count)
    }

    // MARK: - 杂项工具

    private func jsonToValue(_ jsonString: String?) -> Any? {
        guard let jsonString, !jsonString.isEmpty,
              let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func lxString(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        return nil
    }

    /// 响应 body 文本解码：优先 UTF-8，其次 GBK（与 NetworkClient.Response.string 一致）
    private static func decodeBody(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "" }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let gbk = CryptoUtils.gbkString(data) { return gbk }
        return String(decoding: data, as: UTF8.self)
    }

    private func joinJSArguments(_ arguments: [Any]?) -> String {
        guard let arguments, !arguments.isEmpty else { return "" }
        return arguments.map { argument -> String in
            if let value = argument as? JSValue {
                if value.isUndefined || value.isNull { return "null" }
                return value.toString()
            }
            if argument is NSNull { return "null" }
            return "\(argument)"
        }.joined(separator: " ")
    }

    private func emitLog(type: String, message: String) {
        Self.log.info("\(type): \(message, privacy: .public)")
        logHandler?(type, message)
    }

    // MARK: - 微任务 pump（JSC 的 Promise 回调需周期性驱动）

    private func startPumpingIfNeeded() {
        guard !isPumping, !pendingBusinessRequests.isEmpty else { return }
        isPumping = true
        pumpTick()
    }

    private func pumpTick() {
        guard isPumping else { return }
        queue.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
            self?.pumpOnce()
        }
    }

    private func pumpOnce() {
        guard isPumping else { return }
        if pendingBusinessRequests.isEmpty && activeHTTPTasks.isEmpty {
            isPumping = false
            return
        }
        jsContext?.evaluateScript("void 0")
        pumpTick()
    }
}