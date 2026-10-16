import Foundation
import UIKit

/// 「专辑 / 歌单页头」——把 Spotify 的页头换成 Apple Music 式的版本。
///
/// ## 出处
///
/// 借鉴 **spoti.pw v0.21.1** 的 `Redesigned/Kit/SGRHeaderInfo.{h,m}` 与
/// `Redesigned/Playlist/PlaylistHeader.x`（该版本为 **GPL-3.0**；其 v0.22.0 起改为
/// PolyForm Strict，**那里的代码不可复制**）。这里是**按它的判断重写的 Swift 实现**，
/// 不是逐行翻译 —— 目标类与标识符全部用**我们自己真机日志** + `dump-9.1.88.txt` 重新核对。
///
/// ## 形态（Music app 的专辑 / 歌单页）
///
/// ```
///              标  题          ← 居中、粗体、最多 2 行
///            创 建 者          ← 居中、次要色
///         8 首歌 · 41 分钟      ← 居中、三级色（Spotify 自己那行原文）
///         ──────────────      ← 16pt
///      [shuffle] (  ▶ Play  )  [尾随]
///         ──────────────      ← 14pt
///           描 述             ← 自然对齐、最多 2 行
/// ```
/// 整块**贴底排**（内容底边距视图底 14pt）—— 这样标题与创建者正好压在封面的"溶解"边上，
/// 而封面要伸到内容顶部往下 56pt（`titleRise`，给 hero 用）。
///
/// ## 三条关键取舍（都是 pw 的判断）
///
/// 1. **不摆 Spotify 的控件，整列藏掉自己画**：摆它的列就要回应它每一拍的 stack 重排与
///    Auto Layout 写回，实测会被改回去。
/// 2. **按钮"镜像 + 转发"**：字形取自被藏起来的 Spotify 控件（取不到用 SF Symbol 兜底），
///    点击 `sendActions` 转发给那个控件 ⇒ 动作 / 状态 / 语言都留在 Spotify 那边。
/// 3. **只有文字真正画到的地方吃触摸**：这块和页面一样宽，其余部分必须让下拉与点击穿过去。
///
/// ## 安全阀
///
/// **认不出标题就整块不动**（`apply` 早退，一个视图都不藏）。所以任何一环失配的结果是
/// "这个功能没生效"，而不是"歌单页坏了"。每一步都会在调试日志里留一行。
enum EntityPageHeaderMetrics {
    static let side: CGFloat = 20           // 文字左右内缩
    static let playMinWidth: CGFloat = 148  // Play 胶囊最小宽度（Music app 的）
    static let rowSpacing: CGFloat = 16
    static let rowAbove: CGFloat = 16       // 文字与按钮行之间
    static let aboutAbove: CGFloat = 14     // 按钮行与描述之间
    static let bottom: CGFloat = 14         // 内容底边距视图底
    static let titleRise: CGFloat = 56      // 封面要伸到内容顶部往下这么多（hero 用）
    /// ★ 2026-10-13（用户给了 8 张 AM 艺人页，photo_1/3/5/7）：三颗的**尺寸关系**照 Apple Music 来
    /// —— 两侧是**小圆**（`ⓘ` 与 `☆`，≈56pt），中间是**大一档的圆**（纯白 `▶`，≈80pt）。
    /// 原来是 pw 的"两颗 44 圆 + 一颗 148×48 的白胶囊"；现在中间那颗**从胶囊变成圆**（去掉"播放"二字）。
    static let rowHeight: CGFloat = 56      // = 两侧小圆的直径
    static let playSide: CGFloat = 84       // = 中间那颗粒子的直径
    /// ★ 2026-10-13（照 AM）：页头**右上角那颗 `⋯`** 的直径 —— AM 在同一位置放一颗"分享 + ⋯"的
    /// 玻璃胶囊，与左上角的返回键同高。
    static let pinnedMoreSide: CGFloat = 44
    /// 两侧按钮那圈**玻璃圆**的直径（= pw 的 `SGRGlassCircleSize`）。
    static let glassCircle: CGFloat = 44
    /// 两侧按钮的字形边长。★ 2026-10-13（用户看真机：「旁边的按键小了点」）：
    /// 原来是"按 48pt 的 27% 内缩"≈26pt，看着比中间那颗胶囊轻 —— pw 是 44pt 玻璃圆里放字形，
    /// 所以这里改成**固定字形 + 44pt 玻璃圆**，与 Music app 的分量对齐。
    /// ★ 同日再调（用户：「这播放旁边的播放图标太小了吧」）：22 → **24**。
    static let glyphSide: CGFloat = 24
}

/// 浅色玻璃（Play 胶囊里那片）。**探测式**，与 `GlassCapsule.makeGlassView` 同一套手法
/// —— 那一条是给深色标签栏用的（材质兜底是 dark），这颗胶囊要浅色，所以另开一个：
/// iOS 26 有 `UIGlassEffect` 就用真玻璃（带折射与边缘高光），否则退浅色材质。
///
/// 返回的视图**不吃触摸**（它只是底），点击由外面的 `UIControl` 收。
private func eeveeMakeLightGlassView(interactive: Bool) -> UIVisualEffectView {
    let view = UIVisualEffectView(effect: nil)

    if let glassType = NSClassFromString("UIGlassEffect") as? UIVisualEffect.Type {
        let effect = glassType.init()
        // `isInteractive` 要先探 getter/setter 再写 —— KVC 碰未知 key 会抛异常（崩）。
        if interactive, let object = effect as? NSObject,
           object.responds(to: NSSelectorFromString("isInteractive")),
           object.responds(to: NSSelectorFromString("setInteractive:")) {
            object.setValue(true, forKey: "interactive")
        }
        view.effect = effect
    } else {
        view.effect = UIBlurEffect(style: .systemUltraThinMaterialLight)
    }

    view.isUserInteractionEnabled = false
    view.clipsToBounds = true
    view.layer.cornerCurve = .continuous
    view.layer.borderWidth = 0.75
    view.layer.borderColor = UIColor.white.withAlphaComponent(0.32).cgColor
    return view
}

/// 造一个"里面嵌着玻璃"的容器（pw 的 `SGRGlassInside` / `SGRGlassCapsuleInside` 同一件事）。
/// 玻璃铺满、圆角跟着容器；返回玻璃视图，调用方在 `layoutSubviews` 里让它跟着 bounds 走。
private func eeveeInsertGlass(in host: UIView, interactive: Bool) -> UIVisualEffectView {
    let glass = eeveeMakeLightGlassView(interactive: interactive)
    glass.frame = host.bounds
    glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    host.insertSubview(glass, at: 0)
    return glass
}

// MARK: - 藏 / 找 / 点

/// 把 Spotify 的视图**藏死**。三个动作缺一不可：
///
///   · **改 `layer.isHidden`，不碰 `view.isHidden`** —— Spotify 自己会 `setHidden:NO` 把东西
///     显示回来（改层挡得住），而且 Encore 的 stack 在 arranged view 被 `hidden` 时可能在
///     `updateConstraints` 里 trap；
///   · **空 mask** —— Spotify 不碰 mask，被空 mask 罩住的层什么都不画，这是第二道保险；
///   · 关交互 + 关无障碍（藏掉的东西不该再能被点到或读屏读到）。
///
/// 幂等，每一拍调都行。
func eeveeConceal(_ view: UIView?) {
    guard let view else { return }
    if !view.layer.isHidden { view.layer.isHidden = true }
    if view.layer.mask == nil { view.layer.mask = CALayer() }
    if view.isUserInteractionEnabled { view.isUserInteractionEnabled = false }
    view.accessibilityElementsHidden = true
}

/// **只加空 mask** 的藏法：视图什么都不画，但 `layer.isHidden` / `view.isHidden` 一个都不碰。
///
/// ★ 2026-10-13（艺人页）：什么时候必须用它 —— 视图在 **`OverflowStackView`** 里的时候。
/// pw 在艺人页踩过这个真机崩溃，注释逐字：
///
/// > `ios-creator-impl.context_menu_in_navigation_bar_enabled_artist` moves more out of the header's
/// > row, and with it gone Spotify's OverflowStackView force-unwraps the tallest view of a line that
/// > has none and **traps as the page opens** (device crash 2026-09-18 19:09,
/// > **SIGTRAP in -[OverflowStackView updateConstraints]**).
///
/// 空 mask 本身就让视图什么都不画，所以这里少一道 `hidden` 只是少一道保险，**不会漏**。
func eeveeBlank(_ view: UIView?) {
    guard let view else { return }
    if view.layer.mask == nil { view.layer.mask = CALayer() }
    if view.isUserInteractionEnabled { view.isUserInteractionEnabled = false }
    view.accessibilityElementsHidden = true
}

/// 深度优先找第一个（含自身）无障碍 id 匹配的视图。`identifier` 末尾写 `*` 表示前缀匹配
/// —— Spotify 有些 id 带后缀（如 `DownloadButton.Granular*`、`Components.Header.UI.Metadata*`）。
func eeveeFindView(_ root: UIView?, identifier: String, maxNodes: Int = 5000) -> UIView? {
    guard let root else { return nil }
    let isPrefix = identifier.hasSuffix("*")
    let needle = isPrefix ? String(identifier.dropLast()) : identifier

    var queue: [UIView] = [root]
    var visited = 0
    while !queue.isEmpty, visited < maxNodes {
        let view = queue.removeFirst()
        visited += 1
        if let id = view.accessibilityIdentifier, !id.isEmpty {
            if isPrefix ? id.hasPrefix(needle) : id == needle { return view }
        }
        queue.append(contentsOf: view.subviews)
    }
    return nil
}

