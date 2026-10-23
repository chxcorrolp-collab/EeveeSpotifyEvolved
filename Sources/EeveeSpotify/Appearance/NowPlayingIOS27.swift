// 「iOS 27 听歌页」—— 把听歌页做成 Apple Music（iOS 27）那一版的样子。
//
// 2026-10-23（用户）：`C:\dsh\am\1.jpg` 是 iOS 27 在 Apple Music 上的表现，问"我们可以做吗"，
// 随后拍板："和现在的『修改Spotify听歌页布局』这个按钮，直接做新的就好了。"
// ⇒ 这是一颗**独立的新开关**（`UserDefaults.nowPlayingIOS27`），默认关；
//    和旧那套（`NowPlayingLyricsPlate` 的"歌词进播放器"）**互斥**：新的开着时旧的自动让位
//    （`NowPlayingLyricsPlate.isEnabled` 的 `!nowPlayingIOS27` 那道门）。
//
// ## 2026-10-23 第二轮（日志 777 / 照片 160·161 之后）
//
// 第一版是"把 Spotify 那个 `Encore.ImageView` 用 `transform` 放大到满屏"。真机发现两件事：
//
//   ① **它会弹回去**：`[NPVLyrics] artwork picked … at 24,159,366,366` 与 `… at 0,0,414,414`
//      在日志里交替出现 ⇒ 封面层自己会**重写 transform**（倾斜/视差那套），
//      我们 0.3s 一拍地覆盖 ⇒ 屏幕上就是照片 160（原大小）⇄ 161（满屏）来回跳；
//   ② 放大后它自己那层圆角/裁剪还得靠 `clipsToBounds` 硬掰，副作用大。
//
// ⇒ 改成**自己画一张**（与 `NowPlayingLyricsPlate` 同一思路），原生那张只负责供图：
//
//   · 我们的封面 `eevee-ios27-artwork` 挂在**封面所在那个整页 cell** 里（contentlayer），
//     所以天然在标题/进度/控件**下面**，不需要跟任何人的 z-order 打架；
//   · 原生那张壳写 `alpha = 0`（记原值、收尾写回、每拍补一次 —— Spotify 会自己写回来）；
//   · 图从 `rememberArtworkIfNeeded`（按曲目 id 缓存、>=128pt 才算数）拿，
//     拿不到就先让原生那张露着（**绝不出现空白封面**），下一拍再换；
//   · 换歌：`CoverArtTiltLayoutHook` 转发过来的 `coverDidLayOut` 立刻重算一次。
//
// ## 这一版（v1）做什么
//
//   ① **封面满血**：`(0, 0, W, W)` 的方图（`scaleAspectFill`、无圆角），从屏幕最顶上开始画；
//   ② 封面**下沿柔和过渡**（无硬边）：封面自己下沿一条渐变 mask 淡出 → 底下垫同图的
//      高斯模糊（0.50W…1.35W，它自己也用 mask 淡出）→ 再压一条透明→黑的 scrim；
//   ③ **标题叠在过渡带上**（原生标题行挪到 `W + 56`、左缩进 16pt）；
//   ④ 底部细音量条（两端小喇叭）—— 复用 `NowPlayingPageOverlay`；
//   ⑤ 极细进度条 / 底部工具行 / ☆ 与 ⋯ —— 留 v2（见 `HANDOFF_2026-10-23_…`）。
//
// ## 几何（按页宽推，不写死像素）
//
//   封面方块：`(0, 0, W, W)`；模糊底：`(0, 0.50W, W, 0.85W)`（两条 mask 淡出，无硬边）；
//   标题行  ：顶边 = `W + 56`（≈470 on 414×896），左边 = 16pt；先夹在进度条之上。
//
// ## 时序
//
//   · 进页面：`NPVScrollViewControllerHook.viewWillAppear/.viewDidAppear` → `apply(in:)`；
//   · 每 0.3s：蹭 `DeclutterChrome` 既有的复查节拍 → `reconcile()`（不新开定时器）；
//   · 换歌：`CoverArtTiltLayoutHook` → `coverDidLayOut(from:)`（新封面对象当场接管）；
//   · 关开关 / 页面消失：`restore()`（原生壳 alpha 写回、标题行 transform 写回、拆掉我们的视图）。
//
// 日志 tag：`[iOS27]`。排查先看：`artwork up` / `title row moved` / `band mounted` /
// `frames`（一次性把各行的真实坐标打出来，v2 排版靠它）/ `restored`。
import Foundation
import UIKit
import CoreImage
import ObjectiveC.runtime

@MainActor
enum NowPlayingIOS27 {

    static let logTag = "iOS27"

    // MARK: - 几何

