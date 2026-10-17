// 「歌词进播放器」那层自己的宿主（只属于这一层，不抢全屏页/卡片那个单例）。
// 从 `NowPlayingLyricsPlate.swift` 原样拆出；硬约束与总览见那个文件的头注。
import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime

// MARK: - 宿主（只属于这一层，不抢全屏页/卡片那个单例）

@available(iOS 26.0, *)
@MainActor
final class NowPlayingLyricsHost {

    var hostingController: UIHostingController<AppleMusicLyricsOverlayView>?
    var renderedVersion: Int = -1
    var renderedTrackId: String = ""
    /// ★ 2026-10-11：这一份挂上去的是**静态档**（没有时间轴）吗 —— 换档要重挂。
    var renderedStatic = false
    /// ★ 2026-10-11：挂上去那一份的**罗马化开关指纹** —— 变了要就地重写行模型。
    ///
    /// 为什么需要：罗马字是在 `LyricLinesAdapter` 里算进 `LyricLine` 的（按版本缓存），
    /// 而"日文/中文/韩文罗马化"三个开关只写 `UserDefaults`、**不会让版本号变**
    /// ⇒ 不做这件事的话，用户在设置里一开，得等下一次取词（换歌）才看得到。
    var renderedRomanization = -1

    let clock = AppleMusicLyricsClock()
    let projection = AppleMusicLyricsPlaybackProjection {
        WordByWordPositionResolver.shared.currentPositionSeconds()
    }

    var isAttached: Bool { hostingController != nil }

    /// 罗马化那三个开关的**指纹**（逐语言，就是"歌词页面里的选择"）。
    ///
    /// ⚠️ 实现**只有一份**：`romanizationSwitchesFingerprint()`（`LyricLinesAdapter.swift` 开头）——
    /// 同一个判据抄两份，迟早只修一份（2026-10-11 那个 `seekToTappedLyricLine` 就是教训）。
    ///
    /// 它进 `isCurrent` ⇒ 用户一改开关，下一拍（≤0.3s）就会走 `updateLines` 把行模型重写一遍，
    /// 罗马字立刻出现/消失，不用等换歌。
    static func romanizationFingerprint() -> Int {
        romanizationSwitchesFingerprint()
    }

    func isCurrent(version: Int, trackId: String, isStatic: Bool) -> Bool {
        isAttached && renderedVersion == version && renderedTrackId == trackId
            && renderedStatic == isStatic
            && renderedRomanization == Self.romanizationFingerprint()
    }

    func mount(
        in container: UIView,
        lines: [LyricLine],
        version: Int,
        trackId: String,
        isStatic: Bool,
        onSeek: ((TimeInterval) -> Void)?
    ) {
        let root = AppleMusicLyricsOverlayView(
            lines: lines,
            // `.card` 与"透明档"一起用：不画任何背景（播放器这一档底下是整页取色底）。
            backdropStyle: .card,
            solidBackdrop: false,
            showsProviderFooter: false,
            sideInset: NowPlayingLyricsPlate.stageSideInset,
            previewHeaderInset: 0,
            // ⚠️ **不画**预览标题栏那一行（"歌词 · 分享 · 打开全屏歌词"）：它是
            // `AppleMusicLyricsOverlayView.previewHeader`，**我们自己画的**，不是 Spotify 的原生入口
            // ⇒ 去藏原生入口（`lyrics-share-button` 那一批）没用，屏幕上那一行纹丝不动。
            showsPreviewHeader: false,
            onSeek: onSeek,
            trackTitle: "",
            trackArtist: "",
            // ⚠️ **参数顺序必须与结构体里的属性声明顺序完全一致** —— SwiftUI 的逐成员初始化器
            // 是位置敏感的（2026-10-05 CI 抓到：我把 `transparentBackdrop` 写在 `previewHeaderInset`
            // 后面，编译器报 "argument labels do not match"）。
            transparentBackdrop: true,
            clock: clock,
            projection: projection,
            // ★ 2026-10-11：「没有时间轴」那一档 —— 见 `AppleMusicLyricsPage.isStatic`。
            isStatic: isStatic,
            // ★★ 2026-10-17（用户：「**歌词进播放器**的时候也**没有额外的歌词结构**」）：
            //   这一档 `showsProviderFooter` 必须是 `false`（不画署名页脚），而副唱以前被绑在它上面
            //   ⇒ 用户看到的歌词永远没有"主词下方那一小行副唱"。这里显式打开：
            //   署名是元信息、副唱是歌词内容，两件事分开。
            showsBackgroundVocals: true
        )

        let hosting = UIHostingController(rootView: root)
        // ⚠️ 必须写全 `UIColor.clear`：这里没有上下文类型，`.clear` 推断不出来
        // （CI 报 "cannot infer contextual base in reference to member 'clear'"）。
        hosting.view.backgroundColor = UIColor.clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.accessibilityIdentifier = "eevee-npv-lyrics"

        container.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        hostingController?.view.removeFromSuperview()
        hostingController = hosting
        renderedVersion = version
        renderedTrackId = trackId
        renderedStatic = isStatic
        renderedRomanization = Self.romanizationFingerprint()
    }