/// 按**类名片段**找第一个（含自身）视图。
///
/// ★★ 2026-10-17：为什么必须有它 —— 艺人页的"关于艺人"是 **`SPTArtistAboutBiographyView`**
/// （真机树：`[Tree] #9 17.SPTArtistAboutBiographyView@16,82,382,1126`，与 `id=creator-page`
/// **同一棵树**；382 = 414−32，就是列表行的内缩，日志里量到过 `382,70` 收起 / `382,1126` 展开
/// 两种高度）。这种老 `SPT*` 视图**一个 accessibility id 都没有** ⇒ 按 id 永远找不到它
/// （日志 94 的 `leading none` 就是这么来的）。
func eeveeFindView(_ root: UIView?, classNameContains needle: String, maxNodes: Int = 5000) -> UIView? {
    guard let root else { return nil }
    var queue: [UIView] = [root]
    var visited = 0
    while !queue.isEmpty, visited < maxNodes {
        let view = queue.removeFirst()
        visited += 1
        if NSStringFromClass(type(of: view)).contains(needle) { return view }
        queue.append(contentsOf: view.subviews)
    }
    return nil
}

/// 把一个视图滚进它所在那个 `UIScrollView` 的视野。
///
/// ★★ 2026-10-17（用户：「点击（`i`）后**跳转到关于艺人模块**」）：艺人页的"关于"在列表很下面
/// （真机树里那一块展开后 1126pt 高），只把点击转发过去、**不滚动**的话用户什么都看不见 ——
/// 那个东西确实展开了，但不在屏幕上。
@discardableResult
func eeveeScrollIntoView(_ view: UIView, topPadding: CGFloat = 24) -> Bool {
    var node: UIView? = view.superview
    while let current = node {
        if let scroll = current as? UIScrollView {
            let target = view.convert(view.bounds, to: scroll).insetBy(dx: 0, dy: -topPadding)
            scroll.scrollRectToVisible(target, animated: true)
            return true
        }
        node = current.superview
    }
    return false
}

/// 从 `view` 往上找**最外层** `UIScrollView`，往下滚一屏。
///
/// ★★ 2026-10-17：给艺人页那颗 `i` 兜底 —— "关于艺人"（`SPTArtistAboutBiographyView`）是列表里
/// 懒加载的一段，页面刚打开时可能还没建出来。这时候点 `i`：**不许退回去做随机播放**，而是把页面
/// 往下滚一屏，让那一段被建出来；下一拍 `fireTarget` 就有了，再点就是"滚过去 + 展开"。
@discardableResult
func eeveeScrollPageDown(from view: UIView) -> Bool {
    var outermost: UIScrollView?
    var node: UIView? = view.superview
    var levels = 0
    while let current = node, levels < 24 {
        levels += 1
        if let scroll = current as? UIScrollView { outermost = scroll }
        node = current.superview
    }
    guard let scroll = outermost, scroll.bounds.height > 1 else { return false }
    let bottom = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
    let next = min(bottom, scroll.contentOffset.y + scroll.bounds.height)
    guard next > scroll.contentOffset.y + 1 else { return false }
    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: true)
    return true
}

// MARK: - 「关于艺人」在这一版艺人页上的真实名字（真机日志 100 逐字）

/// 卡片：id 前缀 `Components.UI.CreatorBiographyCard.*`、Swift 类名里含 `CreatorBiography`。
/// 正文：`Components.UI.CreatorBiographyCard.BiographyLabel`（真机树里那一格就是它）。
///
/// ⚠️ 为什么不能只认 `SPTArtistAboutBiographyView`（日志 100 的现场）：
///   · 那个类**在二进制里还在** ⇒ 启动那行 `about-artist hook on` 照样打得出来，
///     但它在**这一版艺人页上从头到尾没出现过**：`applyToArtistPage` 那条 BFS 只试两拍、
///     `eeveeMaterialiseBio` 滚到列表底也只报 `nothing built` —— 而**同一份日志**的
///     `[HeaderProbe]` 明明列出了 `id=Components.UI.CreatorBiographyCard.HeaderLabel` /
///     `.FreshFindsForwardBadge`：卡片在页面上，**只是不叫那个名字**。
///   · 这件事本仓库自己早写下来了（`EntityPageRepaint` 的 `aboutArtistClassFragment`：
///     「`aboutArtistFragment` 那条判据在这一版艺人页上永远不可能命中」）—— 那一轮只把
///     **折叠**改对了，**读取侧没跟上** ⇒ 折叠照做（那一段被折成 0 高）、我们的卡片又读不到正文，
///     于是用户**两边都看不到**（2026-10-11：「点击 i 之后，观感还是之前的那个」）。
let eeveeArtistBioCardIdPrefix = "Components.UI.CreatorBiographyCard"
let eeveeArtistBioTextId = "Components.UI.CreatorBiographyCard.BiographyLabel"
let eeveeArtistBioClassFragment = "CreatorBiography"

/// 往上找带这个无障碍 id 的祖先（有界，与 `isArtistPageAncestor` 同一条边界）。
func eeveeAncestor(withIdentifier identifier: String, of view: UIView) -> UIView? {
    var node: UIView? = view
    var level = 0
    while let current = node, level < 28 {
        level += 1
        if current.accessibilityIdentifier == identifier { return current }
        node = current.superview
    }
    return nil
}

/// 找这一步的搜索根：① `creator-page`（整页）② 它自己的最外层 scroll ③ 窗口。
///
/// 为什么必须有它：`i` 那颗按键的**起点是页头里那颗按钮**，从它**往下**走根本到不了列表里
/// 那张卡（卡在 cell 里）—— 必须先**往上**走到"整页"那一层再往下找。
func eeveeArtistBioSearchRoot(from view: UIView) -> UIView {
    if let page = eeveeAncestor(withIdentifier: "creator-page", of: view) { return page }
    if let scroll = eeveeOutermostScroll(from: view) { return scroll }
    return view.window ?? view
}

/// 「关于艺人」那一块 —— **零滚动**，按真机证实过的名字找。
///
/// 顺序：正文 label（id 精确）→ 它上面第一个 `CreatorBiography` 类祖先 → id 前缀 → 类名片段。
/// ⚠️ 只认**落在 `creator-page` 里**的卡：听歌页那张"了解艺人"卡是同一族（`CreatorBiography`），
///    不设这道闸就会在别的页面上乱认。
func eeveeArtistBioCard(in view: UIView) -> UIView? {
    let root = eeveeArtistBioSearchRoot(from: view)
    let nodeLimit = 20000

    var found: UIView?
    if let label = eeveeFindView(root, identifier: eeveeArtistBioTextId, maxNodes: nodeLimit) {
        // 卡片 = label 往上第一个类名含 `CreatorBiography` 的祖先（没有就退回 label 自己）。
        var node: UIView? = label
        var level = 0
        while let current = node, level < 12 {
            level += 1
            if NSStringFromClass(type(of: current)).contains(eeveeArtistBioClassFragment) {
                found = current
                break
            }
            node = current.superview
        }
        if found == nil { found = label }
    }
    if found == nil {
        found = eeveeFindView(root, identifier: eeveeArtistBioCardIdPrefix + "*", maxNodes: nodeLimit)
    }
    if found == nil {
        found = eeveeFindView(root, classNameContains: eeveeArtistBioClassFragment, maxNodes: nodeLimit)
    }
    guard let found, eeveeAncestor(withIdentifier: "creator-page", of: found) != nil else { return nil }
    return found
}

/// 从那一块里读正文：**优先 id 精确的那颗 label**，读不到返回 nil（调用方再退"最长的一段"）。
///
/// ⚠️ 读的是**界面上的文字**：Spotify 会把长简介截断（flag `is_async_biography_truncation_enabled`），
///    要完整正文只能去 hook 数据层（`SPTArtistAboutDataLoader`，见 `ArtistBioSource` 的说明）。
func eeveeArtistBioText(in card: UIView) -> String? {
    guard let label = eeveeFindView(card, identifier: eeveeArtistBioTextId)
        ?? eeveeFindView(card, identifier: eeveeArtistBioTextId + "*") else { return nil }
    let raw = (label as? UILabel)?.text ?? (label as? UITextView)?.text
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trimmed, !trimmed.isEmpty else { return nil }
    return trimmed
}

