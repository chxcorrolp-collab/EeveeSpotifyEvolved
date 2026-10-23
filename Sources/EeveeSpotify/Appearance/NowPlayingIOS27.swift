// 「iOS 27 听歌页」—— 把听歌页做成 Apple Music（iOS 27）那一版的样子。
//
// 2026-10-23（用户）：`C:\dsh\am\1.jpg` 是 iOS 27 在 Apple Music 上的表现，问"我们可以做吗"，
// 随后拍板："和现在的『修改Spotify听歌页布局』这个按钮，直接做新的就好了。"
// ⇒ 这是一颗**独立的新开关**（`UserDefaults.nowPlayingIOS27`），默认关；
//    和旧那套（`NowPlayingLyricsPlate` 的"歌词进播放器"）**互斥**：新的开着时旧的自动让位
//    （`NowPlayingLyricsPlate.isEnabled` 的 `!nowPlayingIOS27` 那道门）。
//
// ## 第四轮（用户："太丑了、bug 很多"之后的**方向修正**）
//
// 前三轮我一直在**搬 Spotify 的原生控件**：放大封面、挪标题、把底部那一坨整抬 130pt、
// 工具行单独挪回去、再用替身转发点击…… 每一次都要"每拍补写 + 记原值 + 撤干净"，
// 而 Spotify 会回收 cell、重写 transform、写回 alpha ⇒ 修一个冒一个（照片 160/162），
// 自制的那条"模糊带"在浅色封面上糊成一块灰（照片 163）。
//
// 用户提示 pw v0.21.1 / 专辑歌单艺人页早就把"取色 + 模糊底"做过了。查证：
//   · `spotipw-v0.21.1/tweak/Sources/Redesigned/Player/PlayerField.x`：
//     播放页背景 = `SGRArtworkField`，**封面的模糊图 + 深色底 + 从窗口 55% 压到纯黑**
//     （`SGRField.m` 的 `kBlackFrom = 0.55` / `kBlackTo = 1`）；
//   · 我们仓库 `EntityPageAppearance` 已经移植了它的 `_solid + _black` 两半，
//     文件头逐字写着"`_backdrop` 那一层只有播放器用" ⇒ 缺的就是这一块。
// ⇒ 这一轮：**背景换成这套 field**，并且**不再搬底部那一坨**（上抬 / 工具行替身全部撤掉）。
//
// ## 这一版做什么
//
//   ① **封面满血**：`(0, 0, W, 0.58H)` 的竖长裁切（`scaleAspectFill`、无圆角），从屏幕最顶上开始画；
//      ⚠️ 2026-10-24 之前这里写的是 `W×W` 方图 —— 照片 2 显示那会在封面与标题之间留 186pt 的黑。
//   ② **背景 = pw 的 field**：字段色（封面下沿的平均色，压到 pw 的两条上限）→
//      窗口 55% 起渐到纯黑 → 封面下沿那一条**模糊拷贝**（同一条边界的裁切，1:1 接得上）；
//   ③ 封面自己下沿再用一条 mask 淡进那条模糊里 ⇒ 没有接缝；
//   ④ **标题行只收左边距**（16pt），**纵向留在 Spotify 原生位置** —— 不抬它就不会和进度条
//      之间空出一大块（照片 161 的老问题）；
//   ⑤ 顶部 chrome：藏歌单名与向下箭头、画 AM 那根小横条（⋯ 留在右上角原生位置）；
//   ⑥ 底部按 AM 重排（2026-10-23 深夜，T1~T4/T6）：
//      · **进度条** 4pt 细轨 + 无圆钮 + 等宽时间 → `NowPlayingIOS27+Progress.swift`；
//      · **传输行** 只留上一首/播放/下一首，循环挪到工具行右上方 → `NowPlayingIOS27+Transport.swift`；
//      · **工具行** 三颗按 AM 摆在 86/207/328（歌词 / 隔空播放 / 队列）→ `NowPlayingIOS27+Footer.swift`；
//      · **音量条** 夹在传输行与工具行之间 → `NowPlayingPageOverlay.ios27VolumeY`。
//
// ## 纪律（前几轮踩出来的）
//
//   · **不移动**任何会被 Spotify 重排的行（stack / 工具行）——移出去就点不到；
//     要换位置的控件统一用"**藏字形 + 自绘 + 替身**"（`NowPlayingIOS27RemoteRelayView`）；
//   · 只对**封面壳**写 `alpha`（记原值、每拍补、收尾写回），其余原生属性一律不碰；
//   · 自己的视图全部挂在**封面所在的那个整页 cell** 里（contentlayer 在 UI 栈下面），
//     z-order 天然正确；
//   · 每 0.3s 蹭 `DeclutterChrome` 的既有节拍（不新开定时器）。
//
// 日志 tag：`[iOS27]`。排查先看：`artwork up` / `field mounted` / `frames`（各行的真实坐标）/
// `progress styled` / `transport` / `repeat state` / `footer` / `restored`。
import Foundation
import UIKit
import CoreImage
import ObjectiveC.runtime

