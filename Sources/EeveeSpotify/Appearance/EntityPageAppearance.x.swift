import CoreImage
import Foundation
import UIKit

/// 专辑页 / 歌单页的 **AM 化**：① 取色底 field　② 封面下缘溶解。
///
/// ── 为什么是这两件（证据）──────────────────────────────────────────────────
///
/// · **AM 的专辑/歌单页 = 封面取色的渐变场 + 封面"溶"进那片颜色**（不是全屏播放器那套
///   Metal 流体渐变 —— 那是播放器的，查证见 aadishv.dev/music）。pw 的 `AlbumField` 就是
///   照 AM 做的，它的文件头逐字写着树里的实情：
///   *"the header's colour wash (a LegacyUI HeaderView the height of the header, with Spotify's
///   GradientView in it)"* ⇒ **Spotify 本来就有头部色晕**，所以 AM 的差别是"**整页**那片颜色
///   + 封面溶进去"，不是"有没有色底"。
/// · **必须清底色**：pw 同一条注释里点名 —— list 与**每个 cell** 都会自己画一层 base surface
///   （`#121212`）；不清掉，铺在页面最底层的 field **根本看不见**。这是"整页变黑"那条老坑的近亲，
///   所以这里清得**非常死**：只清"颜色恰好等于 `#121212`"的那些视图，而且只在这个页面子树里
///   （深度 ≤ 7、节点 ≤ 600），关掉开关**逐个写回原色**。
/// · **不碰 header 的 alpha**：专辑页那次淡入淡出在**父**元素
///   `CreativeWorkPlatform.Header` 上（日志 77：`alpha=-0.42 → 0.59 → -0.05`），
///   `CreativeWorkHeader` 自己是 1.00 ⇒ 谁去动 alpha 谁就跟它打架。
///
/// ── 找谁（日志 78 的探针实测，不是猜的）────────────────────────────────────
///
/// | 页面 | 页面 root | 封面 |
/// |---|---|---|
/// | 专辑 | `CreativeWorkPlatform.CreativeWorkTemplateView` | `CreativeWorkPlatform.Components.UI.ArtWorkElement.WithCoverArt`（248×248 @ 83,62） |
/// | 歌单 | 往上找到"占满屏"的那一层（页面 root 的 id 我们还没拿到） | `Components.Header.UI.ArtworkImage`（262×262 @ 76,62），里面有 `EditableHeaderArtworkElement.ImageView` |
///
/// ── 开关 ─────────────────────────────────────────────────────────────────
///
/// 扩展功能 →「**Melox 风页面**」**一颗**（`UserDefaults.entityPageDissolve`，默认**关**）——
/// 它内部同时管"取色底"与"模糊封面底 / 下缘溶解"两条路径（`tick()` 里的 `wantsField` /
/// `wantsDissolve`），用户侧只有这一颗。
/// ★ 2026-10-14：老键 `entityPageField`（原「封面取色底」那颗）**已删除** —— 它早已零读取端。
/// 这一颗关掉 = **一个字节都不改**（清过的底色逐个写回、两层视图撤掉）。
/// 日志 tag：`[PageField]`。
///
/// ★ 2026-10-17：**顶部那一条"纱"**（`ensureScrim`）跟着「封面下缘溶解」这颗开关走 ——
/// 它是"满幅封面"这套外观的一部分，用户拍板时**没有**要单独一颗开关（他二选一里选的是 A，
/// 不是"两条都做成开关"的 C）⇒ 不新增 UserDefaults 键、不动 l10n。
enum EntityPageAppearance {

    static let logTag = "PageField"

    /// 页面 root 的候选 id（歌单页 root 的 id 还没拿到 ⇒ 用"占满屏"那条几何兜底）。
    ///
    /// ★ 2026-10-13（艺人页）：pw 的 `ArtistField.x` 逐字 —— 艺人页是 `TemplateKit.TemplateView`，
    /// 而它的 `accessibilityIdentifier` 就是 **`creator-page`**（`kPageIdentifier`）。加进来，
    /// `currentTarget()` 就能像认专辑页一样认它。
    private static let pageIdentifiers = [
        "CreativeWorkPlatform.CreativeWorkTemplateView",
        "creator-page",
    ]
    /// 封面元素的候选 id。
    private static let coverIdentifiers = [
        "CreativeWorkPlatform.Components.UI.ArtWorkElement.WithCoverArt",
        "Components.Header.UI.ArtworkImage",
    ]
    /// 清底色时往下走几层 / 最多看多少个节点（**宁可漏，不可错**）。
    ///
    /// ★★ 2026-10-17（照片 121：艺人页的「你已点赞」整行还是黑的、「显示更多」那条黑带）：
    /// 7 层 / 600 个节点**够不到列表里的 cell**（艺人页那一棵比专辑页深），所以那些底色一直没被清到。
    /// 抬到 12 层 / 1500 个节点，并且**连 `layer.backgroundColor` 一起清**（`Label`/cell 的底有画在
    /// layer 上的，见 `eeveeClearBaseSurface` 里那段说明）。
    private static let clearDepth = 12
    private static let clearNodes = 1500
    /// 取色场在页面之外**上下各渗**多少（pw 的 `kBleed = {600, 0, 600, 0}`）—— 给列表顶部/底部的
    /// 回弹、以及歌单页页头那 134pt 的平移留余量，免得露出底。
    private static let fieldBleed: CGFloat = 600
    // ⚠️ 老键 `fieldColorEnd`（"取色底占页面高度的比例"，0.58）**已删** —— 艺人页的收口归 pw 的
    //    `blackFrom` / `blackTo`，专辑/歌单页那一支是平色，两页都不再用它。
    /// 封面化开成的那片背景占页面高度的比例（pw 那张 playlist 截图约 45%，这里给到 52%）。
    private static let heroHeightRatio: CGFloat = 0.52
    /// ★★ 2026-10-18（用户：「AM 那三颗按键比 Spotify 靠下一点，所以它的渐变刚好不压到艺人名字；
    ///    Spotify 的靠上就会被压住」）——**把渐变的收口绑到"我们自己那块页头里的名字"上**。
    ///
    /// 改之前的几何（真机日志 96 + `EntityPageHeaderView.layoutSubviews` 的算式）：
    ///   · 满幅照片的 mask 是 `0 → 54% → 100%`，作用在 **520pt** 的 `HeaderContainer` 上
    ///     ⇒ 照片从 281pt 一路化到 520pt（**239pt 长的尾巴**）；
    ///   · 页头那一块贴底排：名字在 **347–388**、三颗在 **408–506** ⇒ 整块都落在尾巴里，
    ///     名字那一行照片还剩六成 ⇒ 用户看到的正是"**渐变压在艺人名字上**"。
    /// AM 那边不是我们的做法：它的收口在名字**上方**就收完（照片 118：渐变在 ~360pt 收干净，
    /// 名字 365 起、三颗 416–493 全落在平色上）。它靠的是"那一行更靠下"，我们靠这两行常数。
    ///
    /// ⇒ `goneAt = 名字上沿 − meltGap`（照片到这里已经**完全**化没），
    ///    `solidUntil = 名字上沿 − meltSpanRatio × 页头高`（再往上才是完全不透明的照片）。
    /// 页头多高、Spotify 自己把那一行摆在哪，都不再影响收口落点；名字与三颗按钮一律落在平色上。
    private static let meltGap: CGFloat = 8
    /// 化开那一段占页头高度的比例（520pt 的艺人页 ⇒ 156pt）。
    ///
    /// ★★ 2026-10-18 第三轮（用户：「**这有点难看了吧**」，照片 130）：0.20（104pt）那条化开太陡，
    /// 照片的下缘看着像**被切断**。AM 那边收得慢（照片 118 的化开带约 60pt，但它的照片本来就只有
    /// 330pt 高、下缘就是照片自己的边）⇒ 我们这边放宽到 0.30，让它像"化掉"而不是"切掉"。
    private static let meltSpanRatio: CGFloat = 0.30
    /// 化开那一段的**下限**：页头矮的时候别把渐变整成一条硬边。
    private static let minMeltSpan: CGFloat = 90
    /// ★★ 2026-10-18（用户：「**现在的模糊艺人底会有看不清字的情况，做成往下渐变变灰/黑的吧，pw 的逻辑**」）
    /// —— **页面的底整个换成 pw 的 `SGRArtworkField`**（`Redesigned/Kit/SGRField.m`，GPL 的 v0.21.1）：
    ///
    ///   · `_solid` 一块**深色** —— `SGRFieldColorFor` 把封面颜色压成"白字一定读得清"的那一档
    ///     （见下面两条上限常数，`SGRPalette.m:76-97`）；
    ///   · `_black` 一条 `clear → 纯黑` 的 `CAGradientLayer`，locations = **窗口高度**的
    ///     `kBlackFrom = 0.55` / `kBlackTo = 1`（`SGRField.m:14` 的常数、`:98-102` 的算法；
    ///     它的注释逐字：*"the redesign is AMOLED throughout, fading the colour to black down the page"*）；
    ///     两层合起来就是"**上深灰 → 下纯黑**"，这里用一条三段渐变一次画完（见 `paintField`）。
    ///   · 页面**没有模糊底** —— pw 的 `_backdrop` 那一层只有**播放器**用（`SGRField.h:1-4`：
    ///     *"The player's field also carries the artwork itself at the top, blurred and dimmed…"*），
    ///     而模糊封面正是用户说"看不清字"的来源 ⇒ 三页都不再铺它（见 `ensureHero`）。
    ///
    /// ★★ 2026-10-18 **第二轮**（用户：「歌单页的封面会消失（如果歌单页的模糊不和艺人页一样，
    ///    换成和艺人一样的）」）：这套**三页共用** —— 原来"专辑/歌单页照 Melox"那条分岔取消了。
    ///    理由是照片 127：那两页的模糊底 + 浅色底让**白字看不清**，而 AM 自己的专辑/歌单页
    ///    就是"深底 + 封面卡片 + 白字"（照片 123）。
    private static let blackFrom: CGFloat = 0.55
    private static let blackTo: CGFloat = 1
    /// pw 的 `SGRPalette.m:8-9`：底板颜色的**饱和度上限 0.55**、**线性亮度上限 0.07**。
    /// 后一条是最要紧的：**任何封面（哪怕一片白）都被压成一块很深的颜色** ⇒ 白字在上面读得清。
    /// 实测：`#F2F7FB`（Nanatsukaze 那张白猫）⇒ `#494B4C` 那一档；杰克逊那张 ⇒ 一块暗棕。
    private static let maxFieldSaturation: CGFloat = 0.55
    /// ★★ 2026-10-18 第三轮（用户看真机：「**这有点难看了吧**」，照片 129/130）：pw 那个 0.07 是给
    /// **纯黑 AMOLED 底**定的，一片白的封面被它压成 `#494B4C`（深板岩）—— 艺人页整片发暗、白照片像
    /// 贴上去的。AM 自己的规则是 **"顶部 = 作品色压到中调，往下渐到黑"**：
    ///
    /// | | AM | 我们（0.07） | 我们（0.20） |
    /// |---|---|---|---|
    /// | 艺人页（照片 118，白猫） | 淡灰 `#96999B` | `#494B4C` | ≈ `#7B7D7F` |
    /// | 专辑页（照片 123，浅封面） | 很深的灰 | 深 | 深 |
    /// | 歌单页（照片 129） | 深（同 123） | `#344E5B` ✓ | 略浅 |
    ///
    /// ⇒ **艺人页用 0.20，专辑 / 歌单页留 pw 的 0.07**（129 那张用户没嫌难看，而且 AM 的专辑页
    /// 本来就是深底）。要更亮/更暗就改这一个数。
    private static let maxFieldLuminance: CGFloat = 0.07
    private static let artistFieldLuminance: CGFloat = 0.20
    /// ⚠️ 下面两条（Melox 模糊底的常数）与 `blurred()` / `ensureVeil()` / `hero` 一起**已停用**
    /// （2026-10-18 第二轮，三页都不再铺模糊底）—— 函数与常数留着没删，纯粹是为了让这一版
    /// 的改动面小一点；下一次清理时一起删。
    private static let meloxBlurRadius: CGFloat = 18
    /// 先降采样到的目标最长边（MeloX 的 `downsampled` 就是 `160 / max(width, height)`）。
    private static let meloxDownsampleEdge: CGFloat = 160

    // MARK: - 状态

