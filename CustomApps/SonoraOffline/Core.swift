import Foundation
import YouTubeKit

public struct CatalogTrack: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let artist: String
    public let duration: Double
    public let coverURL: URL?
    public var spotifyURL: URL { URL(string: "https://open.spotify.com/track/\(id)")! }
    public init(id: String, title: String, artist: String, duration: Double, coverURL: URL?) {
        self.id = id; self.title = title; self.artist = artist; self.duration = duration; self.coverURL = coverURL
    }
}

public struct Catalog: Sendable {
    public let title: String
    public let artist: String
    public let coverURL: URL?
    public let tracks: [CatalogTrack]
}

public enum SonoraError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public enum WebData {
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.5 Safari/605.1.15"
    public static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SonoraError.message("El servicio no respondió correctamente. Vuelve a intentarlo.")
        }
        return data
    }

    /// Extract a JSON object while respecting braces embedded inside JSON strings.
    public static func object(in text: String, after marker: String) throws -> [String: Any] {
        guard let start = text.range(of: marker)?.upperBound,
              let first = text[start...].firstIndex(of: "{") else {
            throw SonoraError.message("El servicio cambió el formato de sus datos.")
        }
        var depth = 0, quoted = false, escaped = false
        for index in text[first...].indices {
            let char = text[index]
            if quoted {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { quoted = false }
            } else if char == "\"" { quoted = true }
            else if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 {
                    let data = Data(text[first...index].utf8)
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
                    return object
                }
            }
        }
        throw SonoraError.message("Los datos llegaron incompletos. Vuelve a intentarlo.")
    }
}

