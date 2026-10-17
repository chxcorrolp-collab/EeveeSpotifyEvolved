import Foundation
import CommonCrypto

// MARK: - NeteaseLyricsRepository
//
// 网易云音乐歌词源（直连 weapi）。
//
// ── 为什么直连可行 ──────────────────────────────────────────────────────────
// music.163.com 的 weapi 接口要求每个请求体携带 params / encSecKey 两个
// 加密字段，但整套加密是「无状态」的：AES 密钥、IV 与 RSA 公钥都是全网
// 写死的常量，不涉及任何用户身份，因此无需像 Musixmatch 那样要求用户
// 提供 token。实测 2026 年当前状态下，搜索（search/get）与歌词
// （song/lyric）接口仅需 `Cookie: os=pc` 即可匿名访问；
// register/anonimous 匿名注册接口已废弃（返回「参数错误」），不再调用。
// 若响应下发会话 cookie 会自动持久化并随后续请求携带。
//
// ── weapi 加密流程（与 NeteaseCloudMusicApi/util/crypto.js 一致）───────
// 1. 随机 16 字符 secKey；
// 2. params = AES-CBC(明文, key="0CoJUm6Qyw8W8jud", iv="0102030405060708")，
//    再对结果用 key=secKey 加密一次，两次结果均做 base64；
// 3. encSecKey = hex( rawRSA( reverse(secKey), e=65537, 固定 1024 位模数 ) )，
//    左补零到 256 个 hex 字符。这里的 RSA 是无填充的原始模幂（m^e mod n），
//    与 JS 端 BigInt.powMod 等价。
//
// ── 失败兜底 ───────────────────────────────────────────────────────────────
// 本仓库的请求失败/查无此歌统一抛 LyricsError，由 CustomLyrics.x.swift 的
// 既有回退逻辑（geniusFallback 等）接管；本文件不参与多级回退编排。

class NeteaseLyricsRepository: LyricsRepository {

    static let shared = NeteaseLyricsRepository()

