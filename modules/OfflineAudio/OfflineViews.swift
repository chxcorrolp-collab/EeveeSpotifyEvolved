import SwiftUI
import AVFoundation
import MediaPlayer
import UIKit

struct SavedSong: Codable, Identifiable {
    var id: String { track.id }
    let track: CatalogTrack
    let filename: String
    let videoID: String
    let duration: Double
    let addedAt: Date
}

struct DownloadTicket: Codable {
    let track: CatalogTrack
    let videoID: String
    let fileExtension: String
}

struct PendingSong: Codable { let track: CatalogTrack; let videoID: String? }

enum LocalFiles {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    static let audio = documents.appendingPathComponent("EeveeOfflineAudio", isDirectory: true)
    static let covers = support.appendingPathComponent("EeveeOfflineCovers", isDirectory: true)
    static let incoming = support.appendingPathComponent("EeveeOfflineIncoming", isDirectory: true)
    static func setup() { for url in [support, audio, covers, incoming] { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } }
    static func image(_ id: String) -> UIImage? { UIImage(contentsOfFile: covers.appendingPathComponent(id + ".jpg").path) }
}

final class Transfers: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = Transfers()
    weak var owner: MusicStore?
    var completion: (() -> Void)?
    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.eeveespotify.offline.downloads")
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForResource = 1800
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    func start(_ ticket: DownloadTicket, url: URL) throws {
        var request = URLRequest(url: url)
        request.setValue(WebData.userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        task.taskDescription = String(decoding: try JSONEncoder().encode(ticket), as: UTF8.self)
        task.resume()
    }
    func ticket(_ task: URLSessionTask) -> DownloadTicket? {
        guard let description = task.taskDescription else { return nil }
        return try? JSONDecoder().decode(DownloadTicket.self, from: Data(description.utf8))
    }
    func cancel(_ id: String) {
        session.getAllTasks { tasks in for task in tasks where self.ticket(task)?.track.id == id { task.cancel() } }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let ticket = ticket(downloadTask) else { return }
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        Task { @MainActor in self.owner?.progress[ticket.track.id] = progress }
        if totalBytesWritten > 250 * 1024 * 1024 { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let ticket = ticket(downloadTask) else { return }
        do {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw SonoraError.message("YouTube rechazó la transferencia (\(status)). Prueba otra versión de la canción.") }
            let destination = LocalFiles.incoming.appendingPathComponent(UUID().uuidString + "." + ticket.fileExtension)
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in await self.owner?.finish(ticket, temporary: destination) }
        } catch { Task { @MainActor in self.owner?.failed(ticket.track.id, error: error) } }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let ticket = ticket(task) else { return }
        Task { @MainActor in self.owner?.failed(ticket.track.id, error: error) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { let handler = self.completion; self.completion = nil; handler?() }
    }
}