/// 把列表**扫一遍**，逼"关于艺人"那一段建出来，然后返回它。
///
/// ★★ 2026-10-18 第三轮（用户：「**按下 i 之后还是没有跳转到 艺人介绍**」；日志 98 逐字
///    `leading MISSING` + `fired: NOTHING yet (the target is not built) — scrolled the page a screen`）：
///    那一块是**懒加载的 section**（真机树里在列表深度 20），页面刚打开时整棵树只有 979~1678 个节点
///    ⇒ 它压根还没建出来。一次只滚一屏的兜底要用户连点好几次。
///
/// 做法：**在同一个主线程回合里**把最外层 scroll view 逐屏（`animated: false`）往下翻，
/// collection view 会为每一屏建 cell；那一段建出来时 `SPTArtistAboutBiographyView` 的 `layoutSubviews`
/// 就会响（`ArtistBiographyViewHook`），我们当场拿到它。全程不动画、最后**回到原位**，用户看不到跳动。
///
/// ⚠️ 步数有上限（12 屏）；找不到就返回 nil，调用方照旧退回"滚一屏"那条老路。
///
/// ★★ 2026-10-18 第五轮（**日志 99 的现场**）：`about-artist sweep — 1 step(s) over 1416pt,
/// nothing built` —— 它**只看了列表最顶上那一屏**。原因在下面那个 `bottom`：
/// 这是**自适应的懒加载列表**，没滚到的那部分还不存在 ⇒ 进来时算出来的
/// `contentSize.height`（1416pt）比屏幕（896pt）只多 520pt，而 `step` 是 0.9 屏 = 806pt
/// ⇒ 第一次循环就把 offset 推到 806 > 520，条件不成立、直接退出。
/// 于是"滚一整趟把那一块逼出来"这句承诺从来没兑现过，`i` 那颗按键也就永远读不到正文
/// （日志里紧接着的那行 `biography NOT READ (0 char)` 就是这么来的）。
///
/// 现在改成：**每一屏都重新读一次 `contentSize`**，翻到"当前这一趟的底"再继续 ——
/// 列表边滚边长，所以"底"也必须边滚边问。
@discardableResult
func eeveeMaterialiseBio(from view: UIView) -> UIView? {
    // ★★ 2026-10-11（日志 100）：**先零滚动找一遍**。卡片本来就在页面上（只是不叫
    //    `SPTArtistAboutBiographyView`），cell 通常也已经建出来了 ⇒ 不用滚、也不受"折成 0 高"影响。
    //    这一步把"扫列表"从**主路**降成**兜底** —— 以前它是主路，而它一次都没成功过
    //    （日志 100：`2 step(s) down to 603pt of 1416pt, nothing built`）。
    if let card = eeveeArtistBioCard(in: view) {
        EntityPageHeaderManager.artistBiographyAppeared(card)
        writeDebugLog(
            "[EntityPageHeader] about-artist found without scrolling — "
                + NSStringFromClass(type(of: card))
        )
        return card
    }
    guard let scroll = eeveeOutermostScroll(from: view), scroll.bounds.height > 1 else { return nil }
    let origin = scroll.contentOffset
    let step = max(120, scroll.bounds.height * 0.9)
    var offset: CGFloat = 0
    var deepest: CGFloat = 0
    var passes = 0
    var found: UIView?
    while passes < 12 {
        passes += 1
        deepest = offset
        scroll.setContentOffset(CGPoint(x: origin.x, y: offset), animated: false)
        scroll.layoutIfNeeded()
        if let bio = EntityPageHeaderManager.artistBioTarget {
            found = bio
            break
        }
        // ⚠️ 重新问一次"现在到底有多长"（见上面日志 99 那段说明）。
        let bottom = max(
            0,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        )
        guard offset < bottom else { break }
        offset = min(offset + step, bottom)
    }
    if found == nil { found = EntityPageHeaderManager.artistBioTarget }
    // ★★ 2026-10-11（日志 100）：滚完再按真机那三个名字找一次 —— 滚的过程把 cell 建出来了，
    //    但钩子（`SPTArtistAboutBiographyView`）在这一版页面上永远不会响。
    if found == nil, let card = eeveeArtistBioCard(in: view) {
        EntityPageHeaderManager.artistBiographyAppeared(card)
        found = card
    }
    // 回到用户原来的位置（不管找没找到）—— 只有真找到时，调用方才把它滚进视野。
    scroll.setContentOffset(origin, animated: false)
    writeDebugLog(
        "[EntityPageHeader] about-artist sweep — \(passes) step(s) down to"
            + " \(Int(deepest))pt of \(Int(scroll.contentSize.height))pt, "
            + (found == nil ? "nothing built" : "found it")
    )
    return found
}

/// 扫一遍列表、把"关于艺人"那一段逼出来，**顺手把正文读出来**。
///
/// ⚠️ 读文字必须和"逼出来"在**同一个主线程回合**里做：那一段是懒加载的 section，滚走之后 cell 会被
/// 回收、文字就没了（所以我们不缓存 view，缓存的是文字，见 `EntityPageHeaderManager`）。
@discardableResult
func eeveeArtistBio(from view: UIView) -> (view: UIView, text: String?)? {
    guard let bio = eeveeMaterialiseBio(from: view) else { return nil }
    // ★★ 2026-10-11（日志 100）：**先按名字精确读** —— 那一格就是
    //    `Components.UI.CreatorBiographyCard.BiographyLabel`（真机树逐字）。以前一上来就"取最长的一段"，
    //    在卡片里挑到过别的长文本，而且它压根没走到这一步（卡都没认出来）。
    if let text = eeveeArtistBioText(in: bio) { return (bio, text) }
    // ★★ 2026-10-18 第五轮：40 字那道闸是给"排除短标签"用的（"收听""已关注"那种），
    //    但日文 / 中文简介本来就短，正文可能只有二十几个字 ⇒ 40 字找不到时**再按 20 字找一次**。
    //    （卡片上那行日志会写出真正读到几个字，下一份日志就能判断这个下限合不合适。）
    // ★★ 2026-10-16（用户：「AKIR 的艺人简介**就一行几个单词**，现在是不是会**舍弃字数很少**的
    //    情况？」）：**是，被舍弃了**。上面那两道 40 → 20 把"一行几个单词"（十几字以内）整段判成
    //    "没有正文" ⇒ `i` 说没有介绍、折叠闸门（`hasCapturedBio`）也永远不开 —— 正是他报的
    //    "AKIR 的关于艺人没修好"。这里补**第三道 6 字**：卡片里最长的 ≥6 字文本就是正文
    //    （卡片里其余文字是"关于艺人""更多"这类 2~4 字的标题/按钮，6 字足够把它们筛掉）。
    return (bio, eeveeLongestText(in: bio)
        ?? eeveeLongestText(in: bio, minimum: 20)
        ?? eeveeLongestText(in: bio, minimum: 6))
}

/// 一棵子树里**最长的那段文字** —— 艺人简介就在 `SPTArtistAboutBiographyView` 的正文里
/// （`UILabel` / `UITextView` 两种都可能，取最长的那个）。
///
/// `minimum` = "短于这个字数不算正文"（页头里"收听""已关注"那些短标签会被排除掉）。
func eeveeLongestText(in root: UIView, minimum: Int = 40) -> String? {
    var best: String?
    var queue: [UIView] = [root]
    var visited = 0
    while !queue.isEmpty, visited < 300 {
        let view = queue.removeFirst()
        visited += 1
        var text: String?
        if let label = view as? UILabel { text = label.text }
        if let textView = view as? UITextView { text = textView.text }
        if let candidate = text?.trimmingCharacters(in: .whitespacesAndNewlines),
           candidate.count >= minimum,
           candidate.count > (best?.count ?? 0) {
            best = candidate
        }
        queue.append(contentsOf: view.subviews)
    }
    return best
}

/// 往上找**最外层**的 `UIScrollView`（与 `eeveeScrollPageDown` 同一条，只是这里只取不滚）。
private func eeveeOutermostScroll(from view: UIView) -> UIScrollView? {
    var outermost: UIScrollView?
    var node: UIView? = view.superview
    var levels = 0
    while let current = node, levels < 24 {
        levels += 1
        if let scroll = current as? UIScrollView { outermost = scroll }
        node = current.superview
    }
    return outermost
}

