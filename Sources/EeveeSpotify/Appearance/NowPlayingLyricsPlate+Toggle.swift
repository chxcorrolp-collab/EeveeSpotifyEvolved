// 「歌词进播放器」——歌词键、单行歌词、标题行触摸转发。
// 从 `NowPlayingLyricsPlate.swift` 原样拆出（`NowPlayingLyricsPlate` 的 extension）；
// 形状、动画与硬约束见那个文件的头注。
import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime

@MainActor
extension NowPlayingLyricsPlate {
    // MARK: - 歌词键（2026-10-11 第二轮：搬进**控件条**）

    /// 那枚键的落点。
    ///
    /// ★★ 2026-10-11 第二轮（照片 71）：**首选控件条**那一格（与绿色 ✓ / 分享键同一条线），
    /// 也就是 `toggleCenterX` × `controlBandMidY`。用户圈的第 ② 处就是它。
    /// 控件条**量不出来**（没有进度条锚点 / 页面太矮 / 该位置已经被导航条吃掉）时才退回
    /// 下面那套老的三级判据 —— 宁可回到旧行为，也不要摆一个压在进度条或歌词上的键。
    static func toggleFrame(in page: UIView) -> CGRect? {
        // ★ 2026-10-11（照片 75）：和**下面那颗播放/暂停键同一条竖线**（量不到才用常量）。
        let centerX = transportColumnX(playButtonIdentifier, in: page) ?? toggleCenterX
        if let band = controlBandFrame(in: page, side: toggleSide, centerX: centerX) {
            return band
        }
        return fallbackToggleFrame(in: page)
    }

    /// 控件条上的一格（给定中心 x，y 恒为 `controlBandMidY`）。
    ///
    /// 两条健全性检查（任一不过就返回 `nil`，交给 `fallbackToggleFrame`）：
    ///   · 这一格必须在**导航条下沿之下**（否则会压在那三个导航控件上）；
    ///   · 必须在**进度条顶边之上**（否则会压住进度条的拖动）。
    static func controlBandFrame(
        in page: UIView,
        side: CGFloat,
        centerX: CGFloat
    ) -> CGRect? {
        guard page.bounds.height >= livingHeight else { return nil }

        if let nav = navBarBottom(in: page), controlBandMidY - side / 2 <= nav { return nil }
        if let list = findByIdentifier(listIdentifier, in: page),
           let progressTop = progressUnitTop(in: list, page: page),
           controlBandMidY + side / 2 >= progressTop {
            return nil
        }
        return CGRect(
            x: (centerX - side / 2).rounded(),
            y: (controlBandMidY - side / 2).rounded(),
            width: side,
            height: side
        )
    }

    /// 老的三级判据。**只在控件条量不出来时兜底**。
    ///
    /// * **①**：`npv.bottomStackView` 的**最后一行**（footer）的 frame、水平居中。那一坨的子视图依次是
    ///   「标题 / 进度 / 控件 / footer」，footer 恒为**最后一个**（那一行只有两侧原生控件，中间是空的）；
    ///   pw 也是把歌词字形放 footer 那一排。⚠️ 我们只**借它的 frame**，键本身挂在 `page` 上（塞进
    ///   Spotify 的 stack 会让它变成 `stack.subviews.last`，把"认 footer"这件事本身弄坏）
    ///   ⇒ 代价：那一行自己重排时要等下一拍（≤0.3s）才跟上。
    /// * **② footer 不能用**（版式变了 / 它被藏了）：贴那一坨**上面**；展开时**靠右**（歌词正文居中排，
    ///   靠右能把"挡住歌词区、抢走点行跳转"的面积压到最小）。
    /// * **③ 那一坨都找不到**（进页面极早期）：由播放键反推同一条空带（`playToBandTop`）。
    ///
    /// ⚠️ **绝不放在"播放键正上方 44pt"**：那里是**标题行与进度条**，既压住 Spotify 的内容
    /// （进度条的拖动会被抢），也看不出是个按钮。
    static func fallbackToggleFrame(in page: UIView) -> CGRect? {
        let side = toggleSide
        let centeredX = ((page.bounds.width - side) / 2).rounded()

        if let stack = findByIdentifier(bottomStackIdentifier, in: page) {
            let stackFrame = stack.convert(stack.bounds, to: page)

            if let footer = stack.subviews.last, !footer.isHidden, footer.alpha > 0.01 {
                let row = footer.convert(footer.bounds, to: page)
                if row.height >= side, row.width >= side, row.maxY <= page.bounds.maxY + 1 {
                    return CGRect(
                        x: centeredX,
                        y: (row.midY - side / 2).rounded(),
                        width: side,
                        height: side
                    )
                }
            }

            let above = stackFrame.minY - toggleGap - side
            if above > page.bounds.minY + 8 {
                // 展开时我们的歌词区底边就在 stackTop−8：靠右摆，少挡正文、少抢点行跳转。
                let x = door.isOpen ? (page.bounds.maxX - side - 12).rounded() : centeredX
                return CGRect(x: x, y: above.rounded(), width: side, height: side)
            }
        }

        guard let play = findByIdentifier(playButtonIdentifier, in: page) else { return nil }
        let playFrame = play.convert(play.bounds, to: page)
        let y = max(page.bounds.minY + 8, playFrame.minY - playToBandTop - toggleGap - side)
        return CGRect(x: centeredX, y: y.rounded(), width: side, height: side)
    }

