import Foundation
import UIKit

/// 「艺人介绍」的**兜底来源**（2026-10-18 第四轮，用户：「或者 关于艺人 的来源你有什么好方法么，
/// 维基百科？spotify 原生？」）。
///
/// ## 为什么是 Genius
///
/// 本仓库**已经有** Genius 这条线（`Lyrics/Repositories/GeniusLyricsRepository.swift`：`api.genius.com`，
/// 用的是**免 key** 的那套头部 —— `X-Genius-Logged-Out: true` + iOS 版 User-Agent）⇒ 这里复用同一套：
/// 不新增 key、不新增账号、用户不用配置任何东西 ✓。
///
/// 它补的是 Spotify 那边**读不到**的情况（正文为空 / 被截断 / 那一块没建出来）：
///   · `GET /search?q=<艺人名>` —— 取 `type == artist` 且**名字对得上**的那个命中；没有就退到歌命中的主艺人；
///   · `GET /artists/<id>` —— `response.artist.description.plain` 就是简介。
///
/// ⚠️ 两点如实说：
///   ① Genius 的艺人简介**基本是英文**（Spotify 那边是跟着 app 语言的）⇒ **只在 Spotify 读不到时才用**
///      （见 `ArtistBioSheet.present`），而且要**署名**（`artist_bio_from_genius` 那一行）。
///   ② 维基百科**不做正文**：CC BY-SA 要署名 + 许可链接，而且你听的那批日系独立艺人命中率很低
///      ⇒ 只做成一个**链接**（`ArtistBioSheet` 底部那颗 Wikipedia 按钮）。
///      Spotify 自己的 About 页也是这么干的：`SPTArtistAbout:sArtistWikipediaButtonTitle`（dump:21079）。
enum ArtistBioSource {

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "X-Genius-iOS-Version": "6.21.0",
            "X-Genius-Logged-Out": "true",
            "User-Agent": "Genius/1109 iOS/\(UIDevice.current.systemVersion)",
        ]
        configuration.timeoutIntervalForRequest = 12
        return URLSession(configuration: configuration)
    }()

    /// 取这位艺人的简介（回调一律在**主线程**；取不到就是 nil）。
    static func geniusBio(for artist: String, completion: @escaping (String?) -> Void) {
        let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var components = URLComponents(string: "https://api.genius.com/search") else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        components.queryItems = [URLQueryItem(name: "q", value: name)]
        guard let url = components.url else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        fetchJSON(url) { search in
            guard let hits = (search?["response"] as? [String: Any])?["hits"] as? [[String: Any]] else {
                completion(nil)
                return
            }
            var artistID: Int?
            var fallbackID: Int?
            for hit in hits {
                guard let result = hit["result"] as? [String: Any] else { continue }
                if (hit["type"] as? String) == "artist",
                   let id = result["id"] as? Int,
                   let hitName = result["name"] as? String,
                   hitName.compare(name, options: .caseInsensitive) == .orderedSame {
                    artistID = id
                    break
                }
                if fallbackID == nil, let primary = result["primary_artist"] as? [String: Any] {
                    fallbackID = primary["id"] as? Int
                }
            }
            guard let id = artistID ?? fallbackID,
                  let detail = URL(string: "https://api.genius.com/artists/\(id)") else {
                completion(nil)
                return
            }
            fetchJSON(detail) { payload in
                let artist = (payload?["response"] as? [String: Any])?["artist"] as? [String: Any]
                let description = artist?["description"] as? [String: Any]
                let plain = (description?["plain"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                completion((plain?.isEmpty ?? true) ? nil : plain)
            }
        }
    }

    /// 一次 GET → JSON。**日志与回调都在主线程**（底色/界面那边只认主线程；日志文件也不从后台线程写）。
    ///
    /// ⚠️ 名字**不能叫 `get`** —— `swift_member_check.py` 会把这种通用名当成"不该私有的短名"
    /// （实测一次白跑：25 条 `get` 报错，连别的文件的都一起翻出来）。
    private static func fetchJSON(_ url: URL, completion: @escaping ([String: Any]?) -> Void) {
        session.dataTask(with: url) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var json: [String: Any]?
            if let data, let object = try? JSONSerialization.jsonObject(with: data) {
                json = object as? [String: Any]
            }
            DispatchQueue.main.async {
                if status != 200 {
                    writeDebugLog("[ArtistBio] genius \(url.path) → HTTP \(status)")
                }
                completion(json)
            }
        }.resume()
    }
}