    func updateLines(_ lines: [LyricLine], version: Int, trackId: String, isStatic: Bool) {
        guard let hosting = hostingController else { return }
        hosting.rootView.lines = lines
        hosting.rootView.isStatic = isStatic
        renderedVersion = version
        renderedTrackId = trackId
        renderedStatic = isStatic
        renderedRomanization = Self.romanizationFingerprint()
    }

    func tick(seconds: TimeInterval?) {
        guard isAttached else { return }
        if let seconds { clock.submit(seconds: seconds) }
        projection.refresh()
    }

    // MARK: - ★ 2026-10-08：逐词歌词改用**每帧时钟**

    var usingPerFrameClock = false

    /// 逐**词**高亮要每帧才顺：`tick(seconds:)` 若只由 `DeclutterChrome` 那条 **≈0.5s** 的复查
    /// 节拍驱动就只有 **2Hz**，肉眼一格一格跳（逐**行**看不出来 —— 行间本来有 SwiftUI 动画兜着）。
    ///
    /// 复用仓库既有的 `WordByWordPlaybackClock`（`CADisplayLink`），不新起定时器：
    /// ⚠️ 它的 `tickHandler` **只有一个槽**，旧 overlay 那条路（`LyricsWordByWord.x.swift`）
    /// 也在用 ⇒ **占不到就不抢**，退回节拍，绝不把别人的时钟顶掉。
    func usePerFrameClockIfAvailable() {
        guard !usingPerFrameClock else { return }
        let shared = WordByWordPlaybackClock.shared
        guard shared.tickHandler == nil else {
            writeDebugLog(
                "[\(NowPlayingLyricsPlate.logTag)] per-frame clock is taken by another overlay"
                    + " - word-by-word lyrics stay on the 0.5s review tick (choppier)"
            )
            return
        }
        shared.tickHandler = { @MainActor [weak self] ms in
            self?.tick(seconds: ms / 1000)
        }
        shared.start()
        usingPerFrameClock = true
        writeDebugLog("[\(NowPlayingLyricsPlate.logTag)] word-by-word lyrics are now driven per frame (shared CADisplayLink)")
    }

    /// 只停**我们自己**启动的那个时钟（`usingPerFrameClock` 就是这条账）。
    func releasePerFrameClock() {
        guard usingPerFrameClock else { return }
        usingPerFrameClock = false
        let shared = WordByWordPlaybackClock.shared
        shared.tickHandler = nil
        shared.stop()
    }

    func detach() {
        releasePerFrameClock()
        guard let hosting = hostingController else { return }
        hosting.view.removeFromSuperview()
        hostingController = nil
        renderedVersion = -1
        renderedTrackId = ""
    }
}