    /// 摆那枚键（幂等）。**看得见**：半透明圆底 + 歌词字形；展开中换成 `chevron.down`。
    ///
    /// ⚠️ **必须自己判 `#available(iOS 26.0, *)`**：这一整条链（渲染层 / `canShow` /
    /// `layoutAndMount`）都是 iOS 26 起的，而 `apply` 那条路**没有再包一层版本判断** ——
    /// 少这一道，iOS 14–25 上会摆出一枚**看得见但点了必然无效**的键
    ///（`canShow` 直接 false，还会打出误导人的"这首歌没有可用的歌词"）。独立复核抓到的。
    static func ensureToggleZone(in page: UIView) {
        guard #available(iOS 26.0, *) else { return }
        // ★ 2026-10-12：总开关关着就**一枚键都不许摆** —— 用户报的"歌词按钮点不动"
        //   就是"键摆出来了、点下去 `canShow` 直接 false"造成的。调用点（`apply` / `reconcile`）
        //   本来都判过了，这里再判一次是**兜底**：将来多一条调用路径，也不会再造出那枚死键。
        guard isEnabled else {
            removeToggle()
            return
        }
        guard let wanted = toggleFrame(in: page) else {
            noteSkip("cannot find the play button, so there is nowhere to put the lyrics button")
            return
        }

        if let zone = lastToggleZone {
            if zone.frame != wanted { zone.frame = wanted }
            if zone.superview !== page { page.addSubview(zone) }
            applyToggleAppearance(to: zone)
            page.bringSubviewToFront(zone)
            return
        }

        let zone = UIControl(frame: wanted)
        zone.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        zone.layer.cornerRadius = toggleSide / 2
        zone.layer.cornerCurve = .continuous
        zone.clipsToBounds = true
        zone.accessibilityIdentifier = "eevee-npv-lyrics-toggle"
        zone.accessibilityLabel = "歌词"
        zone.addTarget(
            NowPlayingLyricsToggleTarget.shared,
            action: #selector(NowPlayingLyricsToggleTarget.tapped),
            for: .touchUpInside
        )

        let glyph = UIImageView(frame: zone.bounds)
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        glyph.tintColor = .white
        glyph.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glyph.accessibilityIdentifier = "eevee-npv-lyrics-toggle-glyph"
        zone.addSubview(glyph)

        page.addSubview(zone)
        applyToggleAppearance(to: zone)
        page.bringSubviewToFront(zone)
        lastToggleZone = zone
        let words = hasAnythingToDrawFast() ? "this track has lyrics" : "no lyrics for this track — greyed out"
        writeDebugLog(
            "[\(logTag)] lyrics button in place \(frameText(wanted)) (visible round button; tap to expand/collapse; \(words))"
        )
    }

