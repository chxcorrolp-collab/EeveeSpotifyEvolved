import Foundation
import Orion
import UIKit
import QuartzCore

/// 「Spotify 一旦往我们清过的地方重画底色，就把这次写入丢掉」。
///
/// ## 出处
///
/// 借鉴 **spoti.pw v0.21.1** 的 `Redesigned/Kit/SGRRepaint.x`（那一版是 **GPL-3.0**；
/// v0.22.0 起该仓库改为 PolyForm Strict，**那里的代码不可复制**）。它的原文：
///
/// > Keeps the areas the redesign stripped transparent when Spotify repaints them.
///
/// ```objc
/// %hook CALayer
/// - (void)setBackgroundColor:(CGColorRef)color {
///     if (color && (…sgr_playlistRoot || sgr_albumRoot || …)) {
///         UIView *view = (UIView *)self.delegate;
///         if ([view isKindOfClass:UIView.class] && view.layer == self && !SGKeepsColor(view)) {
///             … else if (SGIsBaseSurface(color) && SGIsInside(view, …)) { color = NULL; }
///         }
///     }
///     %orig(color);
/// }
/// ```
///
/// ## 为什么必须有它（用户照片 103 那条"割裂感很强的线"）
///
/// 我们清底色原来只有**每 0.6s 走一遍页面**、而且只清 `depth ≤ 7`、只清等于 `#121212` 的那些 ——
/// 列表在深度 15+，**滚动时才创建的行**更是每一行都要重画一次 ⇒ 于是"页头区（我们的模糊底）"与
/// "列表区（Spotify 的底色）"之间出现一条硬边。
///
/// pw 不轮询，而是**劫住 `CALayer.setBackgroundColor:`**：谁想画底色就在那一刻被拦下 ⇒ 又准又省
/// （事件驱动，只在真有写入时走一次）。
///
/// ## 三道闸门（缺一不可，pw 逐字）
///
///   ① **当前确实在一个我们接管的页面里**（`EntityPageRepaint.root` 非空）——不在就一个字都不动；
///   ② `layer.delegate` 必须真是 `UIView`、而且 `view.layer === layer`（子层不算，pw 的 `view.layer == self`）；
///   ③ 颜色必须是**底面色**（近黑灰，pw 的 `SGIsBaseSurface`），而且那个视图在这个页面的子树里。
enum EntityPageRepaint {

    /// 我们接管的页面根。由 `EntityPageAppearance` 在每一拍里设（weak，页面走了自动失效）。
    static weak var root: UIView?

    static func shouldDrop(_ layer: CALayer, color: CGColor) -> Bool {
        guard let root else { return false }                                  // ①
        guard let view = layer.delegate as? UIView, view.layer === layer else { return false }  // ②
        guard view === root || view.isDescendant(of: root) else { return false }                // ③
        return isBaseSurface(color)
    }

    /// 与 `EntityPageAppearance` 清底色同一个判据：近黑、近灰、不透明。
    ///
    /// ★★ 2026-10-06（照片 111/113：照片区是浅的、**下面"你已点赞"与"热门"整片还是黑的**）：
    /// 阈值 `0.12` 只够 `#121212`（列表底，0.071）；Spotify 的**卡片**是"抬起一层"的 `#282828`
    /// （**0.157**）—— 这一档原来被放过去了。而**列表与 cell 的底是它们在自己的布局回合画的**，
    /// 页面上那趟每 0.6s 的扫描（`depth ≤ 7`）够不到 ⇒ 真正拦得住它们的**只有这一道全局钩子**，
    /// 所以阈值必须和 `EntityPageAppearance.isBaseSurface` 一样放到 0.20。
    static func isBaseSurface(_ color: CGColor) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(cgColor: color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        guard a > 0.5 else { return false }
        return abs(r - g) < 0.02 && abs(g - b) < 0.02 && r < 0.20
    }
}

// MARK: - 挂点

struct EntityPageRepaintGroup: HookGroup {}

