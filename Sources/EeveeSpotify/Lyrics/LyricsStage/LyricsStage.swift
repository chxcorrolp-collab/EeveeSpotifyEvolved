import Foundation
import UIKit
import SwiftUI

// 「歌词舞台」—— **我们自己的全屏歌词窗口**。
//
// ## 为什么要自己开一个窗口
//
// 2026-10-23 的交接文档（`C:\dsh\me\HANDOFF_2026-10-23_EeveeSpotify-ng_LyricsStage-Folia.md`）
// 第 1 / 7 节查清了两件事：
//   ① iOS 27 版听歌页（`Appearance/NowPlayingIOS27*.swift`）**没有歌词区**，底排左边那颗
//      气泡只是 `ShowLyricsButton` 的替身，找不到原生键就直接变暗（按下去没反应）；
//   ② 我们的 `AppleMusicLyricsPage` 一直挂在 **Spotify 自己的歌词页 VC** 上
//      （`AppleMusicLyricsOverlayHost` ← `WordByWordHost.attach`），**不是独立页面**。
// ⇒ 想上"整屏舞台"型效果，必须先拥有自己的全屏页。这一层就是那个页面。
//
// ## 它**不碰** Spotify 的任何原生视图
//
// 前面几轮的教训（iOS27 文档第 4 轮、`NowPlayingIOS27` 文件头）都在说同一句话：
// "搬原生控件"会被它自己的布局写回去，修一个冒一个。所以这里换一条路 ——
// 整层是一个**独立 `UIWindow`**，压过 Spotify 的窗口；不藏、不挪、不改任何原生属性，
// 关闭时把窗口整个拆掉，底下那一页从来不知道我们来过。
//
// ## 时间从哪来
//
// 不抢 `WordByWordPlaybackClock` 那个**单槽**的 `tickHandler`（抢了卡片那边就断逐词，
// 文档 §7 的坑 1）。这里用 `AppleMusicLyricsTickView` 自带的 `CADisplayLink`，
// 位置仍然问 `WordByWordPositionResolver` —— 和歌词高亮同一个数据源，不会错拍。
//
// ## 省电
//
//   · 播放位置**不动**超过 90 拍（1.5s）⇒ 认为已暂停，停止向 SwiftUI 提交时间
//     （页面不再重绘；`CADisplayLink` 还在跑，只是为了发现"又播起来了"）；
//   · 切后台 / 锁屏 ⇒ 暂停 display link **并隐藏窗口**，回到前台再恢复。
//
// 日志 tag：`[LyricsStage]`。

// MARK: - 入口（非 iOS 26 也能安全调用）

/// 「歌词舞台」的对外入口。
///
/// ⚠️ 刻意**不加 `@MainActor`**：调用点一个在 `NowPlayingIOS27+Footer`（main actor 扩展），
///   一个在实验页的 `View`（`View` 协议在 iOS 26 SDK 里是 main actor 的，但那是**推断**出来的
///   隔离、不是显式标注）。这里让这两个入口本身是 nonisolated 的、内部再 hop 到 main actor，
///   就不会因为"某个调用点被推断成非隔离"而编译不过。
enum LyricsStageEntry {

    /// 用户在「设置 → 实验」里打开了舞台，**且**系统是 iOS 26+。
    ///
    /// 纯读一个 `UserDefaults`（`Codable` 解一份短 JSON），不碰 UI、不碰播放器，
    /// 所以 `NowPlayingIOS27` 每 0.3s 那拍叫它一次是安全的。
    static var isEnabled: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return UserDefaults.experimentsOptions.lyricsStage
    }

    /// 打开舞台。已打开时什么都不做（幂等）。
    static func present() {
        guard #available(iOS 26.0, *) else { return }
        Task { @MainActor in
            LyricsStage.shared.present()
        }
    }

    /// 关掉舞台（没开着就什么都不做）。
    static func dismissIfPresented() {
        guard #available(iOS 26.0, *) else { return }
        Task { @MainActor in
            LyricsStage.shared.dismiss()
        }
    }
}

// MARK: - 舞台本体

@available(iOS 26.0, *)
@MainActor
final class LyricsStage {

    static let shared = LyricsStage()