/// 以"点一下"的方式触发 Spotify 自己的控件。**返回真正走通的那条路**（`nil` = 一条都没通）。
///
/// ## 为什么返回值是"路"而不是 Bool（这是被真机打回来的第二次）
///
/// ★★★ 2026-10-06（日志 93：**几百行** `shuffle tapped — source found`，而随机播放毫无动静）：
/// 旧版第一句是 `guard let control = control as? UIControl else { return false }` —— Spotify 的
/// shuffle / play 是 `Encore.Button` 一族（点击挂在 `UITapGestureRecognizer` 上）⇒ 这一句把转发
/// 整个吞掉；返回值又没人看 ⇒ **"日志说转发成功了、界面一动不动"**。
///
/// ★★★ 2026-10-17（用户真机第二轮：「艺人页 / 歌单页的**点击播放**按键没反应」「艺人页左边那颗
/// 应该是 `i`…但现在是歌单的**随机播放**按钮，并且点击没反应」）—— 同样的现场**又复现了**。
/// 这一版把三件事一起做掉：
///
///   ① **UIControl 也要先看有没有 target**：没有 target 的 `UIControl`（`Encore.Button` 正是
///      如此）`sendActions` 是**空转**，而旧代码会因此 `return true`，把后面那条手势路一起挡掉。
///   ② **包装层要往下钻**：按 id 找到的常常是 `ElementView<URL, Any, Any>` 那层包装
///      （本文件 `firstControl` 的注释早就写了），真控件在它里面。调用方现在统一先 `findControl`
///      钻一次，这里再补一道"子树里找手势"。
///   ③ **tap recogniser 可能挂在子树里的某个视图上**，不在我们拿到的那一层。
///
/// ⚠️ **只走通一条就返回** —— 两条都发 = 一次点击触发两次（等于没点）。
@discardableResult
func eeveeFire(_ control: UIView?) -> String? {
    guard let control else { return nil }

    // ① 真·UIControl **且确实注册了 target** ⇒ 发那一个事件（顺序按"最可能的"排）。
    if let uiControl = control as? UIControl {
        for (event, label) in eeveeFireEvents where eeveeHasTargets(uiControl, event) {
            uiControl.sendActions(for: event)
            return "UIControl.\(label)"
        }
    }

    // ② 手势：先自己，再（有界地）往下钻子树。
    if let fired = eeveeFireGesture(in: control) { return fired }

    // ③ ★★ 2026-10-10（**日志 96 是判决**）：有界地再往上看两层。
    //
    //    现场：用户**自己**点艺人页的"关于艺人"那一块，页面**真的跳走了**
    //    （`12:39:04 [PageField] restored 2 background(s) (left the page)`，而且新页面不是我们
    //    接管的三页 ⇒ 是独立的 `Creator_BiographyPageImpl.BiographyViewController`）。
    //    而我们把点击转发给 `SPTArtistAboutBiographyView` 本身时什么都不发生 ⇒ **tap 挂在包着它
    //    的那一层上**（ElementKit 的包装层），而那正是我先前**故意不找**的方向。
    //
    //    ⚠️ 两道闸门（只在"自己+子树都没有"时才走到这里，而且最多两层）：
    //      · **不碰 `UIScrollView`** —— 那上面的 tap 是"点空白关页面"那一类；
    //      · **不碰比目标宽太多的容器** —— 免得点到整页/整段那一级。
    var ancestor = control.superview
    var levels = 0
    while let current = ancestor, levels < 2 {
        let tooWide = current.bounds.width > control.bounds.width * 1.6 + 40
        if !tooWide, !(current is UIScrollView),
           let fired = eeveeFireRecognizers(of: current) {
            return "ancestor\(levels + 1).\(fired)"
        }
        ancestor = current.superview
        levels += 1
    }
    return nil
}

/// **比 `eeveeFire` 更宽一档的转发** —— 只给艺人页那颗 `i`（"关于艺人"）用。
///
/// ★★ 2026-10-18 第二轮（用户：「点击 i 按键不会跳转到艺人介绍」）：`SPTArtistAboutBiographyView`
/// **自己对点击没反应** —— 日志 96 已经验过：用户**自己**点那一块能跳到 `BiographyViewController`，
/// 我们把点击转发给这一块本身却什么都不发生 ⇒ 处理它的那一层在**祖先链**上；而且那一层很可能是
/// **cell 的选中回调**（`UICollectionViewCell` 的点击不是 `UIGestureRecognizer`，`eeveeFire` 那三条路
/// 一条都碰不到它）。
///
/// 三档，走通一档就返回：
///   ① 先按 `eeveeFire` 的老三档（自己 → 子树 → 上两层）；
///   ② **再往上走 6 层**找 tap（闸门照旧：不碰 `UIScrollView` / `UICollectionView` / `UITableView`，
///      也不碰比目标宽太多的容器）；
///   ③ 祖先链上有 `UICollectionViewCell` / `UITableViewCell` 就走**它的选中回调** ——
///      这正是真人点一下走的那条路。
@discardableResult
func eeveeFireWide(_ view: UIView?) -> String? {
    guard let view else { return nil }
    if let fired = eeveeFire(view) { return fired }

    var node: UIView? = view.superview
    var levels = 0
    while let current = node, levels < 6 {
        if current is UIScrollView || current is UICollectionView || current is UITableView { break }
        let tooWide = current.bounds.width > view.bounds.width * 1.8 + 60
        if !tooWide, let fired = eeveeFireRecognizers(of: current) {
            return "wide.ancestor\(levels + 1).\(fired)"
        }
        node = current.superview
        levels += 1
    }
    return eeveeSelectAncestorCell(of: view)
}

/// 顺着祖先链找 `UICollectionViewCell` / `UITableViewCell`，**替用户"选中"它**。
///
/// ⚠️ 调的是 delegate 的可选方法（`collectionView(_:didSelectItemAt:)` / `tableView(_:didSelectRowAt:)`），
/// 也就是真人点一下走的那一条；`selectItem` 只是把选中态一起做掉（Spotify 的 cell 多半自己画高亮）。
private func eeveeSelectAncestorCell(of view: UIView) -> String? {
    var node: UIView? = view
    var levels = 0
    while let current = node, levels < 10 {
        if let cell = current as? UICollectionViewCell {
            if let collection = eeveeEnclosingCollectionView(of: cell),
               let indexPath = collection.indexPath(for: cell) {
                collection.selectItem(at: indexPath, animated: false, scrollPosition: [])
                guard let delegate = collection.delegate else {
                    return "cell.selected(\(indexPath.section),\(indexPath.item)) but no delegate"
                }
                delegate.collectionView?(collection, didSelectItemAt: indexPath)
                return "cell.didSelectItemAt(\(indexPath.section),\(indexPath.item))"
            }
        }
        if let cell = current as? UITableViewCell {
            if let table = eeveeEnclosingTableView(of: cell), let indexPath = table.indexPath(for: cell) {
                table.selectRow(at: indexPath, animated: false, scrollPosition: .none)
                guard let delegate = table.delegate else {
                    return "row.selected(\(indexPath.section),\(indexPath.row)) but no delegate"
                }
                delegate.tableView?(table, didSelectRowAt: indexPath)
                return "row.didSelectRowAt(\(indexPath.section),\(indexPath.row))"
            }
        }
        node = current.superview
        levels += 1
    }
    return nil
}

private func eeveeEnclosingCollectionView(of view: UIView) -> UICollectionView? {
    var node: UIView? = view.superview
    while let current = node {
        if let collection = current as? UICollectionView { return collection }
        node = current.superview
    }
    return nil
}

private func eeveeEnclosingTableView(of view: UIView) -> UITableView? {
    var node: UIView? = view.superview
    while let current = node {
        if let table = current as? UITableView { return table }
        node = current.superview
    }
    return nil
}

/// `sendActions` 候选事件。**顺序有讲究**：`primaryActionTriggered` 是 iOS 14+ 那个"主操作"
/// 事件，Spotify 的 Encore 按钮注册的多半是它；`touchUpInside` 是经典那颗。
private let eeveeFireEvents: [(UIControl.Event, String)] = [
    (.primaryActionTriggered, "primaryActionTriggered"),
    (.touchUpInside, "touchUpInside"),
    (.touchDown, "touchDown"),
]

private func eeveeHasTargets(_ control: UIControl, _ event: UIControl.Event) -> Bool {
    control.allTargets.contains { target in
        !(control.actions(forTarget: target, forControlEvent: event)?.isEmpty ?? true)
    }
}

/// 读手势识别器的 `_targets` 再调它的 target/action —— pw 与我们的标签栏都用这一招
/// （`TabBarSystemGlass` 转发点击走的就是它，真机上已验证可行）。
///
/// ⚠️ `_targets` 是私有键，所以**先用 `responds(to:)` 确认两个键都在**才去 KVC：KVC 碰未知 key 是
/// **抛异常**（不是返回 nil），那会直接崩。
///
/// 广度优先、有界（`nodeLimit`）：命中的越浅越可能就是那颗按钮，所以不深挖。
private func eeveeFireGesture(in root: UIView, depthLimit: Int = 6, nodeLimit: Int = 200) -> String? {
    var queue: [(view: UIView, depth: Int)] = [(root, 0)]
    var visited = 0
    while !queue.isEmpty, visited < nodeLimit {
        let (view, depth) = queue.removeFirst()
        visited += 1
        if let fired = eeveeFireRecognizers(of: view) {
            return depth == 0 ? "gesture.\(fired)" : "gesture.sub\(depth).\(fired)"
        }
        guard depth < depthLimit else { continue }
        for sub in view.subviews { queue.append((sub, depth + 1)) }
    }
    return nil
}

private func eeveeFireRecognizers(of view: UIView) -> String? {
    let targetKey = NSSelectorFromString("target")
    let actionKey = NSSelectorFromString("action")
    for recognizer in view.gestureRecognizers ?? [] where recognizer is UITapGestureRecognizer {
        guard let pairs = recognizer.value(forKey: "_targets") as? [AnyObject] else { continue }
        for pair in pairs {
            guard let object = pair as? NSObject,
                  object.responds(to: targetKey), object.responds(to: actionKey),
                  let target = object.value(forKey: "target") as? NSObject,
                  let name = object.value(forKey: "action") as? String else { continue }
            let selector = NSSelectorFromString(name)
            guard target.responds(to: selector) else { continue }
            _ = target.perform(selector, with: recognizer)
            return "\(NSStringFromClass(type(of: target))).\(name)"
        }
    }
    return nil
}