/// 全局劫一次 `CALayer.setBackgroundColor:`。**不在我们页面里时是一句 nil 检查**，不产生开销。
///
/// ⚠️ hook 类不能加 `final`/`private`/`fileprivate`（Orion 要为它生成胶水子类）。
class EntityPageRepaintLayerHook: ClassHook<CALayer> {
    typealias Group = EntityPageRepaintGroup
    static let targetName = "CALayer"

    func setBackgroundColor(_ color: CGColor?) {
        guard let color, EntityPageRepaint.shouldDrop(target, color: color) else {
            orig.setBackgroundColor(color)
            return
        }
        orig.setBackgroundColor(nil)
    }
}

/// 列表是**在自己的布局回合**把底色画上去的（pw 的 `PlaylistField.x` 原话：*"The list paints itself the
/// base surface from its own pass rather than through a layer that the repaint hook would hear about,
/// so it is cleared where it is laid out."*）—— 所以在它那一拍再清一次。
///
/// 类名来自我们自己的符号表与真机树（`dump-9.1.88.txt:12060`、
/// `[Tree] … FTPTouchCancellingCollectionView@0,0,414,896,id=SPTFreeTierPlaylistTableView`）。
class PlaylistListBackgroundHook: ClassHook<UIScrollView> {
    typealias Group = EntityPageRepaintGroup
    static let targetName = "_TtC35ListUXPlatform_FreeTierPlaylistImpl32FTPTouchCancellingCollectionView"

    func layoutSubviews() {
        orig.layoutSubviews()
        guard EntityPageRepaint.root != nil else { return }
        // ⚠️ `UIColor.cgColor` 是**非可选**的 `CGColor` ⇒ 不能写 `let cg = colour.cgColor` 那种可选绑定
        // （第一版就是这么写的，编译器报 "initializer for conditional binding must have Optional type"）。
        guard let colour = target.backgroundColor else { return }
        guard EntityPageRepaint.isBaseSurface(colour.cgColor) else { return }
        target.backgroundColor = .clear
    }
}

/// 清一棵子树里"画了底面色"的那些层（**递归、有界**）。
///
/// ★ 2026-10-13（照片 108：专辑页往下滚，上半部分带色、`你可能还会喜欢` 以下整片黑）：
/// 只清"列表自己 + 它的直接子视图"不够 —— 那些 section 的底画在更深的层里，而 `CALayer` 那道闸门
/// 又听不到它们（它们同样是**在自己的布局回合**画的）。所以这里往下走到 `depth` 层。
///
/// 深度取 4：cell 的底通常画在 `contentView`（1 层）或它的子视图（2~3 层）上；再往下是
/// label / image 那些不可能画底的层，而且这一路在滚动时是**每帧**走的，不能无限深。
func eeveeClearBaseSurface(_ view: UIView, depth: Int = 0) {
    if let colour = view.backgroundColor, EntityPageRepaint.isBaseSurface(colour.cgColor) {
        view.backgroundColor = .clear
    }
    // ★★ 2026-10-06（日志 92 逐字：`cleared 0 base-surface background(s)` —— 页面上一个底都没清到，
    //    而屏幕上明明是"你已点赞 / 显示更多"那一片黑）：**直接画在 layer 上的底色也要清**。
    //    我们的 `CALayer` 钩子只在"**写入的那一刻**"拦得住；页面是在我们接管**之前**就建好的、
    //    那些 layer 早就画上了，钩子一概听不到。所以这里两种都要看。
    if let layerColour = view.layer.backgroundColor, EntityPageRepaint.isBaseSurface(layerColour) {
        view.layer.backgroundColor = nil
    }
    guard depth < 8 else { return }
    for sub in view.subviews { eeveeClearBaseSurface(sub, depth: depth + 1) }
}

/// ★ 2026-10-13（照片 105：专辑页往下滚是**一片黑**）：**专辑页的列表和歌单页那个类不是一个**
/// （日志 87：`[Tree] … CreativeWorkTemplateListView@0,0,414,896`）。pw 的 `AlbumField.x` 为它单开一个：
///
/// > The list paints itself the base surface from its own pass rather than through a layer that the
/// > repaint hook would hear about, so it is cleared where it is laid out. Its collection view is a
/// > private class whose name carries a build hash, so the list view around it -- one public name,
/// > one child -- is where it is cleared.
///
/// 没有这一钩，`CALayer` 那道闸门**听不到列表自己那一拍画的底** ⇒ 列表照旧不透明地盖在 field 上。
class AlbumListBackgroundHook: ClassHook<UIView> {
    typealias Group = EntityPageRepaintGroup
    static let targetName = "_TtC32CreativeWorkPlatform_TemplateKit28CreativeWorkTemplateListView"