    static let logTag = "LyricsStage"

    /// 现在有没有一扇舞台窗口。**只读**，写入口在 `present()` / `dismiss()`。
    private(set) var isPresented = false

    private var window: UIWindow?
    private weak var stageController: LyricsStageViewController?
    private weak var hostingController: UIHostingController<LyricsStageRootView>?
    private weak var tickView: AppleMusicLyricsTickView?

    /// 舞台自己的时钟（**不是** `WordByWordPlaybackClock` 那份共享的，见文件头）。
    private let clock = AppleMusicLyricsClock()

    // MARK: 当前渲染状态

    /// 已经渲染进页面的行模型。
    private var lines: [LyricLine] = []
    /// 行模型对应的 `currentLyricsVersion`（换歌 / 重新取词都会加）。
    private var renderedVersion = -1
    /// 上一次见到的**播放器实时曲目**。
    ///
    /// 为什么必须有它（2026-10-24 一轮编译前的自审抓出来的死锁）：切歌**不一定**伴随
    /// 一次歌词请求（客户端缓存 / 离线歌词）⇒ `currentLyricsVersion` 不变，而"版本号变了
    /// 才重建"是这一层唯一的重建入口 ⇒ 先 A、再 B（无请求）、再回 A 时，屏幕上就是**永久空屏**，
    /// 而 `currentLyricsDto` 里其实还是 A 那份可以画的词。同一个坑 `AppleMusicLyricsOverlay`
    /// 在真机日志 18 上踩过并修过（`dropForeignLineModel`），这里按同一条纪律处理：
    /// **换歌 ⇒ 把版本号判据作废**，下一次对齐一定重新求值。
    private var lastLiveTrackId = ""
    /// 空状态那一句（还在查 / 没找到 / 纯音乐）。
    private var statusText = ""

    private var currentTrackTitle = ""
    private var currentTrackArtist = ""
    private var providerName = ""
    private var providerCredit = ""

    // MARK: 每帧状态

    private var lastPosition: TimeInterval = -1
    /// 位置连续没动过多少**秒**（≥1.5s 判暂停，见文件头「省电」）。
    ///
    /// ⚠️ 用墙钟而不是拍数：`AppleMusicLyricsTickView` 没有设 `preferredFrameRateRange`，
    ///   ProMotion 上就是 120Hz ⇒ 按"90 拍"算会在 0.75s 就误判成暂停；
    ///   "0.25s 对齐一次"同理，拍数口径在 120Hz 上会变成 8 次/秒。
    private var stalledSeconds: TimeInterval = 0
    /// 上一拍的时间戳。用 `ProcessInfo.systemUptime`：单调、不受系统时间调整影响。
    private var lastTickUptime: TimeInterval = 0
    /// 上一次"对齐状态"的时间戳（0.25s 节流）。
    private var lastPresentationUptime: TimeInterval = 0
    private var didLogStall = false

    private var observers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - 打开 / 关闭

    func present() {
        guard !isPresented else { return }
        guard LyricsStageEntry.isEnabled else {
            writeDebugLog("[\(Self.logTag)] present ignored — the experiment switch is off")
            return
        }
        guard let scene = Self.activeWindowScene() else {
            writeDebugLog("[\(Self.logTag)] present failed — no UIWindowScene in the foreground")
            return
        }

        // 先把行模型、曲名歌手、样式**全都对齐一遍**再建页面：
        // 否则第一帧会闪一下"空舞台"（`force: true` 跳过版本号判据）。
        // 空状态那一句同一次调用里也会算好，不用再单独赋一次。
        refreshPresentation(force: true, rebuild: false)

        let controller = LyricsStageViewController()
        controller.onDismiss = {
            LyricsStage.shared.dismiss()
        }
        // `loadViewIfNeeded()` 之后再量 bounds：窗口还没建，这时的 bounds 就是屏幕大小。
        controller.loadViewIfNeeded()
        let stageBounds = controller.view.bounds

        let hosting = UIHostingController(rootView: makeRootView())
        hosting.view.backgroundColor = .clear
        hosting.view.frame = stageBounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.addChild(hosting)
        controller.view.addSubview(hosting.view)
        hosting.didMove(toParent: controller)

        // 时钟：自带的 CADisplayLink 宿主视图（隐形、不吃触摸）。
        let tick = AppleMusicLyricsTickView(frame: stageBounds)
        tick.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tick.positionProvider = {
            WordByWordPositionResolver.shared.currentPositionSeconds()
        }
        tick.onTick = { [weak self] seconds in
            // ⚠️ 写成"单表达式 `self?…`"也能编（返回值被丢弃），但那个返回类型是 `Void?`，
            //    容易在严格并发那一轮被当成 `Task<Void?, Never>` 之类的推断问题；
            //    这里显式展开，读起来也清楚：拿不到 self 就直接走。
            guard let self else { return }
            self.handleTick(seconds)
        }
        controller.view.addSubview(tick)
        tick.start()

        let stageWindow = UIWindow(windowScene: scene)
        // 压过 Spotify 自己那一页（它用的是 normal），但留在系统弹窗/键盘下面。
        stageWindow.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 1)
        stageWindow.backgroundColor = .clear
        stageWindow.rootViewController = controller
        stageWindow.alpha = 0
        stageWindow.isHidden = false

