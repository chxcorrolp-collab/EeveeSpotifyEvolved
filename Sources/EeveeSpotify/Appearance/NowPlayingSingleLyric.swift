// 收起态「封面与控件条之间那一行歌词」——**直接复用展开时那套逐词渲染器**。
//
// 2026-10-22（用户：「封面/歌名中间的单行逐词歌词效果不佳，可以复用正常的逐词歌词吗？」）：
//
// 原来这一行是我们自己用 `UILabel` + 每 0.3s 改一次逐字 `foregroundColor` 画的：
//   · 只有 0.3s 一拍 ⇒ 看到的是"一格一格亮"，不是流畅的填充；
//   · 已唱 / 未唱只差一档透明度（0.96 / 0.45）⇒ 在深色取色底上几乎看不出"唱到哪"；
//   · 没有展开页那套渐变前沿 / 光晕 / 长音强调。
//
// 现在这一行换成**和展开页完全同一个渲染器** `SynchronizedLyricText`
// （也就是 `AppleMusicLyricsPage` / `NowPlayingLyricsHost` 用的那一个），并且：
//   · 由**共享 CADisplayLink**（`WordByWordPlaybackClock`）每帧喂 `playbackTime`，
//     与展开页同一条时钟（收起时展开页那层已经 detach，槽位是空的）；
//   · 唱到哪一行仍走**唯一**的判定入口 `LyricPlaybackTimeline.position(at:in:)`；
//   · 排版用 `.player` 档（22pt，与展开页主歌词同字号），居中显示。
//
// ⚠️ 时钟槽只有一个：展开前必须释放（`NowPlayingLyricsPlate.openAndMount` 开头会调
//    `releaseSingleLyricClock()`），否则展开页会掉回 0.5s 的复查节拍。
import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime

// MARK: - 主视图

@available(iOS 26.0, *)
@MainActor
final class NowPlayingSingleLyricHost {

    /// 只有一份（收起态一行歌词；换页 / 换歌都复用同一份，见 `remove`）。
    static let shared = NowPlayingSingleLyricHost()

    /// 这一行自己的时钟：**只**由共享 CADisplayLink 提交时间。
    let clock = AppleMusicLyricsClock()

    private var hosting: UIHostingController<NowPlayingSingleLyricLineView>?
    private var renderedKey = ""
    private var renderedWidth: CGFloat = 0
    private var renderedFontSize: CGFloat = 0
    private var usingSharedClock = false
    private var didLogPerFrame = false
    private var didLogFallback = false

    var view: UIView? { hosting?.view }

    /// 建（或接回）我们那一张 SwiftUI 视图。**单独一行**，不参与命中测试。
    func ensureView(in page: UIView) -> UIView {
        if let hosting {
            if hosting.view.superview !== page {
                hosting.view.removeFromSuperview()
                page.addSubview(hosting.view)
            }
            page.bringSubviewToFront(hosting.view)
            return hosting.view
        }

        let root = NowPlayingSingleLyricLineView(
            clock: clock,
            lines: [],
            width: max(60, page.bounds.width),
            fontSize: 22
        )
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = UIColor.clear
        controller.view.isUserInteractionEnabled = false
        controller.view.accessibilityIdentifier = "eevee-npv-single-lyric"
        controller.view.clipsToBounds = false
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        page.addSubview(controller.view)
        page.bringSubviewToFront(controller.view)
        hosting = controller
        return controller.view
    }

    /// 行模型 / 宽度 / 字号**变了才**重建 rootView；播放时间不走这里（那是每帧的 `clock`）。
    func update(lines: [LyricLine], key: String, width: CGFloat, fontSize: CGFloat) {
        guard let hosting else { return }
        let widthChanged = abs(width - renderedWidth) > 0.5
        let fontChanged = abs(fontSize - renderedFontSize) > 0.01
        guard key != renderedKey || widthChanged || fontChanged else { return }
        renderedKey = key
        renderedWidth = width
        renderedFontSize = fontSize
        hosting.rootView = NowPlayingSingleLyricLineView(
            clock: clock,
            lines: lines,
            width: width,
            fontSize: fontSize
        )
    }