    func layoutSubviews() {
        orig.layoutSubviews()
        guard EntityPageRepaint.root != nil else { return }
        eeveeClearBaseSurface(target)
    }
}

/// 每一行 cell 也自己画底色 —— pw 的 `AlbumField.x` 同样为它单独开了一钩：
///
/// > Every cell of the list paints the base surface too, and the repaint hook misses it: a cell is
/// > painted before it is inside the page, and a reused one brings its old paint with it. On the
/// > episode page the Episode Transcript row, the empty section under it and the rule under that sat
/// > on black bands.
///
/// ⚠️ 它挂着的是 **`Element_List.CollectionViewCell`**：这个类别处也在用，所以**必须**加
/// `isDescendant(of: root)` 那道闸门 —— 不在我们接管的页面里的 cell 一个字节都不碰。
class AlbumCellBackgroundHook: ClassHook<UIView> {
    typealias Group = EntityPageRepaintGroup
    static let targetName = "_TtC12Element_List18CollectionViewCell"

    func layoutSubviews() {
        orig.layoutSubviews()
        guard let root = EntityPageRepaint.root, target.isDescendant(of: root) else { return }
        eeveeClearBaseSurface(target)
    }
}

/// ★★ 2026-10-18 第三轮（用户：「**艺人页的 你已点赞** 和 **歌单页的那几个按键** 可以全部去掉」）：
/// **把那一整格折成 0 高**（不是藏内容 —— 藏了会留一块空白）。
///
/// 手法照本仓库已经验证过的那条（`PlayerCardCellHook`，`PlayerDeclutter.x.swift:253`）与 pw 的
/// `ArtistSections.x`：cell 在 `preferredLayoutAttributesFittingAttributes(_:)` 里被问"你要多高"时
/// 回答 **0** ✓。两个目标各认各的：
///
///   · **歌单页那排 pill**（添加 / 编辑 / 排序 / 姓名和详情）= 真机树里
///     `ElementContentView<String, CurationActionsToolbarElement>` 里那个
///     `id=PlaylistCuration.Row.CurationActionsToolbar` 的 414×52 视图
///     （日志 7/8/12/17/47/52… 里到处都有）。pw 把同一个字符串写成常量
///     `SGRPlaylistCurationIdentifier`（`PlaylistMenu.x:35`）—— 连它也是这么摘的 ✓。
///   · **艺人页的「你已点赞」那一排** —— 它**没有 accessibility id**（翻遍我们的树都没有），
///     但它是 `Creator_LikedSongsElementKit` 那一族（`dump-9.1.88.txt:7762-7764`：
///     `LikedSongsElementProvider` / `CollectionObserver` / `ConnectivityObserver`；Swift 泛型实参
///     会出现在 `NSStringFromClass` 里，真机树就是 `ElementContentView<String, …Element>` 这种写法）
///     ⇒ 按**类名**认，而且**只在页面根就是 `creator-page` 时**折 —— 「喜欢的歌曲」那一页不动 ✓。
enum EntityPageSectionDrop {

    static let curationIdentifier = "PlaylistCuration.Row.CurationActionsToolbar"
    static let likedSongsFragment = "LikedSongs"
    /// ★★ 2026-10-18 第三轮：艺人页的「关于艺人」那一块 —— 正文被
    /// `ArtistBioSheet` 读走之后，列表里这一段就折掉（用户：「把原本的 spotify 的
    /// 关于艺人 给去掉，我们自己搞」）。
    static let aboutArtistFragment = "SPTArtistAboutBiographyView"