        window = stageWindow
        stageController = controller
        hostingController = hosting
        tickView = tick
        isPresented = true
        installObservers()

        UIView.animate(withDuration: 0.22) {
            stageWindow.alpha = 1
        }

        writeDebugLog(
            "[\(Self.logTag)] present — crazy word-by-word stage"
                + " lines=\(lines.count)"
                + " scene=\(NSStringFromClass(type(of: scene)))"
                + " level=\(Int(stageWindow.windowLevel.rawValue))"
        )
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false

        tickView?.isPaused = true
        tickView?.onTick = nil
        tickView?.positionProvider = nil
        tickView?.stop()
        tickView?.removeFromSuperview()
        tickView = nil
        removeObservers()

        let stageWindow = window
        window = nil
        stageController = nil
        hostingController = nil
        clock.isFollowing = true
        lastPosition = -1
        stalledSeconds = 0
        lastTickUptime = 0
        lastPresentationUptime = 0
        didLogStall = false

        guard let stageWindow else {
            writeDebugLog("[\(Self.logTag)] dismiss — no window (already gone)")
            return
        }
        UIView.animate(withDuration: 0.2, animations: {
            stageWindow.alpha = 0
        }, completion: { _ in
            stageWindow.isHidden = true
            stageWindow.rootViewController = nil
        })
        writeDebugLog("[\(Self.logTag)] dismiss — window torn down")
    }

    // MARK: - 每帧

    private func handleTick(_ seconds: TimeInterval) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let delta = lastTickUptime == 0 ? 0 : max(0, uptime - lastTickUptime)
        lastTickUptime = uptime

        // 位置不动 = 暂停（或这一首已经播完）：停止向 SwiftUI 提交时间，页面不再重绘。
        // ⚠️ 但仍然**每拍读一次位置** —— 那是发现"又播起来了"的唯一途径。
        if abs(seconds - lastPosition) > 0.0005 {
            lastPosition = seconds
            stalledSeconds = 0
            if !clock.isFollowing {
                clock.isFollowing = true
                didLogStall = false
                writeDebugLog("[\(Self.logTag)] playback resumed — following again")
            }
            clock.submit(seconds: seconds)
        } else {
            stalledSeconds += delta
            if stalledSeconds >= 1.5, clock.isFollowing {
                clock.isFollowing = false
                if !didLogStall {
                    didLogStall = true
                    writeDebugLog(
                        "[\(Self.logTag)] paused — the page stops redrawing"
                            + " (the display link keeps probing for resume)"
                    )
                }
            }
        }

        // 0.25s 一次：换歌 / 新歌词 / 改样式 / 改曲名歌手。
        // 这些都不该每帧做（`toAppleMusicLyricLines()` 是整首的转换）。
        if uptime - lastPresentationUptime >= 0.25 {
            lastPresentationUptime = uptime
            refreshPresentation(force: false, rebuild: true)
        }
    }

    // MARK: - 状态对齐

    /// 把行模型 / 空状态 / 曲名歌手 / 样式对齐到"现在"，必要时重建 SwiftUI 根视图。
    ///
    /// - Parameters:
    ///   - force: 无视版本号强制重建行模型（打开窗口时用）。
    ///   - rebuild: 有变化时是否把新 rootView 写回 hosting controller。
    private func refreshPresentation(force: Bool, rebuild: Bool) {
        var changed = false
        let version = currentLyricsVersion

        // 曲名 / 歌手：从播放器实时读（与自绘壳同一口径，见 `AppleMusicLyricsOverlayHost`）。
        // ⚠️ `EeveeSpotify.hookTarget` 是个**计算属性**：每次访问都会读 Info.plist 并 `NSLog`
        //   一行（`Tweak.x.swift`）。这里 0.25s 就对一次齐，直接问它等于每秒往 syslog 写四行
        //   ⇒ 版本分支只算一次（见 `Self.isLegacyHookTarget`）。
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        let liveTrackId = track?.trackIdentifier ?? ""

        // 换歌 ⇒ 把"版本号"这道判据作废。
        //
        // 切歌不一定有新歌词请求（客户端缓存 / 离线歌词），`currentLyricsVersion` 就不变；
        // 只靠"版本号变了才重建"会死在"先 A、再 B、再回 A"那一步（文件头 `lastLiveTrackId`
        // 那段有完整复盘）。整份设置里**只有这里**能碰这两个判据。
        if liveTrackId != lastLiveTrackId {
            lastLiveTrackId = liveTrackId
            renderedVersion = -1
            if !lines.isEmpty {
                lines = []
                changed = true
            }
        }

        if force || version != renderedVersion {
            renderedVersion = version
            // 版本号被上面作废之后这里会重新跑一次 —— 所以**必须复核这份 dto 是谁的**：
            // 不复核就会把上一首的词画在新歌下面（而且每次对齐都重建一遍、永远空不下来）。
            let dtoBelongsToLiveTrack = currentLyricsDtoTrackId.isEmpty
                || liveTrackId.isEmpty
                || currentLyricsDtoTrackId == liveTrackId
            lines = dtoBelongsToLiveTrack ? (currentLyricsDto?.toAppleMusicLyricLines() ?? []) : []
            providerName = currentLyricsProvider
            providerCredit = currentLyricsCreditText()
            statusText = Self.statusTextForCurrentLyrics()
            changed = true
            writeDebugLog(
                "[\(Self.logTag)] line model rebuilt — \(lines.count) line(s) @v\(version)"
                    + (dtoBelongsToLiveTrack ? "" : " (dto is another track — waiting)")
            )
        }

        let title = track?.trackTitle() ?? ""
        let artist = (Self.isLegacyHookTarget
            ? track?.artistTitle()
            : track?.artistName()) ?? ""
        if title != currentTrackTitle || artist != currentTrackArtist {
            currentTrackTitle = title
            currentTrackArtist = artist
            changed = true
        }

        // 空状态那一句也要跟着"查词进度"变：`loading → failed` **不一定**会让
        // `currentLyricsVersion` 变（失败也可能只是没有再取词），只靠上面那段会停在
        // "正在等待…" —— 而用户盯着的正是那句话。
        let liveStatus = Self.statusTextForCurrentLyrics()
        if liveStatus != statusText {
            statusText = liveStatus
            changed = true
        }

        guard changed, rebuild, let controller = hostingController else { return }
        controller.rootView = makeRootView()
    }

    /// 播放器的版本分支：**只算一次**。
    ///
    /// ⚠️ `EeveeSpotify.hookTarget` 是计算属性，每次访问都会读 Info.plist 并 `NSLog`
    ///   （`Tweak.x.swift:295`）。这一层每 0.25s 对齐一次，直接问它 = 每秒四行 syslog。
    ///   8.9.8 那条老路上标签类的方法名不一样，所以这两条分支不能合并成一个调用。
    private static let isLegacyHookTarget = EeveeSpotify.hookTarget == .lastAvailableiOS14

    private func makeRootView() -> LyricsStageRootView {
        LyricsStageRootView(
            lines: lines,
            clock: clock,
            title: currentTrackTitle,
            artist: currentTrackArtist,
            provider: providerName,
            providerCredit: providerCredit,
            showsTranslation: showsTranslationNow,
            statusText: statusText,
            onClose: { LyricsStage.shared.dismiss() }
        )
    }

    /// 译文要不要画：和 `AppleMusicLyricsOverlayView.showsTranslationNow` 同一口径
    /// （这一首有译文，且用户没在歌词页关掉「隐藏译文」）。
    private var showsTranslationNow: Bool {
        guard !NgzhwmSettingsViewModel.isNeteaseHideTranslationEnabled else { return false }
        return lines.contains { line in
            guard let translation = line.translation else { return false }
            return !translation.isEmpty
        }
    }

    /// 没得画时写哪一句。三种"没词"必须分开说（与 `NowPlayingLyricsContainer` 同一纪律）：
    ///   还在查 / 查完了没有 / 源说这是纯音乐。
    private static func statusTextForCurrentLyrics() -> String {
        switch currentLyricsLookupState {
        case .idle, .loading:
            return "lyrics_stage_waiting".localized
        case .failed:
            return "lyrics_stage_no_lyrics".localized
        case .found:
            if currentLyricsDto?.isInstrumental == true {
                return "song_is_instrumental".localized
            }
            return "lyrics_stage_no_lyrics".localized
        }
    }

    // MARK: - 前后台

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // 一律 `queue: .main` + 再 hop 一次：`addObserver` 的闭包在 iOS 26 SDK 上标了
        // `@Sendable`，直接在闭包里调 main-actor 隔离的方法会在严格并发下报错。
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.suspendForBackground()
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.resumeFromBackground()
            }
        })
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func suspendForBackground() {
        guard isPresented else { return }
        tickView?.isPaused = true
        window?.isHidden = true
        writeDebugLog("[\(Self.logTag)] backgrounded — window hidden, display link paused")
    }

    private func resumeFromBackground() {
        guard isPresented else { return }
        window?.isHidden = false
        tickView?.isPaused = false
        clock.isFollowing = true
        lastPosition = -1
        stalledSeconds = 0
        lastTickUptime = 0
        lastPresentationUptime = 0
        didLogStall = false
        writeDebugLog("[\(Self.logTag)] foregrounded — window back, display link resumed")
    }

    // MARK: - 小工具

    /// 前台那个 `UIWindowScene`（拿不到就退回任意一个，别在后台一票否决）。
    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

