// 「iOS 27 听歌页」的**传输行**（待办 T2，用户 2026-10-23 拍板 **A**）。
//
// ## 用户的原话与选项
//
//   A 藏起来（像 AM；循环挪到工具行，随机进 ⋯）；
//   B 留着不动；C 藏起来 + 长按播放键 = 随机。
//   ⇒ 用户回了 **a**。
//
// ## AM 的目标形状（`C:\dsh\am\1.jpg`）
//
//   · 传输行只有**三颗**：上一首 / 播放 / 下一首（白字形，没有随机、没有循环）；
//   · 循环在**底部工具行**：一颗小圆玻璃钮，位置在"队列"那颗的**右上方**（≈ +8pt / −20pt）；
//   · 随机在 AM 里根本没有常驻入口（它属于播放列表语境）—— 这里同理：Spotify 自己的 ⋯
//     （`Context menu`）菜单里本来就带重复/随机相关的动作（dump 里有
//     `_TtC19NowPlaying_ViewImpl23ContextMenuRepeatAction`），藏掉按钮不等于功能消失。
//
// ## 真机结构（交接文档第八节 8.4，414×896）
//
//   传输行：`UIStackView@12,16,382,64`
//     随机      ElementView 48×48（`Components.UI.ShuffleButton`）
//     SPTNowPlayingPreviousTrackButton 56×56
//     SPTNowPlayingPlayButton          64×64
//     SPTNowPlayingNextTrackButton     56×56
//     Nowplaying-RepeatButton          48×48
//   工具行：`UIStackView@12,0,386,44`（Connect / Share / Queue）
//
// ## 做法（**不移动任何原生控件**）
//
//   · 随机：`hideChrome` ⇒ `alpha = 0`（记原值，`restore()` 统一写回）；它那颗 slot 还在，
//     所以上一首/下一首**不会**因为"少了两颗"而重新排 —— 位置与截图一致，不做二次排版；
//   · 循环：**只藏它的图标子树**（按钮本身 `alpha` 保持 1）—— 因为触摸要靠"替身"转给它
//     （`alpha = 0` 的视图参与不了命中测试，这条在"搬控件"那几轮踩过）；
//   · 我们画的那颗圆钮（30pt 圆 + `repeat` 字形）挂在 `page` 上，位置按**队列那颗**算；
//     它上面盖一层 `NowPlayingIOS27RemoteRelayView`：命中时把触摸**打到原生循环键的中心**，
//     由它自己 `hitTest` 出真正接这一下的视图 ⇒ 原生按钮收到的是**真的触摸**（手势、按压、
//     它自己的动作全都在）。
//
// ## 为什么替身是新类，不直接复用 `NowPlayingTitleRelayView`
//
// 那个类只处理"**行还在原地、只是被 transform 挪走**"：它用
// `row.convert(row.bounds, to: self).contains(point)`，要求替身与目标**同坐标**（它自己是整页视图）。
// 我们这颗是**跨位置**映射（我们的圆钮 ↔ 传输行里的循环键），所以自己写一个只认
// `sourceRect` 的替身，命中后一律打到目标**中心**（本来就是一颗"点一下"的键）。
//
// 日志 tag：`[iOS27]`，一次性两行：`transport — …` 与 `repeat state — …`。
import Foundation
import UIKit
import ObjectiveC.runtime

/// 跨位置替身：把"我们画的那颗"的触摸交给**另一处**的原生控件。
///
/// · `zones` 是若干**本层坐标**里的可点区域，每块各指向一颗原生视图（工具行/传输行共用一套）；
/// · 命中后 `target.hitTest(中心)` ⇒ 返回原生视图链里的那一颗，UIKit 于是把这一下
///   当成**落在原生控件上**（与直接点它完全一样）。
final class NowPlayingIOS27RemoteRelayView: UIView {

    var zones: [(rect: CGRect, target: UIView)] = []

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        return zones.contains { $0.rect.contains(point) }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        guard let zone = zones.first(where: { $0.rect.contains(point) }) else { return nil }
        let target = zone.target
        guard target.window != nil, target.alpha > 0.01, !target.isHidden else { return nil }
        let centre = CGPoint(x: target.bounds.midX, y: target.bounds.midY)
        return target.hitTest(centre, with: event)
    }
}