@MainActor final class MusicStore: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = MusicStore()
    @Published var link = ""
    @Published var downloadHistory: [CatalogTrack] = []
    @Published var catalog: Catalog?
    @Published var loading = false
    @Published var notice: String?
    @Published var library: [SavedSong] = []
    @Published var phases: [String: String] = [:]
    @Published var progress: [String: Double] = [:]
    @Published var errors: [String: String] = [:]
    @Published var nowPlaying: SavedSong?
    @Published var isPlaying = false
    @Published var elapsed = 0.0
    private var player: AVAudioPlayer?
    private var pending: [PendingSong] = []
    private var active = Set<String>()
    private var resolving: Task<Void, Never>?
    private var resolvingID: String?
    private var timer: Timer?
    private let queueFile = LocalFiles.support.appendingPathComponent("eevee-offline-queue.json")
    private let libraryFile = LocalFiles.support.appendingPathComponent("eevee-offline-library.json")

    override init() {
        LocalFiles.setup()
        super.init()
        if let data = try? Data(contentsOf: libraryFile), let entries = try? JSONDecoder().decode([SavedSong].self, from: data) {
            library = entries.filter { FileManager.default.fileExists(atPath: LocalFiles.audio.appendingPathComponent($0.filename).path) }
        }
        if let data = try? Data(contentsOf: queueFile) { pending = (try? JSONDecoder().decode([PendingSong].self, from: data)) ?? [] }
        for item in pending { phases[item.track.id] = "En cola" }
        Transfers.shared.owner = self
        Transfers.shared.session.getAllTasks { tasks in
            Task { @MainActor in
                for task in tasks {
                    if let ticket = Transfers.shared.ticket(task) {
                        self.active.insert(ticket.track.id)
                        self.phases[ticket.track.id] = "Descargando"
                        self.pending.removeAll { $0.track.id == ticket.track.id }
                    }
                }
                self.persistQueue()
                self.beginNext()
            }
        }
        MPRemoteCommandCenter.shared().playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        MPRemoteCommandCenter.shared().pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        MPRemoteCommandCenter.shared().nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(1) }; return .success }
        MPRemoteCommandCenter.shared().previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-1) }; return .success }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = self?.player?.currentTime ?? 0; self?.updateNowPlaying() }
        }
    }
    private func persistQueue() { if let data = try? JSONEncoder().encode(pending) { try? data.write(to: queueFile, options: .atomic) } }
    private func persistLibrary() { if let data = try? JSONEncoder().encode(library) { try? data.write(to: libraryFile, options: .atomic) } }
    func saved(_ id: String) -> SavedSong? { library.first { $0.id == id } }
    func openLink() async {
        loading = true
        defer { loading = false }
        do {
            notice = nil
            catalog = try await SpotifyCatalog.load(link)
            downloadHistory = catalog?.tracks ?? []
        }
        catch { notice = error.localizedDescription }
    }
    func enqueue(_ track: CatalogTrack, videoID: String? = nil) {
        guard saved(track.id) == nil, !active.contains(track.id), !pending.contains(where: { $0.track.id == track.id }) else { return }
        guard pending.count < 100 else { notice = "La cola admite hasta 100 canciones. Espera a que termine alguna descarga."; return }
        errors[track.id] = nil
        pending.append(PendingSong(track: track, videoID: videoID))
        phases[track.id] = "En cola"
        persistQueue()
        beginNext()
    }
    func enqueueAlbum() { for track in catalog?.tracks ?? [] { enqueue(track) } }
    private func beginNext() {
        guard resolving == nil, active.isEmpty, let item = pending.first else { return }
        resolvingID = item.track.id
        phases[item.track.id] = "Buscando audio"
        resolving = Task {
            do {
                let videoID: String
                let audio: ResolvedAudio
                if let forced = item.videoID {
                    videoID = forced
                    audio = try await NativeAudio.resolve(videoID: forced)
                } else {
                    let matches = try await YouTubeSearch.search(item.track)
                    let plausible = matches.filter { YouTubeSearch.score($0, for: item.track) >= 0.72 }
                    guard !plausible.isEmpty else { throw SonoraError.message("No encontré una coincidencia fiable. Usa «Elegir versión» para seleccionar el audio.") }
                    var resolved: (String, ResolvedAudio)?
                    for candidate in plausible.prefix(3) {
                        try Task.checkCancellation()
                        if let stream = try? await NativeAudio.resolve(videoID: candidate.id) { resolved = (candidate.id, stream); break }
                    }
                    guard let match = resolved else { throw SonoraError.message("YouTube no entregó audio para estas coincidencias. Puedes elegir otra versión e intentarlo de nuevo.") }
                    (videoID, audio) = match
                }
                try Task.checkCancellation()
                let ticket = DownloadTicket(track: item.track, videoID: videoID, fileExtension: audio.fileExtension)
                active.insert(item.track.id)
                phases[item.track.id] = "Descargando"
                progress[item.track.id] = 0
                do { try Transfers.shared.start(ticket, url: audio.url) }
                catch { active.remove(item.track.id); throw error }
                pending.removeAll { $0.track.id == item.track.id }
            } catch {
                pending.removeAll { $0.track.id == item.track.id }
                if !(error is CancellationError) { errors[item.track.id] = error.localizedDescription; phases[item.track.id] = "Reintentar" }
                else { phases[item.track.id] = nil }
            }
            resolving = nil; resolvingID = nil
            persistQueue()
            beginNext()
        }
    }
    func cancel(_ id: String) {
        pending.removeAll { $0.track.id == id }
        if resolvingID == id { resolving?.cancel() }
        if active.contains(id) { Transfers.shared.cancel(id) }
        phases[id] = nil; progress[id] = nil; persistQueue()
    }
    func failed(_ id: String, error: Error) {
        active.remove(id); progress[id] = nil
        if (error as NSError).code != NSURLErrorCancelled { errors[id] = error.localizedDescription; phases[id] = "Reintentar" }
        else { phases[id] = nil }
        beginNext()
    }
    func finish(_ ticket: DownloadTicket, temporary: URL) async {
        phases[ticket.track.id] = "Guardando en iPhone"
        var final = temporary
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            if ticket.fileExtension != "m4a" {
                let converted = LocalFiles.incoming.appendingPathComponent(UUID().uuidString + ".m4a")
                guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: temporary), presetName: AVAssetExportPresetAppleM4A) else {
                    throw SonoraError.message("No se pudo convertir este audio.")
                }
                exporter.outputURL = converted; exporter.outputFileType = .m4a
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    exporter.exportAsynchronously {
                        if exporter.status == .completed { continuation.resume() }
                        else { continuation.resume(throwing: exporter.error ?? SonoraError.message("La conversión no terminó.")) }
                    }
                }
                final = converted
            }
            let verifier = try AVAudioPlayer(contentsOf: final)
            guard verifier.duration > 1 && verifier.duration.isFinite else { throw SonoraError.message("El archivo descargado no contiene un audio válido.") }
            let filename = ticket.track.id + ".m4a"
            var destination = LocalFiles.audio.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: final, to: destination)
            var resource = URLResourceValues(); resource.isExcludedFromBackup = true
            try? destination.setResourceValues(resource)
            let savedSong = SavedSong(track: ticket.track, filename: filename, videoID: ticket.videoID, duration: verifier.duration, addedAt: Date())
            library.removeAll { $0.id == ticket.track.id }; library.insert(savedSong, at: 0)
            persistLibrary()
            phases[ticket.track.id] = nil; progress[ticket.track.id] = nil; errors[ticket.track.id] = nil
            if let url = ticket.track.coverURL, let data = try? await WebData.fetch(url), data.count < 5_000_000, let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.8) {
                try? jpeg.write(to: LocalFiles.covers.appendingPathComponent(ticket.track.id + ".jpg"), options: .atomic)
            }
            active.remove(ticket.track.id)
            beginNext()
        } catch { if final != temporary { try? FileManager.default.removeItem(at: final) }; failed(ticket.track.id, error: error) }
    }
    func play(_ song: SavedSong) {
        do {
            NotificationCenter.default.post(name: Notification.Name("EeveeOfflineWillPlay"), object: nil)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: LocalFiles.audio.appendingPathComponent(song.filename))
            player?.delegate = self; player?.prepareToPlay(); player?.play()
            nowPlaying = song; isPlaying = true; elapsed = 0; updateNowPlaying()
        } catch { notice = error.localizedDescription }
    }
    func resume() { player?.play(); isPlaying = player?.isPlaying ?? false; updateNowPlaying() }
    func pause() { player?.pause(); isPlaying = false; updateNowPlaying() }
    func toggle() { isPlaying ? pause() : resume() }
    func seek(_ time: Double) { player?.currentTime = time; elapsed = time; updateNowPlaying() }
    func skip(_ offset: Int) {
        guard let song = nowPlaying, let index = library.firstIndex(where: { $0.id == song.id }), !library.isEmpty else { return }
        play(library[(index + offset + library.count) % library.count])
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { skip(1) }
    func remove(_ song: SavedSong) {
        if nowPlaying?.id == song.id { pause(); nowPlaying = nil; player = nil }
        try? FileManager.default.removeItem(at: LocalFiles.audio.appendingPathComponent(song.filename))
        try? FileManager.default.removeItem(at: LocalFiles.covers.appendingPathComponent(song.id + ".jpg"))
        library.removeAll { $0.id == song.id }; persistLibrary()
    }
    private func updateNowPlaying() {
        guard let song = nowPlaying else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: song.track.title, MPMediaItemPropertyArtist: song.track.artist,
                                 MPMediaItemPropertyPlaybackDuration: song.duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: player?.currentTime ?? 0,
                                 MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0]
        if let image = LocalFiles.image(song.id) { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

private let mint = Color(red: 0.63, green: 0.97, blue: 0.67)
private let canvas = Color(red: 0.055, green: 0.065, blue: 0.085)

struct Artwork: View {
    let url: URL?
    var savedID: String? = nil
    var body: some View {
        Group {
            if let savedID, let image = LocalFiles.image(savedID) { Image(uiImage: image).resizable().scaledToFill() }
            else if let url { AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder } }
            else { placeholder }
        }.clipped()
    }
    private var placeholder: some View {
        ZStack { LinearGradient(colors: [mint.opacity(0.35), .indigo.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing); Image(systemName: "waveform").font(.title).foregroundStyle(mint) }
    }
}

struct RootView: View {
    @EnvironmentObject var store: MusicStore
    @State private var playerPresented = false
    var body: some View {
        TabView {
            DownloadStatusView().tabItem { Label("Descargas", systemImage: "arrow.down.circle") }
            LibraryView().tabItem { Label("En mi iPhone", systemImage: "arrow.down.circle") }.badge(store.library.count)
        }
        .safeAreaInset(edge: .bottom) {
            if let song = store.nowPlaying {
                HStack(spacing: 12) {
                    Artwork(url: nil, savedID: song.id).frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) { Text(song.track.title).font(.subheadline.bold()).lineLimit(1); Text(song.track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    Button { store.toggle() } label: { Image(systemName: store.isPlaying ? "pause.fill" : "play.fill").font(.title3) }.buttonStyle(.plain).padding(8)
                }.padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)).padding(.horizontal, 12).padding(.bottom, 4)
                    .contentShape(Rectangle()).onTapGesture { playerPresented = true }
            }
        }
        .sheet(isPresented: $playerPresented) { PlayerView() }
        .overlay(alignment: .topTrailing) { Button("Cerrar") { UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first(where: { $0.isKeyWindow })?.rootViewController?.presentedViewController?.dismiss(animated: true) }.padding(16) }
        .alert("Descargas", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) { Button("Aceptar", role: .cancel) { store.notice = nil } } message: { Text(store.notice ?? "") }
    }
}

struct MatchPicker: View {
    let track: CatalogTrack
    let choose: (VideoCandidate) -> Void
    @State private var matches: [VideoCandidate] = []
    @State private var failure: String?
    @State private var loading = true
    var body: some View {
        NavigationStack {
            List {
                Text("\(track.artist) — \(track.title)").font(.subheadline).foregroundStyle(.secondary)
                if loading { ProgressView("Buscando versiones…") }
                if let failure { Text(failure).foregroundStyle(.orange) }
                ForEach(matches) { video in
                    Button { choose(video) } label: {
                        HStack(spacing: 12) { Artwork(url: video.thumbnail).frame(width: 65, height: 50).clipShape(RoundedRectangle(cornerRadius: 8)); VStack(alignment: .leading, spacing: 5) { Text(video.title).foregroundStyle(.primary); Text("\(video.channel) · \(Int(video.duration) / 60):\(String(format: "%02d", Int(video.duration) % 60))").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "arrow.down") }
                    }
                }
            }.navigationTitle("Elegir versión").navigationBarTitleDisplayMode(.inline)
        }.task { do { matches = try await YouTubeSearch.search(track) } catch { failure = error.localizedDescription }; loading = false }
    }
}

struct LibraryView: View {
    @EnvironmentObject var store: MusicStore
    @State private var search = ""
    private var songs: [SavedSong] { search.isEmpty ? store.library : store.library.filter { ($0.track.title + " " + $0.track.artist).localizedCaseInsensitiveContains(search) } }
    var body: some View {
        NavigationStack {
            Group {
                if store.library.isEmpty {
                    VStack(spacing: 18) { Image(systemName: "arrow.down.circle").font(.system(size: 65, weight: .light)).foregroundStyle(mint); Text("Tu música se queda contigo").font(.title2.bold()); Text("Las canciones que descargues aparecerán aquí y se reproducirán sin internet.").foregroundStyle(.secondary).multilineTextAlignment(.center) }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(canvas)
                } else {
                    List(songs) { song in
                        Button { store.play(song) } label: {
                            HStack(spacing: 13) { Artwork(url: nil, savedID: song.id).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10)); VStack(alignment: .leading, spacing: 5) { Text(song.track.title).foregroundStyle(.primary).fontWeight(.semibold); Text(song.track.artist).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: store.nowPlaying?.id == song.id && store.isPlaying ? "waveform" : "play.fill").foregroundStyle(mint) }.padding(.vertical, 4)
                        }.contextMenu {
                            ShareLink(item: LocalFiles.audio.appendingPathComponent(song.filename)) { Label("Compartir archivo de audio", systemImage: "square.and.arrow.up") }
                            Button("Eliminar descarga", role: .destructive) { store.remove(song) }
                        }.swipeActions { Button("Eliminar", role: .destructive) { store.remove(song) } }
                    }.searchable(text: $search, prompt: "Buscar en mis descargas").listStyle(.plain)
                }
            }.navigationTitle("En mi iPhone").toolbar { ToolbarItem(placement: .navigationBarTrailing) { Text("\(store.library.count)").foregroundStyle(.secondary) } }
        }
    }
}