    /// 标题行顶边离封面底边的距离（pt）。AM 截图里 ≈ 64；取 56（W + 56 ≈ 470）。
    static let titleTopGap: CGFloat = 56
    /// 标题行左边距（AM 16pt；Spotify 原生 28pt）。
    static let titleLeadInset: CGFloat = 16
    /// 模糊背景的上下沿（占页宽）：0.50W 起、1.35W 止（414pt 上 ≈ 207…559）。
    ///
    /// 为什么不是原来那条"从封面底边往下 149pt 的硬边带子"（照片 163 里那条一眼能看出
    /// 接缝的灰带）：专辑/歌单/艺人页的封面过渡是**模糊底 + 渐变压暗**，没有硬边
    /// （`EntityPageAppearance` 那一套是这个观感）。这里照同一个观感重做：
    ///   · 封面**自己的下沿**用一条渐变 mask 淡出（0.86W 之后），
    ///   · 底下垫一张同图的模糊拷贝（从 0.50W 起），它又被一条 mask 淡出到页面的取色底，
    ///   · 上面再压一条"透明 → 黑"的 scrim（AM 的封面下半段是越来越沉的）。
    /// 三层叠起来就没有硬边了。
    static let blurTopRatio: CGFloat = 0.50
    static let blurBottomRatio: CGFloat = 1.35
    /// 封面自己下沿淡出的起点（占封面高度）。
    static let artworkFadeStart: CGFloat = 0.86
    /// **底部那一坨整体上移**多少（占页高）。AM：进度条 550 / 控件 623 / 工具行 802；
    /// 我们原生 703 / 752 / 840 ⇒ 上移 130（896×0.145）后是 573 / 622 ⇒ 控件那一档正好对上，
    /// 而工具行得**单独留在原地**（否则页面底下空一大块）。
    static let bottomLiftRatio: CGFloat = 0.145
    /// 高斯模糊半径**按原图宽度的比例**算（专辑/歌单/艺人页那条实测规矩：3.5%）。
    ///
    /// 固定 24pt 在 366pt 的封面上会把细节糊成一片纯色（`EntityPageAppearance` 的
    /// 文件头记过同一件事）；按比例算才能"看得出是哪张图"。
    static let blurRadiusRatio: CGFloat = 0.035

    /// 这颗开关自己就是全部条件（旧的"歌词进播放器"在它那边让位，见文件头）。
    static var isEnabled: Bool { UserDefaults.nowPlayingIOS27 }

    // MARK: - 状态

    static weak var lastPage: UIView?

    /// Spotify 那张**真正画封面**的壳（`Encore.ImageView`，366×366）。
    static weak var artworkShell: UIView?
    /// 我们自己画的那张封面 + 它的宿主（整页 cell）。
    static weak var artworkHost: UIView?
    static weak var artworkView: UIImageView?
    /// 被我们按下 `alpha` 的原生壳（记原值，收尾按原值写回）。
    static let hiddenShells = NSHashTable<UIView>.weakObjects()
    static var shellAlphas: [ObjectIdentifier: CGFloat] = [:]

    /// 被我们藏掉的顶部 chrome（歌单名 / 向下箭头）—— 同一套"记原值 + 每拍补"的做法。
    static let hiddenChrome = NSHashTable<UIView>.weakObjects()
    static var chromeAlphas: [ObjectIdentifier: CGFloat] = [:]
    /// 我们自己画的那根小横条。
    static weak var grabber: UIView?

    /// 被搬到工具行正中间的 ⋯（`Context menu`）+ 它的触摸替身。
    static weak var menuView: UIView?
    static var menuBase: (ObjectIdentifier, CGAffineTransform)?
    static weak var menuRelay: NowPlayingTitleRelayView?
    /// 为了把 ⋯ 搬出导航条而放开裁剪的那几层（记原值，收尾写回）。
    static let unclippedViews = NSHashTable<UIView>.weakObjects()
    static var unclippedOriginals: [ObjectIdentifier: Bool] = [:]
    static var didLogMenu = false

    /// 我们那层"模糊背景 + 渐变"（挂在同一个整页 cell 的最底层）。
    static weak var bandHost: UIView?
    static weak var bandImage: UIImageView?
    static weak var scrim: UIView?
    /// 封面自己下沿的渐变 mask（让它淡进下面的模糊层）。
    static weak var artworkMask: CAGradientLayer?

    /// 顶部导航那三件的 id（真机树：`108.log:1735-1736`）。
    ///
    ///   · `now-playing-minimize-button` —— 左上那颗向下箭头（48×48，`Tertiary`）；
    ///   · `now-playing-navigation-unit-title-label` —— 中间那个歌单名（30×48 的 stack）；
    ///   · `Context menu` —— 右上那个 ⋯（48×48，`Tertiary`）。
    ///
    /// AM 的播放页顶部**只有一根小横条**（下拉把手）⇒ 前两件藏起来；⋯ 要搬到标题行
    /// 右边（紧挨 ☆）—— 那一步等 `[iOS27] frames` 给出 ☆ 的真实坐标再做（见文件头 v2 清单）。
    static let navTitleIdentifier = "now-playing-navigation-unit-title-label"
    static let contextMenuIdentifier = "Context menu"
    /// 我们自己画的那根小横条。
    static let grabberIdentifier = "eevee-ios27-grabber"

    /// 底部那一坨（`npv.bottomStackView`）与它的工具行（footer）。
    ///
    /// 做法：整坨往上抬 `bottomLiftRatio×页高`，再把工具行**单独往下平移同样多** ⇒
    /// 视觉上只有"进度条/控件"上来了、工具行留在底部（AM 的比例）。
    /// ⚠️ 工具行移出去之后**不在那一坨的 bounds 里**了 ⇒ 点击必须靠一个替身转发
    /// （与 `NowPlayingTitleRelayView` 同一套做法）。
    static weak var bottomStack: UIView?
    static var bottomStackBase: (ObjectIdentifier, CGAffineTransform)?
    static weak var footerRow: UIView?
    static var footerBase: (ObjectIdentifier, CGAffineTransform)?
    static weak var footerRelay: NowPlayingTitleRelayView?