/// 这颗源控件**现在是不是"开"态**（随机播放已开 / 已关注）。
///
/// ★★ 2026-10-17（用户：「（关注）功能正常。但是如果艺人已经关注了，它应该是有**绿色描边**的，
/// 但现在没有」）：旧版只有 `(source as? UIControl)?.isSelected` 一条判据 —— 而按 id 找到的
/// 常常是 `ElementView<…>` **包装层**（`isSelected` 恒假），于是**永远不变绿**。
/// `firstControl` 的注释里逐字写着这件事，但 Follow 那颗当时没走它。
///
/// 这里把三条能拿到的信号都试一遍，从最标准到最兜底：
///   ① `UIControl.isSelected`；② `accessibilityTraits` 里的 `.selected`（App 暴露开关态的标准做法）；
///   ③ **文字里的"已关注"标记**（`Follow` 是文字按钮：关注 ↔ 已关注 / Follow ↔ Following）。
///
/// ⚠️ 第 ③ 条是按本仓库已有的两套语言写的（与 `am_header_play` 那类一样直接落在代码里）。
/// 真实文本会由 `eeveeOnSignals` 打进日志 —— 下一份日志能直接告诉我们哪一条信号真的会变，
/// 到时候再收窄/扩宽，别靠猜。
func eeveeIsOn(_ view: UIView?) -> Bool {
    guard let view else { return false }
    if let control = view as? UIControl, control.isSelected { return true }
    if view.accessibilityTraits.contains(.selected) { return true }
    let text = eeveeControlText(of: view)
    return eeveeFollowingMarkers.contains { text.localizedCaseInsensitiveContains($0) }
}

private let eeveeFollowingMarkers = ["已关注", "已追蹤", "Following", "Siguiendo", "Abonniert", "已關注"]

/// 把一条源控件上的**所有**状态信号拼成一行（只进日志，不参与判断）。
func eeveeOnSignals(_ view: UIView?) -> String {
    guard let view else { return "source missing" }
    let selected = (view as? UIControl)?.isSelected ?? false
    let trait = view.accessibilityTraits.contains(.selected)
    let text = eeveeControlText(of: view)
    return "isSelected=\(selected) selectedTrait=\(trait)"
        + " label=\"\(view.accessibilityLabel ?? "-")\" text=\"\(text)\""
}

/// 这颗控件子树里第一段非空文字（`Follow` 那种文字按钮的"关注/已关注"就在里面）。
func eeveeControlText(of root: UIView) -> String {
    var queue: [UIView] = [root]
    var visited = 0
    while !queue.isEmpty, visited < 200 {
        let view = queue.removeFirst()
        visited += 1
        if let label = view as? UILabel, let text = label.text, !text.isEmpty { return text }
        if let button = view as? UIButton,
           let text = button.title(for: .normal) ?? button.title(for: .selected), !text.isEmpty {
            return text
        }
        if view !== root, let text = view.accessibilityLabel, !text.isEmpty, view is UIControl { return text }
        queue.append(contentsOf: view.subviews)
    }
    return ""
}

/// 从被藏起来的控件上取字形：它自己/子树里的 `UIImageView.image`，或 `UIButton` 的 image。
func eeveeGlyph(of control: UIView?) -> UIImage? {
    guard let control else { return nil }
    if let button = control as? UIButton {
        return button.image(for: .normal) ?? button.image(for: .selected) ?? button.image(for: .highlighted)
    }

    var queue: [UIView] = control.subviews
    var visited = 0
    while !queue.isEmpty, visited < 200 {
        let view = queue.removeFirst()
        visited += 1
        if let imageView = view as? UIImageView, let image = imageView.image { return image }
        queue.append(contentsOf: view.subviews)
    }
    return nil
}

// MARK: - 页头里那三颗控件

/// 「镜像按钮」：字形取自被藏起来的 Spotify 控件，点击转发给它。
final class EntityPageHeaderButton: UIControl {

    private let glyphView = UIImageView()
    private weak var source: UIView?
    /// 那圈玻璃（44pt 圆，见 `layoutSubviews`）。
    private var glass: UIVisualEffectView?

    /// 源控件取不到字形时的兜底（SF Symbol）。
    ///
    /// ★ 2026-10-13（艺人页）：**换兜底字形要立刻生效** —— 艺人页那一颗是 Follow（文字按钮，
    /// `eeveeGlyph` 永远拿不到字形），"未关注 / 已关注"就是靠这里换一对 SF Symbol 表达的；
    /// 而 `feed(from:)` 在"源没变"时会早退，所以只能在这一侧的 didSet 里补。
    var fallbackGlyph: UIImage? {
        didSet {
            // ★★ 2026-10-17（用户：「艺人页左边应该是一个 `i`…但现在是歌单的**随机播放**按钮」）：
            //    **显式设的兜底字形必须立刻生效**。旧版这里是 `guard glyphView.image == nil` ——
            //    而 `applyToArtistPage` 先 `updateRow`（那一刻 leading 还是 shuffle ⇒ `feed` 取到
            //    shuffle 的字形），随后才 `setLeadingGlyph(info.circle)`，于是被这一句**挡掉**
            //    ⇒ 那颗按钮永远是随机播放的样子（功能也没接对，见那边的说明）。
            //    顺序上不会误伤：`updateRow` 里兜底是**先设、后 feed**，真字形仍然赢。
            guard let fallbackGlyph else { return }
            glyphView.image = fallbackGlyph.withRenderingMode(.alwaysTemplate)
        }
    }
    /// ★★ 2026-10-16（用户：「播放按键右边的**添加艺人**显示有问题，改成中空的五角星（和 AM 一样）……
    ///    点击之后（即收藏艺人之后）变成现在的绿色勾」）：
    /// **强制用兜底字形**，不采用 Spotify 那颗按钮自己的图。只给艺人页的 Follow 用，
    /// 而且只在**未关注**那一档打开 —— 那颗在未关注时是"＋人"，用户要的是 AM 那种中空五角星；
    /// 已关注时保持原样（Spotify 自己的绿勾，取不到才用 `checkmark` 兜底）。
    var prefersFallbackGlyph = false {
        didSet {
            // 与 `fallbackGlyph` 的 didSet 同一条理由：`feed(from:)` 在"源没变"时会早退，
            // 所以显式设的东西必须**当场**落到 `glyphView` 上。
            guard prefersFallbackGlyph, let fallbackGlyph else { return }
            glyphView.image = fallbackGlyph.withRenderingMode(.alwaysTemplate)
        }
    }
    /// 关态颜色 / 开态颜色（开态按源控件的 `isSelected` 判断）。
    var glyphColor: UIColor = .label
    var onGlyphColor: UIColor = .systemGreen
    /// 这颗按钮的**身份**（`shuffle` / `trailing`）—— 只进日志：用户报"右边那颗和别的按钮重合"时，
    /// 日志里必须能分清他说的是哪一颗（见 `updateRow` 与 `tapped`）。
    var role = "side button"

    /// ★★ 2026-10-17（用户：「点击后**跳转到关于艺人模块**」）：这一颗点下去要**先把源滚进视野**
    /// 再转发 —— 艺人页的"关于"（`SPTArtistAboutBiographyView`）在列表很下面，只转发不滚动的话
    /// 用户什么都看不见。由调用方按需打开。
    var scrollsSourceIntoView = false

    /// ★★ 2026-10-18 第二轮（用户：「点击 i 按键不会跳转到艺人介绍」）：**要不要用更宽一档的转发**
    /// （`eeveeFireWide`：再往上 6 层找 tap + cell 的选中回调）。只有艺人页那颗 `i` 打开 ——
    /// 别的按钮（play / shuffle / follow）本来就能用老三档走通，放宽只会多出误触的机会。
    var firesDeep = false

    /// ★★ 2026-10-18 第三轮（用户：「要不点击 i 之后**不要 spotify 自己的了**，把原本的 spotify 的
    /// 关于艺人 给去掉，**我们自己搞**」）：这一颗点下去**不转发给 Spotify**，改弹我们自己的
    /// 「艺人介绍」（`ArtistBioSheet`）—— 正文从 Spotify 那一块里读走（`eeveeLongestText`），
    /// 而列表里那一段已经被折成 0 高（`EntityPageSectionDrop.aboutArtistFragment`），页面上不留重复。
    var presentsOwnBio = false

    /// ★★ 2026-10-17：**真正要转发的目标**（可以不是 `source`）。
    ///
    /// 艺人页左边那颗 `i` 就是这样：`source` 只负责"这颗按钮显示什么字形"（找不到"关于艺人"时
    /// 退回 shuffle 只是为了让按钮**有东西可显示**），而**动作**必须落在"关于艺人"上 ——
    /// 目标还没有时**宁可只往下滚一屏、也绝不退回去做随机播放**（图标说 `i`、动作却是随机，
    /// 正是用户上一轮报的那件事）。
    weak var fireTarget: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        glyphView.contentMode = .scaleAspectFit
        glyphView.isUserInteractionEnabled = false
        // ★ 2026-10-13（用户：「旁边的按键小了点」）：两侧按钮嵌一圈玻璃圆（pw 的 `SGRGlassInside`
        //   用的就是 `SGRGlassCircleSize = 44`）—— 字形 22pt 落在 44pt 玻璃圆里，分量才对得上
        //   中间那颗胶囊。
        _ = eeveeInsertGlass(in: self, interactive: false)
        glass = subviews.first as? UIVisualEffectView
        addSubview(glyphView)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// 认一个 Spotify 的控件：记引用、取字形、取标签（顺带把无障碍名字带过来）。
    ///
    /// ★ 2026-10-13（性能）：**同一个源控件只取一次字形** —— 这一拍在页头折叠的每一帧都会走到，
    /// 而"取字形"要遍历源控件的子树、还会 `withRenderingMode` 造一张新图。
    func feed(from control: UIView?) {
        let sameSource = (source as? NSObject) === (control as? NSObject)
        source = control
        accessibilityLabel = control?.accessibilityLabel ?? accessibilityLabel
        refreshTint()
        guard !sameSource || glyphView.image == nil else { return }

        let glyph = prefersFallbackGlyph ? fallbackGlyph : (eeveeGlyph(of: control) ?? fallbackGlyph)
        glyphView.image = glyph?.withRenderingMode(.alwaysTemplate)
    }