    private static var timer: Timer?
    private static var currentPage: UIView?
    private static var field: GradientView?
    /// 底子那张**模糊**封面（见 `ensureHero` ①）。
    private static var hero: UIImageView?
    /// ★ 2026-10-13：铺在最上面的那张**清晰满幅**封面（见 `ensureHero` ②）。
    private static var sharpHero: UIImageView?
    /// 满幅 hero 的**单调高度**（"到过的最深处"），存在**那块 plane** 上（pw 的 `kHeroHeightKey`）。
    private static var heroHeightKey: UInt8 = 0
    /// hero 的最小高度（pw 的 `kMinHero = 120`）：比这矮就不画，免得出来一条细带。
    private static let minHeroHeight: CGFloat = 120
    /// ★ 2026-10-17：**顶上那一条"带"** —— 用**这个页面的取色**画，照片从它里面化出来（见 `ensureScrim`）。
    private static var scrim: GradientView?
    /// 那一条里**完全不透明**的那一段占多高：`0.55 × (安全区顶 + 22)` ≈ 45pt ⇒ 正好盖住灵动岛/状态栏
    /// 那一条；剩下那截是"照片从色里长出来"的渐变，所以它既是缓冲区、也是渐变（用户两轮要的是同一件事）。
    private static let scrimSolidFraction: CGFloat = 0.55
    /// 那一条在"安全区顶"之外还要往下化开多少 —— 不留这一截的话，色带底沿会看到一条硬边。
    private static let scrimExtraFade: CGFloat = 22
    /// 那一条**当前用着哪个颜色**（`#RRGGBB`）：换封面才重写 layer，0.6s 那一拍不重复写。
    private static var scrimColourKey: String?
    /// 被我们藏掉的 wash 视图（**记原值**，关开关原样撤回）—— 见 `concealWash` / `revealWash`。
    private static var concealedWash: [
        (view: UIView, layerHidden: Bool, hadMask: Bool, interactive: Bool, accessibilityHidden: Bool)
    ] = []
    /// Spotify 自己那张封面 —— 被我们**让位**藏起来的那张。
    ///
    /// ⚠️ 记的是"**我们改了什么**"，关开关时只撤回这些（Spotify 自己的 hidden 一律不碰）——
    /// 与 `DeclutterChrome` 同一条纪律。
    private static var concealedNativeCover: NativeCoverRecord?

    private struct NativeCoverRecord {
        let view: UIView
        let layerHidden: Bool
        let hadMask: Bool
        let interactive: Bool
        let accessibilityHidden: Bool
    }
    /// 模糊结果按"哪张图"缓存一次（同一张封面不重复跑 CoreImage）。
    private static var cachedHeroSource: UIImage?
    private static var cachedHeroImage: UIImage?
    private static let ciContext = CIContext(options: nil)
    /// 我们清过的底色（**记原值**：关开关要逐个写回 —— 与 `DeclutterChrome` 同一条纪律）。
    private static var clearedBackgrounds: [(view: UIView, color: UIColor)] = []
    /// ★ 2026-10-17：**画在 layer 上的**那批底色，分开记（还原时写回的是 `CGColor`，不是 `UIColor`）。
    private static var clearedLayerBackgrounds: [(layer: CALayer, color: CGColor)] = []
    /// ★ 2026-10-17：收掉的「ScrollFadeMask」—— 记两种形态（它是视图 / 它是某个 layer 的 mask）。
    private static var hiddenFadeViews: [(view: UIView, layerHidden: Bool)] = []
    private static var removedFadeMasks: [(layer: CALayer, mask: CALayer)] = []
    private static var fadeMaskViews: Set<ObjectIdentifier> = []
    private static var fadeMaskLayers: Set<ObjectIdentifier> = []
    private static var clearedLayerViews: Set<ObjectIdentifier> = []
    /// 已经清过的**对象**（懒建的 cell 每拍都要查一遍，但只记一次；`ObjectIdentifier` 不做强引用）。
    private static var clearedViews: Set<ObjectIdentifier> = []
    /// 上面两张表的上限（封死，不让它随着滚动无限长）。
    private static let maxCleared = 1200
    /// 「专辑页找到了、但封面图还没加载出来」只报一次（否则那 0.6s 的节拍会刷屏）。
    private static var didReportMissingColour = false
    /// Spotify 自己的按键里，**这些 id 片段**的一律藏掉（见 `hideChrome`）。
    ///
    /// ⚠️ **按片段匹配、不按整串**：真机日志 78 里头部那几颗是
    /// `Components.UI.AddToButton` / `DownloadButton.Granular.None` /
    /// `Components.UI.ContextMenuButton-2iyK0BOpYVMJUpDkAwVhph`（**带一段随机后缀**）/
    /// `Components.UI.WatchFeedEntityExplorerButton` —— 整串比对会漏掉带后缀的那种 ✗。
    ///
    /// ⛔ **`ContextMenuButton` 故意不在这张名单里**（2026-10-13 自查发现）：
    /// 它就是**右上那颗「…」**，而 pw 的整套做法**恰恰骑在它上面** ——
    /// `PlaylistMenu.x` 逐字写着 Spotify 的那七颗 pill 里有五颗
    /// （`Add / Notes / Video / Edit / Name & details`）**⋯ 菜单本来就有**，
    /// pw 只把缺的 `Sort` / `Mix` 补进这张 sheet 的 header，点的还是 Spotify 自己那颗 pill。
    /// ⇒ 把「…」藏掉 = 把我们要往里加东西的那个面板弄没了 ✗（早期的名单里就有它，这里撤回）。
    ///
    /// ⚠️ 剩下的三项（AddTo / Download / WatchFeed）**藏之前要确认 ⋯ 里确实有对应的行** ——
    /// 这正是 pw 反复强调的"只做加法"；行内那两颗（每行的「+」「…」）**id 还没读到过**，
    /// 命不中也不会有副作用，而且**藏了哪些 id 会打进日志**，下一份日志就能看到它们叫什么。
    private static let chromeIdentifierFragments = [
        "AddToButton",
        "DownloadButton",
        "WatchFeedEntityExplorerButton",
    ]
    private static var hiddenChrome: [(view: UIView, alpha: CGFloat)] = []
    private static var hiddenChromeViews: Set<ObjectIdentifier> = []
    private static let maxHiddenChrome = 400
    private static var didReport = false
    /// "清掉了一个页面容器"只报一次（见 `clearPageContainers`）。
    private static var didReportContainerClear = false
    private static var lastLoggedHex: String?

    // MARK: - 入口

    static var isEnabled: Bool { UserDefaults.entityPageDissolve }

    /// 缓存"这一拍那棵树里的封面元素"（见 `layoutPass`），省掉每帧一次子树搜索。
    private static var layoutCoverKey: UInt8 = 0