    /// 被我们挪下去的标题行，以及它原来的 `transform` 与**原生位置**。
    static weak var titleRow: UIView?
    static var titleRowBase: (ObjectIdentifier, CGAffineTransform)?
    static var titleRowBaseRect: (ObjectIdentifier, CGRect)?

    /// 上一次画上去的是哪一首（同一首不重复取图/模糊）。
    static var lastTrackId = ""

    static var didLogArtwork = false
    static var didLogTitle = false
    static var didLogBand = false
    static var didLogFrames = false
    static var didLogMissingCover = false
    static var didLogRestore = false

    // MARK: - 对外入口

    /// 进听歌页时叫一次（蹭既有的两个 appear 点）。
    static func apply(in page: UIView) {
        lastPage = page

        guard isEnabled else {
            restore(reason: "switch off")
            return
        }
        guard page.bounds.width > 1, page.bounds.height > 1 else { return }

        _ = layout(in: page)
    }

    /// 设置页切开关时叫一次：还挂着就当场落地，否则等下次进听歌页。
    ///
    /// ⚠️ **关掉时不管页面在不在都要收尾**：壳与 cell 会被复用，留着 `alpha = 0` 的壳
    /// 就是下一次在别处显形的空封面。`restore()` 不依赖页面对象。
    static func reapply() {
        guard isEnabled else {
            restore(reason: "switch off")
            return
        }
        guard let page = lastPage, page.window != nil else { return }
        _ = layout(in: page)
    }

    /// 蹭 `DeclutterChrome` 既有的 0.3s 复查节拍（**不新开定时器**，本仓库纪律）。
    ///
    /// - Returns: 这一拍真的改了东西吗（给排查用）。
    @discardableResult
    static func reconcile() -> Bool {
        // 页面真的不在窗口里了 ⇒ 把写过的每一处还回去（cell 会被复用）。
        // ⚠️ 这一步**不能**放在 `isEnabled` 后面：用户可能"先离开播放器、再在设置里关掉"。
        if let page = lastPage, page.window == nil {
            restore(reason: "page disappeared")
        }
        guard isEnabled else { return false }
        guard let page = lastPage, page.window != nil else { return false }
        return layout(in: page)
    }

    /// 封面自己被布局的那一刻（`CoverArtTiltLayoutHook` 转发进来）。
    static func coverDidLayOut(from tilt: UIView) {
        guard isEnabled, let page = lastPage, page.window != nil, tilt.window != nil else { return }
        guard tilt.bounds.width >= 200, tilt.isDescendant(of: page) else { return }
        guard isOnScreen(tilt, in: page) else { return }
        guard let shell = shell(in: tilt) else { return }
        _ = updateArtwork(shell, in: page)
    }

    // MARK: - 布局

    @discardableResult
    private static func layout(in page: UIView) -> Bool {
        guard let shell = resolvedShell(in: page) else {
            if !didLogMissingCover {
                didLogMissingCover = true
                writeDebugLog("[\(logTag)] no on-screen artwork yet — nothing to draw this tick")
            }
            return false
        }
        didLogMissingCover = false
        artworkShell = shell

        var changed = updateArtwork(shell, in: page)
        // 顺序：先摆底部那一坨（⋯ 要落到工具行正中间，得先有它的坐标），再摆顶部。
        if placeBottomBlock(in: page) { changed = true }
        if placeNavChrome(in: page) { changed = true }
        if placeTitleRow(in: page) { changed = true }
        if mountBand(in: page) { changed = true }
        if !didLogFrames {
            didLogFrames = true
            logFrames(in: page)
        }
        return changed
    }

    /// 这一拍该用哪张封面。
    ///
    /// **为什么不能每拍只靠 `visibleCover`**（日志 888 的一次实证）：我们自己把原生壳
    /// `alpha = 0` 之后，`visibleCover` 的判据（`alpha > 0.01 || isHiddenByUs`）不再认它
    /// —— 于是**每一拍都报 "no visible artwork"、整页的复查全部早退**。
    /// 所以：先认**上一次画过的那张**（它还在窗口里、还在屏幕中间就用它），
    /// 只有它没了才重新去树里挑。
    ///
    /// 另外还要**挡住"挑到离屏那张"**：日志 888 里出现过 `at 399,161` 和 `at -138252,161`
    /// （横向翻页转场中途），画进那种格子里 = 屏幕上什么都没有（照片 162 就是）。
    private static func resolvedShell(in page: UIView) -> UIView? {
        if let shell = artworkShell, shell.window != nil, isOnScreen(shell, in: page) {
            return shell
        }
        guard let list = NowPlayingLyricsPlate.findByIdentifier(
            NowPlayingLyricsPlate.listIdentifier,
            in: page
        ), let picked = NowPlayingLyricsPlate.visibleCover(in: list, page: page),
           isOnScreen(picked, in: page) else { return nil }
        return picked
    }

    /// 这张封面的横向中线落在页面中间那一半里吗（转场中途的离屏格子会被挡掉）。
    private static func isOnScreen(_ view: UIView, in page: UIView) -> Bool {
        let rect = view.convert(view.bounds, to: page)
        guard rect.width > 1, rect.height > 1 else { return false }
        return rect.midX > page.bounds.width * 0.2 && rect.midX < page.bounds.width * 0.8
    }