    /// 那枚键长什么样：**永远是那个歌词图标**；这一首没词就变灰（**但仍然可点** —— 点了会说明原因）。
    ///
    /// ★ 2026-10-11（用户提的）：展开时**不再**换成 `chevron.down`。
    /// 用户原话：「现在点击歌词按钮之后会显示一个向下的箭头，能不能给这个箭头删了，
    /// 然后就只有原本的歌词长相」+「**它原本就是歌词图标，就无论怎么点，它看起来都是那个歌词图标**」。
    /// （收起仍然靠点这一颗 —— 图标不变，位置也不变。）
    static func applyToggleAppearance(to zone: UIControl) {
        let symbol = "quote.bubble.fill"

        let glyph = zone.subviews
            .compactMap { $0 as? UIImageView }
            .first { $0.accessibilityIdentifier == "eevee-npv-lyrics-toggle-glyph" }

        if let glyph {
            if glyph.frame != zone.bounds { glyph.frame = zone.bounds }
            let drawn = objc_getAssociatedObject(glyph, &toggleSymbolKey) as? String
            if drawn != symbol {
                objc_setAssociatedObject(glyph, &toggleSymbolKey, symbol, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                // 兜底链：万一某个符号名在目标 iOS 上不存在，`UIImage(systemName:)` 会返回 nil
                // ⇒ 那枚键就变成"看得见但什么都没有"的空圆。本机没有运行时，只能这样防。
                let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
                let candidates = ["quote.bubble.fill", "quote.bubble", "text.alignleft"]
                let image = candidates
                    .compactMap { UIImage(systemName: $0, withConfiguration: configuration) }
                    .first
                glyph.image = image?.withRenderingMode(.alwaysTemplate)
            }
        }

        // ★ 2026-10-11：判据从 `hasLyricsAvailable()`（只认"有时间轴的词级/行级"）换成热路径版的
        //   `hasAnythingToDrawFast()` —— 否则"没有时间轴但能静态列出全文"那一档会被错误地变灰。
        zone.alpha = hasAnythingToDrawFast() ? 1 : toggleDisabledAlpha
    }

    /// 把那枚键拿走（关开关 / 离开页面）。
    static func removeToggle() {
        guard let zone = lastToggleZone else { return }
        zone.removeFromSuperview()
        lastToggleZone = nil
    }

    // MARK: - ★ 2026-10-04：封面与歌词键之间的**一行居中歌词**（用户建议的第二条）

    /// 单行歌词的一拍快照：哪一行、原文、以及播放到哪一秒。
    ///
    /// ★ 2026-10-22（用户：「自画单行歌词没有接逐词歌词」）：原来这里只交出 `String`，
    /// 所以那一行永远是"整行亮着"。现在把**行模型 + 播放位置**一起带出来，交给
    /// **展开页同一个逐词渲染器**（`NowPlayingSingleLyric.swift`）按音节时间轴逐字上色。
    struct SingleLyricState {
        let line: LyricLine
        let text: String
        let playback: TimeInterval
    }

    /// 封面与歌词键之间的**一行居中歌词**（展开页同一个 SwiftUI 渲染器的宿主）。
    ///
    /// 落点：**封面底边与控件条上沿的中点**，宽度与歌词块同宽（两侧各 `stageSideInset`）⇒ 这一行
    /// **自己会跟着封面走**（封面没缩成时自动往下落），不会压到封面上。
    ///
    /// 判据**一处都不新写**：行模型 `currentLines()`（按「歌词版本 + 曲目 id」再缓存一层）；
    /// "唱到哪一行"走 `LyricPlaybackTimeline.position(at:in:)` —— 本仓库**唯一**的判定入口
    /// （`AppleMusicLyricsPage` 用的也是它）。★ 2026-10-22 起，**渲染**也复用同一个
    /// `SynchronizedLyricText`（`NowPlayingSingleLyric.swift`），并由共享 CADisplayLink 每帧喂时间；
    /// 本文件只负责"摆哪儿 / 用多大字号 / 该不该出现"。
    ///
    /// **什么时候不显示**：开关关 / 歌词展开着（再来一行是重复）/ 页面要走 / 还没词 /
    /// **一行带时间轴的都没有**（那就没有"当前行"这回事 —— 静态歌词那一档不适用）。
    ///
    /// ⚠️ `weak`：页面归它所有；万一有哪条路没走到 `removeSingleLyric`，也不该由这个静态变量
    /// **钉住上一页的宿主**。
    static weak var singleLyric: UIView?
    static var singleLyricLines: [LyricLine] = []
    static var singleLyricCacheKey = ""
    static var didLogSingleLyric = false
    static var didLogSingleLyricTiming = false

    /// 这一行**现在该写哪一句**（`nil` = 现在不该有它）。
    static func singleLyricStateNow() -> SingleLyricState? {
        guard UserDefaults.nowPlayingSingleLyric else { return nil }

        // ⚠️ 行模型可能还是**上一首**的：切歌**不一定**伴随歌词请求（客户端缓存命中 / 离线歌词时
        //    没有 `color-lyrics` 请求，`resetWordByWordLyrics` 就不会跑）。
        //    两层早就有这条判据（`LyricsWordByWordOverlayView.belongsToAnotherTrack` /
        //    `WordByWordHost.lineModelIsForeign`，口径见 `currentLyricsDtoTrackId` 的说明）；
        //    这里用**同一个**口径：宁可这一行暂时空着，也绝不显示上一首的歌词。
        let model = currentLyricsDtoTrackId
        let live = currentTrackId() ?? ""
        if !model.isEmpty, !live.isEmpty, model != live { return nil }

        let key = "\(currentLyricsVersion)#\(live)"
        if key != singleLyricCacheKey {
            singleLyricCacheKey = key
            // ⚠️ `currentLines()` 会把**没有时间轴的行整首滤掉**（`LyricLinesAdapter` 里的 filter）
            //    ⇒ 没有时间轴的歌这里自然是空的，一句都不画（正确：那种歌没有"当前行"）。
            singleLyricLines = currentLines() ?? []
        }
        guard !singleLyricLines.isEmpty else { return nil }

        // ⚠️ 位置是**可选的**（`currentPositionSeconds() -> Double?`：拿不到播放器时是 nil）
        //    ⇒ 拿不到就**这一拍不画**，不许拿 0 当"唱到开头"（那会让封面下面先闪一句第一行）。
        guard let playback = WordByWordPositionResolver.shared.currentPositionSeconds() else {
            return nil
        }
        let position = LyricPlaybackTimeline.position(at: playback, in: singleLyricLines)
        guard let highlighted = position.highlightedLyricID,
              let line = singleLyricLines.first(where: { $0.id == highlighted }) else {
            return nil
        }
        // ⚠️ 用**未裁剪**的 `line.text`：它与 `syllables.map(\.text).joined()` 严格同源
        //    （见 `LyricLinesAdapter` 里"必须用 line.content"那段），裁掉首尾空格会让
        //    逐字区间整体错位。
        let text = line.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        if !didLogSingleLyricTiming {
            didLogSingleLyricTiming = true
            writeDebugLog(
                "[\(logTag)] the one-line lyric follows "
                    + (line.syllables.isEmpty
                        ? "line timing (this line has no word timeline)"
                        : "word timing (\(line.syllables.count) syllable(s))")
            )
        }
        return SingleLyricState(line: line, text: text, playback: playback)
    }

    /// 每拍摆一次。**关闭 / 展开 / 离页**都会把它收起来（`isHidden`，对象留着给下一拍用）。
    ///
    /// ★ 2026-10-22：这一行交给**展开页同一个逐词渲染器**画（见 `NowPlayingSingleLyric.swift`）。
    ///    这里只负责"摆哪儿 / 用多大字号 / 该不该出现"；播放时间由共享 CADisplayLink 每帧喂。
    static func applySingleLyric(in page: UIView) {
        guard #available(iOS 26.0, *) else { return }
        guard isEnabled, !door.isOpen, page.window != nil,
              let state = singleLyricStateNow() else {
            hideSingleLyric()
            return
        }
        let host = NowPlayingSingleLyricHost.shared
        let view = host.ensureView(in: page)
        singleLyric = view
        let width = max(60, page.bounds.width - stageSideInset * 2)
        let metrics = singleLyricMetrics(for: state.text, width: width)
        host.update(
            lines: singleLyricLines,
            key: singleLyricCacheKey,
            width: width,
            fontSize: metrics.font.pointSize
        )
        host.startClockIfAvailable()
        host.submit(seconds: state.playback)
        layoutSingleLyric(view, in: page, height: metrics.height)
        if view.isHidden {
            view.isHidden = false
            view.alpha = 0
            UIView.animate(withDuration: 0.18, animations: { view.alpha = 1 }, completion: nil)
        } else if view.alpha < 0.99 {
            view.alpha = 1
        }
        if !didLogSingleLyric {
            didLogSingleLyric = true
            writeDebugLog(
                "[\(logTag)] the one-line lyric between the cover and the lyrics button is up"
                    + " (normal word-by-word renderer, \(Int(metrics.font.pointSize))pt;"
                    + " centred between the cover's bottom and"
                    + " \(Int(controlBandMidY - controlBandHalfHeight)))"
            )
        }
    }

    /// 单行歌词最多摆几行 / 字号范围。
    ///
    /// ★ 2026-10-22（用户：「当前行太长会出现『歌词歌词歌词……』的截断」）：长句仍是
    /// **先在三行以内自动缩字号**（短句 22pt），只有极端长句才停在 15pt / 三行。
    /// 上色不再由这里管 —— 展开页那个渲染器自己按音节时间轴画。
    private static let singleLyricMaxLines = 3
    private static let singleLyricMaxFontSize: CGFloat = 22
    private static let singleLyricMinFontSize: CGFloat = 15

    /// 字号/框高的缓存：`applySingleLyric` 每 0.3s 跑一次，而行文本一唱就是几秒 ——
    /// 不缓存的话每一拍都要做最多 8 次 `boundingRect`（一次换句才需要量）。
    private static var singleLyricMetricsCache: (text: String, width: CGFloat, font: UIFont, height: CGFloat)?

    /// 这一行要用的字号与框高：**先在三行以内找最大可用字号**（22 → 15pt）。
    ///
    /// 为什么不是直接 `adjustsFontSizeToFitWidth`：那个属性只对**单行**标签可靠；
    /// 这里要允许折成多行，所以手动量（`boundingRect` 的换行口径与 UILabel 一致，
    /// 都是 CoreText 的同一条折行规则）。
    private static func singleLyricMetrics(
        for text: String,
        width: CGFloat
    ) -> (font: UIFont, height: CGFloat) {
        if let cached = singleLyricMetricsCache,
           cached.text == text,
           abs(cached.width - width) < 0.5 {
            return (cached.font, cached.height)
        }

        var font = UIFont.systemFont(ofSize: singleLyricMinFontSize, weight: .semibold)
        var measured = measuredTextHeight(text, font: font, width: width)

        for size in stride(from: singleLyricMaxFontSize, through: singleLyricMinFontSize, by: -1) {
            let candidate = UIFont.systemFont(ofSize: size, weight: .semibold)
            let height = measuredTextHeight(text, font: candidate, width: width)
            if height <= candidate.lineHeight * CGFloat(singleLyricMaxLines) + 1 {
                font = candidate
                measured = height
                break
            }
        }

        // 连最小字号都放不下 ⇒ 保持上限高度、末尾省略（不再让它无限长高、压到封面/控件）。
        // ★ 2026-10-22：+8 而不是 +2 —— 现在这一行是 SwiftUI 逐词渲染器画的，它自己还会加
        //   折行行距与光晕；留 2pt 会把第二行的下缘裁掉。
        let maxHeight = font.lineHeight * CGFloat(singleLyricMaxLines) + 1
        let height = max(30, ceil(min(measured, maxHeight)) + 8)
        singleLyricMetricsCache = (text, width, font, height)
        return (font, height)
    }

    private static func measuredTextHeight(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return ceil(bounds.height)
    }

    /// 摆哪一行：**封面底边与控件条上沿的中点**（见上面那段）。
    ///
    /// 长句折行时框会变高，仍然以这个中点为心、并夹在控件条上沿之上。
    static func layoutSingleLyric(_ label: UIView, in page: UIView, height: CGFloat) {
        let bandTop = controlBandMidY - controlBandHalfHeight
        let coverBottom = visibleCoverBottom(in: page) ?? page.bounds.midY
        // ⚠️ 夹一道上限（独立复核）：`visibleCoverBottom` 拿不到主封面时会退回**卡片**那张的底边
        //    （≈878）⇒ 中点会落到进度条上。宁可让它贴着控件条上沿，也不要压住进度条。
        let boxHeight = min(height, max(30, bandTop - coverBottom - 8))
        let centerY = min((coverBottom + bandTop) / 2, bandTop - boxHeight / 2)
        let frame = CGRect(
            x: stageSideInset,
            y: (centerY - boxHeight / 2).rounded(),
            width: max(60, page.bounds.width - stageSideInset * 2),
            height: boxHeight
        )
        if label.frame != frame { label.frame = frame }
    }

    /// 封面（**缩放之后**那一帧）的底边。量不到 ⇒ `nil`（调用方退回页面中线，宁可摆低一点也不摆错）。
    static func visibleCoverBottom(in page: UIView) -> CGFloat? {
        guard let list = findByIdentifier(listIdentifier, in: page),
              let cover = visibleCover(in: list, page: page) else { return nil }
        return untransformed(cover, in: page).maxY
    }

    /// 收起来：只隐藏，不销毁（下一句 / 下一次进来还用同一份宿主）。
    /// **同时归还每帧时钟** —— 展开页要占同一个槽。
    static func hideSingleLyric() {
        releaseSingleLyricClock()
        guard let view = singleLyric, !view.isHidden else { return }
        view.isHidden = true
    }

    /// 只停时钟。`openAndMount` 在铺展开页**之前**调（共享 CADisplayLink 只有一个槽）。
    static func releaseSingleLyricClock() {
        guard #available(iOS 26.0, *) else { return }
        NowPlayingSingleLyricHost.shared.releaseClock()
    }

    /// 拿走（关开关 / 页面收尾）。缓存也一起清：下一首 / 下一次进来重新算。
    static func removeSingleLyric() {
        if #available(iOS 26.0, *) {
            NowPlayingSingleLyricHost.shared.remove()
        }
        singleLyric?.removeFromSuperview()
        singleLyric = nil
        singleLyricCacheKey = ""
        singleLyricLines = []
        singleLyricMetricsCache = nil
    }