    /// 每一格"是什么"与"已经决定不要的格子" —— pw 的 `kindsOf` / `droppedOf`
    /// （`ArtistSections.x:49-65`）；每段 = 间隔格 + 标题格 + 内容格。
    enum Kind { case other, spacer, heading }
    private static var kinds: [IndexPath: Kind] = [:]
    private static var dropped: Set<IndexPath> = []
    private static weak var invalidatedFor: UIView?
    private static var invalidations = 0
    private static var didReport = false

    /// 这一拍被问"你要多高"时顺手做两件事：**记下这一格是什么**、
    /// **回答要不要折成 0**。
    ///
    /// ⚠️ **故意不按 cell 对象缓存判定**：cell 会被复用，同一个对象先后装着不同的 section
    /// —— 缓存下来就会"折错格子"。这里只做**有界**的子树走（一个 cell 通常十几个视图）。
    ///
    /// 两道闸门：**在我们接管的页面上**（`EntityPageRepaint.root`，与清底色同一条）⇒ 内容对得上；
    /// 「已点赞」与「关于艺人」那两族还要求**页面根就是 `creator-page`**
    /// （「喜欢的歌曲」那一页也是 playlist，不认这一条会把那一页整段折掉 ✗）。
    static func shouldCollapse(_ cell: UIView, at path: IndexPath?, height: CGFloat) -> Bool {
        guard let root = EntityPageRepaint.root, cell.isDescendant(of: root) else { return false }

        if let path, kinds.count < 400, kinds[path] == nil {
            kinds[path] = kind(of: cell, height: height)
        }
        if let path, dropped.contains(path) {
            scheduleRelayout(of: cell, force: false)
            return true
        }

        var drop = containsIdentifier(cell, curationIdentifier)
        if !drop, root.accessibilityIdentifier == "creator-page" {
            drop = containsClassName(cell, likedSongsFragment)
                || containsClassName(cell, aboutArtistFragment)
        }
        if drop {
            if let path { dropPreceding(path) }
            scheduleRelayout(of: cell, force: true)
        }
        return drop
    }

    /// 这一格是什么：**标题**（`Components.UI.SectionHeadingHome`）/ **间隔**（≤ 16.5pt
    /// 而且一个 id 都没有）/ 别的 —— pw 的 `kindOf`（`ArtistSections.x:31-47`）逐字。
    private static func kind(of cell: UIView, height: CGFloat) -> Kind {
        if containsIdentifier(cell, "Components.UI.SectionHeadingHome") { return .heading }
        if height <= 16.5, !hasAnyIdentifier(cell) { return .spacer }
        return .other
    }

    /// 把这一格**前面**的标题 / 间隔格也标成"不要"（pw 的 `dropHeadingOf`，
    /// `ArtistSections.x:107-121`）：只折内容格的话，标题会孤零零留在那儿 ✗。
    private static func dropPreceding(_ path: IndexPath) {
        var item = path.item - 1
        var steps = 0
        var added = false
        while item >= 0, steps < 2 {
            steps += 1
            let candidate = IndexPath(item: item, section: path.section)
            guard let kind = kinds[candidate], kind == .heading || kind == .spacer else { break }
            if dropped.count < 400, dropped.insert(candidate).inserted { added = true }
            item -= 1
        }
        guard added, !didReport else { return }
        didReport = true
        writeDebugLog(
            "[PageRepaint] dropping a section (the playlist's pills / the artist's liked songs,"
                + " about artist) — the list is asked to lay out again"
        )
    }

    /// 折了之后**让布局重算一次**：高度是布局问出来的，只在下一趟才会问第二遍；
    /// 不主动作废的话，用户得等到页面因为别的原因重排才看得到效果（pw 也是这么干的）。
    /// **每页最多 4 次**、一律 `async`，不会在布局回合里递归。
    private static func scheduleRelayout(of cell: UIView, force: Bool) {
        if invalidatedFor !== EntityPageRepaint.root { invalidations = 0 }
        guard force || invalidatedFor !== EntityPageRepaint.root else { return }
        guard invalidations < 4 else { return }
        var node: UIView? = cell.superview
        var depth = 0
        while let current = node, depth < 8 {
            if let collection = current as? UICollectionView {
                invalidations += 1
                invalidatedFor = EntityPageRepaint.root
                DispatchQueue.main.async { collection.collectionViewLayout.invalidateLayout() }
                return
            }
            node = current.superview
            depth += 1
        }
    }