    /// 把"我们要画的那张封面"摆上去 —— 有图就画我们的、把原生的按下去；
    /// 没图就让原生那张先露着（**绝不空白**）。
    @discardableResult
    private static func updateArtwork(_ shell: UIView, in page: UIView) -> Bool {
        artworkShell = shell
        let trackId = NowPlayingLyricsPlate.currentTrackId() ?? ""
        let trackChanged = trackId != lastTrackId

        // 图：缓存优先（按曲目 id），再退回树里真实那张。
        var image: UIImage? = NowPlayingLyricsPlate.rememberArtworkIfNeeded(in: page)
        if image == nil {
            // ★ 换歌那一两拍，`rememberArtworkIfNeeded` 会**故意**返回 nil（树里还是上一首的图）。
            //   这一拍就**不要**退回 `firstImage` —— 那会拿上一首的封面画到新壳的位置上
            //   （闪一下别人的专辑）。让原生那张先露着，等图的下一拍。
            if trackChanged {
                revealShells()
                if let view = artworkView { view.isHidden = true }
                return false
            }
            image = NowPlayingLyricsPlate.firstImage(in: shell)
        }

        guard let image, let host = fullPageAncestor(of: shell, in: page) else {
            // 还没有可用图（换歌那一两拍）：原生壳先露着、我们那张藏起来。
            revealShells()
            if let view = artworkView { view.isHidden = true }
            return false
        }

        let imageView: UIImageView
        if let existing = artworkView, let currentHost = artworkHost,
           existing.superview === host, currentHost === host {
            imageView = existing
        } else {
            teardownArtwork()
            let view = UIImageView(frame: .zero)
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.isUserInteractionEnabled = false
            view.accessibilityIdentifier = "eevee-ios27-artwork"
            // 贴在 cell 的**最上层**：contentlayer 在 UI 栈下面，所以我们盖住的是原生封面那几层，
            // 不会压到标题/进度/控件；而把原生那张（已 alpha=0）留在下面不影响任何事。
            host.addSubview(view)
            artworkHost = host
            artworkView = view
            imageView = view
        }

        var changed = false
        if imageView.isHidden {
            imageView.isHidden = false
            changed = true
        }
        if trackId != lastTrackId || imageView.image !== image {
            imageView.image = image
            lastTrackId = trackId
            changed = true
            if !didLogArtwork {
                didLogArtwork = true
                writeDebugLog(
                    "[\(logTag)] artwork up — \(Int(image.size.width))×\(Int(image.size.height))"
                        + " in \(NSStringFromClass(type(of: host)))"
                )
            }
        }

        let coverSide = page.bounds.width
        let wanted = host.convert(
            CGRect(x: 0, y: 0, width: coverSide, height: coverSide),
            from: page
        )
        if imageView.frame != wanted {
            imageView.frame = wanted
            changed = true
        }
        if applyArtworkFadeMask(to: imageView) { changed = true }
        // 我们的封面在原生那张**上面**（同一个 cell 里），原生那张必须按下去。
        hideShell(shell)
        return changed
    }

    /// 封面自己下沿的淡出：一条"白 → 白 → 透明"的渐变 mask（无硬边）。
    @discardableResult
    private static func applyArtworkFadeMask(to imageView: UIImageView) -> Bool {
        let mask: CAGradientLayer
        if let existing = artworkMask {
            mask = existing
        } else {
            let fresh = CAGradientLayer()
            fresh.colors = [
                UIColor.white.cgColor,
                UIColor.white.cgColor,
                UIColor.clear.cgColor,
            ]
            fresh.locations = [0, NSNumber(value: Double(artworkFadeStart)), 1]
            fresh.startPoint = CGPoint(x: 0.5, y: 0)
            fresh.endPoint = CGPoint(x: 0.5, y: 1)
            artworkMask = fresh
            imageView.layer.mask = fresh
            mask = fresh
        }
        var changed = false
        if mask.frame != imageView.bounds {
            mask.frame = imageView.bounds
            changed = true
        }
        return changed
    }

    /// 顶部：藏掉 Spotify 的歌单名与向下箭头，画一根 AM 那种小横条。
    ///
    /// 为什么不画一个"假关闭键"：AM 那根横条**本来就不是按钮**，是下拉把手的视觉提示；
    /// 这一页的下拉关闭挂在列表自己的 pan recogniser 上，藏了箭头照样能划掉
    /// （`NowPlayingOneScreen` 的文件头把这条链记过一遍）。
    @discardableResult
    private static func placeNavChrome(in page: UIView) -> Bool {
        var changed = false
        for identifier in [NowPlayingLyricsPlate.minimizeButtonIdentifier, navTitleIdentifier] {
            guard let view = NowPlayingLyricsPlate.findByIdentifier(identifier, in: page) else {
                continue
            }
            if hideChrome(view) { changed = true }
        }

        let width: CGFloat = 44
        let height: CGFloat = 5
        let frame = CGRect(
            x: (page.bounds.width - width) / 2,
            y: max(8, page.safeAreaInsets.top + 4),
            width: width,
            height: height
        )
        if placeContextMenu(in: page) { changed = true }
        if let existing = grabber, existing.superview === page {
            if existing.frame != frame {
                existing.frame = frame
                changed = true
            }
        } else {
            let view = UIView(frame: frame)
            view.backgroundColor = UIColor.white.withAlphaComponent(0.45)
            view.layer.cornerRadius = height / 2
            view.isUserInteractionEnabled = false
            view.accessibilityIdentifier = grabberIdentifier
            page.addSubview(view)
            page.bringSubviewToFront(view)
            grabber = view
            changed = true
        }
        return changed
    }