struct PlayerView: View {
    @EnvironmentObject var store: MusicStore
    var body: some View {
        VStack(spacing: 27) {
            Capsule().fill(.secondary.opacity(0.5)).frame(width: 35, height: 5).padding(.top, 12)
            Spacer()
            if let song = store.nowPlaying {
                Artwork(url: nil, savedID: song.id).frame(maxWidth: 330).aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 25))
                VStack(spacing: 8) { Text(song.track.title).font(.title2.bold()).multilineTextAlignment(.center); Text(song.track.artist).foregroundStyle(.secondary); Label("Guardada en tu iPhone", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(mint) }
                VStack(spacing: 6) {
                    Slider(value: Binding(get: { min(store.elapsed, song.duration) }, set: { store.seek($0) }), in: 0...max(1, song.duration))
                    HStack { Text(clock(store.elapsed)); Spacer(); Text(clock(song.duration)) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 45) {
                    Button { store.skip(-1) } label: { Image(systemName: "backward.end.fill").font(.title) }
                    Button { store.toggle() } label: { Image(systemName: store.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 73)).foregroundStyle(mint) }
                    Button { store.skip(1) } label: { Image(systemName: "forward.end.fill").font(.title) }
                }.buttonStyle(.plain)
            }
            Spacer()
        }.padding(.horizontal, 30).background(canvas)
    }
    private func clock(_ value: Double) -> String { "\(Int(max(0, value)) / 60):\(String(format: "%02d", Int(max(0, value)) % 60))" }
}
