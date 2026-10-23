// 「iOS 27 听歌页」的**底部工具行**（待办 T3 + T6）。
//
// ## 目标（`C:\dsh\am\1.jpg`）
//
// AM 的底排是三颗、左右对称、**等距**：歌词气泡（左）/ 隔空播放（中）/ 队列（右），
// 位置在 414×896 上是 **x = 86 / 207 / 328**，y = 底排中线（本机 ≈805）。
//
// 我们这排现在是 Spotify 自己的布局：**Connect 在最左（≈38），分享与队列挤在右边
// （≈329 / 376）**，中间是一大片空 —— 所以"照 AM 排开"这件事躲不开**挪位置**。
//
// ## 做法：**不移动任何原生控件，只藏字形 + 自绘 + 替身**
//
//   ① 三颗原生键（Connect / 分享 / 队列）**只藏图标子树**（按钮 `alpha` 保持 1）；
//   ② 我们在页面上按 AM 的三个位置画三颗字形（26pt 方框、SF Symbol）；
//   ③ 三个位置各盖一块替身（`NowPlayingIOS27RemoteRelayView` 的 `zones`），命中后
//      `target.hitTest(中心)` ⇒ 原生键收到的是**真触摸**（手势/按压/它自己的动作全在）。
//
// 为什么不用 `transform` 把原生键挪过去：它们在 `UIStackView` 里，栈每次布局都会写
// `frame`，而给带 `transform` 的视图设 `frame` 会把位移吃掉（本仓库"搬控件"那几轮的老坑）。
//
// ## 左边那颗 = 歌词入口（T6）
//
// 新版布局把「歌词卡片」挤到屏幕外了，用户点不到 Spotify 的全屏歌词 —— 这一轮补回来：
//   · 先在页面里找 `lyrics-card-view`（真机日志 8 的 `CardView@0,0,374,320,id=lyrics-card-view`），
//     再找它内部类名带 `ShowLyricsButton` 的那颗键（dump 里有
//     `Lyrics_CardElementImpl.ShowLyricsButtonElementUI`）；
//   · 找到就用替身把触摸打给它 ⇒ 走 Spotify 自己的"打开全屏歌词"；
//   · 找不到（用户把「隐藏歌词卡片」关了、或卡片还没建出来）⇒ 左边那颗**变暗**
//     （alpha 0.35）并在日志里写明原因，**不做假入口**（这一档按下去就是没反应，
//     与本仓库"没词时歌词键变灰"的既有做法一致）。
//
// ★ 2026-10-24（实验 →「歌词舞台」开着时）：这一套**整条让位** ——
//   左边那颗不再转发给原生键，改成打开我们自己的全屏歌词窗口（`LyricsStageEntry`，
//   实现见 `Lyrics/LyricsStage/`）。那时这颗键不依赖 `ShowLyricsButton` 存不存在，
//   所以「找不到就变暗」那一档也不会出现。没开实验时行为与从前逐字一致。
//
// ⚠️ 分享键的**图形**被藏了，但功能还在：Spotify 的 ⋯ 菜单里有分享
// （`ShareButtonNowPlayingView` 只是快捷方式）。
//
// 日志 tag：`[iOS27]`，一次性一行 `footer — …`。
import Foundation
import UIKit
import ObjectiveC.runtime

@MainActor
extension NowPlayingIOS27 {

    // MARK: - 常量

    /// 工具行那三颗（真机树 8.4：`Components.ConnectButtonOutputSwitcher` / `ShareButtonNowPlayingView` /
    /// `QueueButtonNowPlaying`）。
    static let connectButtonIdentifier = "Components.ConnectButtonOutputSwitcher"
    /// Spotify 的歌词卡片（日志 8 的 `[Tree]`：`CardView@0,0,374,320,id=lyrics-card-view`）。
    static let lyricsCardIdentifier = "lyrics-card-view"
    /// 卡片里那颗"打开全屏歌词"的键（dump：`Lyrics_CardElementImpl.ShowLyricsButtonElementUI`）。
    static let lyricsButtonClassFragment = "ShowLyricsButton"