    /// 「NetEase 交叉验证」开关的生效状态**每次启动只记一行**。
    ///
    /// 为什么要这一行：验证只在"低置信度候选"上触发，正常播放时一条 `verify` 日志都不会有 ——
    /// 那就没法从日志判断"开关到底开上了没有"。把这句钉在第一次取词上，一行解决。
    /// ⚠️ 写成 `private static var`（不是 `private(set) static var`）：`swift_member_check.py`
    /// 的成员正则不认 `private(set)` 这种括号写法，会把它判成"类里没有这个成员"。
    private static var didLogCrossValidationState = false

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }

    private let session: URLSession

    private class CachedLyrics {
        let dto: LyricsDto

        init(dto: LyricsDto) {
            self.dto = dto
        }
    }

    private let lyricsCache = NSCache<NSString, CachedLyrics>()

    // MARK: - 常量

    private static let weapiBaseUrl = "https://music.163.com"
    private static let aesFirstKey = "0CoJUm6Qyw8W8jud"
    private static let aesIv = "0102030405060708"
    private static let eapiKey = "e82ckenh8dichen8"

    /// weapi 固定 RSA 公钥模数（1024 位，hex，无前导 00）。
    private static let rsaModulusHex =
        "e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725" +
        "152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e031" +
        "2ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b4" +
        "24d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a2" +
        "2b8e7"

    private static let rsaExponent = 65537

    /// 响应下发的 cookie 持久化（部分接口会返回会话 cookie，留作复用）。
    private static let anonymousCookieKey = "ngzhwm_neteaseAnonymousCookie"

    private var anonymousCookie: String {
        get { UserDefaults.standard.string(forKey: Self.anonymousCookieKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.anonymousCookieKey) }
    }

    /// 从匿名 cookie 里提取 __csrf，作为 weapi 请求的 csrf_token。
    private var csrfToken: String {
        let cookie = anonymousCookie
        guard let match = cookie.firstMatch("__csrf=([^;]+)"),
              let tokenRange = Range(match.range(at: 1), in: cookie) else {
            return ""
        }
        return String(cookie[tokenRange])
    }

    // MARK: - weapi 加密

    /// AES-128-CBC + PKCS7（密钥为 16 字节 UTF-8 字符串，IV 固定）。
    private func aesCbcEncrypt(_ data: Data, key: String) -> Data? {
        guard let keyData = key.data(using: .utf8),
              let ivData = Self.aesIv.data(using: .utf8) else {
            return nil
        }

        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var bytesEncrypted = 0

        let status: CCCryptorStatus = buffer.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                keyData.withUnsafeBytes { keyBytes in
                    ivData.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, keyData.count,
                            ivBytes.baseAddress,
                            inBytes.baseAddress, data.count,
                            outBytes.baseAddress, bufferSize,
                            &bytesEncrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return buffer.prefix(bytesEncrypted)
    }

    /// AES-128-ECB + PKCS7（eapi 用，无 IV）。
    private func aesEcbEncrypt(_ data: Data, key: String) -> Data? {
        guard let keyData = key.data(using: .utf8) else { return nil }

        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var bytesEncrypted = 0

        let status: CCCryptorStatus = buffer.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                keyData.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        keyBytes.baseAddress, keyData.count,
                        nil,
                        inBytes.baseAddress, data.count,
                        outBytes.baseAddress, bufferSize,
                        &bytesEncrypted
                    )
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return buffer.prefix(bytesEncrypted)
    }

    /// Data → 小写 hex（eapi params 用；与 weapi 的 base64 不同）。
    private func hexString(_ data: Data) -> String {
        let hexTable = Array("0123456789abcdef".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count * 2)
        for byte in data {
            bytes.append(hexTable[Int(byte) >> 4])
            bytes.append(hexTable[Int(byte) & 0xF])
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private func md5Hex(_ text: String) -> String {
        guard let data = text.data(using: .utf8) else { return "" }
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            digest.withUnsafeMutableBytes { md in
                _ = CC_MD5(
                    raw.baseAddress,
                    CC_LONG(data.count),
                    md.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }
        return hexString(Data(digest))
    }

    /// eapi 参数加密（/api/song/lyric/v1 等新接口）：
    /// params = hex( AES-128-ECB( url + "-36cd479b6b5-" + JSON + "-36cd479b6b5-" + md5("nobody"+url+"use"+JSON+"md5forencrypt") ) )
    private func eapiEncrypt(_ params: [String: Any], url: String) -> String? {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: params),
              let text = String(data: bodyData, encoding: .utf8) else {
            return nil
        }

        let message = "nobody\(url)use\(text)md5forencrypt"
        let digest = md5Hex(message)
        let data = "\(url)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)"

        guard let cipher = aesEcbEncrypt(Data(data.utf8), key: Self.eapiKey) else {
            return nil
        }
        return hexString(cipher)
    }

    /// 生成 (params, encSecKey)，与网易前端 weapi 加密等价。
    private func weapiEncrypt(_ text: String) throws -> (params: String, encSecKey: String) {
        let secKeyCharacters =
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let secKey = String((0..<16).compactMap { _ in secKeyCharacters.randomElement() })

        // 与官网前端 asrsea / darknessomi 版一致的双层 AES 链：
        // 第二轮加密的输入必须是第一轮的 base64 文本（而非密文字节）。
        // 若传密文字节，服务器解密流程对不上，返回 HTTP 200 + 空 body。
        guard let firstPass = aesCbcEncrypt(Data(text.utf8), key: Self.aesFirstKey) else {
            writeDebugLog("[NetEase] weapiEncrypt AES failure")
            throw LyricsError.decodingError
        }
        let firstPassBase64 = firstPass.base64EncodedString()
        guard let secondPass = aesCbcEncrypt(Data(firstPassBase64.utf8), key: secKey) else {
            writeDebugLog("[NetEase] weapiEncrypt AES failure")
            throw LyricsError.decodingError
        }
        let params = secondPass.base64EncodedString()

        // encSecKey = hex(reverse(secKey) 作为大整数 ^ 65537 mod modulus)，左补零到 256 hex。
        // 手动 hex 表（避免 String(format:) 变参在设备端的类型歧义）。
        let hexTable = Array("0123456789abcdef".utf8)
        var reversedKeyHex = ""
        for byte in String(secKey.reversed()).utf8 {
            reversedKeyHex.append(Character(UnicodeScalar(hexTable[Int(byte) >> 4])))
            reversedKeyHex.append(Character(UnicodeScalar(hexTable[Int(byte) & 0xF])))
        }

        guard let message = NeteaseBigUInt(hex: reversedKeyHex),
              let modulus = NeteaseBigUInt(hex: Self.rsaModulusHex) else {
            writeDebugLog("[NetEase] weapiEncrypt hex parse failure: \(reversedKeyHex)")
            throw LyricsError.decodingError
        }

        let cipher = NeteaseBigUInt.powMod(
            base: message,
            exponent: NeteaseBigUInt(limbs: [UInt64(Self.rsaExponent)]),
            modulus: modulus
        )

        return (params, cipher.hexString(paddedTo: 256))
    }

    // MARK: - 网络

    private func performWeapi(_ path: String, params: [String: Any]) throws -> Data {
        var weapiParams = params
        weapiParams["csrf_token"] = csrfToken

        let bodyText: String
        do {
            let bodyData = try JSONSerialization.data(withJSONObject: weapiParams)
            guard let text = String(data: bodyData, encoding: .utf8) else {
                throw LyricsError.decodingError
            }
            bodyText = text
        } catch let encodingError {
            writeErrorLog("[NetEase] weapi JSONSerialization failure: \(encodingError)")
            throw LyricsError.decodingError
        }

        let (encryptedParams, encSecKey) = try weapiEncrypt(bodyText)

        let csrf = csrfToken
        guard let url = URL(string: "\(Self.weapiBaseUrl)\(path)?csrf_token=\(csrf)") else {
            writeDebugLog("[NetEase] Invalid URL for \(path), csrf=\(csrf)")
            throw LyricsError.decodingError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        var cookie = "os=pc"
        let savedCookie = anonymousCookie
        if !savedCookie.isEmpty {
            cookie += "; " + savedCookie
        }
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        // 手动拼 form body 并 percent-encode：不能用 URLComponents，
        // 它按 RFC 3986 不编码 query 中的 + / =，而 base64 恰好含这三个字符，
        // 会导致 + 被服务器当成空格、= 被当成键值分隔符，base64 在传输中损坏
        // （服务器解密失败 → 返回空 body）。
        let allowedQueryCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        )
        let encodedParams = encryptedParams.addingPercentEncoding(
            withAllowedCharacters: allowedQueryCharacters
        ) ?? encryptedParams
        let encodedSecKey = encSecKey.addingPercentEncoding(
            withAllowedCharacters: allowedQueryCharacters
        ) ?? encSecKey
        let bodyString = "params=\(encodedParams)&encSecKey=\(encodedSecKey)"
        request.httpBody = bodyString.data(using: .utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        var statusCode = 0
        var responseCookie: String?

        let task = session.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
                if let headers = http.allHeaderFields as? [String: String] {
                    let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
                    if !cookies.isEmpty {
                        responseCookie = cookies
                            .map { "\($0.name)=\($0.value)" }
                            .joined(separator: "; ")
                    }
                }
            }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 12) == .timedOut {
            task.cancel()
            throw LyricsError.unknownError
        }

        if let error = responseError {
            throw error
        }

        guard statusCode == 200 else {
            let body = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            writeDebugLog("[NetEase] Non-200 status \(statusCode) for \(path): \(body.prefix(200))")
            throw LyricsError.unknownError
        }

        guard let data = responseData else {
            writeDebugLog("[NetEase] Empty response data for \(path)")
            throw LyricsError.decodingError
        }

        if let cookieValue = responseCookie, !cookieValue.isEmpty {
            anonymousCookie = cookieValue
        }

        return data
    }

    /// eapi 请求：form 只有一个 params 字段（hex，无 encSecKey），
    /// 地址把 /api/ 换成 /eapi/，加密里的 url 仍用 /api/。
    private func performEapi(_ path: String, params: [String: Any]) throws -> Data {
        var eapiParams = params
        eapiParams["csrf_token"] = csrfToken

        guard let encryptedParams = eapiEncrypt(eapiParams, url: path) else {
            writeDebugLog("[NetEase] eapiEncrypt failure for \(path)")
            throw LyricsError.decodingError
        }

        let eapiPath = path.replacingOccurrences(of: "/api/", with: "/eapi/")
        let csrf = csrfToken
        guard let url = URL(string: "\(Self.weapiBaseUrl)\(eapiPath)?csrf_token=\(csrf)") else {
            writeDebugLog("[NetEase] Invalid eapi URL for \(path)")
            throw LyricsError.decodingError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        var cookie = "os=pc"
        let savedCookie = anonymousCookie
        if !savedCookie.isEmpty {
            cookie += "; " + savedCookie
        }
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        let bodyString = "params=\(encryptedParams)"
        request.httpBody = bodyString.data(using: .utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        var statusCode = 0
        var responseCookie: String?

        let task = session.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
                if let headers = http.allHeaderFields as? [String: String] {
                    let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
                    if !cookies.isEmpty {
                        responseCookie = cookies
                            .map { "\($0.name)=\($0.value)" }
                            .joined(separator: "; ")
                    }
                }
            }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 12) == .timedOut {
            task.cancel()
            throw LyricsError.unknownError
        }

        if let error = responseError {
            throw error
        }

        guard statusCode == 200 else {
            let body = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            writeDebugLog("[NetEase] Non-200 eapi status \(statusCode) for \(path): \(body.prefix(200))")
            throw LyricsError.unknownError
        }

        guard let data = responseData else {
            writeDebugLog("[NetEase] Empty eapi response data for \(path)")
            throw LyricsError.decodingError
        }

        if let cookieValue = responseCookie, !cookieValue.isEmpty {
            anonymousCookie = cookieValue
        }

        return data
    }

    // MARK: - 接口

    /// 搜索走老接口 /weapi/search/get：cloudsearch/get/web 已被网易风控
    /// （固定返回 code 50000005），实测老接口带 os=pc cookie 即可匿名使用。
    private func searchSongs(keyword: String) throws -> [[String: Any]] {
        let data = try performWeapi("/weapi/search/get", params: [
            "s": keyword,
            "type": 1,
            // ★ 2026-10-17：30 → **100**。网易的搜索排序按地区变（日志 108：日本 IP 下
            // 正确的 `ヒミツ — MIMI` 掉出前 30，兜底就选了 `Thank You — Royal 44`）。
            // 100 是 weapi 搜索的常用上限；多出来的结果由下面的"标题+歌手+时长"三重闸门筛。
            "limit": 100,
            "offset": 0,
        ])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            writeDebugLog("[NetEase] Search response malformed for \"\(keyword)\": \(body.prefix(300))")
            throw LyricsError.decodingError
        }

        return songs
    }

    private func fetchLyricsRaw(songId: Int) throws -> (lrc: String?, tlyric: String?, romalrc: String?) {
        // os/rv 两个参数控制 romalrc（官方日语罗马音）是否下发，参考 Lyricify-Lyrics-Helper。
        let data = try performWeapi("/weapi/song/lyric", params: [
            "id": songId,
            "os": "pc",
            "lv": -1,
            "kv": -1,
            "tv": -1,
            "rv": -1,
        ])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LyricsError.decodingError
        }

        guard (json["code"] as? Int ?? 200) == 200 else {
            throw LyricsError.noSuchSong
        }

        let lrc = (json["lrc"] as? [String: Any])?["lyric"] as? String
        let tlyric = (json["tlyric"] as? [String: Any])?["lyric"] as? String
        let romalrc = (json["romalrc"] as? [String: Any])?["lyric"] as? String
        return (lrc, tlyric, romalrc)
    }

    /// 逐字（yrc）走新接口 /api/song/lyric/v1（eapi 加密）；
    /// 老 weapi /weapi/song/lyric 不下发 yrc。
    /// 返回 (yrc, ytlrc)：ytlrc 是逐字歌词配套的翻译 LRC，行 offset 与 yrc 行头
    /// 一一对应（tlyric 与 lrc 同源、和 yrc 行头不是一套时间轴，无法精确对齐）。
    private func fetchYrcRaw(songId: Int) throws -> (yrc: String?, ytlrc: String?) {
        let data = try performEapi("/api/song/lyric/v1", params: [
            "id": songId,
            "cp": false,
            "tv": -1,
            "lv": -1,
            "rv": -1,
            "kv": -1,
            "yv": -1,
            "ytv": -1,
            "yrv": -1,
        ])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LyricsError.decodingError
        }
        guard (json["code"] as? Int ?? 200) == 200 else {
            throw LyricsError.noSuchSong
        }

        let yrc = (json["yrc"] as? [String: Any])?["lyric"] as? String
        let ytlrc = (json["ytlrc"] as? [String: Any])?["lyric"] as? String
        writeDebugLog("[NetEase] eapi /api/song/lyric/v1 → yrc \(yrc == nil ? "absent" : "\(yrc!.count) chars"), ytlrc \(ytlrc == nil ? "absent" : "\(ytlrc!.count) chars")")
        if let yrc {
            writeDebugLog("[NetEase] yrc raw head: \(yrc.prefix(600))")
        }
        return (yrc, ytlrc)
    }

    private func songId(from song: [String: Any]) -> Int? {
        if let value = song["id"] as? Int { return value }
        if let value = song["id"] as? Int64 { return Int(value) }
        return nil
    }

    // MARK: - LRC 解析

    /// 过滤网易 LRC 里「作词 : XXX」这类歌曲制作信息行。
    private static let creditLinePattern =
        "^\\s*(作词|作曲|编曲|制作人|制作助理|混音|混音师|母带|母带工程师|录音|录音师|" +
        "监制|和声|和音|吉他|贝斯|鼓|键盘|钢琴|小提琴|大提琴|弦乐|制作|出品|发行|" +
        "配唱|统筹|企划|推广|文案|摄影|封面|导演|经纪人|" +
        "Program|Programming|Vocal|Lyrics|Composer|Arranger|Producer|" +
        "Recorded|Mixed|Mastered)\\s*[:：]"

    private func isCreditLine(_ content: String) -> Bool {
        content ~= Self.creditLinePattern
    }

    /// 是否为 ♪ 间奏行：空行，或整行只有 ♪ 符号（含多个 ♪ / 前后空白）。
    ///
    /// 两个用途：
    ///   ① **丢弃**间奏行的判据 —— 用户拍板 A「把原本有的间奏全部删掉」，无条件生效
    ///      （见下面两处 `.filter { !isInterludeRow(...) }`）；
    ///   ② 翻译错位修复时「哪一行算间奏」的判定。
    ///
    /// ⚠️ 2026-10-18：它不再与任何开关有关。原先那对
    /// `shouldRemoveInterludeSymbol`（读 `ngzhwm_removeMxmInterludeSymbol`）与
    /// `cleanedInterludeSymbol`（把含 ♪ 的行清成空白）**已随开关一起删除** ——
    /// 开关开着关着结果一样，留着就是编译错与"按了没反应"的空壳。
    private func isInterludeRow(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.allSatisfy { $0 == "♪" }
    }

    /// 把 LRC 文本解析成 (offsetMs, content)，丢弃非时间戳行与制作信息行。
    /// 网易 LRC 的时间戳混用两种厘秒分隔符：[mm:ss.xx] 与 [mm:ss:xx]，
    /// 且重复段落会合并成一行多时间戳（如 [00:01.00][00:02.00]歌词），
    /// 每个时间戳都拆成独立一行，避免时间戳混进正文显示。
    private func parseLrc(_ text: String) -> [(offsetMs: Int, content: String)] {
        var parsed: [(offsetMs: Int, content: String)] = []

        let timestampPattern = "\\[(?<minute>\\d*):(?<seconds>\\d+(?:[.:]\\d+)?)\\]"
        guard let regex = try? NSRegularExpression(pattern: timestampPattern) else {
            return parsed
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let nsLine = line as NSString

            let matches = regex.matches(
                in: line,
                range: NSRange(location: 0, length: nsLine.length)
            )
            guard let lastMatch = matches.last else { continue }

            // 正文 = 最后一个时间戳之后的内容
            let lastRange = lastMatch.range
            let content = nsLine.substring(from: lastRange.location + lastRange.length)
                .trimmingCharacters(in: .whitespaces)
            guard !isCreditLine(content) else { continue }
            guard !LyricsMarkerFilter.isNonLyricLine(content) else { continue }

            // 每个时间戳拆成独立一行（相同正文、不同 offset）
            for match in matches {
                let minuteRange = match.range(withName: "minute")
                let secondsRange = match.range(withName: "seconds")
                guard minuteRange.location != NSNotFound,
                      secondsRange.location != NSNotFound else {
                    continue
                }

                guard let minute = Int(nsLine.substring(with: minuteRange)),
                      let seconds = Double(
                          nsLine.substring(with: secondsRange)
                              .replacingOccurrences(of: ":", with: ".")
                      ) else {
                    continue
                }

                // Double + rounded()：Float32 会把 34.010 算成 34009.998 再截断为 34009，
                // 与 yrc 行头的精确毫秒 34010 对不上，导致逐字翻译按 offset 对齐落空。
                parsed.append((minute * 60 * 1000 + Int((seconds * 1000).rounded()), content))
            }
        }

        return parsed
    }

    /// 解析网易逐字（yrc）格式：`[起始,时长](起始,时长,标志)词(起始,时长,标志)词...`，
    /// 时间单位均为毫秒；行头第二个数字是持续时长，词括号第三个数字是标志位（忽略）。
    /// 返回 (行偏移, 行正文, 词级时间轴)。
    private func parseYrc(_ text: String) -> [(offsetMs: Int, content: String, words: [LyricsWordDto])] {
        var parsed: [(offsetMs: Int, content: String, words: [LyricsWordDto])] = []

        let linePattern = "^\\[(\\d+),(\\d+)\\]"
        let wordPattern = "\\((\\d+),(\\d+)(?:,\\d+)?\\)([^\\(]*)"

        guard let lineRegex = try? NSRegularExpression(pattern: linePattern),
              let wordRegex = try? NSRegularExpression(pattern: wordPattern) else {
            writeDebugLog("[NetEase] yrc regex compile failed")
            return parsed
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let nsLine = line as NSString

            guard
                let lineMatch = lineRegex.firstMatch(
                    in: line,
                    options: [],
                    range: NSRange(location: 0, length: nsLine.length)
                ),
                lineMatch.numberOfRanges >= 3,
                let startMs = Int(nsLine.substring(with: lineMatch.range(at: 1)))
            else {
                continue
            }

            let headerLength = lineMatch.range(at: 0).location + lineMatch.range(at: 0).length
            let rest = nsLine.substring(from: headerLength) as NSString

            var words: [LyricsWordDto] = []
            var content = ""
            let wordMatches = wordRegex.matches(
                in: rest as String,
                options: [],
                range: NSRange(location: 0, length: rest.length)
            )
            for wordMatch in wordMatches {
                guard wordMatch.numberOfRanges >= 4,
                      let wordStart = Int(rest.substring(with: wordMatch.range(at: 1))),
                      let wordDuration = Int(rest.substring(with: wordMatch.range(at: 2))) else {
                    continue
                }
                let wordText = rest.substring(with: wordMatch.range(at: 3))
                content += wordText
                words.append(
                    LyricsWordDto(text: wordText, startMs: wordStart, endMs: wordStart + wordDuration)
                )
            }

            guard !content.isEmpty else { continue }
            // 过滤制作信息行（「编曲 : TOKOTOKO」这类 yrc 行头 credit 行），
            // 与 parseLrc 的 isCreditLine 过滤保持一致；否则会出现在歌词第一行。
            guard !isCreditLine(content) else { continue }
            guard !LyricsMarkerFilter.isNonLyricLine(content) else { continue }
            parsed.append((offsetMs: startMs, content: content, words: words))
        }

        // ★★ 2026-10-17（用户：网易云逐词**时间轴错乱 / 字数错误**，且"今天或昨天才出现"）：
        //
        // 现在判不了，因为唯一能看到结构的那一行 `[NetEase] yrc raw head:` **被脱敏器整段藏掉了**
        // （里面是歌词正文）。⇒ 这里只打**数字**，一个歌词字都不带：
        //   · `offset` = 行头起点；`words` = 这一行几个词；
        //   · `monotonic` = 词起点是否单调不减（不是 ⇒ 时间轴必然乱跳）；
        //   · `beforeLine` = 有多少词起点**早于行头**（>0 ⇒ 网易给的是"行内相对时间"，
        //     而我们当绝对时间用了 —— 那正好会让整行的高亮挤在行首、后面不动）；
        //   · `head` = 前三个词的 `start-end` 毫秒。
        if let first = parsed.first {
            let starts = first.words.map(\.startMs)
            let monotonic = zip(starts, starts.dropFirst()).allSatisfy { $0 <= $1 }
            let beforeLine = starts.filter { $0 < first.offsetMs }.count
            let head = first.words.prefix(3)
                .map { "\($0.startMs)-\($0.endMs ?? -1)" }
                .joined(separator: ",")
            writeDebugLog(
                "[NetEase] yrc shape — line0 offset=\(first.offsetMs) words=\(first.words.count)"
                    + " monotonic=\(monotonic) beforeLine=\(beforeLine) head=\(head)"
            )
        }

        writeDebugLog("[NetEase] yrc parsed \(parsed.count) line(s)")
        return parsed
    }

    // MARK: - 翻译对齐

    /// tlyric 与原 lrc 按时间戳对齐；没有对应翻译的行填空串，
    /// 保证翻译行数与主歌词行数一致（Spotify 按行展示翻译层）。
    private func buildTranslation(
        _ tlyric: String,
        originalLines: [LyricsLineDto]
    ) -> LyricsTranslationDto? {
        let parsed = parseLrc(tlyric)
        guard !parsed.isEmpty else { return nil }

        var translationByOffset: [Int: String] = [:]
        for entry in parsed {
            if translationByOffset[entry.offsetMs] == nil, !entry.content.isEmpty {
                translationByOffset[entry.offsetMs] = entry.content
            }
        }

        var translatedLines: [String] = []
        var matchedCount = 0

        for line in originalLines {
            guard let offset = line.offsetMs, let translated = translationByOffset[offset] else {
                translatedLines.append("")
                continue
            }
            // 翻译里 ♪ 单独作为一行的，清成空白（保持行数对齐）——
            // ★ 2026-10-18：原先由「删除间奏符号 ♪」开关控制，那颗开关已退役，
            //   这里与主歌词同一条纪律：**无条件**处理。
            if translated.trimmingCharacters(in: .whitespaces) == "♪" {
                translatedLines.append("")
            } else {
                translatedLines.append(translated)
            }
            matchedCount += 1
        }

        guard matchedCount > 0 else { return nil }

        // 网易 tlyric 的时间戳偶发与主歌词错位：某行歌词的翻译可能落在
        // 上一行的 ♪ 间奏行上。逐行检查：♪ 间奏行有翻译、而下一行歌词没有
        // 翻译时，把翻译下移给下一行；下一行已有翻译则保持不变。
        // 从左到右处理，连续多行间奏会自动接力下移。
        if translatedLines.count > 1 {
            for i in 0..<(translatedLines.count - 1) where isInterludeRow(originalLines[i].content) {
                let current = translatedLines[i].trimmingCharacters(in: .whitespaces)
                let next = translatedLines[i + 1].trimmingCharacters(in: .whitespaces)
                // 纯 ♪ 占位翻译不算真翻译，不搬；下一行已有翻译则保持不变。
                guard !current.isEmpty,
                      !current.allSatisfy({ $0 == "♪" }),
                      next.isEmpty else { continue }
                translatedLines[i + 1] = translatedLines[i]
                translatedLines[i] = ""
            }
        }

        let languageCode = translatedLines.romanizationLanguageCode ?? "zh"
        return LyricsTranslationDto(languageCode: languageCode, lines: translatedLines)
    }

    /// 逐字（yrc）路径的译文：**ytlrc** → 逐行译文。
    ///
    /// 两条路，按可信度排序：
    ///
    ///   ① `buildTranslation` —— 按 **offset 对齐**（与行级 tlyric 完全同一条管线）。
    ///      网易 ytlrc 的行头时间戳与 yrc 行头一一对应，`parseLrc` 侧也早已为这套对齐
    ///      修过精度（见 `parseLrc` 里 "Float32 会把 34.010 算成 34009.998 … 与 yrc 行头的
    ///      精确毫秒 34010 对不上" 那段），所以这是首选路径。
    ///
    ///   ② 兜底：offset 一条都没命中时（`buildTranslation` 返回 nil —— 两份文本的时间戳
    ///      不是同一套时就会这样），**按行序配对**：ytlrc 解析出来的第 i 行 → 主歌词第 i 行。
    ///      理由：这两份文本本来就是同一条流水线按同一顺序产出的，**顺序可信、时间戳不一定**；
    ///      宁可错位一格，也不要整首没有翻译（用户要的就是"逐词歌词也要有翻译"）。
    ///      配对的基准是**最终要交出去的 `originalLines`**，而不是 `yrcParsed`：
    ///      中间还隔着 `LyricsMarkerFilter` 的丢行与"删开头间奏空行"，只有对着最终数组
    ///      才能保证 `translation.lines[i]` 与 `lines[i]` 同源同行
    ///      （渲染层就是按行号取译文的，见 `LyricLinesAdapter` 的 `translationLines[index]`）。
    ///
    /// 返回 nil = 这份 ytlrc 真的没有可用译文（解析不出行 / 配对后全空）。
    private func buildWordByWordTranslation(
        _ ytlrc: String,
        originalLines: [LyricsLineDto]
    ) -> LyricsTranslationDto? {
        if let aligned = buildTranslation(ytlrc, originalLines: originalLines) {
            let filled = aligned.lines.filter { !$0.isEmpty }.count
            if filled > 0 {
                writeDebugLog("[NetEase] word-by-word — translation built from ytlrc (\(filled) line(s))")
                return aligned
            }
        }

        let parsed = parseLrc(ytlrc)
        guard !parsed.isEmpty else {
            writeDebugLog("[NetEase] word-by-word — ytlrc had no usable line")
            return nil
        }

        var lines: [String] = []
        var filled = 0
        for index in originalLines.indices {
            let text = index < parsed.count ? parsed[index].content : ""
            // 与 buildTranslation 同一条 ♪ 规则：整行只有 ♪ 的译文清成空白
            // （保持行数与主歌词一致，不能把行挤掉）。
            // ★ 2026-10-18：不再看「删除间奏符号 ♪」开关（已退役）—— 无条件处理。
            if text.trimmingCharacters(in: .whitespaces) == "♪" {
                lines.append("")
                continue
            }
            lines.append(text)
            if !text.isEmpty { filled += 1 }
        }

        guard filled > 0 else {
            writeDebugLog("[NetEase] word-by-word — ytlrc had no usable line")
            return nil
        }
        writeDebugLog("[NetEase] word-by-word — translation paired by line index (\(filled) line(s))")
        return LyricsTranslationDto(
            languageCode: lines.romanizationLanguageCode ?? "zh",
            lines: lines
        )
    }

    // MARK: - 官方罗马音

    /// 用网易官方 romalrc（日语罗马音）按时间戳替换主歌词行。
    /// 只有对应 offset 命中时才替换，未命中的行保留原文，返回实际替换的行数。
    private func applyRomanization(
        _ romalrc: String,
        originalLines: [LyricsLineDto]
    ) -> (lines: [LyricsLineDto], matched: Int) {
        let parsed = parseLrc(romalrc)
        guard !parsed.isEmpty else { return (originalLines, 0) }

        var romanizedByOffset: [Int: String] = [:]
        for entry in parsed {
            if romanizedByOffset[entry.offsetMs] == nil, !entry.content.isEmpty {
                romanizedByOffset[entry.offsetMs] = entry.content
            }
        }

        var out: [LyricsLineDto] = []
        var matched = 0
        for line in originalLines {
            if let offset = line.offsetMs, let roma = romanizedByOffset[offset] {
                out.append(LyricsLineDto(content: roma, offsetMs: offset))
                matched += 1
            } else {
                out.append(line)
            }
        }
        return (out, matched)
    }

    /// 把网易下发的**原始 LRC** 压成"用来做交叉验证的歌词行"。
    ///
    /// 不追求与最终渲染的行一一对应 —— 交叉验证比的是字符 n-gram 重合率，**不看行**。
    /// 优先用 `parseLrc` 拿到的正文；解析不出来（网易的静态歌词没有 `[mm:ss]` 时间戳）
    /// 就退化成"剥掉行首时间戳后的原始行"，让制作信息之类在归一化那一步自然消失。
    ///
    /// ⚠️ 必须用**原文**：拿译文或罗马音去比会天然不重合（`NeteaseCrossValidation`
    /// 里那道 `script-mismatch` 只兜得住"整份都是罗马字"的情形）。
    private func verificationLines(fromLrc lrc: String) -> [String] {
        let parsed = parseLrc(lrc)
        if !parsed.isEmpty {
            return parsed.map { $0.content }
        }
        return lrc.components(separatedBy: .newlines).map { line in
            line.replacingOccurrences(
                of: "^\\s*\\[[^\\]]*\\]\\s*",
                with: "",
                options: .regularExpression
            )
        }
    }

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        // ★★ 2026-10-17（用户：「netEase 交叉验证似乎未生效」，日志 109 里**一条** CV 行都没有）：
        //    **状态行挪到入口**。以前它挂在"候选过闸之后"（第 1126 行附近），而这台设备上
        //    NetEase 那几首**一条候选都没过闸门** ⇒ 直接 `noSuchSong` 抛出去，那一行**永远打不出来**
        //    ⇒ 日志里分不清"开关没开"和"开了但没触发"。每次启动只打一次，位置必须在这里。
        if !NeteaseLyricsRepository.didLogCrossValidationState {
            NeteaseLyricsRepository.didLogCrossValidationState = true
            writeDebugLog(
                "[NetEase] cross-validation "
                    + (UserDefaults.experimentsOptions.neteaseCrossValidation ? "ON" : "OFF")
            )
        }

        writeDebugLog("[NetEase] Fetching lyrics for \"\(query.title)\" - \(query.primaryArtist)")
        let cacheKey = String(query.hashValue)
        if let cached = lyricsCache.object(forKey: cacheKey as NSString) {
            writeDebugLog("[NetEase] Cache hit")
            return cached.dto
        }

        // 歌名用完整标题（保留 feat./slowed 等后缀），它们本身是重要的区分信息；
        // 网易模糊搜索能靠这些后缀直接命中同曲目的日文名。
        let keyword = "\(query.title) \(query.primaryArtist)"
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var songs: [[String: Any]]
        do {
            songs = try searchSongs(keyword: keyword)
        } catch {
            writeDebugLog("[NetEase] Search error: \(error)")
            throw error
        }

        // ★ 2026-10-17（用户：「使用日本 IP 使用 NetEase 时，返回结果和中国 IP 完全不一样」）：
        //    再发一次**只带标题**的搜索，把结果并进来。网易的排序按地区变，`标题 + 歌手`
        //    那一份可能把正主挤出前 100；标题单独搜往往能把它捞回来。合并按 song id 去重，
        //    失败不影响主查询（`try?`）。
        let titleOnlyKeyword = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !titleOnlyKeyword.isEmpty,
           let extra = try? searchSongs(keyword: titleOnlyKeyword),
           !extra.isEmpty {
            var seen = Set(songs.compactMap { songId(from: $0) })
            var added = 0
            for song in extra {
                guard let id = songId(from: song) else { continue }
                if seen.insert(id).inserted {
                    songs.append(song)
                    added += 1
                }
            }
            writeDebugLog("[NetEase] title-only search added \(added) candidate(s) (total \(songs.count))")
        }

        guard !songs.isEmpty else {
            writeDebugLog("[NetEase] No search results")
            throw LyricsError.noSuchSong
        }
        writeDebugLog("[NetEase] Search returned \(songs.count) result(s)")

        // 选歌：**歌手 + 时长都要对得上**，按相关度顺序取第一个满足的。
        //
        // 历史（两版）：
        //   · 第一版只看第一位：第一位时长差 > 5s 就 noSuchSong（哪怕后面有对得上的）；
        //   · 第二版改成"按相关度找第一个时长对得上的"，但**完全不比对歌手**。
        //
        // 2026-10-04 真机日志 45 暴露了第二版的漏洞：同一时长里躺着翻唱 / 伴奏 / 同曲异名版本，
        // 于是"能展示的歌词也全是错的"（用户原话）。现场是一串
        // `[NetEase] Chosen[11] → yrc absent → No usable lyrics` 与
        // `Chosen[0] → Duration mismatch` 交替出现。
        //
        // 现在：**时长必须对得上**（±5s），并且**歌手必须对得上**（候选的 `ar[].name`
        // 里任意一个与我们的任一艺人名互相包含，忽略大小写）。找不到这样的候选时：
        //   · 还有"时长对得上但歌手对不上"的 → **不用它**（那正是翻唱），交给兜底源；
        //   · 一个时长都对不上 → noSuchSong。
        // 拿不到时长（本地文件）时退回"只看歌手"，仍比盲取第一位安全。
        let durationToleranceMs = 5000
        let spotifyDurationMs = query.durationMs
        let wantedArtists = query.allArtistNames.map { $0.lowercased() }

        func candidateDuration(_ song: [String: Any]) -> Int? {
            (song["duration"] as? NSNumber)?.intValue
        }

        /// 候选的歌手名。
        ///
        /// ⚠️⚠️ 2026-10-16：**两个键都要认** —— 我们用的是 `/weapi/search/get`（老 weapi 接口），
        /// 它返回的是 **`artists`**；**`ar` 是 eapi / 歌曲详情那一档的写法**。
        /// 实测（同一族接口 `https://music.163.com/api/search/get?s=…&type=1`）：
        /// `result.songs[]` 的键是 `id, name, artists, album, duration, alias, rtype, fee, …`
        /// —— **根本没有 `ar`**。
        ///
        /// 历史：只读 `ar` 的那一版里，**每一条候选的歌手都是空的** ⇒ `artistMatches` 永远
        /// 返回 `.none` ⇒ 上面那句"歌手 + 时长都要对得上"**从来没生效过**，实际等于
        /// "取相关度排序里第一个时长在 ±5s 内的"。证据：**所有**日志里的
        /// `[NetEase] Chosen[N]: <歌名> — ? <时长>` 那个 `?` 就是空歌手
        /// （`48/49/50/52/62/89/94/99/102…` 全是）。
        ///
        /// 后果正是用户 2026-10-16 报的「海外 / 国内环境歌词完全不同」：网易的**搜索排序按地区不同**
        /// ⇒ 换个网络环境就选中另一首歌。日志 102 里同一首 180s 的歌，一次
        /// `Chosen[6]: TSUBAKI`、一次 `Chosen[0]: 桜葬` —— 而 `TSUBAKI` 是另一首歌。
        func candidateArtists(_ song: [String: Any]) -> [String] {
            let list = (song["ar"] ?? song["artists"]) as? [[String: Any]]
            return (list ?? []).compactMap { $0["name"] as? String }
        }

        func artistMatches(_ song: [String: Any]) -> Bool? {
            guard !wantedArtists.isEmpty else { return nil }
            let names = candidateArtists(song).map { $0.lowercased() }
            guard !names.isEmpty else { return nil }
            for name in names {
                for wanted in wantedArtists where name.contains(wanted) || wanted.contains(name) {
                    return true
                }
            }
            return false
        }

        /// 标题归一化：去掉括号/标点/空白，砍掉 `feat. …` / `ft. …` 之后的部分。
        ///
        /// ★ 2026-10-17（日志 108：日本 IP 下选了 `Thank You — Royal 44`，而 Spotify 这首是
        ///    `ヒミツ (feat. 可不) — MIMI`）：**光靠时长兜底**会把"恰好差不多长的另一首歌"
        ///    选进来。现在时长之外还必须**标题对得上**；标题对不上的一律不选，交给 Genius 兜底
        ///    （同一条日志里 Genius 确实找到了 `ヒミツ (Secret)`）。
        func normalizeTitle(_ raw: String) -> String {
            var text = raw.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            // ★ 先砍 `feat. …`（**在去标点之前**，否则 `feat` 与后面的词粘在一起，
            //   拿 `ft` 去截会把 `after` 这类词截成 `a`）。
            for marker in ["feat.", "feat ", " ft.", " ft "] {
                if let range = text.range(of: marker, options: .caseInsensitive) {
                    text = String(text[..<range.lowerBound])
                }
            }
            for token in [
                "（", "）", "(", ")", "[", "]", "【", "】", "{", "}", "《", "》", "〈", "〉",
                "-", "—", "–", "・", "·", " ", "　", "\t", "\n",
                "!", "！", "?", "？", "'", "’", "\"", "“", "”", ",", "，", ".", ":", "：", "/",
            ] {
                text = text.replacingOccurrences(of: token, with: "")
            }
            return text
        }

        let wantedTitle = normalizeTitle(query.title)

        func candidateTitles(_ song: [String: Any]) -> [String] {
            var titles: [String] = []
            if let name = song["name"] as? String { titles.append(name) }
            if let aliases = song["alias"] as? [String] { titles.append(contentsOf: aliases) }
            return titles
        }

        func titleMatches(_ song: [String: Any]) -> Bool {
            // 拿不到 Spotify 标题（本地文件等）⇒ 这一关不参与判定，退回旧行为。
            guard !wantedTitle.isEmpty else { return true }
            for title in candidateTitles(song) {
                let candidate = normalizeTitle(title)
                guard !candidate.isEmpty else { continue }
                if candidate.contains(wantedTitle) || wantedTitle.contains(candidate) {
                    return true
                }
            }
            return false
        }

        /// 一首歌的**主干标题**：括号 / 破折号之前的那些字。
        ///
        /// ★★ 2026-10-17（日志 112 的现场：MIMI 那首「找不到歌词」被判 `noSuchSong`）：
        /// 候选[0] 是 `ヒミツ (feat. 可不)`、150085ms（Spotify 150000ms）、歌手 `MIMI / 可不` 对上，
        /// 而 Spotify 那边标题尾注写的是别的（`(Secret)`）—— `normalizeTitle` 是**把括号当字符删掉**，
        /// 两边尾巴不同 ⇒ `contains` 两个方向都不成立 ⇒ 本质上同一首歌被判成"没有候选"。
        /// 主干都是 `ヒミツ`。
        func baseTitle(_ text: String) -> String {
            var head = text
            for marker in ["（", "(", "[", "【", "《", "〈", " - ", " — ", " – ", "-", "—", "–"] {
                if let range = head.range(of: marker) {
                    head = String(head[..<range.lowerBound])
                }
            }
            return normalizeTitle(head)
        }

        /// 主干标题相同（**不**含尾注）。
        ///
        /// ⚠️ 只在"歌手也对上、时长也对上"时才当准入用（见下面那个循环）——
        /// 单看主干会把 `Song (Live)` / `Song (Remix)` 混成一锅。
        func baseTitleMatches(_ song: [String: Any]) -> Bool {
            let wantedBase = baseTitle(query.title)
            guard wantedBase.count >= 2 else { return false }
            for title in candidateTitles(song) {
                let candidate = baseTitle(title)
                guard candidate.count >= 2 else { continue }
                if candidate == wantedBase { return true }
            }
            return false
        }

        // MARK: 候选排序（2026-10-17 重写：从"挑一个"改成"排一串"）
        //
        // 旧版在这里选出一个 `chosen` 就直接去取词。改成一串的原因只有一个：
        // **交叉验证判错之后要能换下一条**（见下面的「交叉验证」段与
        // `NetEaseCrossValidation.swift`）。手上只有"胜者"就没得换。
        //
        // 排序口径与旧版**完全一致**，只是把"只留第一名"改成"全留下"：
        //   ① 歌名 + 歌手 + 时长三道闸门全过的，按相关度顺序排在最前；
        //   ② 然后是"歌名 + 时长对、但歌手对不上／网易没给歌手名"的，**按 Δ时长升序**
        //      —— 排序按地区变，而"哪一条和 Spotify 的时长最接近"跟地区无关。
        var strictlyMatchedIndices: [Int] = []
        var durationOnlyCandidates: [(index: Int, delta: Int)] = []
        /// ★★ 2026-10-18（日志 222 的现场：MIMI 那首**还是**找不到词）：
        ///
        /// ```
        /// [NetEase] candidate[0] ヒミツ (feat. 可不) — MIMI / 可不 150085ms title=false base=false artist=true
        /// [NetEase] no candidate duration matches Spotify (spotify=150000ms, 49 results) — noSuchSong
        /// ```
        ///
        /// **歌手对上、时长只差 85ms**，但 Spotify 那边的标题是**另一种写法**（`秘密` / 罗马字 / 尾注
        /// 全都不同）⇒ 歌名与主干两道都过不去。这不是"比较写得不够松"，而是**同一个词在两套书写系统里
        /// 各有一个名字**（`ヒミツ` 与 `秘密`）—— 字符串比较再放宽也永远不会相等。
        ///
        /// ⇒ 加第三档：**歌手对得上 + 时长差 ≤ 2s** 也收进候选表。位置排在
        /// "三道闸门全过"之后、"只有标题+时长对上（歌手对不上）"之前 —— 前者当然更可信，
        /// 而后者的风险（翻唱 / 同名不同曲）比"同一歌手、时长几乎一样"更大。
        /// 同一歌手两首时长差 2 秒以内的歌很少；这一档也只有在前两档一条都没有时才会被选中。
        let closeDurationMs = 2000
        var closeDurationCandidates: [Int] = []
        /// 拿不到 Spotify 时长（本地文件）时没有 Δ 可比 ⇒ 与旧行为一致，只记第一个。
        var firstDurationOnlyWithoutDelta: Int?

        for (index, song) in songs.enumerated() {
            let durationOK: Bool
            if let spotifyDurationMs, let ms = candidateDuration(song) {
                durationOK = abs(ms - spotifyDurationMs) <= durationToleranceMs
            } else {
                // 拿不到 Spotify 时长（本地文件）⇒ 这一关不参与判定。
                durationOK = true
            }
            guard durationOK else { continue }

            let artistOK = artistMatches(song)
            let titleOK = titleMatches(song)
            // ★ 标题是硬闸门（日志 108 的错误来源），但"**只差尾注**"不算差：
            //   歌手对上、时长对上、主干相同（见 `baseTitle`）⇒ 同一首歌的两种写法。
            //   ★★ 2026-10-17（日志 112）：`ヒミツ (feat. 可不)` vs `ヒミツ (Secret)` 就是这种。
            let baseOK = !titleOK && artistOK == .some(true) && baseTitleMatches(song)
            // ★★ 2026-10-18：标题与主干都对不上、但**歌手对上且时长几乎一样** ⇒ 收进第三档
            //    （见 `closeDurationCandidates` 那段；`ヒミツ` vs `秘密` 就是这一类）。
            if !titleOK, !baseOK, artistOK == .some(true),
               let spotifyDurationMs, let ms = candidateDuration(song),
               abs(ms - spotifyDurationMs) <= closeDurationMs {
                closeDurationCandidates.append(index)
                continue
            }
            guard titleOK || baseOK else { continue }

            if artistOK == .some(true) {
                strictlyMatchedIndices.append(index)
                if baseOK {
                    writeDebugLog(
                        "[NetEase] candidate[\(index)] matched by base title"
                            + " (尾注不同、主干相同、歌手与时长都对上)"
                    )
                }
                continue
            }

            // 标题对、时长对，但**歌手对不上**（翻唱 / 同曲异名）或**网易没给歌手名** ——
            // 记下来当"最差可用"，优先继续找歌手也对得上的。
            //
            // ★★ 2026-10-16：**按时长差取最近的那一个**，不再取"相关度排序里的第一个"。
            //    排序是**按地区**变的（同一首歌 180s，日志 102 一次 Chosen[6]、一次 Chosen[0]），
            //    而"哪一条和 Spotify 的时长最接近"跟地区无关 —— 同一个母带的时长是一样的。
            //    这条兜底只在"歌手闸门也过不去"时才走（例如 Spotify 写 `Natsunose`、
            //    网易写 `ナツノセ`，跨书写系统认不出来），所以它越确定越好。
            if titleOK {
                if let spotifyDurationMs, let ms = candidateDuration(song) {
                    durationOnlyCandidates.append((index, abs(ms - spotifyDurationMs)))
                } else if firstDurationOnlyWithoutDelta == nil {
                    firstDurationOnlyWithoutDelta = index
                }
            }
            continue
        }

        // 把两条排序拼成一条有序候选表（见上面「候选排序」段的 ①②）。
        var orderedCandidateIndices: [Int] = strictlyMatchedIndices
        // ★★ 2026-10-18：第三档（歌手 + 时长，跨书写系统）排在"只有标题+时长对上"之前，
        //    理由见 `closeDurationCandidates` 的说明。
        if !closeDurationCandidates.isEmpty {
            for index in closeDurationCandidates where !orderedCandidateIndices.contains(index) {
                orderedCandidateIndices.append(index)
            }
            writeDebugLog(
                "[NetEase] \(closeDurationCandidates.count) candidate(s) admitted by artist + duration"
                    + " (the title is written in another script) — index \(closeDurationCandidates)"
            )
        }
        for candidate in durationOnlyCandidates.sorted(by: { $0.delta < $1.delta }) {
            orderedCandidateIndices.append(candidate.index)
        }
        if let extra = firstDurationOnlyWithoutDelta {
            orderedCandidateIndices.append(extra)
        }

        // 一条都没过闸门 ⇒ 把前 8 条候选的标题/歌手/时长/两道闸门打进日志（只在失败时打）。
        if orderedCandidateIndices.isEmpty {
            for (index, song) in songs.prefix(8).enumerated() {
                let name = song["name"] as? String ?? "?"
                let artists = candidateArtists(song).joined(separator: " / ")
                let ms = candidateDuration(song).map { "\($0)ms" } ?? "?"
                writeDebugLog(
                    "[NetEase] candidate[\(index)] \(name) — \(artists.isEmpty ? "?" : artists)"
                        + " \(ms) title=\(titleMatches(song)) base=\(baseTitleMatches(song))"
                        + " artist=\(artistMatches(song) ?? false)"
                )
            }
            if let spotifyDurationMs {
                writeDebugLog(
                    "[NetEase] no candidate duration matches Spotify"
                        + " (spotify=\(spotifyDurationMs)ms, \(songs.count) results) — noSuchSong"
                )
            } else {
                writeDebugLog("[NetEase] no usable candidate (\(songs.count) results) — noSuchSong")
            }
            // ★★ 2026-10-17：交叉验证**没事可做**时也要留一行 —— 否则"开关开着"与"开了但一条候选
            //    都没过闸门"在日志里长得一模一样（日志 109 就是这么误判成"未生效"的）。
            writeDebugLog(
                "[NetEase] cross-validation "
                    + (UserDefaults.experimentsOptions.neteaseCrossValidation
                        ? "had nothing to check — no candidate reached the gate"
                        : "is OFF")
            )
            throw LyricsError.noSuchSong
        }

        // 走到"最低一档"（歌手全对不上）时照旧报一句 —— 文案与旧版**逐字一致**，
        // `Tools/log_triage.py` 与历史交接文档都认这一行。
        if strictlyMatchedIndices.isEmpty, let firstIndex = orderedCandidateIndices.first {
            let delta = durationOnlyCandidates
                .first(where: { $0.index == firstIndex })?
                .delta
            writeDebugLog(
                "[NetEase] title matched but artist did not — closest duration wins"
                    + " (index \(firstIndex), Δ\(delta.map { "\($0)" } ?? "-1")ms,"
                    + " \(songs.count) results)"
            )
        }

        // MARK: 交叉验证（实验开关「NetEase 交叉验证」）
        //
        // 触发条件：**只在"三道闸门没有全过"的候选上验**（歌手对不上 / 网易没给歌手名）。
        // 历史上所有错歌现场都是这一类（日志 45 的翻唱、日志 102 的 `TSUBAKI`、
        // 日志 108 的 `Thank You — Royal 44`），而"歌名 + 歌手 + 时长都对得上"的候选
        // 再验等于把每首歌的请求量翻几倍去确认一件几乎不会错的事 —— 那是白花的钱。
        //
        // 判错的处置：**不弃用 NetEase**，而是换下一条候选（用户看中它的 yrc 逐字 /
        // 翻译 / 罗马音，换源等于赢了正确性、输了功能）。全换不出来才交下一个源。
        //
        // ⚠️ 2026-10-17：状态那行**已经挪到 `getLyrics` 入口**（见那里的说明）—— 它挂在这里时，
        //    "一条候选都没过闸门"那条路会在上半段就 `throw`，于是那一行永远打不出来。
        let crossValidationEnabled = UserDefaults.experimentsOptions.neteaseCrossValidation

        var chosenIndex = -1
        var chosenRaw: (lrc: String?, tlyric: String?, romalrc: String?)?
        var chosenLrc = ""
        var attempts = 0
        var lastError: Error?

        for index in orderedCandidateIndices {
            // 防病态：候选表可能有上百条，而验证一次要花几个裁判请求 ⇒ 最多试 6 条。
            guard attempts < 6 else {
                writeDebugLog("[NetEase] gave up after \(attempts) candidate(s) — noSuchSong")
                break
            }
            guard let songId = songId(from: songs[index]) else { continue }
            attempts += 1

            let raw: (lrc: String?, tlyric: String?, romalrc: String?)
            do {
                raw = try fetchLyricsRaw(songId: songId)
            } catch {
                // 第一条就取词失败 ⇒ 与旧行为一致，把错误**抛出去**（网络问题不该被吞成查无此歌）。
                if attempts == 1 {
                    writeDebugLog("[NetEase] Fetch lyrics error: \(error)")
                    throw error
                }
                lastError = error
                writeDebugLog("[NetEase] candidate[\(index)] fetch failed — skipping")
                continue
            }

            guard let lrc = raw.lrc, !lrc.isEmpty else {
                if attempts == 1 {
                    writeDebugLog("[NetEase] No usable lyrics")
                } else {
                    writeDebugLog("[NetEase] candidate[\(index)] has no usable lyrics — skipping")
                }
                continue
            }

            // 「纯音乐，请欣赏」= 可信分类，没有歌词可比对 ⇒ 直接收下。
            if lrc.contains("纯音乐") {
                chosenIndex = index
                chosenRaw = raw
                chosenLrc = lrc
                break
            }

            let isStrictlyMatched = strictlyMatchedIndices.contains(index)
            if crossValidationEnabled, !isStrictlyMatched {
                let outcome = NeteaseCrossValidationRunner.verify(
                    query: query,
                    options: options,
                    neteaseLines: verificationLines(fromLrc: lrc)
                )
                if outcome.verdict == .reject {
                    let name = songs[index]["name"] as? String ?? "?"
                    let percent = String(format: "%.2f", outcome.overlap)
                    writeDebugLog(
                        "[NetEase] cross-validation rejected candidate[\(index)] \(name)"
                            + " (arbiter=\(outcome.arbiterName), overlap=\(percent)) — trying next"
                    )
                    continue
                }
            }

            chosenIndex = index
            chosenRaw = raw
            chosenLrc = lrc
            break
        }

        guard let resolvedRaw = chosenRaw else {
            if let lastError = lastError {
                writeDebugLog("[NetEase] all candidates failed, last error: \(lastError)")
            }
            throw LyricsError.noSuchSong
        }

        let chosen = songs[chosenIndex]
        let chosenArtists = candidateArtists(chosen).joined(separator: " / ")
        let chosenDuration = candidateDuration(chosen).map { "\($0)ms" } ?? "?"
        writeDebugLog(
            "[NetEase] Chosen[\(chosenIndex)]: \(chosen["name"] as? String ?? "?")"
                + " — \(chosenArtists.isEmpty ? "?" : chosenArtists)"
                + " \(chosenDuration)"
                + " (ours: \(query.primaryArtist) \(spotifyDurationMs.map { "\($0)ms" } ?? "?"))"
        )

        // 旧版这里还有一道"第一位时长不符就 noSuchSong"的闸门 —— 现在选歌本身已经要求
        // 时长对得上（或退回的那一位就是时长匹配的），所以那道闸门是重复的，删掉。

        guard let songId = songId(from: chosen) else {
            writeDebugLog("[NetEase] Chosen result has no song id")
            throw LyricsError.noSuchSong
        }

        let raw = resolvedRaw
        // `chosenLrc` 在上面的候选循环里已经保证非空，所以这里不再重复 guard。
        let lrc = chosenLrc

        // 网易「纯音乐，请欣赏」= 这首歌是纯音乐（可信分类）：直接返回纯音乐占位。
        if lrc.contains("纯音乐") {
            writeDebugLog("[NetEase] Instrumental — returning empty lyrics")
            var dto = LyricsDto(lines: [], timeSynced: false, romanization: .original)
            // ★ 2026-10-11：**把"源说过这是纯音乐"记在 dto 上** —— 听歌页那层据此写
            //   「此歌曲为纯音乐。」而不是「未找到歌词」（两者数据都是空行，只有这个字段能区分）。
            dto.isInstrumental = true
            lyricsCache.setObject(CachedLyrics(dto: dto), forKey: cacheKey as NSString)
            return dto
        }

            var lines: [LyricsLineDto]
            var timeSynced = true

            // 逐字歌词：开关开启且网易下发 yrc 时，优先用词级（逐字）时间轴；
            // yrc 缺失/解析为空时回退到 lrc 行级时间轴（下面原逻辑不变）。
            let preferWordByWord = NgzhwmSettingsViewModel.isWordByWordLyricsEnabled
            // ★ 2026-10-11：yrc 与 **ytlrc** 必须从同一次 eapi 响应里一起取出（元组解构）。
            //
            // 以前这里写的是 `yrcText = try fetchYrcRaw(songId: songId).yrc` —— 取 `.yrc`
            // 这一个成员就等于把元组里的 `ytlrc` 当场丢掉。而 ytlrc 是逐字歌词配套的
            // 翻译（`fetchYrcRaw` 自己那行日志 `yrc … chars, ytlrc … chars` 就写着它一直在
            // 下发），丢了它，下面的逐字分支就永远没有译文可取 ——
            // 用户 2026-10-11 的原话：「当返回逐词歌词的时候，不展示歌词翻译」。
            // 真机日志里 `[NetEase] word-by-word — skipping translation layer` 与
            // `[NPVLyrics] expanded … translation 0/29` 成对出现，就是这条路径。
            // ⚠️ **不能**为了拿 ytlrc 再调一次 `fetchYrcRaw`：那是一次额外的网络请求。
            var yrcText: String? = nil
            var ytlrcText: String? = nil
            if preferWordByWord {
                do {
                    let yrcRaw = try fetchYrcRaw(songId: songId)
                    yrcText = yrcRaw.yrc
                    ytlrcText = yrcRaw.ytlrc
                } catch {
                    writeDebugLog("[NetEase] yrc (eapi) fetch failed: \(error)")
                }
            }
            var yrcParsed: [(offsetMs: Int, content: String, words: [LyricsWordDto])] =
                yrcText.map { parseYrc($0) } ?? []

            // ★★ 2026-10-18（日志 222 的现场：`Chosen[1]: 独白 — DUSTCELL 196680ms` 之后
            //    `eapi /api/song/lyric/v1 → yrc absent, ytlrc absent` ⇒ 那首歌**退化回行级**）：
            //
            // 逐字（yrc）是**按歌曲 id** 下发的，同一首歌在网易那边常有多个 id（原版 / 单曲版 /
            // 专辑版）。选中的那条没有 yrc，不代表这首歌没有 —— 用户点名要的就是逐字。
            // ⇒ 选中的候选没给 yrc 时，**再向同歌的其它候选各要一次**（最多 2 条）。
            //
            // 代价：每次最多多 2 个 eapi 请求，而且**只在"选中那条没有 yrc"时**才发生
            // （三道闸门全过的歌一般一次就够）；拿不到就照旧回退行级，不影响功能。
            if preferWordByWord, yrcParsed.isEmpty {
                let probes = orderedCandidateIndices
                    .filter { $0 != chosenIndex }
                    .prefix(2)
                if !probes.isEmpty {
                    writeDebugLog(
                        "[NetEase] yrc absent for candidate[\(chosenIndex)] — probing"
                            + " \(probes.count) sibling candidate(s)"
                    )
                }
                for index in probes {
                    guard let otherSongID = songId(from: songs[index]) else { continue }
                    guard let probe = try? fetchYrcRaw(songId: otherSongID) else { continue }
                    let parsed = probe.yrc.map { parseYrc($0) } ?? []
                    writeDebugLog(
                        "[NetEase] yrc probe — candidate[\(index)]"
                            + " \(songs[index]["name"] as? String ?? "?") →"
                            + " \(parsed.isEmpty ? "absent" : "\(parsed.count) line(s)")"
                    )
                    if !parsed.isEmpty {
                        yrcParsed = parsed
                        // ytlrc 必须与**采用的那一份** yrc 配对（两边的行 offset 是一套）。
                        ytlrcText = probe.ytlrc
                        break
                    }
                }
            }

            if !yrcParsed.isEmpty {
                writeDebugLog("[NetEase] Word-by-word (yrc) lyrics — \(yrcParsed.count) line(s)")
                // `LyricsMarkerFilter.isNonLyricLine` = 与其他源共用的"结构标注行"过滤器。
                // 网易的 `<Music>` 间奏标记就靠它拦掉（2026-10-04 真机日志 45 的现场：
                // 那行被当正文渲染，跟着歌词列一起滚）。判为标注行的**丢掉整行**，
                // 而不是留个空行 —— 空行在 AM 渲染层里会占一行高度，看着像"漏了一句"。
                lines = yrcParsed
                    // ★★ 2026-10-18（用户拍板：「把**原本有的间奏全部删掉**」）：♪ / `<Music>` 那类
                    //    **整行丢掉**，而不是"清成空白、保留位置"。
                    //    判据用现成的 `isInterludeRow`（空行、或整行只有 ♪，含多个 ♪ 与前后空白）。
                    //
                    //    为什么丢掉是对的：**间奏不该由一行文字表达** —— AM 那边是三个呼吸点，
                    //    而"这一行到下一行之间有多久没词"这件事，`LyricInterludeTimeline` 是**按
                    //    时间间隙**推出来的（Melox 的检测逻辑），不靠一个占位行 ✓。
                    //    留空行反而有害：AM 渲染层里空行照样占一行高度，看着像漏了一句。
                    .filter { !isInterludeRow($0.content.lyricsNoteIfEmpty) }
                    .map {
                        LyricsLineDto(
                            content: $0.content.lyricsNoteIfEmpty,
                            offsetMs: $0.offsetMs,
                            words: $0.words
                        )
                    }
                    .filter { !LyricsMarkerFilter.isNonLyricLine($0.content) }
            } else {
                if preferWordByWord {
                    writeDebugLog("[NetEase] yrc unavailable — falling back to line-synced (lrc)")
                }
                let parsed = parseLrc(lrc)
                if parsed.isEmpty {
                    // 网易部分歌只有静态歌词（无 [mm:ss] 时间戳、没做滚动歌词）：
                    // 按行拆分、过滤制作信息行与空行，作为非同步歌词收录传给上游。
                    // 先剥掉行首残留时间戳（如 [00:00.00-1]，parseLrc 解析不出），
                    // 否则「作曲 : xxx」这类制作信息会被误当成歌词收录。
                    var fallbackLines: [LyricsLineDto] = []
                    for rawLine in lrc.components(separatedBy: .newlines) {
                        let content = rawLine.trimmingCharacters(in: .whitespaces)
                        guard !content.isEmpty else { continue }
                        let stripped = content.replacingOccurrences(
                            of: "^\\s*\\[[^\\]]*\\]\\s*",
                            with: "",
                            options: .regularExpression
                        ).trimmingCharacters(in: .whitespaces)
                        guard !stripped.isEmpty, !isCreditLine(stripped),
                              !LyricsMarkerFilter.isNonLyricLine(stripped) else { continue }
                        // 合并式制作信息（如「作词/作曲 : xxx」）isCreditLine 匹配不到，单独兜住：
                        // 以制作关键词开头且后面带冒号，视为制作信息，不收录。
                        let creditKeywords = ["作词", "作曲", "编曲", "混音", "混音师", "母带",
                                              "录音", "录音师", "制作", "出品", "发行", "监制",
                                              "和声", "配唱", "统筹", "企划", "推广", "文案",
                                              "摄影", "封面", "导演", "经纪人"]
                        if creditKeywords.contains(where: { stripped.hasPrefix($0) }),
                           stripped.contains(":") || stripped.contains("：") {
                            continue
                        }
                        fallbackLines.append(LyricsLineDto(content: content, offsetMs: nil))
                    }
                    guard !fallbackLines.isEmpty else {
                        writeDebugLog("[NetEase] No usable lyrics")
                        throw LyricsError.noSuchSong
                    }
                    lines = fallbackLines
                    timeSynced = false
                    writeDebugLog("[NetEase] Unsynced lyrics fallback (\(lines.count) line(s))")
                } else {
                    lines = parsed
                        // ★★ 2026-10-18：与逐字那条路同一条纪律 —— 间奏行**整行丢掉**
                        //    （见上面那段说明：间奏交给三个呼吸点与时间间隙，不交给一行文字）。
                        .filter { !isInterludeRow($0.content.lyricsNoteIfEmpty) }
                        .map {
                            LyricsLineDto(
                                content: $0.content.lyricsNoteIfEmpty,
                                offsetMs: $0.offsetMs
                            )
                        }
                        .filter { !LyricsMarkerFilter.isNonLyricLine($0.content) }
                }
            }

        // ★★ 2026-10-18：**无条件**删掉开头的空行 —— 间奏行已经在上面被整行剔掉了，
        //    这里兜的是"其他源形态留下的空头"（静态歌词路径会把空行原样收进来）。
        //    旧版这颗由「删除间奏符号 ♪」开关控制；那颗开关现在无论开还是关都不该再影响结果
        //    （用户拍板 A：间奏一律删掉），所以这一句不再看它。
        lines = Array(lines.drop(while: { $0.content.isEmpty }))

        // 网易云翻译只有简体中文。开启「不展示网易云歌词翻译」开关时，
        // 跳过翻译层构建，不把简体中文翻译交给上游（不影响中日韩罗马化）。
        var translation: LyricsTranslationDto? = nil
        let hideNetEaseTranslation = NgzhwmSettingsViewModel.isNeteaseHideTranslationEnabled
        if hideNetEaseTranslation {
            writeDebugLog("[NetEase] Hide translation enabled — skipping translation layer")
        } else if !yrcParsed.isEmpty {
            // ★ 2026-10-11（用户）：「当返回逐词歌词的时候，不展示歌词翻译」。
            //
            // 逐字路径的译文来自 **ytlrc**（与 yrc 同一次 eapi 下发、行头一一对应），
            // 不是 `raw.tlyric` —— 后者与行级 lrc 同源，和 yrc 行头不是一套时间轴。
            // 这里以前只有一句 `[NetEase] word-by-word — skipping translation layer`
            // 就结束了：从不给 `translation` 赋值，于是逐字歌永远没有翻译层
            // （真机日志 `[NPVLyrics] expanded … translation 0/29` 的那条路）。
            if let ytlrc = ytlrcText, !ytlrc.isEmpty {
                translation = buildWordByWordTranslation(ytlrc, originalLines: lines)
            } else {
                // ytlrc 真的没下发（`fetchYrcRaw` 的日志会写着 `ytlrc absent`）——
                // 这种情况下确实没有译文可用，如实记账，不再假装"逐字歌词不显示翻译"。
                writeDebugLog("[NetEase] word-by-word — ytlrc absent")
            }
        } else if let tlyric = raw.tlyric, !tlyric.isEmpty {
            translation = buildTranslation(tlyric, originalLines: lines)
        }

        let contents = lines.map(\.content)
        var romanization: LyricsRomanizationStatus = contents.canBeRomanized
            ? .canBeRomanized : .original
        let languageCode = contents.romanizationLanguageCode

        // 官方罗马音：日语歌、用户开启日语罗马化、且网易下发了 romalrc 时，
        // 直接用官方罗马音替换主歌词行（标记 .romanized 跳过本地转换）。
        // 若开启「修改 NetEase 日语罗马字展示方式」开关，则跳过官方罗马音，
        // 保持原文 + .canBeRomanized，把所有日语行统一交给显示层本地罗马化。
        // 未命中上述条件时同样保持原文 + .canBeRomanized，交给显示层本地转换。
        let preferLocalRomaji = UserDefaults.standard.bool(
            forKey: NgzhwmSettingsViewModel.neteaseRomajiLocalKey
        )
        if preferLocalRomaji,
           languageCode == "ja",
           UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization") {
            writeDebugLog("[NetEase] Local romaji display enabled — skipping official romaji")
        }

        // 逐字歌词（preferWordByWord 且拿到 yrc）时跳过官方罗马音 + 本地兜底：
        // 这两步会把 yrc 的 words 词级时间轴丢掉、且产出小写罗马字；
        // 改为保持原文 + .canBeRomanized，交给显示层 romanizedForWordByWordIfEnabled
        // （罗马化 + 首词大写 + 词级对齐）与原生 romanizeLine 处理。
        let usingWordByWord = preferWordByWord && !yrcParsed.isEmpty
        if usingWordByWord {
            writeDebugLog("[NetEase] word-by-word path — skipping repo-side romaji (defer to display layer)")
        }

        // ★★ 2026-10-12（用户拍板）：**官方罗马音也不再替换正文。**
        //
        // 用户原话：「开启歌词内的日语歌词罗马化后，是直接把原日文替换了，不是在原文的上面
        // 展示罗马字」，并选了"原生那页也回到日文原文，罗马字只由我们这层画"。
        //
        // 这一段以前是把 `lines[i].content` **换成**官方 `romalrc`（并顺带把残留日文的行
        // 用本地转换补齐），于是屏幕上**日文原文整个没了** —— 正是用户报的那件事，
        // 只是走的是另一条路（逐字 yrc 那条已经在 `storeLyricsDto` / `toSpotifyLyricsData` 改掉）。
        //
        // 现在：官方那份**留着**（它质量比本地转换好），但存进 `officialRomanizedLines`
        // —— 显示层把它当"原文**上方**那一行"（`LyricLinesAdapter.romanizedContentsForDisplay()`
        // 首选它，缺的行再退回本地转换）。正文一个字都不动。
        //
        // ⚠️ 「修改 NetEase 日语罗马字展示方式」那个开关（`preferLocalRomaji`）**语义不变**：
        //    它仍然是"宁可要本地那份、也不用官方那份"—— 打开时这里就不存官方罗马字。
        var officialRomanizedLines: [String] = []
        if let romalrc = raw.romalrc, !romalrc.isEmpty,
           languageCode == "ja",
           UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization"),
           !preferLocalRomaji,
           !usingWordByWord {
            let romanized = applyRomanization(romalrc, originalLines: lines)
            if romanized.matched > 0 {
                // 与 `lines` **同序同长**：没命中的行留空（显示层会退回本地转换）。
                officialRomanizedLines = romanized.lines.enumerated().map { index, line -> String in
                    guard index < lines.count, lines[index].content != line.content else { return "" }
                    return line.content
                }
                writeDebugLog(
                    "[NetEase] official romaji kept for the line above"
                        + " (\(romanized.matched) line(s)) — the lyrics text stays as-is"
                )
            }
        }

        let dto = LyricsDto(
            lines: lines,
            timeSynced: timeSynced,
            romanization: romanization,
            translation: translation,
            languageCode: languageCode,
            officialRomanizedLines: officialRomanizedLines
        )

        writeDebugLog("[NetEase] Synced lyrics — \(lines.count) line(s)")
        lyricsCache.setObject(CachedLyrics(dto: dto), forKey: cacheKey as NSString)
        return dto
    }
}