@MainActor
enum NowPlayingIOS27 {

    static let logTag = "iOS27"

    // MARK: - 几何 / 配色

    /// 标题行左边距（AM 16pt；Spotify 原生 28pt）。**只改横向**。
    static let titleLeadInset: CGFloat = 16
    /// 封面自己下沿从哪一档开始淡出（占封面高度）。
    ///
    /// ★ 2026-10-23 第六轮（用户：「AM 的渐变做的长度挺长的」）：0.78 → **0.45**。
    /// 也就是说封面从 45% 高度就开始往下淡，到底边完全化成底色 ——
    /// 过渡带占整张封面的一半（约 230pt），才是 AM 那种“没有明确边界”的感觉。
    static let artworkFadeStart: CGFloat = 0.45
    /// 取"字段色"时裁封面下沿多少（占封面边长）。
    static let stripFraction: CGFloat = 0.30
    /// 封面**高度**占页高的比例。
    ///
    /// ★ 2026-10-24（照片 2 的"上下两大块空"）：AM 参考图里封面是**竖长**裁切，
    ///   一直铺到屏幕约 57% 高、标题压在它下沿；我们原来是 414×414 的方图，
    ///   于是封面下方到标题之间空出 186pt。取 0.58（896 × 0.58 ≈ 520）对上参考图。
    static let artworkHeightRatio: CGFloat = 0.58
    /// 封面高宽比上限：方图裁成竖图最多裁到 1.30；再大会把封面两边裁掉太多。
    static let artworkMaxAspect: CGFloat = 1.30
    /// 压黑渐变：从页面 60% 起渐到纯黑（pw 的 `kBlackFrom` 是 0.55；这里推后一点，
    /// 让封面淡出来的那块颜色多留一会儿，过渡更长）。
    static let blackFromRatio: CGFloat = 0.60
    /// 字段颜色：pw 的 `SGRPalette` 两条上限（饱和度 0.55、线性亮度 0.07 ⇒ sRGB ≈ 0.29）。
    static let maxFieldSaturation: CGFloat = 0.55
    static let maxFieldBrightness: CGFloat = 0.30
    /// 顶部导航那三件的 id（真机树：`108.log:1735-1736`）。
    ///
    ///   · `now-playing-minimize-button` —— 左上那颗向下箭头（48×48，`Tertiary`）；
    ///   · `now-playing-navigation-unit-title-label` —— 中间那个歌单名（30×48 的 stack）；
    ///   · `Context menu` —— 右上那个 ⋯（48×48，`Tertiary`）。
    ///
    /// AM 的播放页顶部**只有一根小横条**（下拉把手）⇒ 前两件藏起来；⋯ 搬到工具行正中间。
    static let navTitleIdentifier = "now-playing-navigation-unit-title-label"
    static let contextMenuIdentifier = "Context menu"
    /// 我们自己画的那根小横条。
    static let grabberIdentifier = "eevee-ios27-grabber"

    /// 这颗开关自己就是全部条件（旧的"歌词进播放器"在它那边让位，见文件头）。
    static var isEnabled: Bool { UserDefaults.nowPlayingIOS27 }

    // MARK: - 状态

    static weak var lastPage: UIView?