    /// 把 ⋯（`Context menu`）搬到**工具行正中间** —— 也就是 AM 那颗雷达标的落点。
    ///
    /// 为什么不是搬到标题行右侧跟 ☆ 排：那个位置要先知道 ☆ 的真实坐标、还要把标题行收窄，
    /// 而工具行正中间天然空着（原生 footer 只有左/右几颗），一眼就是个"功能位"。
    ///
    /// 风险与做法：
    ///   · 它现在住在导航条里，往下搬 700+pt ⇒ 链上只要有 `clipsToBounds` 就会被切掉，
    ///     所以先把链上的裁剪**放开**（记原值、收尾写回）；
    ///   · 移出原来的 superview 之后命中测试够不到它 ⇒ 用 `NowPlayingTitleRelayView` 转发
    ///     （与工具行那一颗同一个套路）。
    @discardableResult
    private static func placeContextMenu(in page: UIView) -> Bool {
        guard let menu = NowPlayingLyricsPlate.findByIdentifier(contextMenuIdentifier, in: page) else {
            return false
        }
        guard let footer = footerRow, footer.window != nil else { return false }

        let footerFrame = footer.convert(footer.bounds, to: page)
        let target = CGPoint(x: page.bounds.width / 2, y: footerFrame.midY)
        let current = menu.convert(menu.bounds, to: page)
        let dx = (target.x - current.midX).rounded()
        let dy = (target.y - current.midY).rounded()

        menuView = menu
        let key = ObjectIdentifier(menu)
        let base: CGAffineTransform
        if let recorded = menuBase, recorded.0 == key {
            base = recorded.1
        } else {
            base = menu.transform
            menuBase = (key, base)
            openClips(from: menu, upTo: page)
        }
        let wanted = base.concatenating(CGAffineTransform(translationX: dx, y: dy))
        var changed = false
        if menu.transform != wanted {
            menu.transform = wanted
            changed = true
        }

        let relay: NowPlayingTitleRelayView
        if let existing = menuRelay, existing.superview === page {
            relay = existing
        } else {
            menuRelay?.removeFromSuperview()
            let view = NowPlayingTitleRelayView(frame: page.bounds)
            view.backgroundColor = .clear
            view.accessibilityIdentifier = "eevee-ios27-menu-relay"
            page.addSubview(view)
            page.bringSubviewToFront(view)
            menuRelay = view
            relay = view
            changed = true
        }
        relay.row = menu
        if relay.frame != page.bounds { relay.frame = page.bounds; changed = true }

        if !didLogMenu {
            didLogMenu = true
            writeDebugLog(
                "[\(logTag)] context menu moved to the footer centre — "
                    + "\(Int(dx)),\(Int(dy)) (AM's radar slot); tap relay armed"
            )
        }
        return changed
    }

    /// 放开从 `view` 到 `page` 之间的裁剪（记原值；收尾 `restoreClips()` 写回）。
    private static func openClips(from view: UIView, upTo page: UIView) {
        var current = view.superview
        var visited = 0
        while let candidate = current, candidate !== page, visited < 8 {
            visited += 1
            if candidate.clipsToBounds {
                let key = ObjectIdentifier(candidate)
                if unclippedOriginals[key] == nil {
                    unclippedOriginals[key] = true
                    unclippedViews.add(candidate)
                }
                candidate.clipsToBounds = false
            }
            current = candidate.superview
        }
    }

    private static func restoreClips() {
        for view in unclippedViews.allObjects {
            guard let original = unclippedOriginals[ObjectIdentifier(view)] else { continue }
            if view.clipsToBounds != original { view.clipsToBounds = original }
        }
        unclippedViews.removeAllObjects()
        unclippedOriginals.removeAll()
    }

    /// 按下去（记原值；每拍补一次 —— Spotify 会自己写回来）。
    private static func hideChrome(_ view: UIView) -> Bool {
        let key = ObjectIdentifier(view)
        if chromeAlphas[key] == nil {
            chromeAlphas[key] = view.alpha > 0.01 ? view.alpha : 1
            hiddenChrome.add(view)
        }
        guard view.alpha != 0 else { return false }
        view.alpha = 0
        return true
    }