@MainActor
extension NowPlayingIOS27 {

    // MARK: - 常量

    /// 随机那颗（真机树 `EncoreButton…id=Components.UI.ShuffleButton`）。
    static let shuffleButtonIdentifier = "Components.UI.ShuffleButton"
    /// 循环那颗（交接文档 8.4：`Nowplaying-RepeatButton 48×48`）。
    static let repeatButtonIdentifier = "Nowplaying-RepeatButton"
    /// 工具行里"队列"那颗（AM 的循环就摆在它右上方）。
    static let queueButtonIdentifier = "QueueButtonNowPlaying"

    /// 我们自己画的那颗循环圆钮。
    static let repeatPillIdentifier = "eevee-ios27-repeat"
    static let repeatRelayIdentifier = "eevee-ios27-repeat-relay"
    /// 圆钮直径（AM 那颗小玻璃圆 ≈ 30pt）。
    static let repeatPillSide: CGFloat = 30
    /// 圆钮中心相对**队列那颗中心**的偏移（AM：右 8、上 20）。
    static let repeatPillOffsetX: CGFloat = 8
    static let repeatPillOffsetY: CGFloat = -20
    /// 字形大小（SF Symbol pointSize）。
    static let repeatGlyphSize: CGFloat = 15
    /// 圆钮底色（AM 是极淡的一层玻璃；不敢用真玻璃，这里只是 10% 白）。
    static let repeatPillFill = UIColor(white: 1, alpha: 0.10)
    /// 「循环开着」时字形用的 Spotify 绿。
    static let repeatActiveTint = UIColor(red: 0.11, green: 0.73, blue: 0.33, alpha: 1)
    /// 循环关着时的字形颜色。
    static let repeatIdleTint = UIColor(white: 1, alpha: 0.92)

    // MARK: - 状态

    /// 我们画的圆钮 + 它上面的替身。
    static weak var repeatPill: UIView?
    static weak var repeatGlyph: UIImageView?
    static weak var repeatRelay: NowPlayingIOS27RemoteRelayView?
    static var didLogTransport = false
    static var didLogRepeatState = false

    // MARK: - 每拍入口

    /// 藏随机与循环、把循环摆到工具行。找不到传输行就返回 false（不假装成功）。
    @discardableResult
    static func placeTransport(in page: UIView) -> Bool {
        guard let row = transportRow(in: page) else { return false }

        var changed = false
        if let shuffle = row.shuffle, hideChrome(shuffle) { changed = true }
        if let repeatKey = row.repeat {
            // 先摆圆钮、**再**藏图标：摆不出去（量不到工具行）就让循环留在传输行，
            // 而不是"藏了图标、又没有替身" ⇒ 那颗功能就彻底看不见了。
            if mountRepeatPill(in: page, forwardingTo: repeatKey) {
                changed = true
                if hideGlyphSubtree(repeatKey) { changed = true }
            }
        }

        if !didLogTransport {
            didLogTransport = true
            func describe(_ view: UIView?) -> String {
                guard let view else { return "missing" }
                return "hidden (\(NSStringFromClass(type(of: view))))"
            }
            let pill = repeatPill.map {
                "\(Int($0.frame.minX)),\(Int($0.frame.minY))"
            } ?? "not placed"
            writeDebugLog(
                "[\(logTag)] transport — shuffle \(describe(row.shuffle))"
                    + ", repeat \(describe(row.repeat)), pill \(pill)"
                    + " (AM's three-button row; both stay reachable from the context menu)"
            )
        }
        return changed
    }

    // MARK: - 找传输行那两颗