    /// Spotify 那张**真正画封面**的壳（`Encore.ImageView`，366×366）。
    static weak var artworkShell: UIView?
    /// 我们自己画的那张封面 + 它的宿主（整页 cell）。
    static weak var artworkHost: UIView?
    static weak var artworkView: UIImageView?
    static weak var artworkMask: CAGradientLayer?
    /// 被我们按下 `alpha` 的原生壳（记原值，收尾按原值写回）。
    static let hiddenShells = NSHashTable<UIView>.weakObjects()
    static var shellAlphas: [ObjectIdentifier: CGFloat] = [:]

    /// 被我们藏掉的顶部 chrome（歌单名 / 向下箭头）。
    static let hiddenChrome = NSHashTable<UIView>.weakObjects()
    static var chromeAlphas: [ObjectIdentifier: CGFloat] = [:]
    static weak var grabber: UIView?


    /// 背景 field（挂在封面那个整页 cell 里、我们封面下面）。
    static weak var fieldHost: UIView?
    static weak var fieldSolid: UIView?
    static weak var fieldBlack: UIView?

    /// 被我们改了左边距的标题行，以及它原来的 `transform` 与原生位置。
    static weak var titleRow: UIView?
    static var titleRowBase: (ObjectIdentifier, CGAffineTransform)?
    static var titleRowBaseRect: (ObjectIdentifier, CGRect)?

    /// 上一次画上去的是哪一首。
    static var lastTrackId = ""
    /// 上一次给 field 上色的曲目（`lastTrackId` 在 `updateArtwork` 里先写了，这里要单独一笔）。
    static var lastFieldTrackId = ""

