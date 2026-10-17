import Foundation

// MARK: - 「最新发布」卡片的数据
//
// 用户 2026-10-17（图片 136）：AM 的艺人页在**三颗按钮下面**有一张"最新发布"小卡片：
//
//     ┌────────────────────────────────────────┐
//     │ [封面]  2026年8月22日                   │
//     │         空耳 - Single                   │
//     │         2 首歌曲                         │
//     └────────────────────────────────────────┘
//
// **Spotify 的艺人页没有这一块**（日志 109 的 `[ArtistPageProbe]` 逐行：只有 你已点赞 / 热门 /
// 艺人之选 / 热门新歌，没有任何 release 元素）⇒ 数据和卡片都得我们自己来。
//
// ## 数据源：iTunes Search API（实测 2026-10-17）
//
// `GET https://itunes.apple.com/search?term=<艺人>&entity=album&limit=50&country=jp`
// 对图片 136 那位艺人（ナナツカゼ）返回的最新一条与 AM 卡片**逐字一致**：
//
//     2026-08-22 | 空耳 - Single | ナナツカゼ | tracks=2 | artworkUrl100=…/100x100bb.jpg
//
// 选择它的理由：
//   · **不需要任何令牌**（Apple 的公开搜索接口），不像官方 TTML 那条要 `media-user-token`；
//   · 四个字段（日期 / 名称 / 曲数 / 封面）一次全给；
//   · 「最新发布」本来就是**苹果的目录**在 AM 里显示的东西 —— 用苹果的目录最不容易对不上。
//   封面把 `100x100bb` 换成 `600x600bb` 就是大图。
//
// ⚠️ 搜索是**按相关度**返回的，**不按日期** ⇒ 必须 `limit=50` 拉一批、自己按 `releaseDate` 取最新；
//    并且要核对 `artistName` 与页面上那位艺人（同名不同人时不能直接采信）。
//
// ## 优先级（用户 2026-10-17 追加）
//
// 「优先展示**艺人之选**，没有艺人之选再展示最新发布」。艺人之选是 **Spotify 自己的**板块
// （日志 109：`[ArtistPageProbe] matches y=996 — … [艺人之选]`），不在苹果目录里 ⇒ 它只能从
// 页面里读（见 `EntityPageHeaderManager.captureArtistPick`）。本文件只管"最新发布"这一档。

/// 一张「最新发布」卡片要的全部东西。
struct ArtistLatestRelease {
    let title: String
    let date: Date?
    let trackCount: Int
    let artworkURL: URL?
    /// 取到它的时间（缓存用）。
    let fetchedAt: Date
}

enum ArtistLatestReleaseSource {

    /// 卡片上的日期。AM 用"2026年8月22日"这种**长日期**，跟随系统语言。
    static let cardDateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    // MARK: - 缓存

    private static var cache: [String: ArtistLatestRelease] = [:]
    private static var inFlight: Set<String> = []
    private static let lock = NSLock()
    private static let ttl: TimeInterval = 6 * 60 * 60

    private static var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// 已经取到过的那一份（同步、给 `layoutSubviews` 那一拍用）。
    static func cached(for artist: String) -> ArtistLatestRelease? {
        let key = normalized(artist)
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key] else { return nil }
        guard Date().timeIntervalSince(entry.fetchedAt) < ttl else {
            cache[key] = nil
            return nil
        }
        return entry
    }

    // MARK: - 取数

    /// 取这位艺人的最新一条发布；已经有缓存 / 已经有请求在飞时不重复发。
    ///
    /// - Note: 回调**一定**在主队列上。
    static func fetch(artist: String, completion: @escaping (ArtistLatestRelease?) -> Void) {
        let key = normalized(artist)
        guard !key.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        if let cached = cached(for: artist) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        lock.lock()
        let alreadyRunning = !inFlight.insert(key).inserted
        lock.unlock()
        guard !alreadyRunning else { return }

        guard let url = url(for: artist) else {
            finish(key: key, release: nil, completion: completion)
            return
        }

        writeDebugLog("[Release] iTunes search — \"\(artist)\"")

        let task = session.dataTask(with: url) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, error == nil, status == 200 else {
                writeDebugLog(
                    "[Release] iTunes search failed for \"\(artist)\" —"
                        + " status \(status), error \(error.map { "\($0)" } ?? "-")"
                )
                finish(key: key, release: nil, completion: completion)
                return
            }

            let release = parse(data: data, artist: artist)
            if let release {
                writeDebugLog(
                    "[Release] \"\(artist)\" → \(release.title)"
                        + " (\(release.trackCount) track(s),"
                        + " \(release.date.map { cardDateFormat.string(from: $0) } ?? "date ?"))"
                )
            } else {
                writeDebugLog("[Release] \"\(artist)\" — no usable release in the iTunes response")
            }
            finish(key: key, release: release, completion: completion)
        }
        task.resume()
    }

    private static func finish(
        key: String,
        release: ArtistLatestRelease?,
        completion: @escaping (ArtistLatestRelease?) -> Void
    ) {
        lock.lock()
        inFlight.remove(key)
        if let release { cache[key] = release }
        lock.unlock()
        DispatchQueue.main.async { completion(release) }
    }

    private static func url(for artist: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        // 国家/地区影响"这位艺人有哪些发布"（日区艺人只在 jp 目录里齐全）。
        let country = (Locale.current.region?.identifier ?? "us").lowercased()
        components?.queryItems = [
            URLQueryItem(name: "term", value: artist),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "country", value: country),
        ]
        return components?.url
    }

    // MARK: - 解析

    private static func parse(data: Data, artist: String) -> ArtistLatestRelease? {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let root = raw as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            return nil
        }

        let wanted = normalized(artist)
        var newest: ArtistLatestRelease?

        for item in results {
            guard let name = item["collectionName"] as? String, !name.isEmpty else { continue }

            // 歌手对不上的一律不要（同名不同人是这里唯一的坑）。
            let artistName = item["artistName"] as? String ?? ""
            let normalizedArtist = normalized(artistName)
            guard !normalizedArtist.isEmpty, normalizedArtist.contains(wanted) || wanted.contains(normalizedArtist)
            else { continue }

            let date = parseDate(item["releaseDate"] as? String)
            let tracks = item["trackCount"] as? Int ?? 0
            let artwork = (item["artworkUrl100"] as? String).flatMap(upsizedArtwork)

            let release = ArtistLatestRelease(
                title: name,
                date: date,
                trackCount: tracks,
                artworkURL: artwork,
                fetchedAt: Date()
            )

            // 没日期的排在最后 —— 有日期里挑最新的。
            switch (newest?.date, release.date) {
            case let (existing?, candidate?):
                if candidate > existing { newest = release }
            case (nil, _?):
                newest = release
            case (_?, nil):
                break
            case (nil, nil):
                if newest == nil { newest = release }
            }
        }

        return newest
    }

    /// `06/20/2025 07:00:00` —— iTunes 的固定格式（**不是**跟随地区的那一套）。
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MM/dd/yyyy HH:mm:ss"
        return formatter.date(from: raw)
    }

    /// `…/100x100bb.jpg` → `…/600x600bb.jpg`（同一张图的大图）。
    private static func upsizedArtwork(_ raw: String) -> URL? {
        URL(string: raw.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { character in
            character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        }
    }
}