public enum SpotifyCatalog {
    public static func reference(_ input: String) throws -> (kind: String, id: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String]
        if value.hasPrefix("spotify:") { parts = value.components(separatedBy: ":").dropFirst().map { $0 } }
        else {
            guard let url = URL(string: value), url.scheme == "https", url.host == "open.spotify.com",
                  url.user == nil, url.password == nil, url.port == nil else {
                throw SonoraError.message("Pega el enlace completo de Spotify de una canción o álbum.")
            }
            parts = url.pathComponents.filter { $0 != "/" }
            if parts.first?.hasPrefix("intl-") == true { parts.removeFirst() }
            if parts.first == "embed" { parts.removeFirst() }
        }
        guard parts.count == 2, ["track", "album", "playlist"].contains(parts[0]),
              parts[1].range(of: "^[A-Za-z0-9]{22}$", options: .regularExpression) != nil else {
            throw SonoraError.message("Ese enlace no corresponde a una canción, álbum o playlist pública.")
        }
        return (parts[0], parts[1])
    }

    public static func load(_ input: String) async throws -> Catalog {
        let ref = try reference(input)
        let data = try await WebData.fetch(URL(string: "https://open.spotify.com/embed/\(ref.kind)/\(ref.id)")!)
        let html = String(decoding: data, as: UTF8.self)
        let root = try WebData.object(in: html, after: "id=\"__NEXT_DATA__\"")
        guard let props = root["props"] as? [String: Any], let page = props["pageProps"] as? [String: Any],
              let state = page["state"] as? [String: Any], let payload = state["data"] as? [String: Any],
              let entity = payload["entity"] as? [String: Any] else {
            throw SonoraError.message("Spotify no entregó el contenido de ese enlace. Comprueba que sea público.")
        }
        return try parse(entity)
    }

    public static func parse(_ entity: [String: Any]) throws -> Catalog {
        let title = entity["title"] as? String ?? entity["name"] as? String ?? "Spotify"
        let artists = (entity["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
        let artist = entity["subtitle"] as? String ?? artists
        let visual = entity["visualIdentity"] as? [String: Any]
        let images = visual?["image"] as? [[String: Any]] ?? []
        let artwork = images.last?["url"] as? String
        let cover = artwork.flatMap(URL.init(string:))
        let rows = entity["trackList"] as? [[String: Any]] ?? [entity]
        var seen = Set<String>()
        let tracks: [CatalogTrack] = rows.compactMap { row in
            guard let uri = row["uri"] as? String, uri.hasPrefix("spotify:track:"),
                  let id = uri.components(separatedBy: ":").last,
                  id.range(of: "^[A-Za-z0-9]{22}$", options: .regularExpression) != nil,
                  seen.insert(id).inserted else { return nil }
            return CatalogTrack(id: id, title: row["title"] as? String ?? title,
                                artist: row["subtitle"] as? String ?? artist,
                                duration: (row["duration"] as? Double ?? 0) / 1000, coverURL: cover)
        }
        guard !tracks.isEmpty else { throw SonoraError.message("No se encontraron canciones en este enlace.") }
        // The public embed can limit long playlists; never claim a full playlist was imported.
        if entity["type"] as? String == "playlist", tracks.count >= 100 {
            throw SonoraError.message("Spotify limita esta playlist pública. Abre sus álbumes por separado.")
        }
        return Catalog(title: title, artist: artist, coverURL: cover, tracks: tracks)
    }
}

public struct VideoCandidate: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let channel: String
    public let duration: Double
    public var thumbnail: URL { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")! }
}

public enum YouTubeSearch {
    private static func text(_ value: Any?) -> String {
        guard let object = value as? [String: Any] else { return "" }
        return object["simpleText"] as? String ?? (object["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }
    public static func candidates(from root: Any) -> [VideoCandidate] {
        var output: [VideoCandidate] = [], seen = Set<String>()
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let video = dictionary["videoRenderer"] as? [String: Any], let id = video["videoId"] as? String,
                   id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil,
                   seen.insert(id).inserted {
                    let components = text(video["lengthText"]).split(separator: ":").compactMap { Double($0) }
                    let duration = components.reduce(0) { $0 * 60 + $1 }
                    if duration > 0 {
                        output.append(VideoCandidate(id: id, title: text(video["title"]),
                                                     channel: text(video["ownerText"] ?? video["longBylineText"]), duration: duration))
                    }
                }
                for child in dictionary.values { walk(child) }
            } else if let array = value as? [Any] { array.forEach(walk) }
        }
        walk(root)
        return Array(output.prefix(30))
    }
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
    }
    public static func score(_ video: VideoCandidate, for track: CatalogTrack) -> Double {
        let target = Set(normalized(track.title).split(separator: " ").map(String.init))
        let words = Set(normalized(video.title).split(separator: " ").map(String.init))
        let artist = Set(normalized(track.artist).split(separator: " ").map(String.init))
        let context = normalized(video.title + " " + video.channel)
        guard !target.isEmpty else { return 0 }
        let titleMatch = Double(target.intersection(words).count) / Double(target.count)
        let artistMatch = Double(artist.filter { context.contains($0) }.count) / Double(max(1, artist.count))
        if titleMatch < 0.6 { return 0 }
        let original = normalized(track.title)
        for unwanted in ["karaoke", "cover", "remix", "live", "sped up", "slowed", "instrumental"] {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: unwanted) + "\\b"
            if normalized(video.title).range(of: pattern, options: .regularExpression) != nil && original.range(of: pattern, options: .regularExpression) == nil { return 0 }
        }
        let difference = abs(video.duration - track.duration)
        if track.duration > 0 && difference > max(25, track.duration * 0.15) { return 0 }
        let timing = track.duration <= 0 ? 0.5 : max(0, 1 - difference / max(10, track.duration * 0.12))
        return titleMatch * 0.50 + artistMatch * 0.30 + timing * 0.20
    }
    public static func search(_ track: CatalogTrack) async throws -> [VideoCandidate] {
        var url = URLComponents(string: "https://www.youtube.com/results")!
        url.queryItems = [.init(name: "search_query", value: track.artist + " " + track.title + " audio")]
        let html = String(decoding: try await WebData.fetch(url.url!), as: UTF8.self)
        var object: [String: Any]?
        for marker in ["var ytInitialData =", "window[\"ytInitialData\"] =", "ytInitialData ="] {
            if let candidate = try? WebData.object(in: html, after: marker) { object = candidate; break }
        }
        guard let object else { throw SonoraError.message("YouTube no entregó los resultados. Vuelve a intentarlo.") }
        return candidates(from: object).sorted { score($0, for: track) > score($1, for: track) }
    }
}

public struct ResolvedAudio: Sendable {
    public let url: URL
    public let fileExtension: String
}

public enum NativeAudio {
    public static func resolve(videoID: String) async throws -> ResolvedAudio {
        // Explicitly local: never use YouTubeKit's optional remote extraction service.
        let streams = try await YouTube(videoID: videoID, methods: [.local]).streams
        if let audio = streams.filterAudioOnly().filter({ $0.fileExtension == .m4a }).highestAudioBitrateStream() {
            return ResolvedAudio(url: audio.url, fileExtension: "m4a")
        }
        if let combined = streams.filterVideoAndAudio().filter({ $0.fileExtension == .mp4 && $0.isNativelyPlayable }).lowestResolutionStream() {
            return ResolvedAudio(url: combined.url, fileExtension: "mp4")
        }
        throw SonoraError.message("YouTube no entregó un audio compatible para esta versión. Prueba otra coincidencia.")
    }
}