    /// 有界地往下找"带这个 accessibility id"的视图。
    private static func containsIdentifier(_ root: UIView, _ identifier: String) -> Bool {
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 200 {
            let view = queue.removeFirst()
            visited += 1
            if view.accessibilityIdentifier == identifier { return true }
            queue.append(contentsOf: view.subviews)
        }
        return false
    }

    /// 有界地往下找"类名里含这个片段"的视图（Swift 泛型实参会出现在类名里）。
    private static func containsClassName(_ root: UIView, _ fragment: String) -> Bool {
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 200 {
            let view = queue.removeFirst()
            visited += 1
            if NSStringFromClass(type(of: view)).contains(fragment) { return true }
            queue.append(contentsOf: view.subviews)
        }
        return false
    }

    /// 这棵子树里**一个 accessibility id 都没有**（pw 的间隔格判据）。
    private static func hasAnyIdentifier(_ root: UIView) -> Bool {
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 60 {
            let view = queue.removeFirst()
            visited += 1
            if !(view.accessibilityIdentifier ?? "").isEmpty { return true }
            queue.append(contentsOf: view.subviews)
        }
        return false
    }
}

/// 折 `Element_List.CollectionViewCell`（艺人页那一族的 section 都是它）。
class ElementListSectionDropHook: ClassHook<UICollectionViewCell> {
    typealias Group = EntityPageRepaintGroup
    static let targetName = "_TtC12Element_List18CollectionViewCell"

    func preferredLayoutAttributesFittingAttributes(
        _ attributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let result = orig.preferredLayoutAttributesFittingAttributes(attributes)
        guard EntityPageSectionDrop.shouldCollapse(
            target,
            at: attributes.indexPath,
            height: result.size.height
        ) else { return result }
        result.size = CGSize(width: result.size.width, height: 0)
        // 折起来之后内容仍在视图里，不裁剪会溢到相邻格子上（`PlayerCardCellHook` 同一条）。
        target.clipsToBounds = true
        return result
    }
}

/// 折歌单页的 `ElementCollectionViewCell`（pw 的 `PlaylistRows.x:89` 挂的就是这个类）。
class PlaylistSectionDropHook: ClassHook<UICollectionViewCell> {
    typealias Group = EntityPageRepaintGroup
    static let targetName = "_TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell"

    func preferredLayoutAttributesFittingAttributes(
        _ attributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let result = orig.preferredLayoutAttributesFittingAttributes(attributes)
        guard EntityPageSectionDrop.shouldCollapse(
            target,
            at: attributes.indexPath,
            height: result.size.height
        ) else { return result }
        result.size = CGSize(width: result.size.width, height: 0)
        target.clipsToBounds = true
        return result
    }
}

func activateEntityPageRepaint() {
    // 底色拦截只为「满幅封面 + 取色底」那颗开关服务（它不在，页面本来就不该被清成透明）。
    guard UserDefaults.entityPageDissolve else {
        writeDebugLog("[PageRepaint] off — the page field switch is off")
        return
    }

    let targets = [
        EntityPageRepaintLayerHook.targetName,
        PlaylistListBackgroundHook.targetName,
        AlbumListBackgroundHook.targetName,
        AlbumCellBackgroundHook.targetName,
        // ★★ 2026-10-18 第三轮：「你已点赞」/ 歌单 pill 那两格折成 0 高（见 `EntityPageSectionDrop`）。
        ElementListSectionDropHook.targetName,
        PlaylistSectionDropHook.targetName,
    ]
    let present = targets.filter { NSClassFromString($0) != nil }
    guard !present.isEmpty else {
        writeDebugLog("[PageRepaint] skipped — none of \(targets.joined(separator: ", ")) exist")
        return
    }

    EntityPageRepaintGroup().activate()
    writeDebugLog(
        "[PageRepaint] on — hooked \(present.count)/\(targets.count)"
            + " (\(present.joined(separator: ", "))): Spotify's base-surface paints inside our page"
            + " are dropped at the layer, and the list's own pass (playlist **and** album) is cleared"
            + " where it lays out, cell by cell"
    )
}
