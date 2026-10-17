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

    /// 封面与歌词键之间的**一行居中歌词**（我们自己的 `UILabel`）。
    ///
    /// 落点：**封面底边与控件条上沿的中点**，宽度与歌词块同宽（两侧各 `stageSideInset`）⇒ 这一行
    /// **自己会跟着封面走**（封面没缩成时自动往下落），不会压到封面上。
    ///
    /// 判据**一处都不新写**：行模型 `currentLines()`（按「歌词版本 + 曲目 id」再缓存一层，这条节拍每
    /// 0.3s 就问它一次）；"唱到哪一行"走 `LyricPlaybackTimeline.position(at:in:)` —— 本仓库**唯一**的
    /// 判定入口（`AppleMusicLyricsPage` 用的也是它），**不许**在这里再写一份 `time <= playback`
    /// （「同一个判据抄两份、只修一份」在 `seekToTappedLyricLine` 上刚踩过，HANDOFF_2 §4.9）；
    /// 播放位置取 `WordByWordPositionResolver.shared.currentPositionSeconds()`；节拍蹭 `reconcile`
    /// 那条 0.3s —— **不抢**共享 CADisplayLink（它只有一个 handler 槽，逐词那一层占着）。
    ///
    /// **什么时候不显示**：开关关 / 歌词展开着（再来一行是重复）/ 页面要走 / 还没词 /
    /// **一行带时间轴的都没有**（那就没有"当前行"这回事 —— 静态歌词那一档不适用）。
    /// ⚠️ `weak`：页面归它所有；万一有哪条路没走到 `removeSingleLyric`，也不该由这个静态变量
    /// **钉住上一页的标签**。
    static weak var singleLyric: UILabel?
    static var singleLyricShownText = ""
    static var singleLyricLines: [LyricLine] = []
    static var singleLyricCacheKey = ""
    static var didLogSingleLyric = false

    /// 这一行**现在该写哪一句**（`nil` = 现在不该有它）。
    static func singleLyricTextNow() -> String? {
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
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 每拍摆一次。**关闭 / 展开 / 离页**都会把它收起来（`alpha = 0`，对象留着给下一拍用）。
    static func applySingleLyric(in page: UIView) {
        guard isEnabled, !door.isOpen, page.window != nil, let text = singleLyricTextNow() else {
            hideSingleLyric()
            return
        }
        let label = ensureSingleLyricLabel(in: page)
        layoutSingleLyric(label, in: page)
        showSingleLyric(text, on: label)
    }

    static func ensureSingleLyricLabel(in page: UIView) -> UILabel {
        if let existing = singleLyric {
            if existing.superview !== page {
                existing.removeFromSuperview()
                page.addSubview(existing)
            }
            page.bringSubviewToFront(existing)
            return existing
        }

        let label = UILabel()
        label.accessibilityIdentifier = "eevee-npv-single-lyric"
        label.textAlignment = .center
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        // ⚠️ **不吃触摸**：它落在封面与控件条之间那条空带上，那一带下面是别人的手势区。
        label.isUserInteractionEnabled = false
        // 字号取 `.player` 档的主歌词字号（22pt）—— 与展开时那一页同一个量级，
        // 展开/收起时不会有"字忽然变大变小"的感觉。
        label.font = UIFont.systemFont(ofSize: 22, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.96)
        // 底下是我们的取色渐变，深浅都可能 ⇒ 与标题行同样的可读性手法：一点阴影。
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.35
        label.layer.shadowRadius = 8
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        label.alpha = 0
        page.addSubview(label)
        page.bringSubviewToFront(label)
        singleLyric = label

        if !didLogSingleLyric {
            didLogSingleLyric = true
            writeDebugLog(
                "[\(logTag)] the one-line lyric between the cover and the lyrics button is up"
                    + " (22pt, centred between the cover's bottom and \(Int(controlBandMidY - controlBandHalfHeight)))"
            )
        }
        return label
    }

    /// 摆哪一行：**封面底边与控件条上沿的中点**（见上面那段）。
    static func layoutSingleLyric(_ label: UILabel, in page: UIView) {
        let bandTop = controlBandMidY - controlBandHalfHeight
        let coverBottom = visibleCoverBottom(in: page) ?? page.bounds.midY
        let height: CGFloat = 30
        // ⚠️ 夹一道上限（独立复核）：`visibleCoverBottom` 拿不到主封面时会退回**卡片**那张的底边
        //    （≈878）⇒ 中点会落到进度条上。宁可让它贴着控件条上沿，也不要压住进度条。
        let centerY = min((coverBottom + bandTop) / 2, bandTop - height / 2)
        let frame = CGRect(
            x: stageSideInset,
            y: (centerY - height / 2).rounded(),
            width: max(60, page.bounds.width - stageSideInset * 2),
            height: height
        )
        if label.frame != frame { label.frame = frame }
    }

    /// 封面（**缩放之后**那一帧）的底边。量不到 ⇒ `nil`（调用方退回页面中线，宁可摆低一点也不摆错）。
    static func visibleCoverBottom(in page: UIView) -> CGFloat? {
        guard let list = findByIdentifier(listIdentifier, in: page),
              let cover = visibleCover(in: list, page: page) else { return nil }
        return untransformed(cover, in: page).maxY
    }

    static func hideSingleLyric() {
        guard let label = singleLyric, label.alpha > 0.01 else { return }
        label.alpha = 0
        singleLyricShownText = ""
    }

    /// 换句时**交叉淡入**（0.18s）；开「减弱动态效果」就直接换字。
    static func showSingleLyric(_ text: String, on label: UILabel) {
        if label.alpha < 0.99 {
            label.text = text
            singleLyricShownText = text
            UIView.animate(
                withDuration: 0.18,
                animations: { label.alpha = 1 },
                completion: nil
            )
            return
        }
        guard singleLyricShownText != text else { return }
        singleLyricShownText = text
        guard !UIAccessibility.isReduceMotionEnabled else {
            label.text = text
            return
        }
        UIView.transition(
            with: label,
            duration: 0.18,
            options: [.transitionCrossDissolve, .allowUserInteraction],
            animations: { label.text = text },
            completion: nil
        )
    }

    /// 拿走（关开关 / 页面收尾）。缓存也一起清：下一首 / 下一次进来重新算。
    static func removeSingleLyric() {
        singleLyric?.removeFromSuperview()
        singleLyric = nil
        singleLyricShownText = ""
        singleLyricCacheKey = ""
        singleLyricLines = []
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