// MARK: - Japanese Script Detection

private extension String {
    /// 是否仍含日文假名/汉字（用于判定官方罗马音是否完整、需要本地兜底）。
    var containsJapaneseScriptForRomajiFallback: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // 平假名 + 片假名
                 0x31F0...0x31FF, // 片假名拼音扩展
                 0xFF66...0xFF9D, // 半角片假名
                 0x3400...0x4DBF, // CJK 扩展 A
                 0x4E00...0x9FFF, // CJK 统一表意文字
                 0xF900...0xFAFF: // CJK 兼容表意文字
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - NeteaseBigUInt
//
// 仅为 weapi 的 encSecKey 服务的最小无符号大整数（小端 limbs）：
// 模数是固定 1024 位、指数 65537，因此只需 乘法 / 减法 / 比较 /
// 二进制长除法取模 / 平方-乘模幂。加密对象只有 16 字节，远小于模数，
// 与网易前端 BigInt.powMod 的 raw RSA（无填充）完全等价。

private struct NeteaseBigUInt {

    var limbs: [UInt64] // little-endian，恒无前导零 limb

    static let zero = NeteaseBigUInt(limbs: [0])

    init(limbs: [UInt64]) {
        var trimmed = limbs
        while trimmed.count > 1, trimmed.last == 0 {
            trimmed.removeLast()
        }
        self.limbs = trimmed
    }

