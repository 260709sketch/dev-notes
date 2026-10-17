import Foundation

/// 内嵌 LX 音源脚本运行环境（逐字来自 wellmusic v90 `src/helpers/userApi/user-api-preload.js`）
/// 仅有一处增强：在 handleRequest 的响应整形里新增 `musicSearch` 透传分支，
/// 使脚本返回的搜索结果原样回传原生侧（wellmusic 原版只整形 musicUrl/lyric/pic）。
enum WellLXPreload {
    static let script = #"""
'use strict'

globalThis.lx_setup = (key, id, name, description, version, author, homepage, rawScript) => {
  delete globalThis.lx_setup
  const _nativeCall = globalThis.__lx_native_call__
  delete globalThis.__lx_native_call__
  const checkLength = (str, length = 1048576) => {
    if (typeof str == 'string' && str.length > length) throw new Error('Input too long')
    return str
  }
  const nativeFuncNames = [
    '__lx_native_call__set_timeout',
    '__lx_native_call__utils_str2b64',
    '__lx_native_call__utils_b642buf',
    '__lx_native_call__utils_str2md5',
    '__lx_native_call__utils_aes_encrypt',
    '__lx_native_call__utils_rsa_encrypt',
  ]
  const nativeFuncs = {}
  for (const name of nativeFuncNames) {
    const nativeFunc = globalThis[name]
    delete globalThis[name]
    nativeFuncs[name.replace('__lx_native_call__', '')] = (...args) => {
      for (const arg of args) checkLength(arg)
      return nativeFunc(...args)
    }
  }

  const KEY_PREFIX = {
    publicKeyStart: '-----BEGIN PUBLIC KEY-----',
    publicKeyEnd: '-----END PUBLIC KEY-----',
    privateKeyStart: '-----BEGIN PRIVATE KEY-----',
    privateKeyEnd: '-----END PRIVATE KEY-----',
  }
  const RSA_PADDING = {
    OAEPWithSHA1AndMGF1Padding: 'RSA/ECB/OAEPWithSHA1AndMGF1Padding',
    NoPadding: 'RSA/ECB/NoPadding',
  }
  const AES_MODE = {
    CBC_128_PKCS7Padding: 'AES/CBC/PKCS7Padding',
    ECB_128_NoPadding: 'AES',
  }
  const nativeCall = (action, data) => {
    data = JSON.stringify(data)
    // console.log('nativeCall', action, data)
    checkLength(data, 2097152)
    _nativeCall(key, action, data)
  }

  const callbacks = new Map()
  let timeoutId = 0
  const _setTimeout = (callback, timeout = 0, ...params) => {
    if (typeof callback !== 'function') throw new Error('callback required a function')
    if (typeof timeout !== 'number' || timeout < 0) throw new Error('timeout required a number')
    if (timeoutId > 90000000000) throw new Error('max timeout')
    const id = timeoutId++
    callbacks.set(id, {
      callback(...args) {
        callback(...args)
      },
      params,
    })
    nativeFuncs.set_timeout(id, parseInt(timeout))
    return id
  }
  const _clearTimeout = (id) => {
    const tagret = callbacks.get(id)
    if (!tagret) return
    callbacks.delete(id)
  }
  const handleSetTimeout = (id) => {
    const tagret = callbacks.get(id)
    if (!tagret) return
    callbacks.delete(id)
    tagret.callback(...tagret.params)
  }

  // 将字节数组解码为字符串（UTF-8）
  function bytesToString(bytes) {
    let result = ''
    let i = 0
    while (i < bytes.length) {
      const byte = bytes[i]
      if (byte < 128) {
        result += String.fromCharCode(byte)
        i++
      } else if (byte >= 192 && byte < 224) {
        result += String.fromCharCode(((byte & 31) << 6) | (bytes[i + 1] & 63))
        i += 2
      } else {
        result += String.fromCharCode(((byte & 15) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63))
        i += 3
      }
    }
    return result
  }
  // 将字符串编码为字节数组（UTF-8）
  function stringToBytes(inputString) {
    const bytes = []
    for (let i = 0; i < inputString.length; i++) {
      const charCode = inputString.charCodeAt(i)
      if (charCode < 128) {
        bytes.push(charCode)
      } else if (charCode < 2048) {
        bytes.push((charCode >> 6) | 192)
        bytes.push((charCode & 63) | 128)
      } else {
        bytes.push((charCode >> 12) | 224)
        bytes.push(((charCode >> 6) & 63) | 128)
        bytes.push((charCode & 63) | 128)
      }
    }
    return bytes
  }

  const NATIVE_EVENTS_NAMES = {
    init: 'init',
    showUpdateAlert: 'showUpdateAlert',
    request: 'request',
    cancelRequest: 'cancelRequest',
    response: 'response',

  }
  const EVENT_NAMES = {
    request: 'request',
    inited: 'inited',
    updateAlert: 'updateAlert',
  }
  const eventNames = Object.values(EVENT_NAMES)
  const events = {
    request: null,
    inited: null,
  }
  const allSources = ['kw', 'kg', 'tx', 'wy', 'mg', 'local']
  const supportQualitys = {
    kw: ['128k', '320k', 'flac', 'flac24bit'],
    kg: ['128k', '320k', 'flac', 'flac24bit'],
    tx: ['128k', '320k', 'flac', 'flac24bit'],
    wy: ['128k', '320k', 'flac', 'flac24bit'],
    mg: ['128k', '320k', 'flac', 'flac24bit'],
    local: [],
  }
  const supportActions = {
    kw: ['musicUrl'],
    kg: ['musicUrl'],
    tx: ['musicUrl'],
    wy: ['musicUrl'],
    mg: ['musicUrl'],
    xm: ['musicUrl'],
    local: ['musicUrl', 'lyric', 'pic'],
  }

  const verifyLyricInfo = (info) => {
    if (typeof info != 'object' || typeof info.lyric != 'string') throw new Error('failed')
    if (info.lyric.length > 51200) throw new Error('failed')
    return {
      lyric: info.lyric,
      tlyric: (typeof info.tlyric == 'string' && info.tlyric.length < 5120) ? info.tlyric : null,
      rlyric: (typeof info.rlyric == 'string' && info.rlyric.length < 5120) ? info.rlyric : null,
      lxlyric: (typeof info.lxlyric == 'string' && info.lxlyric.length < 8192) ? info.lxlyric : null,
    }
  }

  const requestQueue = new Map()
  let isInitedApi = false
  let isShowedUpdateAlert = false
  // Best-effort context propagation for native request logs.
  const requestContextStack = []
  const pushRequestContext = (context) => {
    if (!context || typeof context != 'object') return
    requestContextStack.push(context)
  }
  const popRequestContext = (context) => {
    const index = requestContextStack.lastIndexOf(context)
    if (index >= 0) requestContextStack.splice(index, 1)
  }
  const getCurrentRequestContext = () => requestContextStack[requestContextStack.length - 1] || null

  const sendNativeRequest = (url, options, callback) => {
    const requestKey = Math.random().toString()
    const currentRequestContext = getCurrentRequestContext()
    const requestInfo = {
      aborted: false,
      abort: () => {
        nativeCall(NATIVE_EVENTS_NAMES.cancelRequest, requestKey)
      },
    }
    requestQueue.set(requestKey, {
      callback,
      requestInfo,
    })

    nativeCall(NATIVE_EVENTS_NAMES.request, {
      requestKey,
      url,
      options,
      parentRequestKey: currentRequestContext && typeof currentRequestContext.requestKey == 'string'
        ? currentRequestContext.requestKey
        : undefined,
      requestType: currentRequestContext && typeof currentRequestContext.requestType == 'string'
        ? currentRequestContext.requestType
        : undefined,
    })
    return requestInfo
  }
  const handleNativeResponse = ({ requestKey, error, response }) => {
    const targetRequest = requestQueue.get(requestKey)
    if (!targetRequest) return
    requestQueue.delete(requestKey)
    targetRequest.requestInfo.aborted = true
    // ★★ 2026-10-16 第十一轮实源修复（关键）：权威版会按响应头 content-type
    //   **把 JSON 响应体解析成对象**再交给脚本 —— 大量第三方源（聆澜/玉宁熙/
    //   念心…）直接用 `body.code` / `body.url` 取值，字符串 body 会让它们全部
    //   「unknown error」秒失败（其他平台能播、我们不行）。
    if (error == null && response && typeof response.body == 'string') {
      const responseHeaders = response.headers || {}
      let responseContentType = ''
      for (const k in responseHeaders) {
        if (String(k).toLowerCase() == 'content-type') { responseContentType = String(responseHeaders[k]); break }
      }
      if (/json/i.test(responseContentType)) {
        try { response.body = JSON.parse(response.body) } catch (e) { /* 保留原文 */ }
      }
    }
    if (error == null) targetRequest.callback(null, response)
    else targetRequest.callback(new Error(error), null)
  }

  const handleRequest = ({ requestKey, data }) => {
    // console.log(data)
    if (!events.request) return nativeCall(NATIVE_EVENTS_NAMES.response, { requestKey, status: false, errorMessage: 'Request event is not defined' })
    const requestType = data && data.info && typeof data.info == 'object' && data.info.requestContext && typeof data.info.requestContext.requestType == 'string'
      ? data.info.requestContext.requestType
      : 'current'
    const requestContext = typeof requestKey == 'string'
      ? { requestKey, requestType }
      : null
    const requestInfo = data && data.info && typeof data.info == 'object'
      ? { ...data.info }
      : data.info
    if (requestInfo && typeof requestInfo == 'object') delete requestInfo.requestContext
    if (requestContext) pushRequestContext(requestContext)
    try {
      Promise.resolve(
        events.request.call(globalThis.lx, {
          source: data.source,
          action: data.action,
          info: requestInfo,
        }),
      ).then(response => {
        let result
        switch (data.action) {
          case 'musicUrl':
            if (typeof response != 'string' || response.length > 2048 || !/^https?:/.test(response)) throw new Error('failed')
            result = {
              source: data.source,
              action: data.action,
              data: {
                type: data.info.type,
                url: response,
              },
            }
            break
          case 'lyric':
            result = {
              source: data.source,
              action: data.action,
              data: verifyLyricInfo(response),
            }
            break
          case 'pic':
            if (typeof response != 'string' || response.length > 2048 || !/^https?:/.test(response)) throw new Error('failed')
            result = {
              source: data.source,
              action: data.action,
              data: response,
            }
            break
          case 'musicSearch':
            result = {
              source: data.source,
              action: data.action,
              data: response,
            }
            break
        }
        nativeCall(NATIVE_EVENTS_NAMES.response, { requestKey, status: true, result })
      }).catch(err => {
        // console.log('handleRequest err', err)
        nativeCall(NATIVE_EVENTS_NAMES.response, { requestKey, status: false, errorMessage: err.message })
      }).finally(() => {
        if (requestContext) popRequestContext(requestContext)
      })
    } catch (err) {
      if (requestContext) popRequestContext(requestContext)
      // console.log('handleRequest call err', err)
      nativeCall(NATIVE_EVENTS_NAMES.response, { requestKey, status: false, errorMessage: err.message })
    }
  }

  const jsCall = (action, data) => {
    // console.log('jsCall', action, data)
    switch (action) {
      case '__run_error__':
        if (!isInitedApi) isInitedApi = true
        return
      case '__set_timeout__':
        handleSetTimeout(data)
        return
      case 'request':
        handleRequest(data)
        return
      case 'response':
        handleNativeResponse(data)
        return
    }
    return 'Unknown action: ' + action
  }

  Object.defineProperty(globalThis, '__lx_native__', {
    enumerable: false,
    configurable: false,
    writable: false,
    value: (_key, action, data) => {
      if (key != _key) return 'Invalid key'
      return data == null ? jsCall(action) : jsCall(action, JSON.parse(data))
    },
  })


  /**
   *
   * @param {*} info {
   *                    sources: {
   *                         kw: ['128k', '320k', 'flac', 'flac24bit'],
   *                         kg: ['128k', '320k', 'flac', 'flac24bit'],
   *                         tx: ['128k', '320k', 'flac', 'flac24bit'],
   *                         wy: ['128k', '320k', 'flac', 'flac24bit'],
   *                         mg: ['128k', '320k', 'flac', 'flac24bit'],
   *                     }
   *                 }
   */
  const handleInit = (info) => {
    if (!info) {
      nativeCall(NATIVE_EVENTS_NAMES.init, { info: null, status: false, errorMessage: 'Missing required parameter init info' })
      return
    }
    const sourceInfo = {
      sources: {},
    }
    try {
      for (const source of allSources) {
        const userSource = info.sources[source]
        if (!userSource || userSource.type !== 'music') continue
        const qualitys = supportQualitys[source]
        const actions = supportActions[source]
        sourceInfo.sources[source] = {
          type: 'music',
          actions: actions.filter(a => userSource.actions.includes(a)),
          qualitys: qualitys.filter(q => userSource.qualitys.includes(q)),
        }
      }
    } catch (error) {
      // console.log(error)
      nativeCall(NATIVE_EVENTS_NAMES.init, { info: null, status: false, errorMessage: error.message })
      return
    }
    nativeCall(NATIVE_EVENTS_NAMES.init, { info: sourceInfo, status: true })
    // ★ 2026-10-17：init 上报成功后，回调脚本注册的 inited 处理器
    //   （官方 init 数据形状的超集：openDevTools/env/version/scriptVersion）。
    //   音源脚本的更新自检通常就在这个处理器里跑。
    if (events.inited) {
      setTimeout(() => {
        try {
          events.inited({
            openDevTools: false,
            env: 'mobile',
            version: '2.0.0',
            scriptVersion: version,
          })
        } catch (e) {}
      }, 0)
    }
  }
  const handleShowUpdateAlert = (data, resolve, reject) => {
    if (!data || typeof data != 'object') return reject(new Error('parameter format error.'))
    if (!data.log || typeof data.log != 'string') return reject(new Error('log is required.'))
    if (data.updateUrl && !/^https?:\/\/[^\s$.?#].[^\s]*$/.test(data.updateUrl) && data.updateUrl.length > 1024) delete data.updateUrl
    if (data.log.length > 1024) data.log = data.log.substring(0, 1024) + '...'
    nativeCall(NATIVE_EVENTS_NAMES.showUpdateAlert, { log: data.log, updateUrl: data.updateUrl, name })
    resolve()
  }

  const dataToB64 = (data) => {
    if (typeof data === 'string') return nativeFuncs.utils_str2b64(data)
    else if (Array.isArray(data) || ArrayBuffer.isView(data)) return utils.buffer.bufToString(data, 'base64')
    throw new Error('data type error: ' + typeof data + ' raw data: ' + data)
  }
  const utils = {
    crypto: {
      aesEncrypt(buffer, mode, key, iv) {
        // console.log('aesEncrypt', buffer, mode, key, iv)
        switch (mode) {
          case 'aes-128-cbc':
            return utils.buffer.from(nativeFuncs.utils_aes_encrypt(dataToB64(buffer), dataToB64(key), dataToB64(iv), AES_MODE.CBC_128_PKCS7Padding), 'base64')
          case 'aes-128-ecb':
            return utils.buffer.from(nativeFuncs.utils_aes_encrypt(dataToB64(buffer), dataToB64(key), '', AES_MODE.ECB_128_NoPadding), 'base64')
          default:
            throw new Error('Binary encoding is not supported for input strings')
        }
      },
      rsaEncrypt(buffer, key) {
        // console.log('rsaEncrypt', buffer, key)
        if (typeof key !== 'string') throw new Error('Invalid RSA key')
        key = key.replace(KEY_PREFIX.publicKeyStart, '')
          .replace(KEY_PREFIX.publicKeyEnd, '')
        return utils.buffer.from(nativeFuncs.utils_rsa_encrypt(dataToB64(buffer), key, RSA_PADDING.NoPadding), 'base64')
      },
      randomBytes(size) {
        const byteArray = new Uint8Array(size)
        for (let i = 0; i < size; i++) {
          byteArray[i] = Math.floor(Math.random() * 256) // 随机生成一个字节的值（0-255）
        }
        return byteArray
      },
      md5(str) {
        if (typeof str !== 'string') throw new Error('param required a string')
        const md5 = nativeFuncs.utils_str2md5(encodeURIComponent(str))
        // console.log('md5', str, md5)
        return md5
      },
    },
    buffer: {
      from(input, encoding) {
        // console.log('buffer.from', input, encoding)
        if (typeof input === 'string') {
          switch (encoding) {
            case 'binary':
              throw new Error('Binary encoding is not supported for input strings')
            case 'base64':
              return new Uint8Array(JSON.parse(nativeFuncs.utils_b642buf(input)))
            case 'hex':
              return new Uint8Array(input.match(/.{1,2}/g).map(byte => parseInt(byte, 16)))
            default:
              return new Uint8Array(stringToBytes(input))
          }
        } else if (Array.isArray(input)) {
          return new Uint8Array(input)
        } else {
          throw new Error('Unsupported input type: ' + input + ' encoding: ' + encoding)
        }
      },
      bufToString(buf, format) {
        // console.log('buffer.bufToString', buf, format)
        if (Array.isArray(buf) || ArrayBuffer.isView(buf)) {
          switch (format) {
            case 'binary':
              // return new TextDecoder('latin1').decode(new Uint8Array(buf))
              return buf
            case 'hex':
              return new Uint8Array(buf).reduce((str, byte) => str + byte.toString(16).padStart(2, '0'), '')
            case 'base64':
              return nativeFuncs.utils_str2b64(bytesToString(Array.from(buf)))
            case 'utf8':
            case 'utf-8':
            default:
              return bytesToString(Array.from(buf))
          }
        } else {
          throw new Error('Input is not a valid buffer: ' + buf + ' format: ' + format)
        }
      },
    },

  }

  globalThis.lx = {
    EVENT_NAMES,
    request(url, { method = 'get', timeout, headers, body, form, formData, binary }, callback) {
      let options = { headers, binary: binary === true }
      if (timeout && typeof timeout == 'number' && timeout > 0) options.timeout = Math.min(timeout, 60_000)

      let request = sendNativeRequest(url, { method, body, form, formData, ...options }, (err, resp) => {
        if (err) {
          callback(err, null, null)
        } else {
          callback(err, {
            statusCode: resp.statusCode,
            statusMessage: resp.statusMessage,
            headers: resp.headers,
            body: resp.body,
          }, resp.body)
        }
      })

      return () => {
        if (!request.aborted) request.abort()
        request = null
      }
    },
    send(eventName, data) {
      return new Promise((resolve, reject) => {
        if (!eventNames.includes(eventName)) return reject(new Error('The event is not supported: ' + eventName))
        switch (eventName) {
          case EVENT_NAMES.inited:
            if (isInitedApi) return reject(new Error('Script is inited'))
            isInitedApi = true
            handleInit(data)
            resolve()
            break
          case EVENT_NAMES.updateAlert:
            if (isShowedUpdateAlert) return reject(new Error('The update alert can only be called once.'))
            isShowedUpdateAlert = true
            handleShowUpdateAlert(data, resolve, reject)
            break
          default:
            reject(new Error('Unknown event name: ' + eventName))
        }
      })
    },
    on(eventName, handler) {
      if (!eventNames.includes(eventName)) return Promise.reject(new Error('The event is not supported: ' + eventName))
      switch (eventName) {
        case EVENT_NAMES.request:
          events.request = handler
          break
        case EVENT_NAMES.inited:
          // ★ 2026-10-17：官方 lx-music-mobile 支持 —— 音源脚本把更新自检等
          //   初始化后逻辑注册在这里；此前我们 reject 导致脚本在该行崩溃。
          events.inited = handler
          break
        default: return Promise.reject(new Error('The event is not supported: ' + eventName))
      }
      return Promise.resolve()
    },
    utils,
    currentScriptInfo: {
      name,
      description,
      version,
      author,
      homepage,
      rawScript,
    },
    version: '2.0.0',
    env: 'mobile',
  }
  // 兼容部分脚本使用 lxu 命名（早期 lx-music-mobile 内部 API 名）
  globalThis.lxu = globalThis.lx

  // MARK: 宿主缺失的 Web 全局（JavaScriptCore 裸环境没有这些，脚本却大量依赖）
  //
  // LX 音源脚本普遍直接调用 `fetch(url, options)` 发请求（RN 端由 RN runtime 提供
  // 全局 fetch；JSC 里没有 → 脚本一执行到取链就抛 "fetch is not defined" / 上层表现为
  // "musicUrl is not a function"）。这里全部补齐，fetch 走 lx.request → 原生 URLSession。

  // btoa / atob（latin1）
  if (typeof globalThis.btoa != 'function') {
    globalThis.btoa = (input) => {
      const str = String(input)
      let binary = ''
      for (let i = 0; i < str.length; i++) binary += String.fromCharCode(str.charCodeAt(i) & 0xff)
      return nativeFuncs.utils_str2b64(binary)
    }
  }
  if (typeof globalThis.atob != 'function') {
    globalThis.atob = (input) => {
      const bytes = JSON.parse(nativeFuncs.utils_b642buf(String(input)))
      let out = ''
      for (let i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i])
      return out
    }
  }

  // TextEncoder / TextDecoder（脚本用它们做 UTF-8 ↔ 字节）
  if (typeof globalThis.TextEncoder != 'function') {
    globalThis.TextEncoder = function TextEncoder() {}
    globalThis.TextEncoder.prototype.encode = function (str) {
      const utf8 = unescape(encodeURIComponent(String(str)))
      const bytes = new Uint8Array(utf8.length)
      for (let i = 0; i < utf8.length; i++) bytes[i] = utf8.charCodeAt(i)
      return bytes
    }
    globalThis.TextEncoder.prototype.encodeInto = function (str, dest) {
      const bytes = this.encode(str)
      const n = Math.min(bytes.length, dest.length)
      for (let i = 0; i < n; i++) dest[i] = bytes[i]
      return { read: String(str).length, written: n }
    }
  }
  if (typeof globalThis.TextDecoder != 'function') {
    globalThis.TextDecoder = function TextDecoder(encoding) { this.encoding = encoding || 'utf-8' }
    globalThis.TextDecoder.prototype.decode = function (buffer) {
      if (buffer == null) return ''
      const bytes = ArrayBuffer.isView(buffer) ? new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength) : new Uint8Array(buffer)
      let utf8 = ''
      for (let i = 0; i < bytes.length; i++) utf8 += String.fromCharCode(bytes[i])
      try { return decodeURIComponent(escape(utf8)) } catch (e) { return utf8 }
    }
  }

  // fetch：把 WHATWG fetch 语义桥接到 lx.request（原生 URLSession）。
  // 支持 fetch(url, {method, headers, body}) → Response{ok,status,statusText,headers,text(),json()}
  if (typeof globalThis.fetch != 'function') {
    const _fetch = (input, init) => {
      const url = typeof input == 'string' ? input : (input && input.url) || String(input)
      const options = init || {}
      const method = (options.method || 'GET').toLowerCase()
      // body 归一化：字符串直接发；URLSearchParams/对象转 query 或 JSON
      let body = options.body
      const headers = options.headers || {}
      let contentType = ''
      if (headers) {
        if (typeof headers.forEach == 'function' && !Array.isArray(headers)) {
          headers.forEach((v, k) => { if (String(k).toLowerCase() == 'content-type') contentType = v })
        } else {
          for (const k of Object.keys(headers)) {
            if (String(k).toLowerCase() == 'content-type') contentType = headers[k]
          }
        }
      }
      let form
      if (body != null && typeof body != 'string') {
        if (typeof URLSearchParams != 'undefined' && body instanceof URLSearchParams) {
          form = {}
          body.forEach((v, k) => { form[k] = v })
          body = undefined
          if (!contentType) contentType = 'application/x-www-form-urlencoded'
        } else {
          body = JSON.stringify(body)
          if (!contentType) contentType = 'application/json'
        }
      }
      const finalHeaders = Object.assign({}, headers)
      if (contentType && !finalHeaders['Content-Type'] && !finalHeaders['content-type']) {
        finalHeaders['Content-Type'] = contentType
      }
      return new Promise((resolve, reject) => {
        globalThis.lx.request(url, {
          method: method.toUpperCase(),
          headers: finalHeaders,
          body,
          form,
        }, (err, resp) => {
          if (err) { reject(err); return }
          const rawBody = resp.body
          const responseHeaders = resp.headers || {}
          resolve({
            ok: resp.statusCode >= 200 && resp.statusCode < 300,
            status: resp.statusCode,
            statusText: resp.statusMessage || '',
            url,
            headers: {
              get: (name) => {
                const key = Object.keys(responseHeaders).find(k => k.toLowerCase() == String(name).toLowerCase())
                return key ? responseHeaders[key] : null
              },
            },
            text: () => Promise.resolve(typeof rawBody == 'string' ? rawBody : ''),
            json: () => new Promise((res, rej) => {
              try { res(JSON.parse(rawBody)) } catch (e) { rej(e) }
            }),
          })
        })
      })
    }
    globalThis.fetch = _fetch

    // ★ 2026-10-17 用户音源（Well四大平台聚合 v2.9.7）实测：脚本的更新自检用的是
    //   **全局 `request(url, options, callback)`**（洛雪官方为脚本提供的旧式 HTTP API，
    //   不是 lx.request）。此前我们没有这个全局 → checkUpdate() 一执行就
    //   ReferenceError，被脚本自己的 try/catch 吞掉 → 永远没有更新提示。
    //   官方签名：callback(err, resp, body)，resp = { statusCode, statusMessage,
    //   headers, body }；返回 { abort() }。
    if (typeof globalThis.request != 'function') {
      globalThis.request = (url, options, callback) => {
        const opts = options || {}
        const cb = typeof options === 'function' ? options : callback
        const realOpts = typeof options === 'function' ? {} : opts
        try {
          return globalThis.lx.request(url, realOpts, (err, resp, body) => {
            if (typeof cb === 'function') cb(err, resp, body)
          })
        } catch (e) {
          if (typeof cb === 'function') cb(e, null, null)
          return { abort() {} }
        }
      }
    }
  }

  globalThis.setTimeout = _setTimeout
  globalThis.clearTimeout = _clearTimeout

  const freezeObject = (obj) => {
    if (typeof obj != 'object') return
    Object.freeze(obj)
    for (const subObj of Object.values(obj)) freezeObject(subObj)
  }
  freezeObject(globalThis.lx)

  const _toString = Function.prototype.toString
  // eslint-disable-next-line no-extend-native
  Function.prototype.toString = function() {
    return Object.getOwnPropertyDescriptors(this).name.configurable
      ? _toString.apply(this)
      : `function ${this.name}() { [native code] }`
  }
  // eslint-disable-next-line no-eval
  globalThis.eval = function() {
    throw new Error('eval is not available')
  }
  const proxyFunctionConstructor = new Proxy(Function.prototype.constructor, {
    apply() {
      throw new Error('Dynamic code execution is not allowed.')
    },
    construct() {
      throw new Error('Dynamic code execution is not allowed.')
    },
  })
  // eslint-disable-next-line no-extend-native
  Object.defineProperty(Function.prototype, 'constructor', {
    value: proxyFunctionConstructor,
    writable: false,
    configurable: false,
    enumerable: false,
  })
  globalThis.Function = proxyFunctionConstructor

  const excludes = [
    Function.prototype.toString,
    Function.prototype.toLocaleString,
    Object.prototype.toString,
  ]
  const freezeObjectProperty = (obj, freezedObj = new Set()) => {
    if (obj == null) return
    switch (typeof obj) {
      case 'object':
      case 'function':
        if (freezedObj.has(obj)) return
        // Object.freeze(obj)
        freezedObj.add(obj)
        for (const [name, { ...config }] of Object.entries(Object.getOwnPropertyDescriptors(obj))) {
          if (!excludes.includes(config.value)) {
            if (config.writable) config.writable = false
            if (config.configurable) config.configurable = false
            Object.defineProperty(obj, name, config)
          }
          freezeObjectProperty(config.value, freezedObj)
        }
    }
  }
  freezeObjectProperty(globalThis)

  console.log('Preload finished.')
}
"""#
}