    /// **每一帧的轻量入口**（从 `HeaderContentLayout.layoutSubviews` 调，见 `EntityPageHeader.x.swift`）。
    ///
    /// 治的是用户 2026-10-13 报的：「刚进歌单页的时候，原本有的小歌单封面会短暂展现一会」——
    /// 我们原来只有 0.6s 的 `Timer` 会调 `concealNativeCover`，而 Spotify 那张 262×262 的封面
    /// **在第一帧就已经画出来了** ⇒ 最坏 0.6s 的可见窗口。
    ///
    /// pw 的 `PlaylistHeader.x` 是从 `HeaderContentLayout.layoutSubviews` 每帧调 `applyHero` 的，
    /// 而 `applyHero` 的最后一行就是 `conceal(cover)` ⇒ **第一帧就藏**。这里照做，但只做这一件
    /// **幂等且便宜**的事：取色 / 模糊 / 建 field 那些重活仍留在 `tick` 里（0.6s 一次）。
    static func layoutPass(in layout: UIView) {
        guard isEnabled else { return }
        guard layout.bounds.width > 120, layout.bounds.height > 40 else { return }
        // ⚠️ **只处理我们确实会铺 hero 的那几种页面**（专辑页 / 歌单页 / 艺人页）。
        //    它们都有 `Components.Header.UI.ArtworkImage` 或 `ArtWorkElement.WithCoverArt` 同名/同形的
        //    封面元素，判据只看**页面 root 的 id**，所以不会误伤别处。判据只沿祖先链走，
        //    比 `currentTarget()` 便宜，也足够安全。
        guard recognizesPage(of: layout) else { return }

        // ★★ 2026-10-17：**只在艺人页上补藏原生封面**。专辑 / 歌单页现在**保留 Spotify 自己那张
        //    封面卡片**（用户拍板选 A，见 `tick()`）—— 还照旧每帧把它藏掉的话，页面上就一张封面
        //    都没有了。
        guard isArtistPage(of: layout) else { return }

        let cover: UIView?
        if let cached = objc_getAssociatedObject(layout, &layoutCoverKey) as? UIView,
           cached.window != nil, cached.isDescendant(of: layout) {
            cover = cached
        } else {
            cover = firstView(in: layout, withAnyIdentifier: coverIdentifiers)
            objc_setAssociatedObject(layout, &layoutCoverKey, cover, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        guard let cover else { return }
        concealNativeCover(cover)
    }

    /// `layout` 是不是我们要接管的那两种页面之一：专辑页（页面 root 带 id）或歌单页（页头 id `PL.Header`）。
    private static func recognizesPage(of layout: UIView) -> Bool {
        var node: UIView? = layout
        var level = 0
        while let current = node, level < 24 {
            level += 1
            if let identifier = current.accessibilityIdentifier,
               pageIdentifiers.contains(identifier) || identifier == "PL.Header" {
                return true
            }
            node = current.superview
        }
        return false
    }

    /// 藏掉 **Spotify 自己那层色晕**（歌单页 = `_backgroundViewContainer` 里那块 wash plane；
    /// 专辑页 = 头里那个 `HeaderView` 下的 `GradientView`）。
    ///
    /// ★★★ 2026-10-17（照片 126）：这两处原来写在 `ensureSharpHero` 的分支里 —— 那是"有 hero 时顺手
    /// 藏掉盖住 hero 的那层"。**撤掉 hero 之后它们就不跑了**，于是 Spotify 那层 wash 直接露面：
    /// 用户看到的就是"一条**不是从上到下**的暗棕渐变"（Spotify 的 wash 是模糊/径向的，不是我们的线性
    /// 竖直渐变）。卡片版式下它同样是多余的（底色归我们的 field）⇒ 单独提出来，两条路都调。
    ///
    /// 两种形态各找各的，与 `ensureSharpHero` 里的判据完全一样（同一个 `washPlane`）。
    private static func concealNativeWash(for target: Target) {
        guard let cover = target.cover else { return }
        if let plane = washPlane(for: cover), plane.bounds.width > 1 {
            concealWash(on: plane)
        } else {
            concealAlbumWash(in: target.page)
        }
    }

    /// `layout` 是不是**艺人页**（页面 root 的 id = `creator-page`）。
    ///
    /// ★ 2026-10-17：`layoutPass` 只在这一页上继续藏原生封面（见那里的说明）。
    private static func isArtistPage(of layout: UIView) -> Bool {
        var node: UIView? = layout
        var level = 0
        while let current = node, level < 24 {
            level += 1
            if current.accessibilityIdentifier == "creator-page" { return true }
            node = current.superview
        }
        return false
    }

    /// AM 的封面卡片是**连续圆角**（原生只有 4）—— 与 `LibraryRowsAppearance` 同一条纪律：
    /// **记原值**，关开关 / 换页时写回。
    ///
    /// ⚠️ 只圆**里面那张图**（`firstImageView`），不碰外面那个可能带阴影的容器 ——
    /// 给它 `clipsToBounds` 会把阴影一起剪掉。
    private static var coverRounding: (view: UIView, radius: CGFloat, curve: CALayerCornerCurve, clips: Bool)?
    private static let coverCornerRadius: CGFloat = 8

    private static func roundCoverCard(_ cover: UIView?) {
        guard let imageView = cover.flatMap({ firstImageView(in: $0) }) ?? cover as? UIImageView else { return }
        let side = min(imageView.bounds.width, imageView.bounds.height)
        guard side > 40 else { return }
        let radius = min(coverCornerRadius, side / 4)

        if let existing = coverRounding, existing.view === imageView {
            if abs(imageView.layer.cornerRadius - radius) > 0.1 { imageView.layer.cornerRadius = radius }
            return
        }
        restoreCoverRounding()
        coverRounding = (imageView, imageView.layer.cornerRadius, imageView.layer.cornerCurve, imageView.clipsToBounds)
        imageView.layer.cornerRadius = radius
        imageView.layer.cornerCurve = .continuous
        imageView.clipsToBounds = true
        writeDebugLog(
            "[\(logTag)] artwork card rounded to \(Int(radius))pt continuous (AM's artwork card;"
                + " Spotify's own square stays where its layout put it)"
        )
    }

    private static func restoreCoverRounding() {
        guard let record = coverRounding else { return }
        record.view.layer.cornerRadius = record.radius
        record.view.layer.cornerCurve = record.curve
        record.view.clipsToBounds = record.clips
        coverRounding = nil
    }

    static func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.6, repeats: true) { _ in tick() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        writeDebugLog(
            "[\(logTag)] armed — Melox page look \(UserDefaults.entityPageDissolve ? "ON" : "OFF"),"
                + " hiding Spotify's repeated buttons \(UserDefaults.entityPageHideChrome ? "ON" : "OFF")"
        )
    }

    private static func tick() {
        // ★ 2026-10-13（用户：「有些选项可以改改或者删掉了」）：**「封面取色底」并进这一颗了** ——
        //   在用户眼里"模糊封面底"与"整页取色底"就是同一件事的两半（都是拿封面的颜色铺底），
        //   设置页因此从**三颗减到两颗**；代码里两条路径**留着**（要单独排查时能只关一半）。
        // ★ 2026-10-14 实话：下面这两行**同源** —— 读的都是 `entityPageDissolve`；老键
        //   `entityPageField` **已删除**（它零读取端，而且 `:173` 的 `isEnabled` 才是整条入口的
        //   闸门 ⇒ 就算把这一行改回老键也救不回）。留两个变量**只为**让"取色底"与"模糊封面底"
        //   两条路径在代码里各管各的（要单独关一半时改对应那一行即可），行为与拆分前一致。
        let wantsField = UserDefaults.entityPageDissolve
        let wantsDissolve = UserDefaults.entityPageDissolve

        guard let target = currentTarget() else {
            // 页面走了：把上一页留下的东西全部还原（切页/退出都不留残迹）。
            if currentPage != nil || field != nil || hero != nil || sharpHero != nil
                || scrim != nil || concealedNativeCover != nil {
                restore(reason: "left the page")
            }
            // 底色拦截器也一起松手（照片 103 的那条硬边就是它要治的：Spotify 重画底色 ⇒ 丢这次写入）。
            EntityPageRepaint.root = nil
            return
        }

        if target.page !== currentPage {
            restore(reason: "another page")
            currentPage = target.page
        }
        EntityPageRepaint.root = target.page

        // ★★ 2026-10-18：**这一页的底色用哪个颜色**只算一次，三条路共用（底 / 照片的化开 / 顶带）——
        //    否则"底是压暗过的、顶带还是原色"这种不一致会从缝里露出来。见 `pageColour(for:)`。
        let colour = pageColour(for: target)

        if wantsField {
            ensureField(on: target, colour: colour)
        } else if field != nil {
            restore(reason: "field switch off")
        }

        if wantsDissolve {
            // ★★ 2026-10-18 第二轮（用户：「歌单页的封面会消失（如果歌单页的模糊不和艺人页
            //    一样，换成和艺人一样的）」）：**三页共用同一套底**（pw 的深色 + 往黑，
            //    见 `paintField` / `fieldColourFor`），差别只剩“封面是谁的”：艺人页铺我们的满幅照片
            //    （Spotify 那张让位），专辑 / 歌单页**保留 Spotify 自己那张卡片**。
            let sharp = target.kind == .artist
            ensureHero(on: target, sharpCover: sharp, colour: colour)
            // ★ 2026-10-14：这里原来还有一条"头部居中"（`centerHeaderLabels`）—— **已删**：
            //    它只在这个艺人页（`sharp`）分支里跑，可名单里那 4 个 id 全是**专辑页**的
            //    `CreativeWorkPlatform.Components.UI.{PreTitleRow,TitleRow,ParentRow,MetadataRow}`
            //    ⇒ 在艺人页上一行都命不中，从 2026-10-18 起就是空转（日志里永远不会有
            //    `[PageField]` 的"头部居中"记录）；AM 式页头另有实现（见 `EntityPageHeader.x.swift`）。
            if !sharp {
                // 卡片圆角照 AM（连续圆角 8，原生只有 4）。
                roundCoverCard(target.cover)
                // ★★★ 2026-10-17（**照片 126 是判决**）：页面那条**不是从上到下**的暗棕渐变，
                //    **不是我们的 field** —— 是 **Spotify 自己那层色晕**（`GradientView`，本来就是
                //    模糊/径向的）。原因：撤掉 hero 之后，`ensureSharpHero` 里那两处"藏掉 Spotify 色晕"
                //    也跟着不跑了 ✗，于是它露面压在 field 上。
                //    ⇒ 卡片版式**照样要藏它**（底色归我们的 field）。
                concealNativeWash(for: target)
            }
        } else {
            removeHero()
        }

        // ③ Spotify 自己那些按键（用户 2026-10-13：「spotify 本身的那些按键都还在，看起来不咋地」）。
        if UserDefaults.entityPageHideChrome {
            hideChrome(in: target.page)
        } else if !hiddenChrome.isEmpty {
            restoreChrome(reason: "chrome switch off")
        }
    }

    // MARK: - ① 取色底

    /// ★★ 2026-10-18：颜色改成**外面算好传进来**（`tick` 里的 `pageColour(for:)`）——
    /// 艺人页要的是 pw 压暗过的那一版，而且底 / 照片的化开 / 顶上那条带必须用**同一个值**。
    private static func ensureField(on target: Target, colour: UIColor?) {
        guard let colour else { return }
        let page = target.page

        let view: GradientView
        if let field, field.superview === page {
            view = field
        } else {
            view = GradientView(frame: page.bounds)
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.isUserInteractionEnabled = false
            view.accessibilityIdentifier = "eevee-page-field"
            page.insertSubview(view, at: 0)
            field = view
            clearBaseSurfaces(in: page)
        }

        // ★★ 2026-10-18：**上下各渗 600pt**（pw 的 `kBleed = {600, 0, 600, 0}`，见它的
        //    `PlaylistField.x:23-24`："Above for the bounce at the top of the list, below for the one at
        //    the end of it"）。歌单页的列表会回弹、页头会平移（静止 −134 → 滚动 −529），
        //    场正好等于页面时会在那些时刻露出底 ✗。
        //    ⚠️ 现在这一层是**纯色**，所以渗多少都不会改观感（旧的三段渐变是按高度算 locations 的，
        //       那时候外扩会把渐变拉稀 —— 这也是为什么现在才敢做）。
        let painted = page.bounds.insetBy(dx: 0, dy: -fieldBleed)
        if !view.frame.equalTo(painted) { view.frame = painted }
        // ⚠️ `paintField` 靠"上下各渗出去的那 600pt"反推页面高度与渐变落点 ⇒ **必须在这两行之后**调。
        paintField(view, colour: colour)

        // ★ 2026-10-13（**日志 79** 实测只有 7 处被清之后发现）：**每一拍都要补清**。
        //   cell 是**随滚动懒建**的 —— 只在建场那一拍清一次的话，往下滚出来的新 cell 会自己再画一层
        //   `#121212`，把 field **重新盖住**（pw 那边也是持续在清：它的注释点名 list 与每个 cell）。
        //   已经清过的按对象记住，不会重复记、也不会重复写。
        clearBaseSurfaces(in: page)
        // ★ 2026-10-13（照片 110）：**页面直接子视图那一层也要清** —— 见 `clearPageContainers`。
        clearPageContainers(in: page)
        // ★★ 2026-10-18 第二轮：**section 底部那层"往黑渐变"**（「显示更多」那条黑带）——
        //    例行扫描够不到它，这里另开一次有上限的深搜，见 `huntScrollGradients`。
        huntScrollGradients(in: page)

        // ★★ 2026-10-06：**浅底时把文字翻成深色** —— 见 `textTone`（你报的"浅色背景下看不清
        //    账号名字 / 本月有 xxx 听众"）。与清底色同一条纪律：**每一拍补一次**。
        let light = isLight(colour)
        textTone(in: page, isLight: light)

        // ★★ 2026-10-17：**状态栏也跟着翻** —— AM 的 118（亮底）是黑字、119（暗棕底）是白字，
        //    它就是靠这一条解决"照片铺到顶"的（不是靠留白）。我们原来一处都没碰过状态栏，
        //    于是在亮封面上白字直接消失（用户照片 115 的现场）。
        //    判据**复用同一个 `isLight`**，不另立阈值；值没变时 `apply` 只是一次比较。
        EntityPageStatusBar.apply(light ? .darkContent : .lightContent)

        guard !didReport else { return }
        didReport = true
        let raw = target.color.map { hex(of: $0) } ?? "?"
        let kind = target.kind == .artist ? "artist" : "album/playlist"
        writeDebugLog(
            "[\(logTag)] field on \(type(of: page)) \(frameText(page.bounds)) [\(kind)]"
                + " ← cover colour #\(raw), field #\(hex(of: colour))"
                + " (pw: saturation ≤ \(Int(maxFieldSaturation * 100))%,"
                + " linear luminance ≤ \(maxFieldLuminance); fading to black from"
                + " \(Int(blackFrom * 100))% of the window down)"
                + "; cleared \(clearedBackgrounds.count) base-surface background(s)"
                + " (only the ones equal to #121212, inside this page, depth ≤ \(clearDepth))"
        )
    }

    /// 这片颜色**亮不亮**（决定底色往上抬还是往下压、也决定文字要不要反色）。
    private static func isLight(_ colour: UIColor) -> Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        guard colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        return (0.299 * red + 0.587 * green + 0.114 * blue) > 0.55
    }

    /// ★★ 2026-10-06（用户：「在浅色背景下，**看不清账号名字 / 本月有 xxx 听众** 这种信息」，
    /// 照片 111 就是那张白底专辑的白字）：**浅底时把页面里的浅色文字翻成深色**。
    ///
    /// 判据只有一条：我们铺的那块取色底**亮不亮**（`isLight`）。亮 ⇒ 白字改成近黑；
    /// 暗 ⇒ 一个字都不动（Spotify 本来就是白字）。
    ///
    /// ⚠️ 两条纪律与"清底色"完全一样：
    ///   · Spotify **每一拍都会把文字色写回去** ⇒ 这里也是**每一拍补一次**；
    ///   · 只改**本来就亮的**字（`white > 0.62`）—— 绿色的"正在播放"、彩色的标签一律不碰
    ///     （`getWhite` 对彩色返回 false，天然被排除）。
    ///
    /// 记原值是为了**撤得干净**：底一变暗（或页面换掉），`restoreTextTone` 逐个写回。
    private static var tonedLabels: [(label: UILabel, color: UIColor)] = []
    private static var tonedViews: Set<ObjectIdentifier> = []
    private static let maxToned = 400

    private static func textTone(in page: UIView, isLight light: Bool) {
        guard light else {
            restoreTextTone()
            return
        }
        var seen = 0
        func walk(_ node: UIView, _ depth: Int) {
            guard depth <= 5, seen < clearNodes, tonedLabels.count < maxToned else { return }
            seen += 1
            if let label = node as? UILabel, !(node is UIButton) {
                var white: CGFloat = 0, alpha: CGFloat = 1
                if label.textColor.getWhite(&white, alpha: &alpha), alpha > 0.5, white > 0.62 {
                    let identifier = ObjectIdentifier(label)
                    if !tonedViews.contains(identifier) {
                        tonedViews.insert(identifier)
                        tonedLabels.append((label, label.textColor))
                    }
                    let dark = UIColor(white: 0.09, alpha: 1)
                    if label.textColor != dark { label.textColor = dark }
                }
            }
            for sub in node.subviews { walk(sub, depth + 1) }
        }
        walk(page, 0)
    }

    private static func restoreTextTone() {
        guard !tonedLabels.isEmpty else { return }
        for entry in tonedLabels where entry.label.textColor != entry.color {
            entry.label.textColor = entry.color
        }
        tonedLabels.removeAll()
        tonedViews.removeAll()
    }

