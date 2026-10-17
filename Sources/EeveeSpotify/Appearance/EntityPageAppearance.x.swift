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
/// 它内部同时管"取色底"与"满幅照片 / 下缘溶解"两条路径（`tick()` 里的 `wantsField` /
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
    /// ★★ 2026-10-16：满幅照片**整幅上移**的比例（图高的 5%~7%，用户量的差是 25pt / 414pt ≈ 6%）。
    ///
    /// 用户诊断（照片 118 vs 130）：「AM 是图片顶部对齐、铺满到状态栏下面，主体落在上半部分……
    /// Spotify 的图偏下」⇒ 整体上移，裁掉的是照片顶部那条空白。照片因此不再和名字抢版面。
    private static let heroRiseRatio: CGFloat = 0.06
    /// ★★ 2026-10-16（照片 118/130 对比是判决）：**化开的起点改成绑"图自己的高度"**。
    ///
    /// 旧几何（照片 130 的现场）：`solidUntil = 名字上沿 − 30% × 页头高` = `347 − 156` = **191pt**，
    /// 而方图 414pt 贴在 y=0、猫在 **100–350pt** ⇒ 照片从 **46%** 就开始淡，下半身整段落在淡出区 ✗
    /// （用户原话：「渐变压在艺人名字上」之后，接着就是「化开窗口把主体吃掉了」）。
    /// AM（照片 118）的渐变**只吃掉照片最底部那一段**，起手远低于此。
    ///
    /// ⇒ 起点 = `图高 × meltStartRatio`（414pt 的方图 ⇒ 273pt），
    ///   终点仍锚在名字上沿之上（`meltGap`）⇒ 名字与那三颗按钮照旧落在平色上，
    ///   但**不再**因此把渐变一路往上顶到图的中段。
    private static let meltGap: CGFloat = 8
    /// 化开的**起点**占图高的比例（AM = 图高的 65%~70%，取中）。
    private static let meltStartRatio: CGFloat = 0.66
    /// 化开那一段的**下限**：页头矮的时候别把渐变整成一条硬边。
    private static let minMeltSpan: CGFloat = 90
    /// 化开那一段的缓动采样：**两端都要平**（`1 − smoothstep(p)`，9 个等分点）。
    ///
    /// 用户诊断（照片 130）：「线性斜坡两端的折角才是'被切断'感的主要来源，和长短关系不大」。
    /// `CAGradientLayer` 只在档位之间线性插值，所以用多档逼近一条 S 形曲线。
    ///
    /// ★★ 2026-10-16（**照片 135：「渐变太刻意了」**）：上一版取的是 `1 − p²` ——
    ///    它**每一档掉得比上一档多**（相邻差 0.028 → 0.083 → 0.139 → 0.194 → 0.25 → 0.306），
    ///    最后一段在 **17pt** 里从 0.306 掉到 0 ⇒ 照片底沿留下一条**肉眼可见的横边**，
    ///    读起来就是"贴了一条渐变"，而不是照片化进底色。
    ///    实测量化（照片 135 的像素采样）：那道边在 ~399pt 处 20px 内掉 53 级灰度。
    ///
    ///    现在换成 **1 − smoothstep**（对称 S 形）：首尾两段的落差从 **0.306 降到 0.043**（≈1/7），
    ///    同一段距离内那道边从 **53 级灰度降到 ~8 级** —— 肉眼不再能看出"这里贴了一条渐变"。
    ///    中段仍在跨度一半处落到 0.5（"多快吃掉主体"的观感没动）。
    /// ★ 2026-10-18：9 档 → **17 档**。9 档在 90pt 的跨度里每档约 11pt，仍然够让眼睛读出
    /// "这里贴了一条渐变"（用户：「淡出那部分太刻意了」）⇒ 加密到 17 档，每档约 5.6pt，
    /// 同一段距离的相邻落差再减半。曲线仍是 `1 − smoothstep`，观感方向没变。
    private static let meltEasing: [CGFloat] = (0...16).map { index in
        let p = CGFloat(index) / 16
        return 1 - (p * p * (3 - 2 * p))
    }
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
    /// ★★ 2026-10-18（用户看 AM 参考图 136：「现在的艺人淡出那部分太刻意了，和图片不像」）：
    /// **艺人页单独一条**更长的"灰 → 更深灰"渐变，不再和专辑/歌单页一样从 55% 一路压到纯黑。
    ///
    /// 参考图 136 的实测像素：y=47% 处 `#949494`、y=62%~78% 处 `#595959` —— 也就是
    /// **整页一直是灰的，只是往下变深**，没有"到某一行突然开始黑"的那条带。
    /// 我们把艺人页的终点改成 `#4A4A4A`（比参考图略深一点，保证白字），起点从 55% 推到 62%。
    private static let artistFadeFrom: CGFloat = 0.62
    private static let artistFadeTo = UIColor(white: 0.29, alpha: 1)
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
    private static let artistFieldLuminance: CGFloat = 0.32

    // MARK: - 状态

    /// 这一页现在用的底色（`tick` 每拍写）—— "艺人介绍"那张卡片拿它当卡面颜色（见 `ArtistBioSheet`）。
    static var currentFieldColour: UIColor?

    private static var timer: Timer?
    private static var currentPage: UIView?
    private static var field: GradientView?
    /// ★ 2026-10-13：铺在最上面的那张**清晰满幅**封面（见 `ensureHero`）。
    private static var sharpHero: UIImageView?
    /// 满幅 hero 的**单调高度**（"到过的最深处"），存在**那块 plane** 上（pw 的 `kHeroHeightKey`）。
    private static var heroHeightKey: UInt8 = 0
    /// hero 的最小高度（pw 的 `kMinHero = 120`）：比这矮就不画，免得出来一条细带。
    private static let minHeroHeight: CGFloat = 120
    /// ★★ 2026-10-16：**顶上那一条"纱"**（见 `ensureScrim`）—— 现在它**挂在照片自己身上**，
    /// 颜色取**照片顶边那一小条的平均色**，高度只到状态栏。
    private static var scrim: GradientView?
    /// 那一截在"安全区顶"之外还要往下化开多少 —— 不留这一截的话，色带底沿会看到一条硬边。
    private static let scrimExtraFade: CGFloat = 12
    /// 取顶边颜色时只看**图高最上面这一小条**，不是整图平均 ——
    /// 整图平均会把主体也算进去（白猫那张就是被"整图 + 压暗"糊成一条灰带的，见 `ensureScrim`）。
    private static let topEdgeStripFraction: CGFloat = 0.06
    /// 顶边那一小条的平均色，按"哪张图"缓存一次（0.6s 一拍，不能每拍重算 CoreGraphics）。
    private static var cachedTopEdgeSource: UIImage?
    private static var cachedTopEdgeColour: UIColor?
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
        // ★★ 2026-10-18（用户：「歌单页的那个**搜索歌单内歌曲框**还在」）：
        //    歌单页的「在此页面上查找」搜索框不在页头里（`HeaderArtworkProbe` 的注释早就写了），
        //    所以它一直躲过 `block.subviews` 那一轮。这里按 id 补进 chrome 名单 ——
        //    三个名字分别对应：页头工具条里的搜索框、歌单搜索 VC 自己的搜索条、
        //    以及页面级的通用搜索条。它们只在被 `hideChrome` 扫到的实体页上生效。
        //    ⚠️ 只把 `alpha` 置 0（和本名单里别的项一样），**不折高度** —— 这一行到底该不该
        //    留空档要等下一页的 `[HeaderProbe] page ids:` 定；`[PageRepaint] hid … chrome`
        //    那一行会告诉我们到底命中了哪个 id。
        "Toolbar.SearchField",
        "PL.SearchViewController.SearchBar",
        "Components.UI.SearchBar",
    ]
    private static var hiddenChrome: [(view: UIView, alpha: CGFloat)] = []
    private static var hiddenChromeViews: Set<ObjectIdentifier> = []
    private static let maxHiddenChrome = 400
    private static var didReport = false
    /// "清掉了一个页面容器"只报一次（见 `clearPageContainers`）。
    private static var didReportContainerClear = false
    /// "藏掉了页头那层 wash"只报一次（见 `concealAlbumWash`）。
    private static var didReportAlbumWash = false
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

        // ★★ 2026-10-16（**照片 134 的"黑色页面"**）：**我们那张满幅照片还没有图的时候，什么都别藏**。
        //
        //    这一句以前是每帧无条件跑的（2026-10-13 为了治"歌单页刚进会闪现小封面"，
        //    见上面那段）。可艺人页那 1~2 秒里：Spotify 自己那张封面**已经被我们藏了**，
        //    而我们的满幅照片要等 `coverImage(in:)` 拿到图才建得出来（`ensureHero` 的
        //    `guard let source = coverImage(in: cover)`）⇒ 那一小段整页只剩 `#121212`
        //    底 + 白字标题，就是用户报的"进去先黑一下"。
        //
        //    ⇒ 判据改成"**我们那张图真的有 image、而且就挂在这一页里**"才藏。图没到的那几帧
        //    让 Spotify 自己那张照常显示（比黑屏自然得多），图一到、`ensureSharpHero` 会把
        //    藏 + 铺在同一拍里做完。
        guard let hero = sharpHero, hero.image != nil, hero.isDescendant(of: layout) else { return }
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
        // ★★ 2026-10-17（用户：图片 142「刚进入艺人页可能会有 spotify 的原黑色底」）：
        //    **进来先跑一拍**。定时器 0.6s 才响 ⇒ 那一帧里页面还是 Spotify 自己的黑底，
        //    然后我们的底才"跳"上来。先 tick 一次，取色底与页头就跟着第一帧一起出现。
        tick()
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
            if currentPage != nil || field != nil || sharpHero != nil
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
            // ★★ 2026-10-17（用户：图片 142「刚进入艺人页可能会有 spotify 的原黑色底」）：
            //    换页这一拍**立刻再跑一次**（`currentPage` 已更新 ⇒ 不会递归）。
            //    定时器最坏要等 0.6s，那一段里页面还是 Spotify 自己的黑底/原生页头。
            tick()
            return
        }
        // ⚠️ `EntityPageRepaint.root = target.page` 原来**就写在这里**，2026-10-16 挪到下面
        //    "取色底画完之后"（原因见那一处注释：照片 137 的下半页整片黑）。
        // ★★ 2026-10-18 第五轮（诊断）：这一页上「你已点赞」那一行**装在哪个 cell 类**里 ——
        //    见 `EntityPageSectionDrop.reportLikedSongsRowClassOnce`。它不依赖任何钩子，
        //    所以"钩子压根没被叫"那一支照样能给出下一步该挂哪个类（每页一次）。
        EntityPageSectionDrop.reportLikedSongsRowClassOnce(in: target.page)

        // ★★ 2026-10-18：**这一页的底色用哪个颜色**只算一次（底 / 照片的化开共用它）。
        let colour = pageColour(for: target)
        currentFieldColour = colour
        // ★★ 2026-10-16：**顶上那条纱与状态栏字色**改用照片**自己的顶边**那一小条，不再用这个压暗过的
        //    底色 —— 压暗过的底色恒为暗 ⇒ 白照片上贴一条灰带、状态栏永远白字（照片 130 就是现场）。
        let topEdge = target.kind == .artist ? topEdgeColour(for: target) : nil

        if wantsField {
            ensureField(on: target, colour: colour, topEdge: topEdge)
        } else if field != nil {
            restore(reason: "field switch off")
        }

        // ★★ 2026-10-16（**照片 137：刚进艺人页时下半页整片黑**）：底色拦截器
        //    （`EntityPageRepaint.root`）**必须等我们自己的底画上之后再武装**。
        //
        //    它的作用是"Spotify 重画这一页的底色时，把那次写入丢掉"（见 `restore` 里那句说明）——
        //    可它一武装就开始丢**Spotify 画在这一页里的所有底色**，而封面颜色还没算出来时
        //    `ensureField` 会 `guard let colour else { return }` **整拍什么都不画**
        //    ⇒ 那一段里页面上**一张底都没有** = 纯黑，正是 137 里"照片 + 标题在、下面全黑"。
        //
        //    现在：**这一拍真有底**（`colour != nil`）才武装。没有底就让 Spotify 自己的底先留着
        //    （比黑屏自然），等封面色算出来的那一拍再接管。切页 / 离场那条 `root = nil` 不变。
        if wantsField, colour != nil {
            EntityPageRepaint.root = target.page
        }

        if wantsDissolve {
            // ★★ 2026-10-18 第二轮（用户：「歌单页的封面会消失（如果歌单页的模糊不和艺人页
            //    一样，换成和艺人一样的）」）：**三页共用同一套底**（pw 的深色 + 往黑，
            //    见 `paintField` / `fieldColourFor`），差别只剩“封面是谁的”：艺人页铺我们的满幅照片
            //    （Spotify 那张让位），专辑 / 歌单页**保留 Spotify 自己那张卡片**。
            let sharp = target.kind == .artist
            ensureHero(on: target, sharpCover: sharp)
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
    /// 艺人页要的是 pw 压暗过的那一版。
    /// ★★ 2026-10-16：再加一个 `topEdge`（照片顶边那一小条的平均色）——
    /// 状态栏压在照片上，所以它只看照片的顶边，不看那块被压暗过的底。
    private static func ensureField(on target: Target, colour: UIColor?, topEdge: UIColor?) {
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
        paintField(view, colour: colour, kind: target.kind)

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
        //    ⚠️ 判据仍然是**页面底色的明暗**：正文压在底上，不压在照片上。
        textTone(in: page, isLight: isLight(colour))

        // ★★ 2026-10-17：**状态栏也跟着翻** —— AM 的 118（亮底）是黑字、119（暗棕底）是白字，
        //    它就是靠这一条解决"照片铺到顶"的（不是靠留白）。我们原来一处都没碰过状态栏，
        //    于是在亮封面上白字直接消失（用户照片 115 的现场）。
        // ★★ 2026-10-16：判据换成**照片顶边那一小条**（`topEdge`）—— 状态栏正压在照片顶上；
        //    用压暗后的底色判会让它**恒为白字**（照片 130 的现场：白照片 + 白字）。
        //    没有满幅照片的页面（专辑 / 歌单）退回"页面色亮不亮"那一档，与改之前逐字一致。
        let statusLight = isLight(topEdge ?? colour)
        EntityPageStatusBar.apply(statusLight ? .darkContent : .lightContent)

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

    /// 竖直渐变：**上面的取色 → 窗口 55% 起渐到纯黑**（pw 的 `SGRField`；见 `blackFrom` 那段的出处）。
    ///
    /// ⚠️ **照片 95-97 的教训**：原来 57% 之后就是纯 `#121212` ⇒ 用户看到的是"**下半部分还是黑的**" ✗。
    /// 现在颜色是**封面压暗过的那一版**（`fieldColourFor`），不是 `#121212` ⇒ 整页一直带着这片颜色。
    private static func paintField(_ view: GradientView, colour: UIColor, kind: PageKind) {
        // 专辑 / 歌单页仍走 pw 的"55% 起渐到纯黑"；**艺人页单独一条**更长的灰 → 深灰
        //（见 `artistFadeFrom` / `artistFadeTo` 的说明）。三页的差别只剩"封面是谁"。
        let layer = view.gradient
        layer.startPoint = CGPoint(x: 0.5, y: 0)
        layer.endPoint = CGPoint(x: 0.5, y: 1)

        // 页面高度 = 渗过之后的高度 − 上下各 600（`ensureField` 就是这么摆的帧）。
        let painted = max(1, view.bounds.height)
        let pageHeight = max(1, painted - 2 * fieldBleed)
        let window = windowHeight(fallback: pageHeight)
        let startRatio = kind == .artist ? artistFadeFrom : blackFrom
        let faded = kind == .artist ? artistFadeTo : UIColor.black
        // pw 的 locations 是**绝对**位置（窗口高度 × 0.55 / × 1）换算成整块画布的比例 ——
        // `from = height * kBlackFrom + bleed.top`（`SGRField.m:99-102`），这里 `fieldBleed`
        // 就是那个 bleed.top。
        let from = min(1, max(0, (fieldBleed + window * startRatio) / painted))
        let to = min(1, max(from, (fieldBleed + window * blackTo) / painted))
        layer.locations = [NSNumber(value: 0), NSNumber(value: from), NSNumber(value: to)]
        layer.colors = [colour.cgColor, colour.cgColor, faded.cgColor]

        let key = hex(of: colour)
        if key != lastLoggedHex {
            lastLoggedHex = key
            writeDebugLog(
                "[\(logTag)] field colour is now #\(key) — "
                    + (kind == .artist
                        ? "artist page: a soft grey, deepening at 62%"
                        : "pw's field: a deep solid, fading to black at 55%")
            )
        }
    }

    /// 窗口高度（pw 的 `windowHeight()`，`SGRField.m:16-19`）：黑渐变按**窗口**锚定，不按页面。
    private static func windowHeight(fallback: CGFloat) -> CGFloat {
        if let height = frontWindow()?.bounds.height, height > 0 { return height }
        return fallback > 0 ? fallback : 874
    }

    /// **这一页的底色**：三页**同一个** —— 一律是 **pw 压暗过的那一版**（`fieldColourFor`）。
    ///
    /// 三页不分开的理由：浅色底让**白字看不清**（照片 127 的歌单页就是现场），
    /// 而 **AM 自己的专辑 / 歌单页就是"深底 + 封面卡片 + 白字"**（照片 123）。
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
    /// **封面那一层**。它只剩两件事：
    ///   · **艺人页**：让 Spotify 那张小封面让位，铺我们自己的满幅照片（`ensureSharpHero`）；
    ///   · **专辑 / 歌单页**：**保留 Spotify 自己那张封面卡片**（只把圆角改成 AM 的连续圆角）。
    private static func ensureHero(on target: Target, sharpCover: Bool) {
        guard let cover = target.cover else { return }

        if sharpCover {
            // ⚠️ 原来这里有一句"图还没到也要先把 Spotify 那张小封面藏掉"的
            //    `concealNativeCover(cover)`（2026-10-13 加的）。**2026-10-16 删掉**：
            //    它正是照片 134 那一下黑屏的另一半 —— 藏了却还没建出我们的图，页头就是空的。
            //    现在藏的动作只留在两处，两处都要求"**我们真有图**"：
            //      · `ensureSharpHero`（宿主认出来之后，藏 + 铺同一拍）；
            //      · `layoutPass`（每帧补的那道保险，判据是 `sharpHero.image != nil`）。
            guard let source = coverImage(in: cover) else { return }
            ensureSharpHero(cover: cover, source: source, page: target.page)
            return
        }

        // **专辑 / 歌单页保留 Spotify 自己那张封面卡片**：
        //    · "封面会消失"的根因就是原来这里无条件跑的 `concealNativeCover(cover)`：
        //      专辑 / 歌单页也照藏 ⇒ 卡片整张不见（照片 127：歌单页只剩一层模糊底 + 白字）。
        //      它现在只服务艺人页（上面那一支）。
        //    · 两页的底也是 pw 那条"深色 → 黑"（`paintField`），"白字压在浅底上看不清"一并解决。
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
    private static func ensureSharpHero(cover: UIView, source: UIImage, page: UIView) {
        // ★ 2026-10-13（照片 104：专辑页只有一片颜色、没有封面）：**宿主分两种** ——
        //   · 歌单页：Spotify 画页面颜色 wash 的那块 plane（pw 的 `PlaylistHeader.x` 做法）；
        //   · 专辑页：**头自己**（pw 的 `AlbumHeader.x` 逐字：`[header insertSubview:hero atIndex:0]`）。
        //
        //   专辑页**没有** `_backgroundViewContainer`（那是歌单页的结构；它的 wash 是页面里那个
        //   `LegacyUI…HeaderView` + `GradientView`，见 pw 的 `AlbumField.x`）⇒ 原来这里
        //   `guard let plane … else { return }` 一句直接返回 ⇒ **整条 sharpHero 静默不装**：
        //   日志 87 里就**没有** `sharp hero …` 那一行，
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
        // ★★ 2026-10-16：**整幅上移**（`frame.y` 取负）—— AM 的照片主体落在上半部分，
        //    我们原来顶对齐、主体偏下（照片 130 的猫比 AM 照片 118 低约 25pt；25/414 ≈ 6%）。
        //    裁掉的是照片顶部那条空白；下面 mask 的落点按同一偏移换算（见 `imageHeight` 那一段）。
        let rise = fillsHost ? round(height * heroRiseRatio) : 0
        let frame = CGRect(
            x: 0,
            y: topInset - rise,
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

        // ★★ 2026-10-16：**起点绑图高（66%），终点绑名字上沿** —— 见 `meltStartRatio` 那段。
        //    mask 作用在 `view` 自己的坐标里，而照片上移了 `rise` ⇒ 名字的本地 y 要把 `rise` 加回来
        //    （`frame.minY` 是负的，减它等于加）。
        let imageHeight = max(1, view.bounds.height)
        let meltStart: CGFloat
        let meltEnd: CGFloat
        if let textTop = ourHeaderTextTop(in: host), textTop > host.bounds.height * 0.2 {
            let local = textTop - frame.minY
            // ★★ 2026-10-18（用户：「现在的艺人淡出那部分太刻意了，和图片不像」）：
            //    旧公式是 `max(meltStart + 90, titleTop - 8)` —— 跨度不够时**多出来的那段会
            //    往标题下面顶**，于是标题/三颗按钮压在"半透明的照片"上，看起来就是一条刻意
            //    画出来的渐变带。AM 的标题是落在**实心底色**上的。
            //    ⇒ 终点永远不超过 `titleTop - meltGap`；跨度不够就**把起点提前**（拉长渐变），
            //      而不是把终点顶到标题下面。
            meltEnd = min(imageHeight, max(0, local - meltGap))
            meltStart = min(imageHeight * meltStartRatio, max(0, meltEnd - minMeltSpan))
        } else {
            // 认不出我们那块页头（还没建 / 正在收起）：一路化到图的下缘，
            // 但起点仍是图高的 66% —— 不像旧版那样从 54% 就开始（那正是"吃掉主体"的来源）。
            meltStart = imageHeight * meltStartRatio
            meltEnd = imageHeight
        }
        applyDissolveMask(to: view, solidUntil: meltStart, goneAt: meltEnd)

        // ★★ 2026-10-16：顶上那条纱**挂在照片自己身上**、颜色取**照片顶边那一小条** ——
        //    不再是"页面取色"（压暗过的深灰贴在白照片上 = 照片 130 顶上那条灰带，见 `ensureScrim`）。
        ensureScrim(in: view, page: page, image: source)
    }

    /// **顶上那一条"纱"** —— 状态栏压在满幅照片上时，给它一条与照片同色的底。
    ///
    /// AM 的做法（照片 118/119）：顶上那一条**就是照片自己的颜色**（照片从这片颜色里长出来），
    /// 不是叠一层深色。所以这里的三条：
    ///
    /// * 颜色 = **照片顶边那一小条的平均色**（`topEdgeStripFraction`）。整图平均不行 ——
    ///   我们上一版用的是**页面取色**（封面被压到亮度上限之后的那一档深灰，
    ///   白猫那张 ≈ `#7B7D7F`）⇒ 深灰糊在白照片顶上，就是照片 130 顶上那条脏灰带。
    /// * 高度 = **安全区（状态栏 / 灵动岛）+ 一小截化开**，不再往下伸进页头。
    /// * **顶边偏亮就整条不画**：那种情况状态栏已经翻成黑字（`ensureField` 用同一小条判），
    ///   照片自己就是最好的底，再叠一层只会把它弄脏（用户：「图偏亮就弱化或直接不要」）。
    /// * 挂在**照片视图自己身上**（`hero.addSubview`）⇒ 照片被缩放 / 视差 / 被宿主裁切时，
    ///   纱的位置永远和图钉在一起，不会和图错开。
    ///
    /// ⚠️ 与 `wantsTopInset`（真正把图往下挪）仍**不是一回事**：那条 2026-10-06 被用户否过
    /// （"缓冲没和封面接上、而且太大"），现在仍然恒 `false`。
    private static func ensureScrim(in hero: UIImageView, page: UIView, image: UIImage) {
        // 取不到顶边颜色、或顶边本来就亮 ⇒ **什么都不画**：宁可没有这一条，
        // 也不能拿一个错的颜色顶上去（黑纱、灰带都是这么来的，AM 那边根本没有那一层）。
        guard let colour = topEdgeColour(of: image), !isLight(colour) else {
            removeScrim()
            return
        }

        let host = hero.superview ?? page
        let view: GradientView
        if let scrim, scrim.superview === hero {
            view = scrim
        } else {
            removeScrim()
            let fresh = GradientView()
            fresh.isUserInteractionEnabled = false
            fresh.accessibilityIdentifier = "eevee-page-scrim"
            let gradient = fresh.gradient
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            hero.addSubview(fresh)
            scrim = fresh
            view = fresh
        }

        let safeTop = resolvedSafeAreaTop(in: host, page: page)
        let height = max(12, safeTop + scrimExtraFade)
        let solid = min(1, safeTop / height)

        // 颜色 / 高度只在变了的时候才写 layer（0.6s 一拍，不能每拍都写）。
        let key = "\(hex(of: colour))@\(Int(height))"
        if key != scrimColourKey {
            scrimColourKey = key
            let gradient = view.gradient
            gradient.colors = [
                colour.cgColor,
                colour.cgColor,
                colour.withAlphaComponent(0).cgColor,
            ]
            gradient.locations = [
                NSNumber(value: 0),
                NSNumber(value: Double(solid)),
                NSNumber(value: 1),
            ]
            writeDebugLog(
                "[\(logTag)] top band #\(hex(of: colour)) — the cover's own top edge,"
                    + " \(Int(height))pt (status bar + \(Int(scrimExtraFade))pt) over the picture;"
                    + " nothing at all when that edge is light"
            )
        }

        let frame = CGRect(x: 0, y: 0, width: hero.bounds.width, height: height)
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
        // ★★ 2026-10-17（用户：图片 144「专辑页可能会是图片这个样子」—— 页头一层**粉色渐变**压在我们的
        //    取色底上、内容区却已经是我们的平色，同一页两段颜色、中间一条硬边）：
        //
        //    根因就是 **Spotify 自己的 wash 没被藏掉**：那是 `HeaderView` 里的一块 `GradientView`。
        //    旧判据只看**页面的直接子视图**、再只看它的**直接子视图**、而且**命中第一个就 return**
        //    ⇒ 专辑页（`CreativeWorkTemplateView`）的 wash 一旦不是那个形状（或不止一块），
        //    它就整块留着，压在我们的底上。
        //
        //    现在：从页面往下**有界 BFS**（深 10 / 600 节点），凡是"在 HeaderView 子树上"的
        //    `GradientView` 都藏掉（最多 8 块）；`eevee-` 前缀与我们自己的 field / scrim / hero
        //    一律跳过 —— 那几块是**要显示**的。
        var queue: [(view: UIView, insideHeader: Bool, depth: Int)] = page.subviews.map { ($0, false, 1) }
        var visited = 0
        var taken = 0

        while !queue.isEmpty, visited < 600, taken < 8 {
            let (view, insideHeader, depth) = queue.removeFirst()
            visited += 1

            let name = NSStringFromClass(type(of: view))
            let identifier = view.accessibilityIdentifier ?? ""
            let isHeaderRoot = name.contains("HeaderView") && !name.contains("NavigationBar")
            let inHeader = insideHeader || isHeaderRoot

            if inHeader,
               name.contains("GradientView"),
               !identifier.hasPrefix("eevee-"),
               view !== field,
               view !== scrim,
               !(sharpHero.map { view === $0 } ?? false) {
                concealWash(on: view)
                taken += 1
                continue
            }

            guard depth < 10 else { continue }
            queue.append(contentsOf: view.subviews.map { ($0, inHeader, depth + 1) })
        }

        guard taken > 0, !didReportAlbumWash else { return }
        didReportAlbumWash = true
        writeDebugLog(
            "[\(logTag)] album wash — concealed \(taken) GradientView(s) inside the page header"
        )
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


    /// 向下**淡出**：`solidUntil` 之上完全不透明，`goneAt` 之下完全透明，中间走 `meltEasing` 的多档缓动。
    ///
    /// ⚠️ 这是**给图片本身加透明度蒙版**（`view.layer.mask`），不是在图上叠一层深色 ——
    /// 图是"自己淡出到下面的底色里"的，底色由 `paintField` 负责。
    private static func applyDissolveMask(to view: UIView, solidUntil: CGFloat, goneAt: CGFloat) {
        let height = max(1, view.bounds.height)
        let solid = max(0, min(1, solidUntil / height))
        let gone = max(solid, min(1, goneAt / height))

        let steps = meltEasing.count
        let mask: CAGradientLayer
        if let existing = view.layer.mask as? CAGradientLayer, existing.colors?.count == steps {
            mask = existing
        } else {
            view.layer.mask = nil
            let layer = CAGradientLayer()
            layer.startPoint = CGPoint(x: 0.5, y: 0)
            layer.endPoint = CGPoint(x: 0.5, y: 1)
            view.layer.mask = layer
            mask = layer
        }

        var locations: [NSNumber] = []
        var colours: [CGColor] = []
        for (index, alpha) in meltEasing.enumerated() {
            let progress = CGFloat(index) / CGFloat(steps - 1)
            locations.append(NSNumber(value: Double(solid + (gone - solid) * progress)))
            colours.append(UIColor.white.withAlphaComponent(alpha).cgColor)
        }

        // ⚠️ 复用的那个 layer 上写的是**上一拍的位置** ⇒ 位置**每次都要重写**（原来只在新建那一支里写过，
        //    所以换一个更矮/更高的收口时它不会跟着动）。写的时候关掉隐式动画，免得收口自己动。
        let wanted = locations.map { $0.doubleValue }
        let current = mask.locations?.map { $0.doubleValue } ?? []
        if current != wanted {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.colors = colours
            mask.locations = locations
            CATransaction.commit()
        }
        if !mask.frame.equalTo(view.bounds) { mask.frame = view.bounds }
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
        revealNativeCover()
        revealWash()
        // 单调高度是记在**那块 plane** 上的（换页面时 plane 可能被复用）⇒ 撤的时候一起清掉，
        // 否则下一个页面的 hero 会一上来就是上一个页面那么高。
        if let plane = sharpHero?.superview {
            objc_setAssociatedObject(plane, &heroHeightKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        sharpHero?.removeFromSuperview()
        sharpHero = nil
    }

    /// 封面元素里那张真图。
    private static func coverImage(in root: UIView) -> UIImage? {
        firstImageView(in: root)?.image
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
        // ★ 2026-10-18：`⋯` 现在挂在 window 上（见 `EntityPageHeaderManager.pinMoreButton`），
        // 离开实体页/关掉外观时**不会跟着页头一起消失** ⇒ 必须在这里收走。
        EntityPageHeaderManager.removePinnedMore(reason: reason)
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

    /// 这一页照片**顶边那一小条**的平均色（认不出照片就是 nil）。
    ///
    /// 与 `pageColour(for:)` 是**两个不同的东西**：那个是"整页的底"（要压暗到白字读得清），
    /// 这个是"照片最上面那一条长什么样" —— 顶上那条纱与状态栏字色都只看它。
    private static func topEdgeColour(for target: Target) -> UIColor? {
        guard let cover = target.cover, let image = coverImage(in: cover) else { return nil }
        return topEdgeColour(of: image)
    }

    /// 把整张图画进一个 **1 × rows** 的上下文：**每一行就是图里对应那一横条的平均色**。
    ///
    /// `draw` 用的是 CG 坐标（原点在左下）⇒ 图的最上面一条落在**第 0 行**；
    /// 取最前面那 `topEdgeStripFraction` 的几行求平均 = "顶边一小条"，不把主体算进去。
    private static func topEdgeColour(of image: UIImage) -> UIColor? {
        if cachedTopEdgeSource === image, let cached = cachedTopEdgeColour { return cached }
        guard let cgImage = image.cgImage else { return nil }

        let rows = 64
        var buffer = [UInt8](repeating: 0, count: rows * 4)
        guard let context = CGContext(
            data: &buffer,
            width: 1,
            height: rows,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: rows))

        let wanted = max(1, min(rows, Int((CGFloat(rows) * topEdgeStripFraction).rounded())))
        var red = 0
        var green = 0
        var blue = 0
        for row in 0..<wanted {
            red += Int(buffer[row * 4])
            green += Int(buffer[row * 4 + 1])
            blue += Int(buffer[row * 4 + 2])
        }
        let divisor = CGFloat(wanted) * 255
        let colour = UIColor(
            red: CGFloat(red) / divisor,
            green: CGFloat(green) / divisor,
            blue: CGFloat(blue) / divisor,
            alpha: 1
        )
        cachedTopEdgeSource = image
        cachedTopEdgeColour = colour
        return colour
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