    /// 把底部那一坨往上抬、工具行留在原地（见 `bottomStack` 那段注释）。
    ///
    /// 为什么值得动它：AM 的进度条/控件在 550/623，而我们原生在 703/752 —— 标题挪到 470 之后，
    /// 中间会空出一大片（照片 161 那块空就是这么来的）。整坨上移 130 之后，控件正好落到 622，
    /// 标题行也一起上来（≈465，正好是我们想要的位置，`placeTitleRow` 只再补几 pt 的 x/微调）。
    ///
    /// 风险与兜底：工具行找不到（量不到 `ShareButtonNowPlayingView` 的祖先）就**不动任何东西**
    /// —— 宁可还是旧比例，也不要出现"工具行飘在半空、又点不到"的页面。
    @discardableResult
    private static func placeBottomBlock(in page: UIView) -> Bool {
        guard let stack = NowPlayingLyricsPlate.findByIdentifier(
            NowPlayingLyricsPlate.bottomStackIdentifier,
            in: page
        ) else { return false }

        // 工具行 = 分享键在 stack 里的那一层祖先。
        let share = NowPlayingLyricsPlate.findByIdentifier(
            NowPlayingLyricsPlate.shareButtonIdentifier,
            in: page
        )
        var footer: UIView?
        if let share {
            var current: UIView? = share
            while let view = current, view !== stack, view.superview !== nil {
                if view.superview === stack { footer = view; break }
                current = view.superview
            }
        }
        guard let footer else { return false }

        let lift = (page.bounds.height * bottomLiftRatio).rounded()
        guard lift > 1 else { return false }

        bottomStack = stack
        var changed = applyLift(to: stack, lift: -lift, record: &bottomStackBase, key: "stack")
        footerRow = footer
        if applyLift(to: footer, lift: lift, record: &footerBase, key: "footer") { changed = true }

        // 工具行现在在那一坨外面 ⇒ 点击靠替身（只覆盖工具行那一块，别处照常穿透）。
        let relay: NowPlayingTitleRelayView
        if let existing = footerRelay, existing.superview === page {
            relay = existing
        } else {
            footerRelay?.removeFromSuperview()
            let view = NowPlayingTitleRelayView(frame: page.bounds)
            view.backgroundColor = .clear
            view.accessibilityIdentifier = "eevee-ios27-footer-relay"
            page.addSubview(view)
            page.bringSubviewToFront(view)
            footerRelay = view
            relay = view
        }
        relay.row = footer
        if relay.frame != page.bounds { relay.frame = page.bounds; changed = true }
        return changed
    }

    /// 只对"第一次接管"记原 `transform`，之后每拍按同一笔账重写（幂等）。
    private static func applyLift(
        to view: UIView,
        lift: CGFloat,
        record: inout (ObjectIdentifier, CGAffineTransform)?,
        key: String
    ) -> Bool {
        let identifier = ObjectIdentifier(view)
        let base: CGAffineTransform
        if let recorded = record, recorded.0 == identifier {
            base = recorded.1
        } else {
            base = view.transform
            record = (identifier, base)
        }
        let wanted = base.concatenating(CGAffineTransform(translationX: 0, y: lift))
        guard view.transform != wanted else { return false }
        view.transform = wanted
        if !didLogTitle {
            writeDebugLog(
                "[\(logTag)] bottom block \(key) shifted \(Int(lift))pt (v2 spacing)"
            )
        }
        return true
    }

    /// 把标题行挪到封面下沿那条带上。
    @discardableResult
    private static func placeTitleRow(in page: UIView) -> Bool {
        guard let row = titleRowView(in: page) else { return false }
        titleRow = row

        let key = ObjectIdentifier(row)
        let base: CGAffineTransform
        let natural: CGRect
        if let recorded = titleRowBase, recorded.0 == key,
           let rect = titleRowBaseRect, rect.0 == key {
            base = recorded.1
            natural = rect.1
        } else {
            base = row.transform
            natural = NowPlayingLyricsPlate.untransformed(row, in: page)
            titleRowBase = (key, base)
            titleRowBaseRect = (key, natural)
        }
        guard natural.width > 1, natural.height > 1 else { return false }

        let coverSide = page.bounds.width
        var top = coverSide + titleTopGap
        if let progressTop = progressTop(in: page) {
            top = min(top, progressTop - natural.height - 8)
        }
        top = max(top, coverSide * 0.55)

        let dx = (titleLeadInset - natural.minX).rounded()
        let dy = (top - natural.minY).rounded()
        let wanted = base.concatenating(CGAffineTransform(translationX: dx, y: dy))

        guard row.transform != wanted else { return false }
        row.transform = wanted
        if !didLogTitle {
            didLogTitle = true
            writeDebugLog(
                "[\(logTag)] title row moved — \(Int(natural.minX)),\(Int(natural.minY))"
                    + " → \(Int(titleLeadInset)),\(Int(top)) (over the artwork's fade band)"
            )
        }
        return true
    }

    /// 模糊带 + 压黑渐变（挂在封面那个整页 cell 的最底层，靠 page 坐标一次算好）。
    @discardableResult
    private static func mountBand(in page: UIView) -> Bool {
        guard let shell = artworkShell, let host = fullPageAncestor(of: shell, in: page) else {
            return false
        }

        let width = page.bounds.width
        let height = page.bounds.height

        if let existing = bandHost, existing.superview === host {
            var changed = false
            if existing.frame != CGRect(x: 0, y: 0, width: width, height: height) {
                existing.frame = CGRect(x: 0, y: 0, width: width, height: height)
                changed = true
            }
            if let image = bandImage, updateBandImage(image, shell: shell) { changed = true }
            if let scrim { layoutBandLayers(in: existing, scrim: scrim) }
            return changed
        }

        teardownBand()

        let wrapper = UIView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        wrapper.isUserInteractionEnabled = false
        wrapper.accessibilityIdentifier = "eevee-ios27-band"

        let imageView = UIImageView(frame: .zero)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = false
        imageView.accessibilityIdentifier = "eevee-ios27-band-image"
        wrapper.addSubview(imageView)

        // 模糊底自己的淡出（上不透明、下透明）—— 这是"没有硬边"的关键。
        let blurMask = CAGradientLayer()
        blurMask.name = "eevee-ios27-blur-mask"
        blurMask.colors = [
            UIColor.white.cgColor,
            UIColor.white.cgColor,
            UIColor.clear.cgColor,
        ]
        blurMask.locations = [0, 0.55, 1]
        blurMask.startPoint = CGPoint(x: 0.5, y: 0)
        blurMask.endPoint = CGPoint(x: 0.5, y: 1)
        imageView.layer.mask = blurMask

        let scrimView = UIView(frame: .zero)
        scrimView.isUserInteractionEnabled = false
        scrimView.accessibilityIdentifier = "eevee-ios27-scrim"
        let gradient = CAGradientLayer()
        gradient.name = "eevee-ios27-scrim-gradient"
        gradient.colors = [
            UIColor.black.withAlphaComponent(0.10).cgColor,
            UIColor.black.withAlphaComponent(0.45).cgColor,
            UIColor.black.withAlphaComponent(0.92).cgColor,
        ]
        gradient.locations = [0, 0.55, 1]
        scrimView.layer.addSublayer(gradient)
        wrapper.addSubview(scrimView)

        // 同一条：整页 cell 的最上层（它在 UI 栈下面，见文件头）。
        host.addSubview(wrapper)
        bandHost = wrapper
        bandImage = imageView
        scrim = scrimView
        layoutBandLayers(in: wrapper, scrim: scrimView)
        _ = updateBandImage(imageView, shell: shell)

        if !didLogBand {
            didLogBand = true
            writeDebugLog(
                "[\(logTag)] blurred backdrop mounted in \(NSStringFromClass(type(of: host)))"
                    + " — masked blur from \(Int(width * blurTopRatio))"
                    + " to \(Int(width * blurBottomRatio))"
            )
        }
        return true
    }