    /// 返回传输行最外那两颗：**随机**（最左）与**循环**（最右）。
    ///
    /// 先按 id 找；**缺哪一颗就补哪一颗**（真机 8.4 的树里随机那颗常常没有 id）——
    /// 补法是**结构**：从播放键往上爬到"装得下上一首、播放、下一首的那一层"，
    /// 再把这一层里不在那三颗之列、看得见且够宽的最左/最右子视图当随机/循环。
    private static func transportRow(in page: UIView) -> (shuffle: UIView?, repeat: UIView?)? {
        var shuffle = NowPlayingLyricsPlate.findByIdentifier(shuffleButtonIdentifier, in: page)
        var repeatKey = NowPlayingLyricsPlate.findByIdentifier(repeatButtonIdentifier, in: page)
        if shuffle != nil, repeatKey != nil { return (shuffle, repeatKey) }

        if let structural = structuralTransportRow(in: page) {
            if shuffle == nil { shuffle = structural.shuffle }
            if repeatKey == nil { repeatKey = structural.repeat }
        }
        if shuffle == nil, repeatKey == nil { return nil }
        return (shuffle, repeatKey)
    }

    /// 按"和上一首/播放/下一首同一排"这个结构找最外两颗。
    private static func structuralTransportRow(in page: UIView) -> (shuffle: UIView?, repeat: UIView?)? {
        guard let play = NowPlayingLyricsPlate.findByIdentifier(
            NowPlayingLyricsPlate.playButtonIdentifier, in: page
        ), let previous = NowPlayingLyricsPlate.findByIdentifier(
            NowPlayingControlsPlate.previousButtonID, in: page
        ), let next = NowPlayingLyricsPlate.findByIdentifier(
            NowPlayingControlsPlate.nextButtonID, in: page
        ) else { return nil }

        var candidate: UIView? = play
        var visited = 0
        while let view = candidate, view !== page, visited < 10 {
            visited += 1
            if previous.isDescendant(of: view), next.isDescendant(of: view), view.subviews.count >= 3 {
                let core = [previous, play, next]
                let others = view.subviews.filter { sub in
                    guard !sub.isHidden, sub.frame.width > 20 else { return false }
                    return !core.contains { $0 === sub || $0.isDescendant(of: sub) }
                }
                guard others.count >= 2 else { return (nil, nil) }
                let left = others.min { $0.frame.minX < $1.frame.minX }
                let right = others.max { $0.frame.minX < $1.frame.minX }
                // 还没排过版（都挤在 0）就先别认，免得把别的行当传输行。
                if let left, let right, left.frame.minX == right.frame.minX { return (nil, nil) }
                return (left, right)
            }
            candidate = view.superview
        }
        return nil
    }

    // MARK: - 循环：工具行那颗圆钮 + 替身

    @discardableResult
    private static func mountRepeatPill(in page: UIView, forwardingTo repeatKey: UIView) -> Bool {
        guard let anchor = footerAnchorFrame(in: page) else { return false }
        let side = repeatPillSide
        let centre = CGPoint(
            x: anchor.midX + repeatPillOffsetX,
            y: anchor.midY + repeatPillOffsetY
        )
        // 夹在页面里：贴边的机型上"右 8"会出屏。
        let origin = CGPoint(
            x: min(max(centre.x - side / 2, 4), page.bounds.width - side - 4),
            y: max(centre.y - side / 2, page.safeAreaInsets.top + 4)
        )
        let frame = CGRect(origin: origin, size: CGSize(width: side, height: side))

        var changed = false
        let pill: UIView
        if let existing = repeatPill, existing.superview === page {
            pill = existing
        } else {
            let fresh = UIView(frame: frame)
            fresh.accessibilityIdentifier = repeatPillIdentifier
            fresh.isUserInteractionEnabled = false
            fresh.backgroundColor = repeatPillFill
            fresh.layer.cornerRadius = side / 2
            fresh.layer.cornerCurve = .continuous
            fresh.clipsToBounds = true

            let glyph = UIImageView(frame: fresh.bounds)
            glyph.contentMode = .center
            glyph.isUserInteractionEnabled = false
            glyph.tintColor = repeatIdleTint
            glyph.image = repeatGlyphImage()
            fresh.addSubview(glyph)

            page.addSubview(fresh)
            repeatPill = fresh
            repeatGlyph = glyph
            changed = true
        }
        if pill.frame != frame {
            pill.frame = frame
            repeatGlyph?.frame = pill.bounds
            changed = true
        }
        if updateRepeatGlyph(repeatKey) { changed = true }

        // 替身（整页大小，只有 `sourceRect` 那一块认触摸）。
        let relay: NowPlayingIOS27RemoteRelayView
        if let existing = repeatRelay, existing.superview === page {
            relay = existing
        } else {
            let fresh = NowPlayingIOS27RemoteRelayView(frame: page.bounds)
            fresh.accessibilityIdentifier = repeatRelayIdentifier
            fresh.backgroundColor = .clear
            fresh.isUserInteractionEnabled = true
            page.addSubview(fresh)
            relay = fresh
            repeatRelay = fresh
            changed = true
        }
        relay.zones = [(frame, repeatKey)]
        if relay.frame != page.bounds { relay.frame = page.bounds }
        if page.subviews.last !== relay { page.bringSubviewToFront(relay) }
        return changed
    }