    init?(hex: String) {
        var limbs: [UInt64] = [0]
        for character in hex {
            guard let digit = character.hexDigitValue else { return nil }
            // limbs = limbs << 4 | digit
            var carry = UInt64(digit)
            for i in 0..<limbs.count {
                let shifted = limbs[i] << 4
                let sum = shifted &+ carry
                carry = (limbs[i] >> 60) &+ (sum < shifted ? 1 : 0)
                limbs[i] = sum
            }
            if carry != 0 {
                limbs.append(carry)
            }
        }
        self.init(limbs: limbs)
    }

    var isZero: Bool {
        limbs.allSatisfy { $0 == 0 }
    }

    var bitWidth: Int {
        guard let top = limbs.lastIndex(where: { $0 != 0 }) else { return 0 }
        return top * 64 + (64 - limbs[top].leadingZeroBitCount)
    }

    func bit(at index: Int) -> UInt64 {
        let word = index / 64
        guard word < limbs.count else { return 0 }
        return (limbs[word] >> UInt64(index % 64)) & 1
    }

    func shiftedLeftOneBit(insertingBit bit: UInt64) -> NeteaseBigUInt {
        guard !limbs.isEmpty else { return NeteaseBigUInt(limbs: [bit & 1]) }
        var out = [UInt64](repeating: 0, count: limbs.count + 1)
        var carry = bit & 1
        for i in 0..<limbs.count {
            out[i] = (limbs[i] << 1) | carry
            carry = limbs[i] >> 63
        }
        out[limbs.count] = carry
        return NeteaseBigUInt(limbs: out)
    }