    /// 把颜色**按倍数压暗**（保留色相与饱和度）。
    ///
    /// ★★ 2026-10-06（照片 116/117：「渐变也有问题」，日志 92 逐字 `#B08FA8 → #B08DA7 → #A887A0`）：
    /// 那三段**几乎是同一个颜色**，所以整页看着是平的。原因是 `tinted` 只设**上限**——
    /// 基色亮度本来只有 0.65 时，`atMost: 0.88` 等于什么都没做，而 `0.66` 也只压掉一点点。
    /// 这里改成**乘一个系数**（往上抬不了就往下走），亮底与暗底都能拉开。
    private static func scaled(_ colour: UIColor, by factor: CGFloat) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 1
        guard colour.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return colour
        }
        return UIColor(
            hue: hue,
            saturation: saturation,
            brightness: max(0.04, min(1, brightness * factor)),
            alpha: 1
        )
    }

    /// 竖直渐变。**两种页面两套画法**（这一节的两段注释是历史，别把两页的规矩搞混）：
    ///
    /// · **艺人页**（2026-10-18，用户：「现在的模糊艺人底会有看不清字的情况，做成往下渐变变灰/黑的吧，
    ///   **pw 的逻辑**」）= **照 pw**：上面一块**深色**（封面颜色压过亮度上限的那一版，见
    ///   `maxFieldLuminance`），从**窗口高度的 55%** 起一路渐变到**纯黑**（`blackFrom` / `blackTo`）。
    ///   pw 的 `SGRArtworkField` 是两层（`_solid` 一块色 + `_black` 一条 clear→纯黑，`SGRField.m:98-102`），
    ///   这里用一条三段渐变画出**同一个合成结果** ⇒ 页面越往下越黑，白字就压得住。
    /// · **专辑 / 歌单页** = Melox 那三层里最底的一层：**纯取色**（不是渐变），
    ///   那条"往下变沉"归 `veil` 画在模糊封面之上（用户 2026-10-18：「看 melox 的歌单页和 am
    ///   几乎一模一样，看它的吧」）。
    ///
    /// ⚠️ 下面那条"照片 95-97 的教训"说的是**专辑/歌单页**（那两页至今不许落到纯 `#121212`）；
    ///     艺人页这条"渐到黑"是用户点名要的，字都压在它上面，和 pw 一样。
    ///
    /// ⚠️ **照片 95-97 的教训**：原来 57% 之后就是纯 `#121212` ⇒ 用户看到的是"**下半部分还是黑的**" ✗。
    /// pw 的字段是 `bleed = {600, 0, 600, 0}`（**比整页还大一圈**，见 `AlbumField.x` / `PlaylistField.x`），
    /// 整页都带着那片颜色 ⇒ 专辑 / 歌单页那一支至今只画**一块平色**（不再有"越往下越沉"的三段）；
    /// 要不要抄 pw 那条 `_black`，两页的答案**相反**（艺人页要、这两页不要，见上面两段）。
    private static func paintField(_ view: GradientView, colour: UIColor) {
        // ★★ 2026-10-18 第二轮：**三页同一条**（用户：「歌单页的封面会消失（如果歌单页的模糊不和艺人页
        //    一样，换成和艺人一样的）」）—— 原来 `if artist` / `else`（Melox 平色）那条分岔**已合并**：
        //    专辑 / 歌单页也走 pw 这条"深色 → 纯黑"。它们与艺人页的差别只剩"封面是 Spotify 那张卡片"
        //    （见 `ensureHero`），底色与收口完全一致。
        // ★ 2026-10-13（照片 110）那条“两个上限 0.26 / 0.14”（`scaled(_:by:)` / `tinted(_:atMost:)`）
        //    已经**整条退役**：专辑 / 歌单页不再压颜色（Melox 是渐到取色本身），艺人页的压暗改在
        //    `fieldColourFor` 里按 pw 的线性亮度上限做。那两个旧函数留着，但**已无调用点**。
        // ★★ 2026-10-06 那条"封面亮就给亮底"（照片 111）**对艺人页已经作废** —— 它正是"看不清字"的
        //    来源；`textTone` 的反色判据现在跟着 `fieldColourFor` **压暗后**的颜色走
        //    （压暗之后 `isLight` 恒为假 ⇒ 艺人页不再反色，白字照旧）。专辑 / 歌单页不受影响。
        // ★★★ 2026-10-18（用户：「我看 melox 的歌单页和 am 几乎一模一样，**看它的吧**」）：
        //   照 Melox `Features/Playlist/PlaylistDetailContent.swift:441-452` 的三层 ——
        //   **取色纯色 + 模糊封面 + 一条 `取色@34% → 取色` 的 LinearGradient**（`:237-241` 页头区同一条）。
        //   ⇒ 这一层（最底）只负责"底色是取色"，**它是纯色、不是渐变**；那条渐变由 `veil` 画在
        //     模糊封面**之上**（见 `ensureVeil`），跟 Melox 的叠放次序一致。
        //
        //   ⚠️ 2026-10-18 起：**艺人页要 pw 那条 `_black`**（下面 `if artist` 那一支），
        //     专辑 / 歌单页**不要**（它们照 Melox 渐到取色本身）。用户 2026-10-13 否掉的那句
        //     「往下滑是全黑的、没有颜色」说的是**专辑/歌单页**，别拿它去撤艺人页。
        let layer = view.gradient
        layer.startPoint = CGPoint(x: 0.5, y: 0)
        layer.endPoint = CGPoint(x: 0.5, y: 1)

        // 页面高度 = 渗过之后的高度 − 上下各 600（`ensureField` 就是这么摆的帧）。
        let painted = max(1, view.bounds.height)
        let pageHeight = max(1, painted - 2 * fieldBleed)
        let window = windowHeight(fallback: pageHeight)
        // pw 的 locations 是**绝对**位置（窗口高度 × 0.55 / × 1）换算成整块画布的比例 ——
        // `from = height * kBlackFrom + bleed.top`（`SGRField.m:99-102`），这里 `fieldBleed`
        // 就是那个 bleed.top。
        let from = min(1, max(0, (fieldBleed + window * blackFrom) / painted))
        let to = min(1, max(from, (fieldBleed + window * blackTo) / painted))
        layer.locations = [NSNumber(value: 0), NSNumber(value: from), NSNumber(value: to)]
        layer.colors = [colour.cgColor, colour.cgColor, UIColor.black.cgColor]

        let key = hex(of: colour)
        if key != lastLoggedHex {
            lastLoggedHex = key
            writeDebugLog(
                "[\(logTag)] field colour is now #\(key) — pw's field on every page now"
                    + " (a deep solid, fading to black down the page)"
            )
        }
    }

    /// 窗口高度（pw 的 `windowHeight()`，`SGRField.m:16-19`）：黑渐变按**窗口**锚定，不按页面。
    private static func windowHeight(fallback: CGFloat) -> CGFloat {
        if let height = frontWindow()?.bounds.height, height > 0 { return height }
        return fallback > 0 ? fallback : 874
    }

    /// **这一页的底色**：三页**同一个**（2026-10-18 第二轮，用户：「歌单页的封面会消失（如果歌单页的
    /// 模糊不和艺人页一样，换成和艺人一样的）」）—— 一律是 **pw 压暗过的那一版**（`fieldColourFor`）。
    ///
    /// ⚠️ 这一条**推翻了**上一轮"专辑 / 歌单页照 Melox（纯取色 + 模糊封面 + veil）"那条分岔：
    /// 用户看到的是**歌单页的封面不见了 + 白字压在浅底上看不清**（照片 127），而 **AM 自己的专辑/歌单页
    /// 就是"深底 + 封面卡片 + 白字"**（照片 123：底色是暗灰、标题/艺人/元数据全是白字）⇒ 统一到 pw 这套。
    private static func pageColour(for target: Target) -> UIColor? {
        guard let colour = target.color else { return nil }
        // ★★ 2026-10-18 第三轮：**艺人页压得轻、专辑/歌单页压得重**（见 `artistFieldLuminance` 那张表）。
        let ceiling = target.kind == .artist ? artistFieldLuminance : maxFieldLuminance
        return fieldColourFor(colour, ceiling: ceiling)
    }

    /// **艺人页的底色** = pw 的 `SGRFieldColorFor`（`SGRPalette.m:76-97`）：保住色相，
    /// **饱和度压到 0.55**、**线性亮度压到 0.07**。
    ///
    /// ★★ 2026-10-18（用户：「现在的模糊艺人底会有看不清字的情况，做成往下渐变变灰/黑的吧」）：
    /// 这一步就是"**白字读得清**"的全部保证 —— 不管封面是一片白还是一团花，底色都落到很深的一档
    /// （`#F2F7FB` 那张白猫 ⇒ 约 `#494B4C`；杰克逊那张 ⇒ 一块暗棕），再叠下面那条渐到黑。
    /// pw 那边是整套重设计的前提（它注释里逐字：*"the redesign is AMOLED throughout"*）。
    ///
    /// ⚠️ 亮度在**线性空间**里算（sRGB 先解 gamma）—— 直接在 sRGB 数值上乘会偏亮，
    ///    那正是"看着还是发灰、字还是发虚"的来源。两个换算函数各自只此一份。
    private static func fieldColourFor(_ colour: UIColor, ceiling: CGFloat) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        if !colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 0
            guard colour.getWhite(&white, alpha: &alpha) else {
                return UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
            }
            red = white
            green = white
            blue = white
        }
        let clamped = UIColor(
            red: min(1, max(0, red)),
            green: min(1, max(0, green)),
            blue: min(1, max(0, blue)),
            alpha: 1
        )
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        clamped.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let capped = UIColor(
            hue: hue,
            saturation: min(saturation, maxFieldSaturation),
            brightness: brightness,
            alpha: 1
        )
        capped.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        var linearRed = linearised(red)
        var linearGreen = linearised(green)
        var linearBlue = linearised(blue)
        let luminance = 0.2126 * linearRed + 0.7152 * linearGreen + 0.0722 * linearBlue
        if luminance > ceiling {
            let scale = ceiling / luminance
            linearRed *= scale
            linearGreen *= scale
            linearBlue *= scale
        }
        return UIColor(
            red: encoded(linearRed),
            green: encoded(linearGreen),
            blue: encoded(linearBlue),
            alpha: 1
        )
    }

    /// sRGB 编码值 → 线性（pw 的 `toLinear`，`SGRPalette.m:68-70`）。
    private static func linearised(_ component: CGFloat) -> CGFloat {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    /// 线性 → sRGB 编码值（pw 的 `toEncoded`，`SGRPalette.m:72-74`）。
    private static func encoded(_ component: CGFloat) -> CGFloat {
        component <= 0.0031308 ? component * 12.92 : 1.055 * pow(component, 1 / 2.4) - 0.055
    }

    /// Melox 的**第三层**：`取色@34% → 取色`，盖在模糊封面**之上**、页面内容**之下**。
    ///
    /// ⚠️ **2026-10-18 第二轮起已停用**：三页都不再铺模糊底（见 `blackFrom` 那段末尾的 ⚠️），
    ///    所以这一层没有东西可盖了 —— 函数留着没删，只是为了让这一版改动面小一点。
    ///
    /// ★★ 2026-10-18：这一层就是"往下滑颜色变沉"的**全部来源**（Melox `:441-452` 的
    /// `LinearGradient(colors: [palette.backgroundColor.opacity(0.34), palette.backgroundColor])`）。
    /// 它的下端是**不透明的取色** ⇒ 页面下半部分稳定落在"这个封面的颜色"上，
    /// 不像 pw 那样落到纯黑，也不像我们旧做法那样一路压到 45% 亮度。
    private static var veil: GradientView?
    private static var veilColourKey: String?

    private static func ensureVeil(above blurred: UIView, in container: UIView, colour: UIColor?) {
        guard let colour else { return }
        let view: GradientView
        if let veil, veil.superview === container {
            view = veil
        } else {
            removeVeil()
            let fresh = GradientView()
            fresh.isUserInteractionEnabled = false
            fresh.accessibilityIdentifier = "eevee-page-veil"
            fresh.gradient.startPoint = CGPoint(x: 0.5, y: 0)
            fresh.gradient.endPoint = CGPoint(x: 0.5, y: 1)
            fresh.gradient.locations = [NSNumber(value: 0), NSNumber(value: 1)]
            container.insertSubview(fresh, aboveSubview: blurred)
            veil = fresh
            view = fresh
            writeDebugLog(
                "[\(logTag)] veil over the blurred cover — Melox's third layer (colour 34% → colour);"
                    + " this is what makes the page settle into the artwork's colour going down"
            )
        }
        let key = hex(of: colour)
        if key != veilColourKey {
            veilColourKey = key
            view.gradient.colors = [
                colour.withAlphaComponent(0.34).cgColor,
                colour.cgColor,
            ]
        }
        let frame = CGRect(x: 0, y: 0, width: container.bounds.width, height: max(1, container.bounds.height))
        if !view.frame.equalTo(frame) { view.frame = frame }
    }

    private static func removeVeil() {
        veil?.removeFromSuperview()
        veil = nil
        veilColourKey = nil
    }

    /// 同一**色相**压暗（保住"就是这片颜色"的观感，而不是褪成中性灰 ✗）。
    private static func tinted(_ color: UIColor, atMost ceiling: CGFloat) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return UIColor(white: ceiling, alpha: 1)
        }
        return UIColor(
            hue: hue,
            saturation: min(1, saturation * 1.05),
            brightness: min(brightness, ceiling),
            alpha: 1
        )
    }

    /// **只清那些颜色恰好是 `#121212` 的视图**（pw 的教训：list 与每个 cell 都自己画这层）。
    ///
    /// ⚠️ **每一拍都调**：新 cell 是懒建的，清一次不够（见 `ensureField` 里的调用点）。
    /// 清过的按对象记下来，第二次走到它就不重复记；上限封死，不会无限长。
    private static func clearBaseSurfaces(in page: UIView) {
        guard clearedBackgrounds.count < maxCleared else { return }
        var seen = 0

        func walk(_ node: UIView, _ depth: Int) {
            guard depth <= clearDepth, seen < clearNodes, clearedBackgrounds.count < maxCleared else { return }
            seen += 1
            let identifier = ObjectIdentifier(node)
            if let color = node.backgroundColor, isBaseSurface(color), !clearedViews.contains(identifier) {
                clearedViews.insert(identifier)
                clearedBackgrounds.append((view: node, color: color))
                node.backgroundColor = .clear
            }
            // ★★ 2026-10-17（照片 121）：**画在 layer 上的底也要清**。列表与 cell 的底常常是直接写在
            //    `layer.backgroundColor` 上的（`eeveeClearBaseSurface` 里那条注释说过同一件事），
            //    只清 `view.backgroundColor` 会漏掉一整片 —— 而「ScrollFadeMask」把内容渐隐掉之后，
            //    露出来的正好就是它 ⇒ 用户看到的「显示更多」那条黑带。
            if let layerColor = node.layer.backgroundColor,
               isBaseSurface(UIColor(cgColor: layerColor)),
               !clearedLayerViews.contains(identifier) {
                clearedLayerViews.insert(identifier)
                clearedLayerBackgrounds.append((layer: node.layer, color: layerColor))
                node.layer.backgroundColor = nil
            }
            collectFadeMask(node, identifier: identifier)
            for sub in node.subviews { walk(sub, depth + 1) }
        }

        walk(page, 0)
    }

    /// 哪些类名是"section 底部那层渐变"。
    ///
    /// ★★ 2026-10-18 第二轮（用户：「艺人页 显示更多 还是黑的，有什么解决方法么」）：把照片 128 放大之后
    /// 看清楚了 —— **整片底（连页面底色）都被刷成纯黑**，不是"内容渐隐、露出后面那层没清掉的黑底"。
    /// ⇒ 一定有一层**画黑的**渐变盖在上面。`EntitySegments_ScrollGradientViewKit` 里正好两个类
    /// （`dump-9.1.88.txt:12488-12489`）：`ScrollFadeMask`（把内容渐隐的那张 mask）
    /// 与 **`ScrollGradientOverlay`（画渐变的那一层）** —— 后者就是黑带的来源，两个一起收。
    private static func isFadeClass(_ name: String) -> Bool {
        name.contains("ScrollFadeMask") || name.contains("ScrollGradientOverlay")
    }

    /// 收掉 Spotify 给"可滚动的一段"画的**渐隐遮罩 / 往黑渐变**。
    ///
    /// ★★ 2026-10-17（照片 121：「显示更多」那一带的颜色不对，把热门歌曲十首歌展开之后就好了）：
    /// 那个渐隐的真类是 `EntitySegments_ScrollGradientViewKit.ScrollFadeMask`（`dump-9.1.88.txt:12488`）。
    /// 两种形态都要处理：它可能是**视图**，也可能是某个 layer 的 **mask**。
    private static func collectFadeMask(_ node: UIView, identifier: ObjectIdentifier) {
        if isFadeClass(NSStringFromClass(type(of: node))), !fadeMaskViews.contains(identifier) {
            fadeMaskViews.insert(identifier)
            hiddenFadeViews.append((view: node, layerHidden: node.layer.isHidden))
            node.layer.isHidden = true
        }
        if let mask = node.layer.mask,
           isFadeClass(NSStringFromClass(type(of: mask))),
           !fadeMaskLayers.contains(identifier) {
            fadeMaskLayers.insert(identifier)
            removedFadeMasks.append((layer: node.layer, mask: mask))
            node.layer.mask = nil
        }
    }

    /// 把已经收掉的再压一遍 —— Spotify 会在它自己那一拍把渐变画回来（`layer.isHidden` / `layer.mask`
    /// 都可能被写回）。
    private static func reapplyFadeMasks() {
        for entry in hiddenFadeViews where !entry.view.layer.isHidden { entry.view.layer.isHidden = true }
        for entry in removedFadeMasks where entry.layer.mask !== entry.mask { entry.layer.mask = nil }
    }

    /// **专治"显示更多"那条黑带**：section 里那层渐变藏得很深，例行扫描（12 层 / 1500 节点）够不到
    /// —— 日志 95/97 里艺人页那一拍只 `cleared 2 base-surface`（歌单页 25）就是证据。
    /// ⇒ 每页**前两拍**各深搜一次，之后**每 10 拍（≈6s）补一次**（section 是懒建的：往下滚才建出来，
    /// 只搜前两拍会漏掉晚到的那个）；其余每一拍只把认下的再压一遍（O(命中数)，几乎为零）。
    ///
    /// ⚠️ 深搜是**有上限的**（24 层 / 12000 节点）：一次约几毫秒，6 秒一次。
    private static let fadeHuntDepth = 24
    private static let fadeHuntNodes = 12000
    private static var fadeHuntTick = 0
    private static var fadeHuntPasses = 0
    private static var didReportFadeHunt = false

    private static func huntScrollGradients(in page: UIView) {
        fadeHuntTick += 1
        guard fadeHuntPasses < 2 || fadeHuntTick % 10 == 0 else {
            reapplyFadeMasks()
            return
        }
        fadeHuntPasses += 1
        var seen = 0
        func walk(_ node: UIView, _ depth: Int) {
            guard depth <= fadeHuntDepth, seen < fadeHuntNodes else { return }
            seen += 1
            collectFadeMask(node, identifier: ObjectIdentifier(node))
            for sub in node.subviews { walk(sub, depth + 1) }
        }
        walk(page, 0)
        guard !didReportFadeHunt else { return }
        didReportFadeHunt = true
        var found = hiddenFadeViews.map { NSStringFromClass(type(of: $0.view)) }
        found.append(contentsOf: removedFadeMasks.map { "mask:" + NSStringFromClass(type(of: $0.mask)) })
        // ⚠️ 插值里不写引号（`swift_member_check.py` 的去字符串扫描器会提前收尾）⇒ 先拼好。
        let detail = found.isEmpty
            ? "none found (nothing of that kind is drawn on this page)"
            : found.joined(separator: ", ")
        writeDebugLog(
            "[\(logTag)] scroll-gradient hunt: \(seen) node(s), \(found.count) taken — \(detail)"
        )
    }

    /// 判"这是不是 Spotify 画的那层 base surface"。
    ///
    /// ⚠️ **照片 95-97 的教训**：原来卡在 `#121212` ±0.02 ⇒ **同一列表里有的 cell 被清、有的没被清**,
    /// 于是出现"一横条一横条"的色差 —— 用户原话「**有几条线，看起来很怪**」✗。
    /// 改成"**很暗的中性色都算**"（三通道互差 ≤ 0.03、最亮通道 ≤ 0.12）⇒ 一致性回来了。
    /// （现在字段整页带色，多清一点不会有副作用 ✓。）
    private static func isBaseSurface(_ color: UIColor) -> Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha > 0.9 else {
            return false
        }
        let brightest = max(red, max(green, blue))
        let darkest = min(red, min(green, blue))
        // ★★ 2026-10-13（用户看真机：「你已点赞、艺人之选什么的**都还是黑的**」）：**阈值 0.12 → 0.20**。
        //
        //   0.12 只够 `#121212`（列表底，0.071）那一档。而 Spotify 的**卡片**用的是"抬起一层"的
        //   深灰 `#282828`（**0.157**）—— 我们自己的真机树里逐字写着（艺人页）：
        //
        //   ```
        //   10.CreatorBiographyCardLayout@0,0,374,416,bg=#282828      ← 艺人简介卡
        //   11.OBJC_ONLY_Label id=Components.UI.CreatorBiographyCard.HeaderLabel
        //   14.ContainerView   id=Components.UI.CreatorBiographyCard.BiographyLabel
        //   ```
        //
        //   0.157 > 0.12 ⇒ 那些卡片**从来没被清过**；列表底清了、卡片没清 ⇒ 页面底色一变浅，
        //   卡片就变成一块块深灰（用户照片里"你已点赞"、"艺人之选"、"关于"全是这个问题）。
        //   0.20 正好收进 `#282828`（0.157）与 `#333333`（0.2），同时仍然要求"近灰"（互差 ≤ 0.03）。
        return brightest <= 0.20 && (brightest - darkest) <= 0.03
    }

    /// ★ 2026-10-13（照片 110：专辑页往下滑**整片黑**）：`clearBaseSurfaces` 只清"**恰好等于** `#121212`"
    /// 而且只走到 `depth ≤ 7` —— 而盖住 field 的那一层是**页面的直接子视图**（列表的祖先容器，
    /// 也就是 pw 树里那个 `CreativeWorkPlatform.Tab`）：它比 7 层浅，但颜色不是 `#121212`，
    /// 所以日志 89 那行 `cleared 0 base-surface background(s)` 一个都没命中，它就一直不透明地压着 field。
    ///
    /// 这里对**页面的每个直接子视图**单独来一遍，判据放宽到"近黑近灰"，而且**不递归**
    /// （只清容器那一层，不碰内容，免得把 cell 里该有的深色也清掉）。
    private static func clearPageContainers(in page: UIView) {
        for sub in page.subviews where sub !== field {
            guard let colour = sub.backgroundColor else { continue }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha > 0.5 else { continue }
            let brightest = max(red, max(green, blue))
            let darkest = min(red, min(green, blue))
            guard brightest <= 0.25, (brightest - darkest) <= 0.04 else { continue }
            if !didReportContainerClear {
                didReportContainerClear = true
                writeDebugLog(
                    "[\(logTag)] cleared a page container: \(type(of: sub)) \(frameText(sub.frame))"
                        + " had \(hex(of: colour)) — that was the layer covering the field"
                )
            }
            sub.backgroundColor = .clear
        }
    }

    // MARK: - ② 封面溶进背景

    /// 用户 2026-10-13 指着 pw 的 playlist 截图：「**pw 的做法是把封面溶进背景**」——
    /// **封面那一层**。★ 2026-10-18 第二轮之后它只剩两件事：
    ///   · **艺人页**：让 Spotify 那张小封面让位，铺我们自己的满幅照片（`ensureSharpHero`）；
    ///   · **专辑 / 歌单页**：**保留 Spotify 自己那张封面卡片**（只把圆角改成 AM 的连续圆角）。
    ///
    /// ⚠️ 这个函数原来还画"两张图"（① 整页的模糊底 ② 满幅清晰封面）—— **2026-10-18 起"模糊底 + veil"
    /// 那一套在三个页面上都停用了**（用户点名要 pw 的"深色 → 黑"，见 `paintField` / `blackFrom`；
    /// 起因是浅底的模糊底让白字看不清，照片 127）。函数体里那段模糊底已经删掉，历史留在这一行。
    private static func ensureHero(on target: Target, sharpCover: Bool, colour: UIColor?) {
        guard let cover = target.cover else { return }

        if sharpCover {
            // ★ 2026-10-13：**图还没到也要先把 Spotify 那张小封面藏掉**
            //   （`layoutPass` 每帧补的那一次能盖住大部分，这里是第二道保险）——
            //   它让位给我们那张满幅照片。
            concealNativeCover(cover)
            guard let source = coverImage(in: cover) else { return }
            ensureSharpHero(cover: cover, source: source, page: target.page, colour: colour)
            return
        }

        // ★★ 2026-10-18 第二轮（用户：「歌单页的封面会消失（如果歌单页的模糊不和艺人页一样，
        //    换成和艺人一样的）」）—— **专辑 / 歌单页保留 Spotify 自己那张封面卡片，
        //    并且不再铺模糊底**：
        //    · “封面会消失”的根因就是原来这里无条件跑的 `concealNativeCover(cover)`：
        //      专辑 / 歌单页也照藏 ⇒ 卡片整张不见（照片 127：歌单页只剩一层模糊底 + 白字）。
        //      它现在只服务艺人页（上面那一支）。
        //    · 模糊底 + veil 那一套（Melox）在这两页**停用** —— 它们的底现在也是
        //      pw 那条“深色 → 黑”（`paintField`），“白字压在浅底上看不清”一并解决。
        revealNativeCover()
        roundCoverCard(cover)
    }

    /// 满幅那张清晰封面。
    ///
    /// ★ 2026-10-13 **第二版**（用户真机反馈：「刚进去没封面，往下滑才有，而且封面一直在底部」）——
    /// **照 pw 的定位方式重写**（`PlaylistHeader.x` 的 `applyBackground` + `applyHero`，v0.21.1 / GPL-3.0）。
    ///
    /// 我第一版按"封面在**页面根**坐标里的 y"来摆，三条都错，而且都源自同一个错：
    ///   · 进场时封面的帧还没定、图也还没来 ⇒ 什么都不画（"刚进去没封面"）；
    ///   · 位置不跟着 Spotify 自己那块裁剪面走 ⇒ 滑一下才读到一个帧，而且停在错的地方（"一直在底部"）。
    ///
    /// pw 的做法是**把图塞进 Spotify 自己画那层颜色 wash 的 plane 里**，坐标用 **plane 自己的 (0,0)**，
    /// 高度只取"到过的最深处"（单调增），移动**交给 Spotify 的 plane**。它的原话：
    ///
    /// > the hero belongs in the plane Spotify's own colour wash is drawn on … So the picture needs
    /// > no help to move — Core Animation carries it with the plane, in the same motion Spotify gives
    /// > the cover itself. … the hero is measured once … and its [movement] is the plane's movement,
    /// > which is Spotify's to make and ours to sit still inside.
    ///
    /// ⚠️ `_backgroundViewContainer` 里那些 wash 的 `GradientView` 必须**一起藏掉**：pw 的 issue #53
    /// 就是"wash 的 alpha 被抬高之后，不透明的一层把整张图整个盖住"。
    private static func ensureSharpHero(cover: UIView, source: UIImage, page: UIView, colour: UIColor?) {
        // ★ 2026-10-13（照片 104：专辑页只有一片颜色、没有封面）：**宿主分两种** ——
        //   · 歌单页：Spotify 画页面颜色 wash 的那块 plane（pw 的 `PlaylistHeader.x` 做法）；
        //   · 专辑页：**头自己**（pw 的 `AlbumHeader.x` 逐字：`[header insertSubview:hero atIndex:0]`）。
        //
        //   专辑页**没有** `_backgroundViewContainer`（那是歌单页的结构；它的 wash 是页面里那个
        //   `LegacyUI…HeaderView` + `GradientView`，见 pw 的 `AlbumField.x`）⇒ 原来这里
        //   `guard let plane … else { return }` 一句直接返回 ⇒ **整条 sharpHero 静默不装**：
        //   日志 87 里就只剩 `hero …`（模糊底）而**没有** `sharp hero …` 那一行，
        //   用户看到的正是"只有背景色、没有封面"。
        let plane = washPlane(for: cover)
        let albumHeader = firstView(
            in: page,
            withAnyIdentifier: ["CreativeWorkPlatform.Components.UI.CreativeWorkHeader"]
        )

        // ★ 2026-10-13（艺人页）：**第三条宿主**。pw 的 `ArtistHeader.x` 把 hero 挂在 `TemplateKit` 的
        //    `HeaderContainer` 上（它的 `applyHero(UIView *container, …)`，容器由 `containerOf(header)`
        //    沿祖先链找"类名含 HeaderContainer"的那一个）。歌单页的 `_backgroundViewContainer`
        //    与专辑页的 `CreativeWorkHeader` 在艺人页**都不存在**。
        let artistContainer = ancestor(of: cover, classNameContains: "HeaderContainer")

        let host: UIView
        let layout: UIView
        /// 高度按**宿主**算、且**不要求封面已经量好**（专辑页与艺人页：封面可能这一拍还没布局）。
        let fillsHost: Bool
        /// 顶部留出状态栏那一条（= 把图**往下挪**，上面露出取色底）。★ 2026-10-06：**恒 false** ——
        /// 用户看真机后确认"缓冲没和封面接上、而且太大"，而 AM 与歌单页都是铺到顶的。
        /// ★ 2026-10-17（用户再问"怎么搞好"）：他二选一里选了**方案 A（照片照旧铺到顶 + 顶上叠一层纱）**
        /// ⇒ 这一条**仍然是 false**，顶上那件事由 `ensureScrim` 做。变量留着只作记录。
        let wantsTopInset: Bool

        if let plane, plane.bounds.width > 1 {
            host = plane
            layout = headerLayout(of: cover) ?? cover.superview ?? page
            fillsHost = false
            wantsTopInset = false
            concealWash(on: plane)
        } else if let albumHeader, albumHeader.bounds.height > 40 {
            host = albumHeader
            layout = albumHeader
            fillsHost = true
            wantsTopInset = false
            concealAlbumWash(in: page)
        } else if let artistContainer, artistContainer.bounds.height > 40 {
            host = artistContainer
            layout = artistContainer
            fillsHost = true
            wantsTopInset = false
        } else {
            return
        }

        let coverFrame = cover.convert(cover.bounds, to: layout)
        // 歌单页那条路要封面已经量好（帧都没量出来就别画）；另外两条铺满整个宿主，不依赖封面的帧。
        if !fillsHost {
            guard coverFrame.width > 40, coverFrame.height > 40 else { return }
        }

        concealNativeCover(cover)

        // 高度 = **到过的最深处**，下限 `minHeroHeight`，**只增不减** ——
        // pw：页头还在加载时 block 的位置偏高，取"当前值"会让图够不到标题、中间留一条裸色带。
        //
        // ★★ 2026-10-18 第三轮（用户：「**这有点难看了吧**」，照片 130）：**铺满宿主那条改成"按图自己
        // 的宽高比"** —— 原来一律拉到 520pt（`host.bounds.height`），而 Spotify 给艺人页的照片是**方图**
        // ⇒ `scaleAspectFill` 为了填满 520pt 会把它**放大 1.26 倍、再从两侧各裁掉 53pt**（照片 130 里的
        // 猫明显比 AM 参考 118 里大一圈，而且下半身被切了）。现在高度取 `宽 × 图的高宽比`
        // （方图 = 414pt，正好与照片自己的下缘对齐）⇒ `scaleAspectFill` 既不放大也不裁 ✓。
        let imageAspect = source.size.width > 1 ? max(0.4, source.size.height / source.size.width) : 1
        let natural = host.bounds.width * imageAspect
        let reach = fillsHost
            ? max(minHeroHeight, min(host.bounds.height, natural))
            : max(minHeroHeight, coverFrame.maxY + EntityPageHeaderMetrics.titleRise)
        let previous = (objc_getAssociatedObject(host, &heroHeightKey) as? NSNumber)?.doubleValue ?? 0
        let height = max(previous, reach)
        if height != previous {
            objc_setAssociatedObject(host, &heroHeightKey, NSNumber(value: height), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        // 缓冲（只有专辑页要，见 `wantsTopInset`）：把图从状态栏下面开始画。
        // ★ 2026-10-17：这条**永远是死路** —— 用户二选一里选了方案 A（图照旧铺到顶 + 顶上加纱），
        //    顶上那件事现在由 `ensureScrim` 做。算式留着，将来真要翻回"把图往下挪"时不用重推。
        let topInset = wantsTopInset ? page.safeAreaInsets.top : 0
        let frame = CGRect(
            x: 0,
            y: topInset,
            width: host.bounds.width,
            height: max(minHeroHeight, round(height) - topInset)
        )

        let view: UIImageView
        if let sharpHero, sharpHero.superview === host {
            view = sharpHero
        } else {
            sharpHero?.removeFromSuperview()
            let fresh = UIImageView()
            fresh.contentMode = .scaleAspectFill
            fresh.clipsToBounds = true
            fresh.isUserInteractionEnabled = false
            fresh.accessibilityIdentifier = "eevee-page-hero-sharp"
            host.insertSubview(fresh, at: 0)
            sharpHero = fresh
            view = fresh
            writeDebugLog(
                "[\(logTag)] sharp hero in \(type(of: host)) \(frameText(host.bounds))"
                    + " at \(frameText(frame))"
                    + " — the cover \(frameText(coverFrame)) measured in \(type(of: layout));"
                    + " the host carries it, so it moves with Spotify's own layout"
            )
        }

        if !view.frame.equalTo(frame) { view.frame = frame }
        if view.image !== source { view.image = source }

        // ★★ 2026-10-18：**收口绑名字，不绑页头高度** —— 见 `meltGap` / `meltSpanRatio` 那段。
        //    认得出我们那块页头（名字的 y 拿得到）就用它算；认不出（还没建 / 正在收起、整块已渐隐）
        //    就退回老行为（54% 起化、到底化完），**绝不因为算不出来把渐变整条撤掉**。
        if let textTop = ourHeaderTextTop(in: host), textTop > host.bounds.height * 0.2 {
            let span = max(minMeltSpan, host.bounds.height * meltSpanRatio)
            applyDissolveMask(to: view, solidUntil: textTop - span, goneAt: textTop - meltGap)
        } else {
            applyDissolveMask(to: view, opaqueFraction: 0.54)
        }

        // ★ 2026-10-17：照片**照旧铺到顶**，顶上那条由**页面取色**去化（不是黑纱）—— 见 `ensureScrim`。
        ensureScrim(in: host, above: view, page: page, colour: colour)
    }

    /// ★★ 2026-10-17（用户，第二轮 —— 看了 AM 的艺人页截图 118/119 之后）：
    /// 「am 是这么处理的：**用渐变来处理**，而往下滚就**一直保持渐变之后的颜色**。我们不是这个设计吧？
    /// 能不能做成这样。而且渐变之后的颜色**会根据艺人变化**的。比如 nanatsukaze 的就是淡灰色，
    /// 杰克逊的就是棕色。」
    ///
    /// ## 先厘清：这三句里有两句我们**早就是**了
    ///
    /// 真机日志逐字（`eeveespotify_debug_shared 93.log`）：
    ///
    /// ```
    /// [PageField] field colour is now #F2F7FB — top F2F7FB, 57% #D7DCE0, bottom #A1A5A8   ← Nanatsukaze 艺人页
    /// [PageField] field on TemplateView 0,0,414,896 ← cover colour #F2F7FB               ← field 是页面根的子视图
    /// [PageField] sharp hero in HeaderContainer 0,0,414,520 at 0,0,414,520
    /// ```
    ///
    /// ⇒ ① **渐变**：`paintField` 就是一条整页的取色渐变，照片再"化"进它（`applyDissolveMask`）；
    ///    ② **往下滚保持**：field 挂在**页面根**上（不在 scroll view 里）⇒ 内容滚、颜色不动；
    ///    ③ **随艺人变**：颜色是每页从封面/照片当场算的（`averageColor`），Nanatsukaze 的底正是
    ///      `#A1A5A8`（淡灰 ✓），另一张是 `#B08FA8`（粉紫 ✓）。这三条**不用改**。
    ///
    /// ## 真正缺的两件（这一轮补的就是它们）
    ///
    /// **① 顶上那一条不是黑的。** 上一版我按"方案 A"盖了一条 **黑 → 透明** 的纱（用户当时选的就是
    /// 它）—— 但 AM 不是这么干的：AM 顶上那一条**就是页面自己的颜色**，照片从这片颜色里"长"出来。
    /// 改成取色之后，同一条纱自动变成"这个艺人的颜色"，与下面 field 的顶色**一模一样**（
    /// `paintField` 的 0 号色就是它）⇒ 纱和 field 之间不可能有接缝。
    ///
    /// **② 状态栏明暗要跟着翻。** AM 的 118（Nanatsukaze）状态栏是**黑字**、119（Michael Jackson）
    /// 是**白字** —— 它就是靠这个解决"照片铺到顶"的，而不是靠留白。我们这边原来一处都没碰过状态栏
    /// ⇒ 亮封面上白字直接消失（照片 115 就是这个现场）。现在 `EntityPageStatusBar` 接手。
    ///
    /// ## 形状
    ///
    /// * 高 = `安全区顶 + 22`（与安全区同高那一段**不透明**，正好盖住灵动岛/状态栏那一条；
    ///   最后一截化开，照片从色里长出来 ⇒ 既是"缓冲区"也是"渐变"）。
    /// * 颜色 = 这个页面的取色（`colour`），取不到就不画（别用黑色顶替 —— 那正是上一版的问题）。
    /// * 插在 **`hero` 正上方、宿主的其余子视图之下**（`insertSubview(_:aboveSubview:)`）⇒
    ///   Spotify 自己的返回键、我们 pinned 的 ⋯、页头那些文字都在它**上面**，谁都不会被压暗。
    /// * 锚在宿主 y=0（跟着照片滚）。滚下去之后那一条由 Spotify 自己收起来的导航栏接手。
    ///
    /// ⚠️ 与 `wantsTopInset`（真正把图往下挪）仍**不是一回事**：那条 2026-10-06 被用户否过
    /// （"缓冲没和封面接上、而且太大"），现在仍然恒 `false`。
    private static func ensureScrim(in host: UIView, above hero: UIView, page: UIView, colour: UIColor?) {
        // 取不到颜色就**什么都不画**：宁可没有这一条，也不能拿一个错的颜色顶上去
        // （黑纱就是这么来的，AM 那边根本没有那一层）。
        guard let colour else { return }

        let view: GradientView
        if let scrim, scrim.superview === host {
            view = scrim
        } else {
            removeScrim()
            let fresh = GradientView()
            fresh.isUserInteractionEnabled = false
            fresh.accessibilityIdentifier = "eevee-page-scrim"
            let gradient = fresh.gradient
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            host.insertSubview(fresh, aboveSubview: hero)
            scrim = fresh
            view = fresh
            writeDebugLog(
                "[\(logTag)] top band in \(type(of: host)) — the cover still runs full bleed to the top;"
                    + " the page's own colour holds the top \(Int(scrimSolidFraction * 100))% of it and"
                    + " dissolves into the picture below (AM's look, and the status bar flips with it)"
            )
        }

        // 颜色只在"换了一张封面"时才重写（每 0.6s 走一趟，不能每拍都写 layer）。
        let key = hex(of: colour)
        if key != scrimColourKey {
            scrimColourKey = key
            let gradient = view.gradient
            gradient.colors = [
                colour.withAlphaComponent(1).cgColor,
                colour.withAlphaComponent(1).cgColor,
                colour.withAlphaComponent(0).cgColor,
            ]
            gradient.locations = [
                NSNumber(value: 0),
                NSNumber(value: Double(scrimSolidFraction)),
                NSNumber(value: 1),
            ]
        }

        let safeTop = resolvedSafeAreaTop(in: host, page: page)
        let height = max(12, safeTop + scrimExtraFade)
        let frame = CGRect(x: 0, y: 0, width: host.bounds.width, height: height)
        if !view.frame.equalTo(frame) { view.frame = frame }
    }

    /// 顶上那一条安全区 —— **窗口那一份才是准的**（嵌在别人里的视图常常读到 0，
    /// 与 `EntityPageHeader.pinMoreButton` / `LyricsWordByWord.resolvedSafeAreaInsets` 同一条纪律）。
    private static func resolvedSafeAreaTop(in host: UIView, page: UIView) -> CGFloat {
        if let top = host.window?.safeAreaInsets.top, top > 0 { return top }
        if host.safeAreaInsets.top > 0 { return host.safeAreaInsets.top }
        return page.safeAreaInsets.top
    }

    private static func removeScrim() {
        scrim?.removeFromSuperview()
        scrim = nil
        scrimColourKey = nil
    }

    /// 专辑页的 wash：页面里那个 `LegacyUI…HeaderView`（头的高度），里面是 Spotify 的 `GradientView`。
    ///
    /// pw 的 `AlbumHeader.x` `applyWash` 逐字：按**类名**找 `HeaderView`（**排除 `NavigationBar`**），
    /// 藏掉它下面的 `GradientView`。歌单页那块 `_backgroundViewContainer` 在专辑页上不存在 ——
    /// 两条路各找各的。
    ///
    /// ⚠️ 不藏的话它照旧画在我们的图**之上**（pw 的 issue #53 就是"不透明的一层把整张图整个盖住"）。
    /// 这里直接复用 `concealWash(on:)`：它拿参数的 **superview** 当容器递归 —— 传 GradientView 进去，
    /// 容器就是那个 HeaderView，正好是它要清的那一块。
    private static func concealAlbumWash(in page: UIView) {
        for sub in page.subviews {
            let name = NSStringFromClass(type(of: sub))
            guard name.contains("HeaderView"), !name.contains("NavigationBar") else { continue }
            for inner in sub.subviews where NSStringFromClass(type(of: inner)).contains("GradientView") {
                concealWash(on: inner)
                return
            }
        }
    }

    /// pw 的 `applyBackground` 逐字：沿**封面的祖先链**找 id = `_backgroundViewContainer` 的容器，
    /// 那块画页面颜色 wash 的 plane 就是**它的第一个子视图**。
    private static func washPlane(for cover: UIView) -> UIView? {
        var node: UIView? = cover
        var guardCount = 0
        while let current = node, guardCount < 12 {
            guardCount += 1
            for sub in current.subviews where sub.accessibilityIdentifier == "_backgroundViewContainer" {
                return sub.subviews.first
            }
            node = current.superview
        }
        return nil
    }

    /// 包着封面的那个 `HeaderContentLayout`（用来把封面的帧换算到"页头自己的坐标系"里）。
    private static func headerLayout(of cover: UIView) -> UIView? {
        var node: UIView? = cover
        while let current = node {
            if NSStringFromClass(type(of: current)).contains("HeaderContentLayout") { return current }
            node = current.superview
        }
        return nil
    }

    /// 沿祖先链找**类名里含** `needle` 的那个视图。
    ///
    /// pw 的 `containerOf` / `SGRPlaylistPageOf` 都是这个形状：艺人页的页头容器（`HeaderContainer`）
    /// 与别的页面那些"认 id"的容器不同，**它身上没有 accessibility id**，只有类名可用。
    private static func ancestor(of view: UIView, classNameContains needle: String) -> UIView? {
        var node: UIView? = view.superview
        var level = 0
        while let current = node, level < 16 {
            level += 1
            if NSStringFromClass(type(of: current)).contains(needle) { return current }
            node = current.superview
        }
        return nil
    }

    /// 把 wash 的 `GradientView` 藏掉。
    ///
    /// ★ 2026-10-13 **第二版**（用户照片 101：整片空泥棕、清晰封面完全看不见）：第一版只看了
    /// **直接子视图**（`container.subviews`），而 Spotify 那层洗色在更深的地方 ⇒ 它照旧画在我们的图
    /// 之上，把整张封面盖掉。pw 的 `applyBackground` 用的是 **`SGForEachView(container, …)`（递归）** ——
    /// 这里照它改成递归，并且**跳过我们自己的 hero 及其子树**（pw 同样跳：
    /// `if (hero && (v == hero || [v isDescendantOfView:hero])) return;`）——
    /// ★ 2026-10-17：**顶上那条纱（`scrim`）也一起跳**，理由见下面那一行。
    ///
    /// pw 在同一段里还会把"底色漆"从容器里每个视图上擦掉（issue #53：wash 的 alpha 被抬高后
    /// 不透明的一层会盖住图），这里一并做，并且**把原值记下来**（我们有开关，关掉要还原）。
    private static func concealWash(on plane: UIView) {
        guard let container = plane.superview else { return }

        var queue: [UIView] = [container]
        var visited = 0
        while !queue.isEmpty, visited < 200 {
            let view = queue.removeFirst()
            visited += 1
            queue.append(contentsOf: view.subviews)

            if let hero = sharpHero, view === hero || view.isDescendant(of: hero) { continue }
            // ★ 2026-10-17：**顶上那条纱也是 `GradientView`** —— 不跳过的话，这一趟会把它当成
            //    Spotify 的 wash 藏掉（歌单页那条路每拍都走这里 ⇒ 纱永远不出现）。
            //    （专辑/艺人页那两条路不用管：它们的"藏"按 `eevee-` 前缀认自己人，见 `isOurs`。）
            if let scrim, view === scrim { continue }
            if view === plane { continue }

            if NSStringFromClass(type(of: view)).contains("GradientView") {
                recordWash(view)
                continue
            }

            // 底色漆（Spotify 的 base surface）：擦成透明，原色记着。
            if let colour = view.backgroundColor, isBaseSurface(colour) {
                clearedBackgrounds.append((view: view, color: colour))
                view.backgroundColor = .clear
            }
        }
    }

    /// 记下一个被我们藏掉的 wash 视图（**只记我们改的那几样**，见 `revealWash`）。
    private static func recordWash(_ view: UIView) {
        guard !concealedWash.contains(where: { $0.view === view }) else { return }
        concealedWash.append(
            (view: view,
             layerHidden: view.layer.isHidden,
             hadMask: view.layer.mask != nil,
             interactive: view.isUserInteractionEnabled,
             accessibilityHidden: view.accessibilityElementsHidden)
        )
        eeveeConceal(view)
    }

    /// 原样撤回（开关关掉 / 离开页面时）。
    private static func revealWash() {
        for record in concealedWash {
            record.view.layer.isHidden = record.layerHidden
            if !record.hadMask { record.view.layer.mask = nil }
            record.view.isUserInteractionEnabled = record.interactive
            record.view.accessibilityElementsHidden = record.accessibilityHidden
        }
        concealedWash.removeAll()
    }

    // ⚠️ 「底面色」的判据**只留一份**：`isBaseSurface(_:)`（参数是 `UIColor`，在 `clearBaseSurfaces`
    // 那一节里）。我第一版在这里又写了一份一模一样的 —— Swift 只看签名（`isBaseSurface(_:)`），
    // 参数名一个 color 一个 colour 也算重复声明，编译器直接报 `invalid redeclaration`。


    /// 向下化开：`solidUntil` 之上**完全不透明**，`goneAt` 之下**完全透明**，中间线性。
    ///
    /// ★★ 2026-10-18：从"只抽一个比例"改成**两个绝对 y** —— 艺人页的收口要落在**名字上沿**
    /// （见 `meltGap` / `meltSpanRatio`），那是按内容算出来的位置，不是一个固定比例。
    /// 比例那条路（模糊底）仍然走下面那个薄包装 ⇒ 行为与改之前**逐字一致**。
    private static func applyDissolveMask(to view: UIView, solidUntil: CGFloat, goneAt: CGFloat) {
        let height = max(1, view.bounds.height)
        let solid = max(0, min(1, solidUntil / height))
        let gone = max(solid, min(1, goneAt / height))

        let mask: CAGradientLayer
        if let existing = view.layer.mask as? CAGradientLayer {
            mask = existing
        } else {
            let layer = CAGradientLayer()
            layer.startPoint = CGPoint(x: 0.5, y: 0)
            layer.endPoint = CGPoint(x: 0.5, y: 1)
            layer.colors = [
                UIColor.white.cgColor,
                UIColor.white.cgColor,
                UIColor.clear.cgColor,
            ]
            view.layer.mask = layer
            mask = layer
        }

        // ⚠️ 复用的那个 layer 上写的是**上一拍的比例** ⇒ 位置**每次都要重写**（原来只在新建那一支里写过，
        //    所以换一个更矮/更高的收口时它不会跟着动）。写的时候关掉隐式动画，免得收口自己动。
        let wanted = [0, Double(solid), Double(gone)]
        let current = mask.locations?.map { $0.doubleValue } ?? []
        if current != wanted {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.locations = [
                NSNumber(value: 0),
                NSNumber(value: solid),
                NSNumber(value: gone),
            ]
            CATransaction.commit()
        }
        if !mask.frame.equalTo(view.bounds) { mask.frame = view.bounds }
    }

    /// 按比例那条路（**模糊底**用）：上 `opaqueFraction` 不透明 → 底全透明。
    private static func applyDissolveMask(to view: UIView, opaqueFraction: CGFloat) {
        let height = max(1, view.bounds.height)
        applyDissolveMask(to: view, solidUntil: height * opaqueFraction, goneAt: height)
    }

    /// 我们自己那块页头（`EntityPageHeaderView`）里**名字的上沿**，换算到 `host` 的坐标里；认不出就是 nil。
    ///
    /// ★★ 2026-10-18：`ensureSharpHero` 用它决定渐变收在哪 —— **名字与那三颗都是我们自己画的**
    /// ⇒ 这个位置是我们说了算的。AM 靠"把那一行做得更靠下"避开渐变，我们靠这一行避开
    /// （页头多高、那一行摆在哪都不影响）。
    ///
    /// 两道闸门：**整块已经渐隐（收起中）时不算** —— 那时候它本来就让位了，
    /// 用它的 y 会把收口推到屏幕上方；**y ≤ 0 不算** —— 那是"还没布局"的现场。
    private static func ourHeaderTextTop(in host: UIView) -> CGFloat? {
        var queue: [UIView] = [host]
        var visited = 0
        while !queue.isEmpty, visited < 200 {
            let view = queue.removeFirst()
            visited += 1
            if let block = view as? EntityPageHeaderView,
               block.window != nil, !block.isHidden, block.alpha > 0.99, block.textTop > 0 {
                return block.convert(CGPoint(x: 0, y: block.textTop), to: host).y
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// 让 Spotify 自己那张封面**让位**：**改层不改属性**（Spotify 会用 `setHidden:NO` 把视图写回来）
    /// + 空 mask 双保险（Spotify 不碰 mask）。原值全记在 `concealedNativeCover` 里，关开关原样撤回。
    private static func concealNativeCover(_ cover: UIView) {
        // ★ 2026-10-13：这一张**已经记过**时每拍补一次 —— Spotify 会在按下 Play 之类的时候用
        //   `setHidden:NO` 把它写回来（pw 的 `conceal()` 就是每帧无条件补），原来这里直接 return，
        //   于是"写回来之后就再也不藏了"。但**不再覆盖原值记录**，否则关开关还原时会把我们自己
        //   写进去的 hidden 当成"Spotify 的原值"。
        // ⚠️★ 2026-10-13（艺人页）：**在 `OverflowStackView` 里只能加空 mask、绝不能碰 hidden**。
        //    pw 在艺人页踩过这个坑，它的注释逐字：
        //    > `ios-creator-impl.context_menu_in_navigation_bar_enabled_artist` moves more out of the
        //    > header's row, and with it gone Spotify's OverflowStackView force-unwraps the tallest view
        //    > of a line that has none and traps as the page opens
        //    > (device crash 2026-09-18 19:09, SIGTRAP in -[OverflowStackView updateConstraints]).
        //    空 mask 本身就能让视图什么都不画，所以少一个 hidden 只是少一道保险，不会漏。
        let canHide = ancestor(of: cover, classNameContains: "OverflowStackView") == nil
        if concealedNativeCover?.view === cover {
            if canHide, !cover.layer.isHidden { cover.layer.isHidden = true }
            if cover.layer.mask == nil { cover.layer.mask = CALayer() }
            if cover.isUserInteractionEnabled { cover.isUserInteractionEnabled = false }
            if !cover.accessibilityElementsHidden { cover.accessibilityElementsHidden = true }
            return
        }
        revealNativeCover()

        concealedNativeCover = NativeCoverRecord(
            view: cover,
            layerHidden: cover.layer.isHidden,
            hadMask: cover.layer.mask != nil,
            interactive: cover.isUserInteractionEnabled,
            accessibilityHidden: cover.accessibilityElementsHidden
        )
        if canHide { cover.layer.isHidden = true }
        if cover.layer.mask == nil { cover.layer.mask = CALayer() }
        cover.isUserInteractionEnabled = false
        cover.accessibilityElementsHidden = true
    }

    /// 只撤回**我们**改的那几样（Spotify 自己的 hidden 不碰）。
    private static func revealNativeCover() {
        guard let record = concealedNativeCover else { return }
        record.view.layer.isHidden = record.layerHidden
        if !record.hadMask { record.view.layer.mask = nil }
        record.view.isUserInteractionEnabled = record.interactive
        record.view.accessibilityElementsHidden = record.accessibilityHidden
        concealedNativeCover = nil
    }

    private static func removeHero() {
        removeScrim()
        removeVeil()
        revealNativeCover()
        revealWash()
        // 单调高度是记在**那块 plane** 上的（换页面时 plane 可能被复用）⇒ 撤的时候一起清掉，
        // 否则下一个页面的 hero 会一上来就是上一个页面那么高。
        if let plane = sharpHero?.superview {
            objc_setAssociatedObject(plane, &heroHeightKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        sharpHero?.removeFromSuperview()
        sharpHero = nil
        hero?.removeFromSuperview()
        hero = nil
        cachedHeroSource = nil
        cachedHeroImage = nil
    }

    /// 封面元素里那张真图。
    private static func coverImage(in root: UIView) -> UIImage? {
        firstImageView(in: root)?.image
    }

    /// 底子那张模糊封面 —— **照 MeloX 的三步**（`MeloX/Core/Artwork/ArtworkAccentColorProvider.swift`）：
    ///
    /// 1. **先把图缩到最长边 160px**（Lanczos，它的 `downsampled`）—— 先缩再糊，半径的相对强度才可控 ✓
    ///    （我上一版直接糊原图 ✗，只能拿"图宽的百分比"凑半径，效果飘）；
    /// 2. **`clampedToExtent()` 再糊** —— 不 clamp 的话边缘会被糊成透明，铺满整页时四周发虚 ✗；
    /// 3. **半径 18**（它的常数 ✓），作用在那张 160px 的图上。
    ///
    /// 它算完**按封面 URL 缓存**，整页当背景铺 ✓ —— 我们这里同样按"哪张图"缓存一次 ✓。
    private static func blurred(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let source = CIImage(cgImage: cgImage)
        let sourceExtent = source.extent.integral
        guard !sourceExtent.isEmpty, !sourceExtent.isInfinite else { return nil }

        // ① 先降采样（最长边 160）—— 与 MeloX 的 `downsampled` 同一件事。
        var prepared = source
        let longest = max(sourceExtent.width, sourceExtent.height)
        if longest > meloxDownsampleEdge, let lanczos = CIFilter(name: "CILanczosScaleTransform") {
            lanczos.setValue(source, forKey: kCIInputImageKey)
            lanczos.setValue(meloxDownsampleEdge / longest, forKey: kCIInputScaleKey)
            lanczos.setValue(1, forKey: kCIInputAspectRatioKey)
            if let scaled = lanczos.outputImage { prepared = scaled }
        }

        // ② clamp 边缘 + ③ 半径 18，都作用在那张小图上。
        let preparedExtent = prepared.extent.integral
        guard !preparedExtent.isEmpty, !preparedExtent.isInfinite,
              let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(prepared.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(meloxBlurRadius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage,
              let rendered = ciContext.createCGImage(output, from: preparedExtent) else { return nil }
        return UIImage(cgImage: rendered)
    }

    // MARK: - ③ 藏掉 Spotify 自己那些按键

    /// AM 的专辑 / 歌单页没有这些：每行的「+」「…」、头部的下载 / 加入 / 菜单 / 观看信息。
    ///
    /// 与清底色同一套纪律：**每拍补一次**（行是懒建的）、按对象只记一次、记原 `alpha` 以便逐个还原。
    /// **不动 play / shuffle** —— 那两只是真的功能，AM 自己也有（`play` 相关的一律不碰）。
    private static func hideChrome(in page: UIView) {
        var seen = 0
        var newlyHidden: [String] = []

        func walk(_ node: UIView, _ depth: Int) {
            guard depth <= clearDepth, seen < clearNodes, hiddenChrome.count < maxHiddenChrome else { return }
            seen += 1
            if let id = node.accessibilityIdentifier, !id.isEmpty,
               chromeIdentifierFragments.contains(where: { id.contains($0) }),
               !hiddenChromeViews.contains(ObjectIdentifier(node)) {
                hiddenChromeViews.insert(ObjectIdentifier(node))
                hiddenChrome.append((view: node, alpha: node.alpha))
                node.alpha = 0
                newlyHidden.append(id)
            }
            for sub in node.subviews { walk(sub, depth + 1) }
        }

        walk(page, 0)

        if !newlyHidden.isEmpty {
            writeDebugLog(
                "[\(logTag)] hid \(newlyHidden.count) chrome view(s) — \(newlyHidden.joined(separator: ", "))"
                    + "; kept play / shuffle (those are real controls, Apple Music has them too)"
            )
        }
    }

    /// 逐个写回原 `alpha`（不是一律写 1：有的本来就是半透明）。
    private static func restoreChrome(reason: String) {
        guard !hiddenChrome.isEmpty else { return }
        for entry in hiddenChrome { entry.view.alpha = entry.alpha }
        writeDebugLog("[\(logTag)] restored \(hiddenChrome.count) chrome view(s) (\(reason))")
        hiddenChrome.removeAll()
        hiddenChromeViews.removeAll()
    }

    // MARK: - 还原（关开关 / 切页都走这里）

    private static func restore(reason: String) {
        removeHero()
        restoreCoverRounding()
        // 状态栏还回 app 自己那一档（我们只在"这个页面的取色"这件事上有意见）。
        EntityPageStatusBar.release()
        restoreChrome(reason: reason)
        field?.removeFromSuperview()
        field = nil
        if !clearedBackgrounds.isEmpty {
            for entry in clearedBackgrounds { entry.view.backgroundColor = entry.color }
            writeDebugLog(
                "[\(logTag)] restored \(clearedBackgrounds.count) background(s) (\(reason))"
            )
        }
        // ★ 2026-10-17：layer 上那批 + 两种 fade 形态也逐个写回（与上面同一条纪律）。
        for entry in clearedLayerBackgrounds { entry.layer.backgroundColor = entry.color }
        for entry in hiddenFadeViews { entry.view.layer.isHidden = entry.layerHidden }
        for entry in removedFadeMasks { entry.layer.mask = entry.mask }
        clearedLayerBackgrounds.removeAll()
        hiddenFadeViews.removeAll()
        removedFadeMasks.removeAll()
        fadeMaskViews.removeAll()
        fadeMaskLayers.removeAll()
        // ★★ 2026-10-18 第二轮：深搜的次数与"报过没"也要跟着页面走 —— 下一页要重新搜一次。
        fadeHuntTick = 0
        fadeHuntPasses = 0
        didReportFadeHunt = false
        clearedLayerViews.removeAll()
        clearedBackgrounds.removeAll()
        clearedViews.removeAll()
        currentPage = nil
        didReport = false
        didReportMissingColour = false
        lastLoggedHex = nil
    }

    // MARK: - 找页面 / 找封面 / 取色

    private struct Target {
        let page: UIView
        let cover: UIView?
        let color: UIColor?
        /// ★ 2026-10-17：这一页是**艺人页**（照片铺到顶）还是**专辑 / 歌单页**（封面是卡片，不铺）
        /// —— 用户拍板选 A 之后就靠它分岔，见 `tick()`。
        let kind: PageKind
    }

    /// 我们接管的三页。只有 `.artist` 铺满幅；另两页照 AM 留 Spotify 自己那张封面卡片。
    private enum PageKind { case artist, album, playlist }

    private static func currentTarget() -> Target? {
        guard let window = frontWindow() else { return nil }

        // 专辑页：root 有 id，封面元素也有 id。
        if let page = firstView(in: window, withAnyIdentifier: pageIdentifiers) {
            let cover = firstView(in: page, withAnyIdentifier: coverIdentifiers)
            let color = cover.flatMap(coverColor)
            // ⚠️ 拿不到颜色时**不许静默**（日志 79 里专辑页一次都没出现，就是被我"悄悄 return"藏掉了）：
            //    报一次，说明是"页面认出来了、图还没加载"还是"封面元素压根没找到"。
            if color == nil, !didReportMissingColour {
                didReportMissingColour = true
                writeDebugLog(
                    "[\(logTag)] album page \(type(of: page)) found, but no cover colour yet"
                        + " (cover element \(cover == nil ? "not found at all" : "found, its image is still empty"))"
                        + " — waiting for the artwork, nothing was changed"
                )
            }
            return Target(
                page: page,
                cover: cover,
                color: color,
                kind: page.accessibilityIdentifier == "creator-page" ? .artist : .album
            )
        }

        // 歌单页：root 的 id 还没拿到 ⇒ 从封面元素往上找"占满屏"的那一层。
        if let art = firstView(in: window, withAnyIdentifier: coverIdentifiers),
           let page = pageRoot(from: art, in: window) {
            return Target(page: page, cover: art, color: coverColor(art), kind: .playlist)
        }
        return nil
    }

    /// 从封面元素往上走，找到**真正该垫底的那一层**。
    ///
    /// ⚠️ **照片 89 的教训**：那片横在列表中间的灰带，就是"底跟着内容一起滚"的现场 ✗。
    /// 歌单页的 root 我没有 id（专辑页有），原先按"占满屏"猜 ⇒ 猜中的那一层**在 scroll view 里**
    /// ⇒ 垫上去的渐变随内容滚，滚到哪就脏到哪。
    /// 所以改成：先沿着祖先链找到**最外层那个 scroll view**，垫在**它的父视图**上（那一层不滚 ✓）；
    /// 封面上方本来就不滚的页面（专辑页）才走"占满屏"那条几何。
    private static func pageRoot(from view: UIView, in window: UIView) -> UIView? {
        var outermostScroll: UIScrollView?
        var node: UIView? = view
        while let current = node, current !== window {
            if let scroll = current as? UIScrollView { outermostScroll = scroll }
            node = current.superview
        }
        if let scroll = outermostScroll {
            if let container = scroll.superview, container.bounds.height >= window.bounds.height * 0.5 {
                return container
            }
            return scroll
        }

        // 不在 scroll view 里（= 页面本来就不滚）⇒ 沿用"占满屏"那条几何。
        node = view
        while let current = node, current !== window {
            let frame = current.convert(current.bounds, to: window)
            if frame.width >= window.bounds.width - 1,
               frame.height >= window.bounds.height * 0.8,
               frame.minY <= 2 {
                return current
            }
            node = current.superview
        }
        return nil
    }

    /// 封面元素里那张真图 → 平均色。
    private static func coverColor(_ root: UIView) -> UIColor? {
        guard let imageView = firstImageView(in: root), let image = imageView.image else { return nil }
        return averageColor(of: image)
    }

    private static func firstImageView(in root: UIView) -> UIImageView? {
        if let imageView = root as? UIImageView, imageView.image != nil { return imageView }
        for sub in root.subviews {
            if let hit = firstImageView(in: sub) { return hit }
        }
        return nil
    }

    /// 1×1 重绘 = 平均色（与听歌页那条路同一个思路，省掉一遍像素遍历）。
    private static func averageColor(of image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel,
            width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }

    // MARK: - 小工具

    /// 最前面那个有内容的窗口（`EntityPageStatusBar` 也要用同一个判据，所以它是 internal 的）。
    static func frontWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { !$0.isHidden && $0.alpha > 0.01 }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    private static func firstView(in root: UIView, withAnyIdentifier identifiers: [String]) -> UIView? {
        if let id = root.accessibilityIdentifier, identifiers.contains(id) { return root }
        for sub in root.subviews {
            if let hit = firstView(in: sub, withAnyIdentifier: identifiers) { return hit }
        }
        return nil
    }

    private static func hex(of color: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "?" }
        return String(
            format: "%02X%02X%02X",
            Int(red * 255), Int(green * 255), Int(blue * 255)
        )
    }

    private static func frameText(_ rect: CGRect) -> String {
        "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded()))"
            + ",\(Int(rect.width.rounded())),\(Int(rect.height.rounded()))"
    }
}

/// 一条竖直线性渐变（`CAGradientLayer` 当自己的 layer，改颜色/位置一句话）。
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var gradient: CAGradientLayer { layer as! CAGradientLayer }
}