    /// 模糊底与 scrim 的框（同一个矩形：0.50W…1.35W），以及它俩自己那条 mask 的尺寸。
    private static func layoutBandLayers(in wrapper: UIView, scrim scrimView: UIView) {
        let width = wrapper.bounds.width
        let top = (width * blurTopRatio).rounded()
        let bottom = (width * blurBottomRatio).rounded()
        let rect = CGRect(x: 0, y: top, width: width, height: max(40, bottom - top))

        if let image = bandImage {
            if image.frame != rect { image.frame = rect }
            if let mask = image.layer.mask as? CAGradientLayer, mask.frame != image.bounds {
                mask.frame = image.bounds
            }
        }
        if scrimView.frame != rect { scrimView.frame = rect }
        if let gradient = scrimView.layer.sublayers?.first as? CAGradientLayer,
           gradient.frame != scrimView.bounds {
            gradient.frame = scrimView.bounds
        }
    }

    /// 模糊带那张图：与封面同一张，按曲目 id 只做一次。
    @discardableResult
    private static func updateBandImage(_ imageView: UIImageView, shell: UIView) -> Bool {
        let trackId = NowPlayingLyricsPlate.currentTrackId() ?? ""
        if trackId == lastTrackId, imageView.image != nil { return false }
        guard let image = NowPlayingLyricsPlate.firstImage(in: shell),
              let blurred = blurredImage(image) else { return false }
        imageView.image = blurred
        return true
    }

    // MARK: - 原生壳的显隐

    /// 把原生那张壳按下去（记原值；每拍补一次 —— Spotify 会自己把 `alpha` 写回来）。
    private static func hideShell(_ shell: UIView) {
        let key = ObjectIdentifier(shell)
        if shellAlphas[key] == nil {
            // 换歌转场里新壳可能先以 0 出现 ⇒ 原值不可信时按 1 记（关开关要能看见）。
            let original = shell.alpha
            shellAlphas[key] = original > 0.01 ? original : 1
            hiddenShells.add(shell)
        }
        if shell.alpha != 0 { shell.alpha = 0 }
    }

    /// 让原生壳露回来（还没有可用图时 / 收尾时）。
    private static func revealShells() {
        for shell in hiddenShells.allObjects {
            guard let original = shellAlphas[ObjectIdentifier(shell)] else { continue }
            if shell.alpha != original { shell.alpha = original }
        }
    }

    // MARK: - 收尾

    /// 关开关 / 离开页面：把写过的每一处写回去，拆掉我们自己的视图。
    static func restore(reason: String) {
        let hadState = bandHost != nil || artworkView != nil || titleRowBase != nil
            || bottomStackBase != nil || footerRelay != nil || grabber != nil
            || menuBase != nil || menuRelay != nil || !unclippedOriginals.isEmpty
            || !shellAlphas.isEmpty || !chromeAlphas.isEmpty
        if didLogRestore || !hadState {
            clearState()
            return
        }
        didLogRestore = true

        revealShells()
        if let row = titleRow, let recorded = titleRowBase,
           recorded.0 == ObjectIdentifier(row), row.transform != recorded.1 {
            row.transform = recorded.1
        }
        revealChrome()
        teardownContextMenu()
        grabber?.removeFromSuperview()
        grabber = nil
        teardownBottomBlock()
        teardownBand()
        teardownArtwork()

        writeDebugLog("[\(logTag)] restored (\(reason)) — native cover, title row and our views are back")
        clearState()
    }

    private static func clearState() {
        artworkShell = nil
        artworkHost = nil
        artworkView = nil
        titleRow = nil
        titleRowBase = nil
        titleRowBaseRect = nil
        bottomStack = nil
        bottomStackBase = nil
        footerRow = nil
        footerBase = nil
        footerRelay = nil
        grabber = nil
        menuView = nil
        menuBase = nil
        menuRelay = nil
        hiddenShells.removeAllObjects()
        shellAlphas.removeAll()
        hiddenChrome.removeAllObjects()
        chromeAlphas.removeAll()
        lastTrackId = ""
        didLogArtwork = false
        didLogTitle = false
        didLogBand = false
        didLogFrames = false
        didLogRestore = false
    }