    func shiftedRightOneBit() -> NeteaseBigUInt {
        var out = [UInt64](repeating: 0, count: limbs.count)
        var carry: UInt64 = 0
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            let nextCarry = limbs[i] & 1
            out[i] = (limbs[i] >> 1) | (carry << 63)
            carry = nextCarry
        }
        return NeteaseBigUInt(limbs: out)
    }

    func hexString(paddedTo digits: Int) -> String {
        var result = ""
        var started = false
        for limb in limbs.reversed() {
            let hex = String(limb, radix: 16)
            if !started {
                if limb != 0 {
                    result += hex
                    started = true
                }
            } else {
                result += String(repeating: "0", count: 16 - hex.count) + hex
            }
        }
        if result.isEmpty { result = "0" }
        while result.count < digits {
            result = "0" + result
        }
        return result
    }

    static func < (lhs: NeteaseBigUInt, rhs: NeteaseBigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        var i = lhs.limbs.count - 1
        while i >= 0 {
            if lhs.limbs[i] != rhs.limbs[i] {
                return lhs.limbs[i] < rhs.limbs[i]
            }
            i -= 1
        }
        return false
    }

    /// 假定 lhs >= rhs。
    static func - (lhs: NeteaseBigUInt, rhs: NeteaseBigUInt) -> NeteaseBigUInt {
        var out = [UInt64](repeating: 0, count: lhs.limbs.count)
        var borrow: UInt64 = 0
        for i in 0..<lhs.limbs.count {
            let r = i < rhs.limbs.count ? rhs.limbs[i] : 0
            let (d1, b1) = lhs.limbs[i].subtractingReportingOverflow(r)
            let (d2, b2) = d1.subtractingReportingOverflow(borrow)
            out[i] = d2
            borrow = (b1 ? 1 : 0) &+ (b2 ? 1 : 0)
        }
        return NeteaseBigUInt(limbs: out)
    }

