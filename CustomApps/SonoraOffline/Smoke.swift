import Foundation
import SonoraCore

@main struct Smoke {
    static func main() async {
        do {
            let catalog = try await SpotifyCatalog.load("https://open.spotify.com/track/0VjIjW4GlUZAMYd2vXMi3b")
            print("CATALOG_OK: \(catalog.title), \(catalog.tracks.count) track")
        } catch { print("CATALOG_NETWORK_ERROR: \(error.localizedDescription)") }
        do {
            // Blender Foundation's Creative Commons test film; request only a small audio range.
            let audio = try await NativeAudio.resolve(videoID: "aqz-KE-bpKQ")
            var request = URLRequest(url: audio.url, timeoutInterval: 25)
            request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("NATIVE_AUDIO_HTTP: \(status), BYTES: \(data.count), FORMAT: \(audio.fileExtension)")
            if (200..<300).contains(status) && data.count > 1024 { print("NATIVE_AUDIO_OK") }
        } catch { print("NATIVE_AUDIO_NETWORK_ERROR: \(error.localizedDescription)") }
    }
}