    /// ⋯ 的位移撤销 + 裁剪写回 + 替身摘掉。
    private static func teardownContextMenu() {
        if let view = menuView, let recorded = menuBase,
           recorded.0 == ObjectIdentifier(view), view.transform != recorded.1 {
            view.transform = recorded.1
        }
        menuRelay?.removeFromSuperview()
        menuRelay = nil
        restoreClips()
    }

    /// 顶部 chrome 的 `alpha` 写回原值。
    private static func revealChrome() {
        for view in hiddenChrome.allObjects {
            guard let original = chromeAlphas[ObjectIdentifier(view)] else { continue }
            if view.alpha != original { view.alpha = original }
        }
    }

    private static func teardownBottomBlock() {
        if let stack = bottomStack, let recorded = bottomStackBase,
           recorded.0 == ObjectIdentifier(stack), stack.transform != recorded.1 {
            stack.transform = recorded.1
        }
        if let footer = footerRow, let recorded = footerBase,
           recorded.0 == ObjectIdentifier(footer), footer.transform != recorded.1 {
            footer.transform = recorded.1
        }
        footerRelay?.removeFromSuperview()
        footerRelay = nil
    }

    private static func teardownBand() {
        bandHost?.removeFromSuperview()
        bandHost = nil
        bandImage = nil
        scrim = nil
    }

    private static func teardownArtwork() {
        artworkView?.layer.mask = nil
        artworkView?.removeFromSuperview()
        artworkView = nil
        artworkHost = nil
        artworkMask = nil
    }

    // MARK: - 小工具

    /// 封面壳（tilt 里那张 `Encore.ImageView`）。
    private static func shell(in tilt: UIView) -> UIView? {
        var visited = 0
        var queue: [UIView] = [tilt]
        while !queue.isEmpty, visited < 128 {
            let view = queue.removeFirst()
            visited += 1
            if view.accessibilityIdentifier == NowPlayingLyricsPlate.coverImageIdentifier {
                return view
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// 标题行：`now-playing-title-label` 的祖父（与 `NowPlayingLyricsPlate.measure` 同一口径）。
    private static func titleRowView(in page: UIView) -> UIView? {
        let list = NowPlayingLyricsPlate.findByIdentifier(
            NowPlayingLyricsPlate.listIdentifier,
            in: page
        )
        let label = list.flatMap {
            NowPlayingLyricsPlate.findByIdentifier(NowPlayingLyricsPlate.titleLabelIdentifier, in: $0)
        } ?? NowPlayingLyricsPlate.findByIdentifier(
            NowPlayingLyricsPlate.titleLabelIdentifier,
            in: page
        )
        guard let label else { return nil }
        return label.superview?.superview
    }

    private static func progressTop(in page: UIView) -> CGFloat? {
        guard let unit = NowPlayingLyricsPlate.findByIdentifier(
            NowPlayingLyricsPlate.progressUnitIdentifier,
            in: page
        ) else { return nil }
        let frame = NowPlayingLyricsPlate.untransformed(unit, in: page)
        guard frame.minY > 0, frame.minY < page.bounds.height else { return nil }
        return frame.minY
    }

    /// 封面所在的**整页**祖先（contentlayer 的 cell，414×896）。
    private static func fullPageAncestor(of view: UIView, in page: UIView) -> UIView? {
        var current = view.superview
        var visited = 0
        while let candidate = current, candidate !== page, visited < 12 {
            visited += 1
            if candidate.bounds.width >= page.bounds.width - 1,
               candidate.bounds.height >= page.bounds.height - 1 {
                return candidate
            }
            current = candidate.superview
        }
        return nil
    }

    /// 一次性把各行的真实坐标打出来 —— v2 排版（进度条/控件/工具行）靠这几个数，不靠猜。
    private static func logFrames(in page: UIView) {
        func text(_ identifier: String) -> String {
            guard let view = NowPlayingLyricsPlate.findByIdentifier(identifier, in: page) else {
                return "\(identifier)=missing"
            }
            let rect = NowPlayingLyricsPlate.untransformed(view, in: page)
            return "\(identifier)=\(Int(rect.minX)),\(Int(rect.minY))"
                + " \(Int(rect.width))×\(Int(rect.height))"
        }
        var parts: [String] = [
            "page=\(Int(page.bounds.width))×\(Int(page.bounds.height))",
            text(NowPlayingLyricsPlate.progressUnitIdentifier),
            text(NowPlayingLyricsPlate.playButtonIdentifier),
            text(NowPlayingLyricsPlate.shareButtonIdentifier),
            text("Components.UI.AddToButton"),
            text(NowPlayingLyricsPlate.bottomStackIdentifier),
            text(NowPlayingLyricsPlate.minimizeButtonIdentifier),
            text(navTitleIdentifier),
            text(contextMenuIdentifier),
        ]
        if let row = titleRow {
            let rect = NowPlayingLyricsPlate.untransformed(row, in: page)
            parts.append(
                "titleRow=\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))"
            )
        }
        writeDebugLog("[\(logTag)] frames — " + parts.joined(separator: " · "))
    }

    /// 高斯模糊（只给小带子用；一换歌才一次，不缓存 `CIContext`）。
    private static func blurredImage(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        let radius = min(40, max(8, image.size.width * blurRadiusRatio))
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: nil)
        guard let rendered = context.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
    }
}