    static var didLogArtwork = false
    static var didLogField = false
    static var didLogTitle = false
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
        _ = updateField(in: page)
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
        if mountField(in: page) { changed = true }
        if placeTitleRow(in: page) { changed = true }
        if placeNavChrome(in: page) { changed = true }
        // 待办 T1：进度条（4pt 轨 + 藏圆钮 + 等宽时间），见 `NowPlayingIOS27+Progress.swift`。
        // 它只换 UISlider 的三张图与两颗标签的字体，不碰几何、不碰手势。
        if placeProgress(in: page) { changed = true }
        // 待办 T3 + T6：工具行排成 AM 的三颗（歌词 / 隔空播放 / 队列），见 `NowPlayingIOS27+Footer.swift`。
        // ⚠️ 必须排在 T2 前面：循环那颗圆钮是**按我们画的那颗队列字形**定位的。
        if placeFooter(in: page) { changed = true }
        // 待办 T2（用户拍板 A）：藏随机/循环，循环挪到工具行右上方，见 `NowPlayingIOS27+Transport.swift`。
        if placeTransport(in: page) { changed = true }
        // ★ 2026-10-24：传输行那块替身（循环钮）必须**最后**抬到最前。
        //
        // `placeFooter` 每拍都会把自己的替身 bringToFront 一次；`placeTransport` 排在它后面、
        // 本来也该轮到循环钮 —— 但 `placeTransport` 有几条提前返回（量不到锚 / 传输行缺一颗），
        // 那些拍里 footer 的替身就压在上面，于是同一处触摸"时而开队列、时而循环"
        // （用户报的就是这个）。这一句把"循环钮在最上"变成**每拍都成立**的事实；
        // footer 那边还有一道 `excludedRects` 兜底，两者互不依赖。
        if let repeatRelay, repeatRelay.superview === page,
           page.subviews.last !== repeatRelay {
            page.bringSubviewToFront(repeatRelay)
        }
        if !didLogFrames {
            didLogFrames = true
            logFrames(in: page)
        }
        return changed
    }

    /// 这一拍该用哪张封面。
    ///
    /// 1. **先认自己画过的那张**：我们把原生壳 `alpha = 0` 之后，`visibleCover` 的判据
    ///    （`alpha > 0.01 || isHiddenByUs`）不再认它 —— 只靠它每拍都会早退。
    /// 2. **挡住"挑到离屏那张"**：日志 888 里出现过 `at 399,161` 和 `at -138252,161`
    ///    （横向翻页转场中途），画进那种格子 = 屏幕上什么都没有（照片 162）。
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

    /// 这张视图的横向中线落在页面中间那一半里吗。
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

        // ★★ 2026-10-23 第六轮（用户：「图片可能不是当前专辑封面，而是上一首的艺人图 / 上一首的专辑页」）：
        //   **图只认"播放页自己那张壳里的图"**——`firstImage(in: shell)`。
        //
        //   原来是缓存优先（`rememberArtworkIfNeeded`）：它按**曲目 id** 存图，
        //   而从艺人页 / 专辑页进来时，转场那一两拍封面格里可能还是**那个页面的头图** ⇒
        //   它会把那张图当成"这一首的封面"存进缓存，之后整个会话都用错图。
        //   现在：当前壳里没图就**等**（旧图继续顶着），不去缓存里拿"可能是别人的那张"。
        var image: UIImage? = NowPlayingLyricsPlate.firstImage(in: shell)
        if image == nil {
            if trackChanged {
                // ★ 第五轮（照片 2：切歌闪过原生大封面）：
                //   **换歌时不要把自己那张收起来** —— 旧图继续顶着，
                //   新图一到就原地替换；只有"这一次进来还没有任何图"才让原生露出来。
                if artworkView != nil {
                    hideShell(shell)
                } else {
                    revealShells()
                }
                return false
            }
            // 刚进页面的头几拍：允许缓存兜底（那时还没有"上一首"的问题）。
            image = NowPlayingLyricsPlate.rememberArtworkIfNeeded(in: page)
        }

        guard let image, let host = fullPageAncestor(of: shell, in: page) else {
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

        // 封面画多大：**宽 = 页宽，高 = 页高的 58%**（不是方图）。
        //
        // ★ 2026-10-24（真机照片 2）：原来是 414×414 的方图，而 AM 参考图
        //   （`C:\dsh\am\1.jpg`）里那块封面是"铺到屏幕 57% 左右的**竖长**裁切"，
        //   标题正好压在它下沿的淡出区上。方图会在封面下面留出一大块黑（照片 2 里
        //   从 y≈414 到标题 y≈600 那 186pt 的空白），看起来就是"排版散了"。
        //   这里只改**我们自己那张图**的框（`scaleAspectFill` 会自己裁），不动任何原生视图。
        let coverWidth = page.bounds.width
        let coverHeight = max(
            coverWidth,
            min(page.bounds.height * Self.artworkHeightRatio, coverWidth * Self.artworkMaxAspect)
        )
        let wanted = host.convert(
            CGRect(x: 0, y: 0, width: coverWidth, height: coverHeight),
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

    /// 封面自己下沿的淡出：一条"白 → 白 → 透明"的渐变 mask（淡进下面的模糊拷贝，无硬边）。
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

    // MARK: - 背景 field（pw 的配方）

    /// 字段色底 + 压黑渐变（`_solid + _black` 那两半，与专辑/歌单/艺人页同一套）。
    ///
    /// 层次（从下往上）：`solid`（字段色，整页）→ `black`（55% 起渐到纯黑，整页）
    /// → 我们那张封面（`updateArtwork` 加的，下沿自己淡出）。
    /// ★ 2026-10-23 第五轮：**去掉了那条模糊拷贝**（pw 的 `_backdrop`）—— 用户看了照片 1/163
    /// 说"和 AM 不搭、回退"。现在封面下沿直接淡进字段色，没有会糊成一块的中间层。
    @discardableResult
    private static func mountField(in page: UIView) -> Bool {
        guard let shell = artworkShell,
              let host = fullPageAncestor(of: shell, in: page) else { return false }

        if let existing = fieldHost, existing.superview === host {
            var changed = false
            if existing.frame != page.bounds {
                existing.frame = page.bounds
                changed = true
            }
            if updateField(in: page) { changed = true }
            if layoutField(in: existing) { changed = true }
            return changed
        }

        teardownField()

        let wrapper = UIView(frame: page.bounds)
        wrapper.isUserInteractionEnabled = false
        wrapper.accessibilityIdentifier = "eevee-ios27-field"

        let solid = UIView(frame: page.bounds)
        solid.isUserInteractionEnabled = false
        solid.backgroundColor = .black
        wrapper.addSubview(solid)

        let black = UIView(frame: page.bounds)
        black.isUserInteractionEnabled = false
        black.accessibilityIdentifier = "eevee-ios27-black"
        let blackGradient = CAGradientLayer()
        blackGradient.name = "eevee-ios27-black-gradient"
        blackGradient.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        black.layer.addSublayer(blackGradient)
        wrapper.addSubview(black)

        // 插在**我们那张封面下面**（cell 里其它原生视图仍在更下面）。
        if let art = artworkView, art.superview === host {
            host.insertSubview(wrapper, belowSubview: art)
        } else {
            host.insertSubview(wrapper, at: 0)
        }

        fieldHost = wrapper
        fieldSolid = solid
        fieldBlack = black
        _ = layoutField(in: wrapper)
        _ = updateField(in: page)

        if !didLogField {
            didLogField = true
            writeDebugLog(
                "[\(logTag)] field mounted in \(NSStringFromClass(type(of: host)))"
                    + " — pw's artwork field: black from \(Int(blackFromRatio * 100))% of the page"
            )
        }
        return true
    }

    /// 子层的框（wrapper 是整页坐标）。
    @discardableResult
    private static func layoutField(in wrapper: UIView) -> Bool {
        let bounds = wrapper.bounds
        var changed = false
        if let solid = fieldSolid, solid.frame != bounds {
            solid.frame = bounds
            changed = true
        }
        if let black = fieldBlack, black.frame != bounds {
            black.frame = bounds
            changed = true
        }
        if let black = fieldBlack,
           let gradient = black.layer.sublayers?.first as? CAGradientLayer {
            if gradient.frame != black.bounds {
                gradient.frame = black.bounds
                changed = true
            }
            let locations = [NSNumber(value: Double(blackFromRatio)), NSNumber(value: 1)]
            if (gradient.locations as? [NSNumber]) != locations {
                gradient.locations = locations
                changed = true
            }
        }

        return changed
    }

    /// 字段色：按曲目 id 只做一次；换歌交叉淡入。
    @discardableResult
    private static func updateField(in page: UIView) -> Bool {
        let trackId = NowPlayingLyricsPlate.currentTrackId() ?? ""
        if trackId == lastFieldTrackId, fieldSolid != nil { return false }
        guard let shell = artworkShell,
              let image = NowPlayingLyricsPlate.firstImage(in: shell) else { return false }

        let colour = fieldColour(from: image)
        lastFieldTrackId = trackId
        // ⚠️ 必须**显式**标成 `() -> Void`。
        //
        // `fieldSolid?.backgroundColor = colour` 是**可选链赋值**，它的值类型是 `Void?`
        // ⇒ 一个**只有这一句**的闭包会被推断成 `() -> ()?`，而
        // `UIView.transition(animations:)` 要 `() -> Void`，于是报：
        //   cannot convert value of type '() -> ()?' to expected argument type '() -> Void'
        //
        // 来由（别被 blame 带偏）：这个闭包原来是**两句**（第二句是
        // `if let strip { fieldBlur?.image = strip }`，那一句是 Void），所以推断一直是
        // `() -> Void`；`1ac5568`（2026-10-23 深夜，删掉那条模糊拷贝）之后它变成一句，
        // 类型推断跟着变 —— 而 blame 只会说这三行来自 `328c202`。修法就是把类型写死。
        let apply: () -> Void = {
            fieldSolid?.backgroundColor = colour
        }
        // 只对我们自己的 wrapper 做交叉淡入（对外层 cell 做 transition 会连 Spotify 的内容一起快照）。
        if let wrapper = fieldHost, wrapper.window != nil {
            UIView.transition(with: wrapper, duration: 0.35, options: .transitionCrossDissolve, animations: apply)
        } else {
            apply()
        }
        return true
    }

    /// 封面**下沿**那一块（与原图同一比例）—— 放在方图底边之下 1:1 接上，所以没有接缝。
    private static func bottomStrip(of image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let height = CGFloat(cgImage.height)
        let width = CGFloat(cgImage.width)
        let cropHeight = max(1, height * stripFraction)
        let rect = CGRect(x: 0, y: height - cropHeight, width: width, height: cropHeight)
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    /// 从封面取"字段色"：封面**下沿**的平均色，再压到 pw 的两条上限（白字一定读得清）。
    private static func fieldColour(from image: UIImage) -> UIColor {
        let strip = bottomStrip(of: image) ?? image
        guard let average = averageColour(of: strip) else { return .black }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return UIColor(
            hue: hue,
            saturation: min(saturation, maxFieldSaturation),
            brightness: min(max(brightness, 0.08), maxFieldBrightness),
            alpha: 1
        )
    }

    /// 一张图的**平均色**（`CIAreaAverage` 渲染到 1×1 再读那一个像素）。
    ///
    /// ⚠️ 不要用 `UIImage.getRed(_:green:blue:alpha:)` —— 那是 `UIColor` 的方法；
    /// `UIImage` 只能经 `CGContext` 读像素（这里用 Core Image 一步到位）。
    private static func averageColour(of image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: input.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: nil)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        return UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }

    // MARK: - 标题行

    /// 只把标题行的**左边距**收到 16pt（纵向留在原生位置）。
    ///
    /// 为什么不抬上去：前三轮把它抬到 `W+56`，而进度条在原生那一档 —— 中间就空出一大块
    /// （照片 161）。不搬底部的前提下，唯一自洽的做法是"纵向不动"。
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

        let dx = (titleLeadInset - natural.minX).rounded()
        let wanted = base.concatenating(CGAffineTransform(translationX: dx, y: 0))
        guard row.transform != wanted else { return false }
        row.transform = wanted
        if !didLogTitle {
            didLogTitle = true
            writeDebugLog(
                "[\(logTag)] title row inset to \(Int(titleLeadInset))pt"
                    + " (kept at its native y \(Int(natural.minY)))"
            )
        }
        return true
    }

    // MARK: - 顶部 chrome

    /// 顶部：藏掉 Spotify 的歌单名与向下箭头，画一根 AM 那种小横条，⋯ 搬到工具行正中。
    ///
    /// 为什么不画一个"假关闭键"：AM 那根横条**本来就不是按钮**，是下拉把手的视觉提示；
    /// 这一页的下拉关闭挂在列表自己的 pan recogniser 上，藏了箭头照样能划掉。
    @discardableResult
    private static func placeNavChrome(in page: UIView) -> Bool {
        var changed = false
        for identifier in [NowPlayingLyricsPlate.minimizeButtonIdentifier, navTitleIdentifier] {
            guard let view = NowPlayingLyricsPlate.findByIdentifier(identifier, in: page) else {
                continue
            }
            if hideChrome(view) { changed = true }
        }
        // ★ 2026-10-23 第五轮：⋯ **不搬了**。
        //   它住在导航条里（SwiftUI 托管的那一层），**每一帧都会重置 transform** ——
        //   我们 0.3s 一拍地搬回去就是"一直在闪"（用户报的现象）。要搬得换一种做法
        //   （自绘一颗 + 自己拉菜单），不在这一轮。
        if placeGrabber(in: page) { changed = true }
        return changed
    }

    @discardableResult
    private static func placeGrabber(in page: UIView) -> Bool {
        let width: CGFloat = 44
        let height: CGFloat = 5
        let frame = CGRect(
            x: (page.bounds.width - width) / 2,
            y: max(8, page.safeAreaInsets.top + 4),
            width: width,
            height: height
        )
        if let existing = grabber, existing.superview === page {
            guard existing.frame != frame else { return false }
            existing.frame = frame
            return true
        }
        let view = UIView(frame: frame)
        view.backgroundColor = UIColor.white.withAlphaComponent(0.45)
        view.layer.cornerRadius = height / 2
        view.isUserInteractionEnabled = false
        view.accessibilityIdentifier = grabberIdentifier
        page.addSubview(view)
        page.bringSubviewToFront(view)
        grabber = view
        return true
    }

    /// 把一颗原生视图按 `alpha = 0` 藏掉（记原值；`revealChrome()` 统一写回）。
    ///
    /// ⚠️ 从 `private` 提到 internal（2026-10-23，T2）：传输行那两颗也走这一条，
    /// 于是"记原值 / 收尾写回"只有一套实现，`hiddenChrome` / `chromeAlphas` 也只有一份。
    static func hideChrome(_ view: UIView) -> Bool {
        let key = ObjectIdentifier(view)
        if chromeAlphas[key] == nil {
            chromeAlphas[key] = view.alpha > 0.01 ? view.alpha : 1
            hiddenChrome.add(view)
        }
        guard view.alpha != 0 else { return false }
        view.alpha = 0
        return true
    }

    // MARK: - 原生壳的显隐

    private static func hideShell(_ shell: UIView) {
        let key = ObjectIdentifier(shell)
        if shellAlphas[key] == nil {
            let original = shell.alpha
            shellAlphas[key] = original > 0.01 ? original : 1
            hiddenShells.add(shell)
        }
        if shell.alpha != 0 { shell.alpha = 0 }
    }

    private static func revealShells() {
        for shell in hiddenShells.allObjects {
            guard let original = shellAlphas[ObjectIdentifier(shell)] else { continue }
            if shell.alpha != original { shell.alpha = original }
        }
    }

    // MARK: - 收尾

    /// 关开关 / 离开页面：把写过的每一处写回去，拆掉我们自己的视图。
    static func restore(reason: String) {
        let hadState = fieldHost != nil || artworkView != nil || titleRowBase != nil
            || grabber != nil || !shellAlphas.isEmpty || !chromeAlphas.isEmpty
            || progressStyledSlider != nil || progressTimeLabelViews.count > 0
            || repeatPill != nil || footerRelay != nil || !hiddenGlyphs.allObjects.isEmpty
        if didLogRestore || !hadState {
            clearState()
            return
        }
        didLogRestore = true

        revealShells()
        revealChrome()
        // T2/T3 藏掉的原生字形（循环 / 工具行三颗）—— 与 `revealChrome()` 同一套写法，只是目标另一组。
        revealHiddenGlyphs()
        grabber?.removeFromSuperview()
        grabber = nil
        if let row = titleRow, let recorded = titleRowBase,
           recorded.0 == ObjectIdentifier(row), row.transform != recorded.1 {
            row.transform = recorded.1
        }
        teardownField()
        teardownArtwork()
        teardownProgress()
        teardownTransport()
        teardownFooter()

        writeDebugLog("[\(logTag)] restored (\(reason)) — native cover, title row and our views are back")
        clearState()
    }

    private static func clearState() {
        artworkShell = nil
        artworkHost = nil
        artworkView = nil
        artworkMask = nil
        titleRow = nil
        titleRowBase = nil
        titleRowBaseRect = nil
        grabber = nil
        fieldHost = nil
        fieldSolid = nil
        fieldBlack = nil
        lastTrackId = ""
        lastFieldTrackId = ""
        hiddenShells.removeAllObjects()
        shellAlphas.removeAll()
        hiddenChrome.removeAllObjects()
        chromeAlphas.removeAll()
        didLogArtwork = false
        didLogField = false
        didLogTitle = false
        didLogFrames = false
        didLogMissingCover = false
        didLogRestore = false
        clearProgressState()
        clearTransportState()
        clearFooterState()
        clearHiddenGlyphs()
    }

    private static func revealChrome() {
        for view in hiddenChrome.allObjects {
            guard let original = chromeAlphas[ObjectIdentifier(view)] else { continue }
            if view.alpha != original { view.alpha = original }
        }
    }

    private static func teardownField() {
        fieldHost?.removeFromSuperview()
        fieldHost = nil
        fieldSolid = nil
        fieldBlack = nil
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

    /// 工具行：分享键在 `npv.bottomStackView` 里的那一层祖先。
    private static func footerRowView(in page: UIView) -> UIView? {
        guard let stack = NowPlayingLyricsPlate.findByIdentifier(
            NowPlayingLyricsPlate.bottomStackIdentifier,
            in: page
        ), let share = NowPlayingLyricsPlate.findByIdentifier(
            NowPlayingLyricsPlate.shareButtonIdentifier,
            in: page
        ) else { return nil }
        var current: UIView? = share
        while let view = current, view !== stack {
            if view.superview === stack { return view }
            current = view.superview
        }
        return nil
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

    /// 一次性把各行的真实坐标打出来（排查 / 下一轮排版靠它）。
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
}