// MARK: - 舞台窗口的根视图控制器

/// 舞台窗口的 VC。**只管两件事**：
///   ① 把 SwiftUI 根视图铺满；
///   ② 顶部往下拖 = 关闭（别的区域的手势留给 SwiftUI / 滚动视图）。
///
/// 为什么不做成 `UISheetPresentationController`：那会让系统接管圆角与 grabber，
/// 而舞台要的是**整屏**、没有卡片感（交接文档 §7 的 D 方案是次选，理由就在这）。
@available(iOS 26.0, *)
final class LyricsStageViewController: UIViewController, UIGestureRecognizerDelegate {

    var onDismiss: (() -> Void)?

    /// 只有从**顶部这一带**起手才算"往下拖关闭"：整屏都能拖的话，滑动歌词也会把舞台带走。
    private let dragStartBand: CGFloat = 160
    /// 拖过这么远就关（再快一点也算，见 `handlePan` 的速度判据）。
    private let dismissTranslation: CGFloat = 120

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let location = pan.location(in: view)
        let velocity = pan.velocity(in: view)
        return location.y <= dragStartBand && velocity.y > 0
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let stageView = view else { return }
        let translation = max(0, pan.translation(in: stageView).y)

        switch pan.state {
        case .changed:
            stageView.transform = CGAffineTransform(translationX: 0, y: translation)
            stageView.alpha = max(0.35, 1 - translation / 520)
        case .ended, .cancelled, .failed:
            let velocity = pan.velocity(in: stageView).y
            if translation > dismissTranslation || velocity > 900 {
                onDismiss?()
            } else {
                UIView.animate(withDuration: 0.25) {
                    stageView.transform = .identity
                    stageView.alpha = 1
                }
            }
        default:
            break
        }
    }
}