    private func refreshTint() {
        let isOn = eeveeIsOn(source)
        glyphView.tintColor = isOn ? onGlyphColor : glyphColor
        // ★★ 2026-10-17（用户：「如果艺人已经关注了，它应该是有**绿色描边**的，但现在没有」）：
        //    Spotify 自己的"已关注"就是**绿字 + 绿描边**，AM 那颗收藏键也是描边态
        //    ⇒ 把那圈玻璃的边描上（玻璃本身就是那颗 44pt 圆，圆角在 `layoutSubviews` 里跟着走）。
        if let glass {
            let width: CGFloat = isOn ? 1.5 : 0
            if glass.layer.borderWidth != width {
                glass.layer.borderWidth = width
                glass.layer.borderColor = isOn ? onGlyphColor.cgColor : nil
            }
        }
    }

    @objc private func tapped() {
        refreshTint()

        // ★★ 2026-10-18 第三轮（用户：「点击 i 之后不要 spotify 自己的了 … 我们自己搞」）：
        //    艺人页这颗 `i` 现在**弹我们自己的"艺人介绍"**，不再往 Spotify 那一块转发。
        if presentsOwnBio {
            let name = EntityPageHeaderManager.currentArtistName
            // ★★ 2026-10-11（日志 100）：**读到过一次就不再扫列表** —— 扫列表会滚一遍、
            //    把沿途 cell 全建出来；用户连点四次就是四次整页扫描（日志 100 的 03:51:41-44）。
            //
            // ★★ 2026-10-16（用户：「如果是 Nana 这种正常的，需要往下划到原本的 艺人介绍 才有，
            //    并且有很明显的卡顿」）：这里原来退到 `eeveeArtistBio(from: self)`，而它内部是
            //    `eeveeMaterialiseBio` —— **会把列表一路滚到底再滚回来**（最多 12 步），
            //    那一下卡顿就是这个。现在**零滚动**：先看缓存，再试"页面上已经建出来的那张卡"
            //    （`eeveeArtistBioCard` 只做有界搜索），读到就存进 `bioTexts`
            //    （`artistBiographyAppeared` 内部读走 + 作废一次布局 ⇒ 折叠闸门这才打开），
            //    仍然读不到就照实弹"没有可读的介绍" —— 那张卡片自己还会盯 6 秒补看
            //    （`ArtistBioSheet.watchForNativeText`），不再拿"滚一趟列表"去换它。
            var text = EntityPageHeaderManager.cachedBioText(for: name)
            if text == nil, let card = eeveeArtistBioCard(in: self) {
                EntityPageHeaderManager.artistBiographyAppeared(card)
                text = EntityPageHeaderManager.cachedBioText(for: name)
            }
            ArtistBioSheet.present(
                name: name,
                text: text,
                colour: EntityPageAppearance.currentFieldColour
            )
            return
        }

        // 转发目标：**优先 `fireTarget`**；只有没开"先滚进视野"这一档时才退回 `source`
        // （否则目标缺失时就会去点那颗只负责显示字形的 shuffle —— 见 `fireTarget` 的说明）。
        var target = fireTarget ?? (scrollsSourceIntoView ? nil : source)
        if target == nil, scrollsSourceIntoView {
            // ★★ 2026-10-18 第三轮（用户：「按下 i 之后还是没有跳转到 艺人介绍」）：
            //    目标**还没建出来** ⇒ 先把列表扫一遍把它逼出来（见 `eeveeMaterialiseBio`），
            //    不再只是"滚一屏"（那要用户连点好几次，而且滚过头就找不回来了）。
            target = eeveeMaterialiseBio(from: self)
        }
        var scrolled = false
        var path = "NOTHING (no target, no tap recogniser)"
        if let target {
            if scrollsSourceIntoView { scrolled = eeveeScrollIntoView(target) }
            // ★★ 2026-10-18：那颗 `i` 走"宽转发"（祖先链上的 tap + cell 的选中回调），见 `eeveeFireWide`。
            path = (firesDeep ? eeveeFireWide(target) : eeveeFire(target)) ?? path
        } else if scrollsSourceIntoView {
            // 目标那一段还没建出来（懒加载）⇒ 把页面往下滚一屏让它出现，**不转发**。
            scrolled = eeveeScrollPageDown(from: self)
            path = scrolled
                ? "NOTHING yet (the target is not built) — scrolled the page a screen to build it"
                : "NOTHING (the target is not built and the page has nothing to scroll)"
        }

        // ⚠️ 不要在这些字符串**插值里写引号**：`swift_member_check.py` 的去字符串扫描器会提前
        //    收尾、把剩下的英文当裸标识符误报（2026-10-17 踩过，见 `EntityPageStatusBar`）。先拼好。
        let kind = (target ?? source).map { NSStringFromClass(type(of: $0)) } ?? "-"
        let isControl = (target ?? source) as? UIControl != nil
        let signals = eeveeOnSignals(source)
        writeDebugLog(
            "[EntityPageHeader] \(role) tapped — class \(kind), uicontrol=\(isControl),"
                + " scrolledIntoView=\(scrolled), fired: \(path); \(signals)"
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 玻璃圆居中（`glassCircle`，比按钮矮 4pt 留出边距），字形固定 `glyphSide` 落在它中间。
        let circle = min(EntityPageHeaderMetrics.glassCircle, min(bounds.width, bounds.height))
        let glassFrame = CGRect(
            x: round((bounds.width - circle) / 2),
            y: round((bounds.height - circle) / 2),
            width: circle,
            height: circle
        )
        if let glass {
            if glass.frame != glassFrame { glass.frame = glassFrame }
            glass.layer.cornerRadius = circle / 2
        }

        let side = EntityPageHeaderMetrics.glyphSide
        glyphView.frame = CGRect(
            x: round((bounds.width - side) / 2),
            y: round((bounds.height - side) / 2),
            width: side,
            height: side
        )
    }
}

/// 白色的 Play 胶囊（Music app 那颗）。字形同样镜像 Spotify 的 Play。
final class EntityPageHeaderPlay: UIControl {

    private let glyphView = UIImageView()
    private let wordLabel = UILabel()
    private weak var source: UIView?
    /// 胶囊里那片玻璃（见 `init`）。
    private var glass: UIVisualEffectView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // ★ 2026-10-13（用户看真机：「播放那个不是液态玻璃」）：pw 的 `SGRPlayCapsule` 是
        //   **白底 + 里面再嵌一片玻璃**（v0.21.1 的 `SGRGlassCapsuleInside(self, &kCapsuleGlassKey,
        //   bounds.size, YES)`，interactive 打开），所以这里照做：白底留一点透明（让玻璃有东西
        //   可折射：底下的封面与取色底），玻璃嵌在最底层，字形与文字保持黑色（浅玻璃上才读得清）。
        //   iOS 26 以下拿不到 `UIGlassEffect` 时退浅色材质 —— 见 `eeveeMakeLightGlassView`。
        backgroundColor = UIColor.white.withAlphaComponent(0.9)
        layer.masksToBounds = true
        _ = eeveeInsertGlass(in: self, interactive: true)
        glass = subviews.first as? UIVisualEffectView

        glyphView.contentMode = .scaleAspectFit
        glyphView.tintColor = .black
        glyphView.image = UIImage(systemName: "play.fill")?.withRenderingMode(.alwaysTemplate)
        glyphView.isUserInteractionEnabled = false
        addSubview(glyphView)

        wordLabel.text = "am_header_play".localized
        wordLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        wordLabel.textColor = .black
        wordLabel.textAlignment = .center
        addSubview(wordLabel)

        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = wordLabel.text
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func feed(from control: UIView?) {
        let sameSource = (source as? NSObject) === (control as? NSObject)
        source = control
        // 同一个源控件就不重复取字形（见上面 `EntityPageHeaderButton.feed` 的说明）。
        guard !sameSource || glyphView.image == nil else { return }
        if let glyph = eeveeGlyph(of: control) {
            glyphView.image = glyph.withRenderingMode(.alwaysTemplate)
        }
    }

    /// ★★ 2026-10-17：**长按 = 随机播放**。
    ///
    /// 左边那颗位置让给 AM 的 `i`（"关于艺人"）之后，随机播放就没地方点了 —— 用户早就问过
    /// 「左边还是点不了的随机播放上哪点去」（见 `HANDOFF_2026-10-13_..._EntityPages-AM.md` §四.2），
    /// 当时定下的方案就是这一条。长按识别成功会**取消**这次触摸 ⇒ `touchUpInside` 不会跟着发，
    /// 所以"轻点 = 播放、长按 = 随机"不会互相打架。
    private weak var longPressSource: UIView?
    private var longPress: UILongPressGestureRecognizer?