    static func * (lhs: NeteaseBigUInt, rhs: NeteaseBigUInt) -> NeteaseBigUInt {
        if lhs.isZero || rhs.isZero { return .zero }

        let m = lhs.limbs.count
        let n = rhs.limbs.count
        var result = [UInt64](repeating: 0, count: m + n)

        for i in 0..<m {
            let a = lhs.limbs[i]
            if a == 0 { continue }

            var carry: UInt64 = 0
            // carry 溢出 2^64 的部分（0 或 1），作为下一轮的额外进位。
            var carryHigh: UInt64 = 0

            for j in 0..<n {
                let (hi, lo) = a.multipliedFullWidth(by: rhs.limbs[j])
                let idx = i + j

                let t1 = result[idx] &+ lo
                let c1: UInt64 = t1 < result[idx] ? 1 : 0
                let t2 = t1 &+ carry
                let c2: UInt64 = t2 < t1 ? 1 : 0
                result[idx] = t2

                let (h1, o1) = hi.addingReportingOverflow(c1)
                let (h2, o2) = h1.addingReportingOverflow(c2)
                let (h3, o3) = h2.addingReportingOverflow(carryHigh)
                carry = h3
                carryHigh = (o1 || o2 || o3) ? 1 : 0
            }

            var idx = i + n
            while carry != 0 || carryHigh != 0 {
                if idx >= result.count { result.append(0) }
                let t1 = result[idx] &+ carry
                let c1: UInt64 = t1 < result[idx] ? 1 : 0
                result[idx] = t1
                let (h, o) = c1.addingReportingOverflow(carryHigh)
                carry = h
                carryHigh = o ? 1 : 0
                idx += 1
            }
        }

        return NeteaseBigUInt(limbs: result)
    }

    static func % (lhs: NeteaseBigUInt, rhs: NeteaseBigUInt) -> NeteaseBigUInt {
        if rhs.isZero { return lhs }
        if lhs < rhs { return lhs }

        // 二进制长除法：1024 位被除数约 2048 位，循环次数固定且有限。
        var remainder = NeteaseBigUInt.zero
        var i = lhs.bitWidth - 1
        while i >= 0 {
            remainder = remainder.shiftedLeftOneBit(insertingBit: lhs.bit(at: i))
            if !(remainder < rhs) {
                remainder = remainder - rhs
            }
            i -= 1
        }
        return remainder
    }

    static func powMod(
        base: NeteaseBigUInt,
        exponent: NeteaseBigUInt,
        modulus: NeteaseBigUInt
    ) -> NeteaseBigUInt {
        if modulus.isZero {
            return NeteaseBigUInt(limbs: [1])
        }

        var result = NeteaseBigUInt(limbs: [1])
        var b = base % modulus
        var e = exponent

        while !e.isZero {
            if e.bit(at: 0) == 1 {
                result = (result * b) % modulus
            }
            b = (b * b) % modulus
            e = e.shiftedRightOneBit()
        }

        return result
    }
}