    // MARK: - ★ 2026-10-12：被我们移走的标题行**还能点**（点歌名 / 歌手跳专辑 / 歌手页）

    /// 触摸替身（来龙去脉见 `NowPlayingTitleRelayView` 的说明）。
    static weak var titleRelay: NowPlayingTitleRelayView?
    static var titleRelayForwards = 0

    /// 每拍把替身对准"当前那一行"。
    ///
    /// **两个状态都要摆**：展开时那一行在缩略图右边（`lastUnit`），收起时在左上角
    /// （`closedTitleRow`）—— 两处都是被 `transform` 移出自己 cell 的，所以两处都点不到。
    /// 一行都没有（量不到标题行）就把替身收掉：宁可没有替身，也不要一个乱转发触摸的层。
    static func applyTitleRelay(in page: UIView) {
        guard let row = lastUnit ?? closedTitleRow, row.window != nil else {
            removeTitleRelay()
            return
        }

        let relay: NowPlayingTitleRelayView
        if let existing = titleRelay, existing.superview === page {
            relay = existing
        } else {
            relay = NowPlayingTitleRelayView(frame: page.bounds)
            relay.backgroundColor = .clear
            relay.isUserInteractionEnabled = true
            relay.accessibilityIdentifier = "eevee-npv-title-relay"
            relay.isAccessibilityElement = false
            relay.onForward = { noteTitleRelayForward() }
            page.addSubview(relay)
            titleRelay = relay
        }
        relay.row = row
        if relay.frame != page.bounds { relay.frame = page.bounds }
        page.bringSubviewToFront(relay)
    }

    /// 真的转发了一次触摸 ⇒ 记一行（**有上限**：这是每点一次都会走的路，不许刷屏）。
    ///
    /// 为什么要这行日志：用户 2026-10-12 报的"点歌名/歌手不能跳转"在**上一份日志里
    /// 一条痕迹都没有**（我们根本没参与那次触摸）。有了它，下一份日志能直接回答
    /// "替身接到触摸了吗、转进去了吗"。
    static func noteTitleRelayForward() {
        guard titleRelayForwards < 5 else { return }
        titleRelayForwards += 1
        writeDebugLog(
            "[\(logTag)] forwarded a tap into the moved title row — forward #\(titleRelayForwards)"
                + " (it should open the album / artist page)"
        )
    }

    static func removeTitleRelay() {
        titleRelay?.removeFromSuperview()
        titleRelay = nil
    }
}