    func feedLongPress(_ control: UIView?) {
        longPressSource = control
        guard longPress == nil else { return }
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed))
        press.minimumPressDuration = 0.4
        addGestureRecognizer(press)
        longPress = press
    }

    @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let path = eeveeFire(longPressSource) ?? "NOTHING (no target, no tap recogniser)"
        writeDebugLog("[EntityPageHeader] play long-pressed → shuffle fired: \(path)")
    }

    @objc private func tapped() {
        let path = eeveeFire(source) ?? "NOTHING (no target, no tap recogniser)"
        let kind = source.map { NSStringFromClass(type(of: $0)) } ?? "-"
        writeDebugLog("[EntityPageHeader] play capsule tapped — class \(kind), fired: \(path)")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        // 玻璃铺满整颗（圆角跟形状走）。
        if let glass {
            if glass.frame != bounds { glass.frame = bounds }
            glass.layer.cornerRadius = bounds.height / 2
        }

        // ★ 2026-10-13（照 AM）：**形状决定形态**。布局那边给的是正方形（`playSide`，84pt）时，
        //   它就是 AM 那颗"大圆 ▶"——**没有"播放"两个字**；给的是扁的（旧的 148×48）时，
        //   还是 pw 那颗"▶ 播放"胶囊。两种形态共用这一份代码，不用开关、也不会两处漂。
        let isCircle = abs(bounds.width - bounds.height) < 8
        if wordLabel.isHidden != isCircle { wordLabel.isHidden = isCircle }

        // 形状决定底色：AM 那颗是**纯白**（照片 113 里我们这颗是"白 90% + 玻璃" ⇒ 在亮照片上
        // 灰得看不出来）；胶囊形态仍留一点透明，好让底下的封面透出来（pw 的做法）。
        let wanted: UIColor = isCircle ? .white : UIColor.white.withAlphaComponent(0.9)
        if backgroundColor != wanted { backgroundColor = wanted }
        glass?.alpha = isCircle ? 0 : 1

        // [字形][6pt][Play] 整体居中（圆形态里只剩字形，自然就是居中的）
        // ★★ 2026-10-06（用户：「播放按钮里面的按键**不够大**」）：圆形态 44 → **52**
        //   （AM 那颗 ▶ 占到圆的一半以上），胶囊形态仍是 24。
        let glyphSide: CGFloat = isCircle ? 52 : 24
        let glyphWidth = glyphView.image == nil ? 0 : glyphSide
        let spacing: CGFloat = (!isCircle && glyphWidth > 0) ? 6 : 0
        let wordWidth = isCircle ? 0 : ceil(wordLabel.sizeThatFits(
            CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        ).width)
        let total = glyphWidth + spacing + wordWidth
        let startX = round((bounds.width - total) / 2)

        glyphView.frame = CGRect(x: startX, y: round((bounds.height - glyphSide) / 2),
                                 width: glyphWidth, height: glyphSide)
        wordLabel.frame = CGRect(x: startX + glyphWidth + spacing, y: 0,
                                 width: wordWidth, height: bounds.height)
    }
}

// MARK: - 页头本体

/// 那一块文字与按钮。输入永远是"文本 + Spotify 自己的控件"，自己不持有任何 Spotify 状态。
final class EntityPageHeaderView: UIView {

    /// ★ 2026-10-13（AM 的标题**很大** —— photo_1 里 `Abel Tesfaye` 一个人占掉大半个屏宽）：
    /// 22 → **34**，缩放基准同时从 `.title2` 换成 `.largeTitle`（`makeLabel` 走 `UIFontMetrics`，
    /// 基准不换的话辅助功能字号下的比例会不对）。
    private let titleLabel = EntityPageHeaderView.makeLabel(
        style: .largeTitle, size: 34, weight: .bold, color: .label, lines: 2, alignment: .center
    )
    private let creatorLabel = EntityPageHeaderView.makeLabel(
        style: .body, size: 17, weight: .regular, color: .secondaryLabel, lines: 1, alignment: .center
    )
    private let lengthLabel = EntityPageHeaderView.makeLabel(
        style: .footnote, size: 13, weight: .regular, color: .tertiaryLabel, lines: 1, alignment: .center
    )
    private let aboutLabel = EntityPageHeaderView.makeLabel(
        style: .footnote, size: 13, weight: .regular, color: .secondaryLabel, lines: 2, alignment: .natural
    )

    private let shuffleButton = EntityPageHeaderButton()
    private let playButton = EntityPageHeaderPlay()
    private let trailingButton = EntityPageHeaderButton()

    /// 创建者那一行背后那个 Spotify 控件（点了打开作者页）——被藏起来、只负责响应。
    private weak var creatorLink: UIView?

    private static func makeLabel(
        style: UIFont.TextStyle, size: CGFloat, weight: UIFont.Weight,
        color: UIColor, lines: Int, alignment: NSTextAlignment
    ) -> UILabel {
        let label = UILabel()
        label.font = UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = lines
        label.textAlignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.isHidden = true
        return label
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        for label in [titleLabel, creatorLabel, lengthLabel, aboutLabel] { addSubview(label) }
        titleLabel.accessibilityTraits = .header

        shuffleButton.fallbackGlyph = UIImage(systemName: "shuffle")
        // 关态用主色（Spotify 自己那颗关态是灰的，挨着白色 Play 像"坏了"）；开态给强调色，
        // 这样"随机播放已开"仍然看得出来。
        shuffleButton.glyphColor = .label
        shuffleButton.onGlyphColor = .systemGreen
        trailingButton.glyphColor = .label

        for button in [shuffleButton, playButton, trailingButton] {
            button.isHidden = true
            button.accessibilityIdentifier = "eevee-entity-header-button"
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: 输入

    /// 文本变了才重排。返回是否变了（调用方用它决定要不要再走一遍）。
    @discardableResult
    func update(title: String, creator: String, length: String, about: String) -> Bool {
        var changed = false
        changed = setText(titleLabel, title) || changed
        changed = setText(creatorLabel, creator) || changed
        changed = setText(lengthLabel, length) || changed
        changed = setText(aboutLabel, about) || changed
        if changed { setNeedsLayout() }
        return changed
    }

    private func setText(_ label: UILabel, _ text: String) -> Bool {
        if (label.text ?? "") == text { return false }
        label.text = text
        label.isHidden = text.isEmpty
        return true
    }

    /// 三颗按钮各认一个 Spotify 控件；`nil` = 那颗不显示。
    ///
    /// - Parameter trailingPrefersFallback: 右那颗**只用兜底字形**（见 `prefersFallbackGlyph`）——
    ///   艺人页未关注时要用中空五角星，不能采用 Spotify 那颗自己的"＋人"图。
    func updateRow(
        shuffle: UIView?,
        play: UIView?,
        trailing: UIView?,
        trailingFallback: UIImage?,
        trailingPrefersFallback: Bool = false
    ) {
        // ★ 2026-10-13：给两颗按钮**标身份** —— 日志 89 只有一行 `header button tapped (source found)`，
        //   分不出用户点的是左边那颗还是右边那颗（他报告"右边那颗和原生按钮重合"时，
        //   这一条恰恰是最该看清的）。下一份日志会写成 `tapped (role trailing, source …)`。
        shuffleButton.role = "shuffle"
        trailingButton.role = "trailing"
        trailingButton.fallbackGlyph = trailingFallback
        trailingButton.prefersFallbackGlyph = trailingPrefersFallback
        shuffleButton.feed(from: shuffle)
        if let play { playButton.feed(from: play) }
        trailingButton.feed(from: trailing)

        let pairs: [(UIControl, Bool)] = [
            (shuffleButton, shuffle != nil),
            (playButton, play != nil),
            (trailingButton, trailing != nil),
        ]
        for (control, shown) in pairs where control.isHidden == shown {
            control.isHidden = !shown
            setNeedsLayout()
        }
    }

    /// ★★ 2026-10-17：**长按播放键 = 随机播放**（见 `EntityPageHeaderPlay.feedLongPress` 的说明）。
    /// 三个页面都接上：歌单/专辑页左边本来就是 shuffle，多一个入口无害；艺人页那颗位置让给 `i` 之后，
    /// 这里就是随机播放唯一的入口。
    func updatePlayLongPress(_ shuffle: UIView?) {
        playButton.feedLongPress(shuffle)
    }

    /// ★★ 2026-10-06（用户：「播放页左边的按钮不应该是那个 `i` 吗，还没改？」）：
    /// 左边那颗（AM 的 **Info**）在 Spotify 侧对应的是**艺人简介卡**，那颗卡上没有图标可镜像
    /// ⇒ 由调用方**显式给一个**字形（`info.circle`）。中间与右边那两颗不经过这里。
    func setLeadingGlyph(_ glyph: UIImage?) {
        shuffleButton.fallbackGlyph = glyph
    }

    /// ★★ 2026-10-17（用户：「点击（`i`）后**跳转到**关于艺人模块」）：左边那颗点下去要**先把源
    /// 滚进视野**再转发 —— 艺人页的"关于"（`SPTArtistAboutBiographyView`）在列表很下面。
    ///
    /// `target` 为 `nil`（那一块还没建出来）时**动作也不落在 `source` 上**（见 `fireTarget` 的说明）。
    func setLeadingTarget(_ target: UIView?, glyph: UIImage?) {
        shuffleButton.fireTarget = target
        shuffleButton.fallbackGlyph = glyph
        shuffleButton.scrollsSourceIntoView = true
        // ★★ 2026-10-18：这一颗（艺人页的 `i`）要**宽转发** —— 见 `eeveeFireWide` 那段。
        shuffleButton.firesDeep = true
        // ★★ 2026-10-18 第三轮：而且它**不转发**了 —— 弹我们自己的那张（见 `presentsOwnBio`）。
        shuffleButton.presentsOwnBio = true
    }

    /// 创建者那一行可点（点开作者页）：`control` 是 Spotify 自己那个按钮，被藏着只负责响应。
    func updateCreatorLink(_ control: UIView?) {
        creatorLink = control
        let live = control != nil
        guard creatorLabel.isUserInteractionEnabled != live else { return }
        creatorLabel.isUserInteractionEnabled = live
        creatorLabel.accessibilityTraits = live ? .button : .staticText
        guard live, creatorLabel.gestureRecognizers?.isEmpty ?? true else { return }
        creatorLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(creatorTapped)))
    }