    /// 我们画的三颗字形：id 前缀 + 名字（从左到右）。
    static let footerGlyphIdentifierPrefix = "eevee-ios27-footer-"
    /// AM 的三个中心 x（414×896 上量的；页面比这窄/宽时按比例换算）。
    static let footerGlyphCentres: [CGFloat] = [86, 207, 328]
    /// 字形方框边长（AM 那颗气泡 ≈ 26pt）。
    static let footerGlyphBox: CGFloat = 26
    /// 可点区域边长。
    ///
    /// ⚠️ 必须比字形大：原生那三颗只是**图标被藏了**、按钮还在原位（分享在 x≈329，
    /// 正好压在我们画的队列字形 328 底下）—— 可点区域太小的话，点"看得见的队列"会落到
    /// **看不见的分享键**上。44pt 正好把那一块盖住（苹果的最小触摸目标，也是它们的 frame）。
    static let footerTapSide: CGFloat = 44
    /// SF Symbol 的 pointSize。
    static let footerGlyphPointSize: CGFloat = 19
    /// 字形颜色（AM 是隐约的浅白）。
    static let footerGlyphTint = UIColor(white: 1, alpha: 0.92)
    /// 没有歌词入口时左边那颗的暗度。
    static let footerGlyphDisabledAlpha: CGFloat = 0.35

    // MARK: - 状态（T2/T3 共用"藏字形"的一套表）

    /// 被我们藏掉的**原生字形子树**（按钮本身还活着，替身要能命中它们）。
    static let hiddenGlyphs = NSHashTable<UIView>.weakObjects()
    static var glyphAlphas: [ObjectIdentifier: CGFloat] = [:]

    /// 我们画的三颗（弱引用，页面走了自己掉）。
    static let footerGlyphs = NSHashTable<UIImageView>.weakObjects()
    static weak var footerRelay: NowPlayingIOS27RemoteRelayView?
    /// 上一次找到的"打开全屏歌词"那颗键（弱引用；页面重建就自己掉）。
    static weak var lyricsEntryView: UIView?
    /// 找歌词入口的节流计数（没找到时约 3 秒才全树扫一次）。
    static var lyricsSearchTicks = 0
    static var didLogFooter = false
    /// 左边那颗现在有没有歌词入口（决定暗不暗）。
    static var footerLyricsAvailable = false

    // MARK: - 藏原生字形（T2 循环键也用这一套）

    /// 把一颗原生键的**图标子树**按 `alpha = 0` 藏掉（按钮本身不动）。
    ///
    /// 为什么不是把按钮整体 `alpha = 0`：替身要靠 `hitTest` 进它，而 `alpha <= 0.01`
    /// 的视图**参与不了命中测试**（UIKit 在 `hitTest` 第一句就返回 nil）。
    @discardableResult
    static func hideGlyphSubtree(_ view: UIView) -> Bool {
        var changed = false
        var queue: [UIView] = view.subviews
        var visited = 0
        while !queue.isEmpty, visited < 64 {
            let sub = queue.removeFirst()
            visited += 1
            queue.append(contentsOf: sub.subviews)
            let key = ObjectIdentifier(sub)
            if glyphAlphas[key] == nil {
                glyphAlphas[key] = sub.alpha > 0.01 ? sub.alpha : 1
                hiddenGlyphs.add(sub)
            }
            if sub.alpha != 0 {
                sub.alpha = 0
                changed = true
            }
        }
        return changed
    }

    /// 把藏起来的字形按原值写回（幂等；T2 与 T3 都会叫它）。
    static func revealHiddenGlyphs() {
        for sub in hiddenGlyphs.allObjects {
            guard let original = glyphAlphas[ObjectIdentifier(sub)] else { continue }
            if sub.alpha != original { sub.alpha = original }
        }
    }

    /// 清空那两张表（`clearState()` 里调用）。
    static func clearHiddenGlyphs() {
        hiddenGlyphs.removeAllObjects()
        glyphAlphas.removeAll()
    }

    // MARK: - 每拍入口

    /// 把工具行排成 AM 的三颗。找不到工具行就返回 false。
    ///
    /// ⚠️ **先量到中线再藏**：量不到位置时若已经把原生字形藏掉，底排就空了。
    @discardableResult
    static func placeFooter(in page: UIView) -> Bool {
        let connect = NowPlayingLyricsPlate.findByIdentifier(connectButtonIdentifier, in: page)
        let share = NowPlayingLyricsPlate.findByIdentifier(
            NowPlayingLyricsPlate.shareButtonIdentifier, in: page
        )
        let queue = NowPlayingLyricsPlate.findByIdentifier(queueButtonIdentifier, in: page)
        guard connect != nil || share != nil || queue != nil else { return false }
        guard let rowMidY = footerRowMidY(connect: connect, share: share, queue: queue, in: page) else {
            return false
        }

        var changed = false
        for button in [connect, share, queue].compactMap({ $0 }) {
            if hideGlyphSubtree(button) { changed = true }
        }
        if mountFooterGlyphs(in: page, midY: rowMidY, connect: connect, share: share, queue: queue) {
            changed = true
        }
        return changed
    }