    /// 循环圆钮的锚：**我们画的那颗队列字形**（T3 之后它才在 AM 的位置上）；
    /// 还没有字形（第一拍 / T3 没跑）就退到原生队列那颗、再退到分享那颗。
    private static func footerAnchorFrame(in page: UIView) -> CGRect? {
        let identifiers = [
            footerGlyphIdentifierPrefix + "queue",
            queueButtonIdentifier,
            NowPlayingLyricsPlate.shareButtonIdentifier,
        ]
        for identifier in identifiers {
            guard let view = NowPlayingLyricsPlate.findByIdentifier(identifier, in: page) else {
                continue
            }
            let rect = NowPlayingLyricsPlate.untransformed(view, in: page)
            guard rect.width > 8, rect.height > 8 else { continue }
            guard rect.midX > 0, rect.midX < page.bounds.width else { continue }
            return rect
        }
        return nil
    }

    /// 循环开着就把字形染绿。只用来决定颜色 —— 判别式见下面的注释。
    ///
    /// ⚠️ 没能可靠区分"全部循环"与"单曲循环"（Spotify 是换字形、不是换 tint），
    /// 所以字形**固定是 `repeat`**，开着只是变绿；真要区分得等下一轮找到状态源。
    @discardableResult
    private static func updateRepeatGlyph(_ button: UIView) -> Bool {
        let active = repeatIsActive(button)
        guard let glyph = repeatGlyph else { return false }
        let wanted = active ? repeatActiveTint : repeatIdleTint
        var changed = false
        if glyph.tintColor != wanted {
            glyph.tintColor = wanted
            changed = true
        }
        if !didLogRepeatState {
            didLogRepeatState = true
            writeDebugLog(
                "[\(logTag)] repeat state — active=\(active ? "Y" : "N")"
                    + " class=\(NSStringFromClass(type(of: button)))"
            )
        }
        return changed
    }

    /// "循环开着吗"：控件 `isSelected`，或它某个子视图的 tint 被 Spotify 染成绿。
    private static func repeatIsActive(_ button: UIView) -> Bool {
        if let control = button as? UIControl, control.isSelected { return true }
        for view in button.subviews {
            guard let tint = view.tintColor else { continue }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard tint.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { continue }
            if green > 0.45, red < 0.5, blue < 0.5 { return true }
        }
        return false
    }

    private static func repeatGlyphImage() -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(
            pointSize: repeatGlyphSize,
            weight: .semibold
        )
        return UIImage(systemName: "repeat", withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate)
    }

    // MARK: - 收尾

    /// 拆掉我们的圆钮与替身。
    ///
    /// 藏掉的图标（随机走 `hideChrome`、循环走 `hideGlyphSubtree`）由 `restore()` 里的
    /// `revealChrome()` / `revealHiddenGlyphs()` 统一写回 —— T2 与 T3 共用那两套表，只写一次。
    static func teardownTransport() {
        repeatPill?.removeFromSuperview()
        repeatPill = nil
        repeatGlyph = nil
        repeatRelay?.removeFromSuperview()
        repeatRelay = nil
    }

    static func clearTransportState() {
        repeatPill = nil
        repeatGlyph = nil
        repeatRelay = nil
        didLogTransport = false
        didLogRepeatState = false
    }
}