    /// 没有每帧时钟时（被别的 overlay 占着）由 0.3s 的复查节拍补一拍 —— 至少不会停住。
    func submit(seconds: TimeInterval?) {
        guard let seconds else { return }
        clock.submit(seconds: seconds)
    }

    /// 占共享 CADisplayLink；占不到就退回节拍（**不抢**别人的槽，仓库纪律）。
    func startClockIfAvailable() {
        guard !usingSharedClock else { return }
        let shared = WordByWordPlaybackClock.shared
        guard shared.tickHandler == nil else {
            if !didLogFallback {
                didLogFallback = true
                writeDebugLog(
                    "[\(NowPlayingLyricsPlate.logTag)] the one-line lyric cannot take the per-frame clock"
                        + " (another overlay holds it) - it stays on the review tick"
                )
            }
            return
        }
        shared.tickHandler = { @MainActor [weak self] ms in
            self?.clock.submit(seconds: ms / 1000)
        }
        shared.start()
        usingSharedClock = true
        if !didLogPerFrame {
            didLogPerFrame = true
            writeDebugLog(
                "[\(NowPlayingLyricsPlate.logTag)] the one-line lyric now uses the normal word-by-word renderer"
                    + " (per frame, same CADisplayLink as the expanded page)"
            )
        }
    }

    /// 只归还**我们自己**占的那个槽（`usingSharedClock` 就是这条账）。
    ///
    /// ⚠️ 另一个消费者（旧 overlay 走 `onChange`）可能正在用同一条时钟 ⇒ 它还在时**只摘 handler、
    ///    不停时钟**（否则会把别人的逐词刷新一起停掉，而它不会自己重启）。
    func releaseClock() {
        guard usingSharedClock else { return }
        usingSharedClock = false
        let shared = WordByWordPlaybackClock.shared
        shared.tickHandler = nil
        if shared.onChange == nil {
            shared.stop()
        }
    }

    func remove() {
        releaseClock()
        hosting?.view.removeFromSuperview()
        hosting = nil
        renderedKey = ""
        renderedWidth = 0
        renderedFontSize = 0
    }
}

// MARK: - 那一行本身

@available(iOS 26.0, *)
private struct NowPlayingSingleLyricLineView: View {

    @ObservedObject var clock: AppleMusicLyricsClock
    let lines: [LyricLine]
    let width: CGFloat
    let fontSize: CGFloat

    var body: some View {
        let current = currentLine
        ZStack {
            if let line = current {
                SynchronizedLyricText(
                    syllables: line.syllables,
                    text: line.text,
                    playbackTime: clock.playbackTime,
                    isFocused: true,
                    focusStrength: 1,
                    translation: nil,
                    romanization: nil,
                    backgroundVocal: nil,
                    constrainedWidth: width,
                    alignment: .center,
                    typography: typography,
                    fontWeight: .semibold,
                    primaryColor: .white,
                    appliesTimingEffects: !line.syllables.isEmpty,
                    showsBackgroundVocals: false,
                    showsTranslation: false
                )
                // 换句 = 换一个视图身份 ⇒ 下面 `.animation(value:)` 会给它一个交叉淡入。
                .id(line.id)
                .transition(.opacity)
            }
        }
        .frame(width: width, alignment: .center)
        .animation(.easeInOut(duration: 0.18), value: current?.id)
    }

    /// 与展开页 `.player` 同一档，只改主歌词字号（长句时由外层缩到 15pt）。
    private var typography: LyricsTypographyScale {
        LyricsTypographyScale(
            primaryFontSize: fontSize,
            supplementalFontSize: max(11, fontSize * 0.72),
            lineSpacing: 2,
            wrappedLineSpacing: 2,
            supplementalSpacing: 2
        )
    }

    /// **唯一**的"唱到哪一行"入口（与展开页同一个函数）。
    private var currentLine: LyricLine? {
        guard !lines.isEmpty else { return nil }
        let position = LyricPlaybackTimeline.position(at: clock.playbackTime, in: lines)
        guard let highlighted = position.highlightedLyricID,
              let line = lines.first(where: { $0.id == highlighted }) else {
            return nil
        }
        guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return line
    }
}