    /// 底排的中线 y（页面坐标）：三颗里能量到的取中位数，量不到就用底排的公共上沿推。
    private static func footerRowMidY(
        connect: UIView?, share: UIView?, queue: UIView?, in page: UIView
    ) -> CGFloat? {
        var values: [CGFloat] = []
        for view in [share, queue, connect].compactMap({ $0 }) {
            let rect = NowPlayingLyricsPlate.untransformed(view, in: page)
            guard rect.height > 1, rect.midY > 0, rect.midY < page.bounds.height else { continue }
            values.append(rect.midY)
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    // MARK: - 三颗字形 + 替身

    @discardableResult
    private static func mountFooterGlyphs(
        in page: UIView,
        midY: CGFloat,
        connect: UIView?,
        share: UIView?,
        queue: UIView?
    ) -> Bool {
        // ★ 2026-10-24：开了「歌词舞台」（设置 → 实验）就**不再需要**原生那颗键 ——
        //   左边这颗气泡直接开我们自己的全屏歌词窗口（`LyricsStageEntry`）。
        //   这也顺手修掉了"找不到 `ShowLyricsButton` 就变暗"那一档：舞台键不依赖它。
        //
        // ⚠️ 顺序很重要：舞台开着时**连找都不要去找**。`lyricsEntryTarget` 在找不到时
        //   会做一次 ≤2000 节点的 BFS（每 ~3s 一次），而这份结果在舞台这一档**永远用不上**。
        let stageEnabled = LyricsStageEntry.isEnabled
        // ⚠️ 要认**缓存**：`lyricsEntryTarget` 是节流的，被节流的那一拍返回 nil，
        // 但上一拍已经找到的那颗还在（`lyricsEntryView`）—— 否则那颗键会每 3 秒"失灵 9 拍"、
        // 左边那颗也会跟着一闪一闪。
        let lyricsTarget: UIView? = stageEnabled
            ? nil
            : (lyricsEntryTarget(in: page) ?? lyricsEntryView)
        footerLyricsAvailable = stageEnabled || lyricsTarget != nil

        // 页面换了（或上一份的宿主没了）⇒ 先把旧字形拆干净，别留在上一页上。
        if footerRelay == nil || footerRelay?.superview !== page {
            for glyph in footerGlyphs.allObjects { glyph.removeFromSuperview() }
            footerGlyphs.removeAllObjects()
        }

        let box = footerGlyphBox
        let scale = page.bounds.width / 414
        var changed = false
        var frames: [CGRect] = []
        let symbols = ["quote.bubble", "airplayaudio", "list.bullet"]
        let names = ["lyrics", "connect", "queue"]

        for (index, name) in names.enumerated() {
            let centreX = footerGlyphCentres[index] * scale
            let frame = CGRect(
                x: (centreX - box / 2).rounded(),
                y: (midY - box / 2).rounded(),
                width: box,
                height: box
            )
            frames.append(frame)

            let identifier = footerGlyphIdentifierPrefix + name
            var glyph = footerGlyphs.allObjects.first { $0.accessibilityIdentifier == identifier }
            if glyph == nil {
                let fresh = UIImageView(frame: frame)
                fresh.accessibilityIdentifier = identifier
                fresh.contentMode = .center
                fresh.isUserInteractionEnabled = false
                fresh.tintColor = footerGlyphTint
                fresh.image = footerSymbol(named: symbols[index])
                page.addSubview(fresh)
                footerGlyphs.add(fresh)
                glyph = fresh
                changed = true
            }
            guard let glyph else { continue }
            if glyph.frame != frame {
                glyph.frame = frame
                changed = true
            }
            let wantedAlpha: CGFloat = (name == "lyrics" && !footerLyricsAvailable)
                ? footerGlyphDisabledAlpha : 1
            if glyph.alpha != wantedAlpha {
                glyph.alpha = wantedAlpha
                changed = true
            }
        }

        // 替身：三个互不相交的 zone，各指向一颗原生键。
        let relay: NowPlayingIOS27RemoteRelayView
        if let existing = footerRelay, existing.superview === page {
            relay = existing
        } else {
            let fresh = NowPlayingIOS27RemoteRelayView(frame: page.bounds)
            fresh.accessibilityIdentifier = "eevee-ios27-footer-relay"
            fresh.backgroundColor = .clear
            fresh.isUserInteractionEnabled = true
            page.addSubview(fresh)
            relay = fresh
            footerRelay = fresh
            changed = true
        }
        var zones: [(rect: CGRect, target: UIView)] = []
        var actionZones: [(rect: CGRect, action: () -> Void)] = []
        let tapSide = footerTapSide
        func tapRect(_ frame: CGRect) -> CGRect {
            CGRect(
                x: (frame.midX - tapSide / 2).rounded(),
                y: (frame.midY - tapSide / 2).rounded(),
                width: tapSide,
                height: tapSide
            )
        }
        // ★ 2026-10-24：舞台开着时左中那颗走**自己的动作**（替身的 `actionZones`），
        //   不再把触摸转发给原生 `ShowLyricsButton`；其余两颗永远是转发。
        if stageEnabled {
            actionZones.append((tapRect(frames[0]), { LyricsStageEntry.present() }))
        } else if let target = lyricsTarget {
            zones.append((tapRect(frames[0]), target))
        }
        if let target = connect { zones.append((tapRect(frames[1]), target)) }
        if let target = queue { zones.append((tapRect(frames[2]), target)) }
        relay.zones = zones
        relay.actionZones = actionZones
        if relay.frame != page.bounds { relay.frame = page.bounds }
        if page.subviews.last !== relay { page.bringSubviewToFront(relay) }

        if !didLogFooter {
            didLogFooter = true
            func name(_ view: UIView?) -> String {
                view.map { NSStringFromClass(type(of: $0)) } ?? "missing"
            }
            writeDebugLog(
                "[\(logTag)] footer — connect \(name(connect)), share \(name(share)),"
                    + " queue \(name(queue)); three glyphs at"
                    + " \(Int(frames[0].midX))/\(Int(frames[1].midX))/\(Int(frames[2].midX))"
                    + " (y \(Int(midY))); lyrics entry"
                    + (stageEnabled
                        ? " = our lyrics stage (LyricsStageEntry)"
                        : (footerLyricsAvailable
                            ? " = \(name(lyricsTarget))"
                            : " missing (left glyph dimmed)"))
            )
        }
        return changed
    }

    /// 全屏歌词的入口：Spotify 歌词卡片里那颗 `ShowLyricsButton*`
    /// （dump：`Lyrics_CardElementImpl.ShowLyricsButtonElementUI`）。
    ///
    /// ⚠️ **不拿卡片本身当替身**：卡片整块是可点的歌词预览，把触摸打进它的中心有可能
    /// 落到"点某一行 ⇒ seek"上，那不是我们要的入口。找不到那颗键就让左边那颗变暗。
    ///
    /// 只在第一次（以及那颗键随页面重建消失时）做一次全树查找 —— 这条每 0.3s 会跑，
    /// 每次都 BFS 一遍播放页太贵。
    private static func lyricsEntryTarget(in page: UIView) -> UIView? {
        if let cached = lyricsEntryView, cached.window != nil, cached.alpha > 0.01 {
            return cached
        }
        // 没找到时**不要每拍全树扫**（0.3s 一次的 2000 节点 BFS 太贵）：约 3 秒找一次。
        lyricsSearchTicks += 1
        guard lyricsSearchTicks % 10 == 1 else { return nil }
        var roots: [UIView] = [page]
        if let list = NowPlayingOneScreen.pinnedList, list !== page { roots.append(list) }
        for root in roots {
            if let found = firstLyricsButton(in: root) {
                lyricsEntryView = found
                return found
            }
        }
        lyricsEntryView = nil
        return nil
    }

    /// 子树里第一颗类名含 `ShowLyricsButton` 的 `UIControl`（预算 2000 个视图）。
    private static func firstLyricsButton(in root: UIView) -> UIView? {
        var visited = 0
        var queue: [UIView] = [root]
        while !queue.isEmpty, visited < 2000 {
            let view = queue.removeFirst()
            visited += 1
            queue.append(contentsOf: view.subviews)
            guard view is UIControl, view.alpha > 0.01, !view.isHidden else { continue }
            if NSStringFromClass(type(of: view)).contains(lyricsButtonClassFragment) {
                return view
            }
        }
        return nil
    }

    private static func footerSymbol(named name: String) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(
            pointSize: footerGlyphPointSize,
            weight: .regular
        )
        return UIImage(systemName: name, withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate)
    }

    // MARK: - 收尾

    static func teardownFooter() {
        revealHiddenGlyphs()
        for glyph in footerGlyphs.allObjects {
            glyph.removeFromSuperview()
        }
        footerGlyphs.removeAllObjects()
        footerRelay?.removeFromSuperview()
        footerRelay = nil
    }

    static func clearFooterState() {
        footerGlyphs.removeAllObjects()
        footerRelay = nil
        lyricsEntryView = nil
        lyricsSearchTicks = 0
        didLogFooter = false
        footerLyricsAvailable = false
    }
}