    @objc private func creatorTapped() {
        _ = eeveeFire(creatorLink)
    }

    // MARK: 布局（贴底排）

    /// 内容从标题顶到描述底的高度。`apply` 用它算"封面该伸到哪"。
    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        let text = max(0, width - 2 * EntityPageHeaderMetrics.side)
        var height: CGFloat = 0
        var previous: UILabel?

        for label in [titleLabel, creatorLabel, lengthLabel] where !label.isHidden {
            if let previous { height += previous === creatorLabel ? 4 : 2 }
            height += ceil(label.sizeThatFits(CGSize(width: text, height: .greatestFiniteMagnitude)).height)
            previous = label
        }
        if previous != nil { height += EntityPageHeaderMetrics.rowAbove }
        // ★ 2026-10-13（照 AM）：按钮行的高度取三颗里**最高**的那颗（中间那颗比两侧大一档）。
        height += max(EntityPageHeaderMetrics.rowHeight, EntityPageHeaderMetrics.playSide)
        if !aboutLabel.isHidden {
            height += EntityPageHeaderMetrics.aboutAbove
            height += ceil(aboutLabel.sizeThatFits(CGSize(width: text, height: .greatestFiniteMagnitude)).height)
        }
        return height
    }

    /// ★ 2026-10-17：**只在会缩的页头上启用**上面那条渐隐。
    ///
    /// ⚠️ 照片 124 的教训：这条本来是给**艺人页**写的（那边 `HeaderContainer` 会从 520pt 缩到 100pt
    /// 的导航栏），但我无条件打开了 —— 而歌单页的 `PL.Header` **根本不会缩**，于是某一拍
    /// `bounds.height` 还没定下来时算出的 `fade = 0` 被留在那儿，**整块页头（标题 + 三颗按钮）
    /// 就此消失**，只剩 Spotify 自己的搜索框和 pill 行露在外面。
    /// ⇒ 改成一个显式开关，只有 `applyToArtistPage` 打开它。
    var fadesWhenTight = false

    /// 贴底排时留多少（默认 `EntityPageHeaderMetrics.bottom` = 14）。
    ///
    /// ★★ 2026-10-18 第三轮（用户：「**那怎么解决艺人页的展示问题，spotify 的按键又靠上**」）：
    /// **艺人页给 0** —— AM 的姓名与那三颗比我们低约 14pt（照片 118：名字 361–403、三颗 417–494；
    /// 我们原来是 347–388 / 408–506），把整块往下挪 14pt 就对上了。专辑 / 歌单页维持 14
    /// （那两页的版式用户没提意见）。
    var contentBottom: CGFloat = EntityPageHeaderMetrics.bottom

    /// **名字（标题）上沿**在本视图坐标里的 y；没有名字时是 −1。
    ///
    /// ★★ 2026-10-18（用户：「AM 那三颗按键比 Spotify 靠下一点，所以它的渐变刚好不压到艺人名字；
    ///    Spotify 的靠上就会被压住」）：`EntityPageAppearance.ensureSharpHero` 用它把**满幅照片的渐变
    ///    收在名字上方**（`meltGap` / `meltSpanRatio`）—— AM 靠"把那一行做得更靠下"避开渐变，
    ///    我们靠这一行避开：**页头多高、Spotify 自己把那一行摆在哪，都不影响收口落点**。
    ///
    /// ⚠️ 读的是 `titleLabel.frame`，也就是**上一次 `layoutSubviews` 的结果**（本文件就是排它的地方）
    ///    ⇒ 首帧可能还是 0，那一拍 `ensureSharpHero` 会退回默认收口，下一拍就对上了（0.6s 的拍子）。
    var textTop: CGFloat { titleLabel.isHidden ? -1 : titleLabel.frame.minY }

    override func layoutSubviews() {
        super.layoutSubviews()

        // ★★ 2026-10-17（用户：「歌单页的图标似乎**没下沉**」；照片 121 是现场：那一行三颗按钮浮在
        //    **收起来的导航栏**上、和 "AKIRVTXNSHI" 叠在一起）：
        //
        //    这一整块是**贴着页头底部**排的（`y = bounds.height - bottom - contentHeight`），而页头会随
        //    滚动从 520pt 缩到 100pt 的导航栏 ⇒ 内容放不下时 `y` 变成负数，标题与按钮就**溢出到页头
        //    上方**，正好压在 Spotify 自己的导航栏上 ✗。
        //
        //    ⇒ 页头矮到装不下这一块时，它整体**渐隐让位**（AM 里就是"跟着页头一起滚走"）：
        //      `room ≥ 32pt` 全亮、`room ≤ 0` 全隐、中间线性。用 `alpha` 而不是 `isHidden`，
        //      免得折叠过程中一闪一闪。
        if fadesWhenTight {
            let needed = contentHeight(forWidth: bounds.width) + contentBottom
            let room = bounds.height - needed
            let fade = max(0, min(1, room / 32))
            if alpha != fade { alpha = fade }
        } else if alpha != 1 {
            alpha = 1
        }

        let width = bounds.width
        let text = max(0, width - 2 * EntityPageHeaderMetrics.side)
        var y = round(bounds.height - contentBottom - contentHeight(forWidth: width))

        var previous: UILabel?
        for label in [titleLabel, creatorLabel, lengthLabel] where !label.isHidden {
            if let previous { y += previous === creatorLabel ? 4 : 2 }
            let height = ceil(label.sizeThatFits(CGSize(width: text, height: .greatestFiniteMagnitude)).height)
            label.frame = CGRect(x: EntityPageHeaderMetrics.side, y: y, width: text, height: height)
            y += height
            previous = label
        }
        if previous != nil { y += EntityPageHeaderMetrics.rowAbove }

        // Play 始终在页面正中，另两颗挂在它两侧 —— 少一颗也不动位置。
        //
        // ★ 2026-10-13（照 AM）：中间那颗**大一档**（84 vs 两侧 56），三颗要**圆心同高**
        //   ⇒ 中间那颗往上抬 `(big - side) / 2`，两侧才与它的圆心齐平。
        let side = EntityPageHeaderMetrics.rowHeight
        let big = EntityPageHeaderMetrics.playSide
        let play = CGRect(
            x: round((width - big) / 2),
            y: y - (big - side) / 2,
            width: big,
            height: big
        )
        playButton.frame = play
        shuffleButton.frame = CGRect(
            x: play.minX - EntityPageHeaderMetrics.rowSpacing - side, y: y, width: side, height: side
        )
        trailingButton.frame = CGRect(
            x: play.maxX + EntityPageHeaderMetrics.rowSpacing, y: y, width: side, height: side
        )
        y += max(side, big)

        if !aboutLabel.isHidden {
            y += EntityPageHeaderMetrics.aboutAbove
            let height = ceil(aboutLabel.sizeThatFits(CGSize(width: text, height: .greatestFiniteMagnitude)).height)
            aboutLabel.frame = CGRect(x: EntityPageHeaderMetrics.side, y: y, width: text, height: height)
        }
    }

    // MARK: 触摸

    /// 只有按钮和**创建者那行文字**吃触摸；其余位置一律还给页面
    /// （这一块和页面一样宽，全吃的话下拉就拉不动了）。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self || hit === creatorLabel { return creatorHit(point) }
        return hit
    }

    private func creatorHit(_ point: CGPoint) -> UIView? {
        guard creatorLabel.isUserInteractionEnabled, !creatorLabel.isHidden else { return nil }
        let size = creatorLabel.sizeThatFits(
            CGSize(width: creatorLabel.bounds.width, height: .greatestFiniteMagnitude)
        )
        let word = CGRect(
            x: round(creatorLabel.frame.midX - size.width / 2),
            y: creatorLabel.frame.minY,
            width: min(size.width, creatorLabel.frame.width),
            height: creatorLabel.frame.height
        ).insetBy(dx: -8, dy: -6)
        return word.contains(point) ? creatorLabel : nil
    }
}
