import UIKit

/// **歌单页那排 setting pill** 与 **「喜欢的歌曲」顶上那排 tags chips** —— 藏掉它们。
///
/// 用户 2026-10-17（图片 148 / 149）原话：
///
/// > 喜欢的歌曲 里面的那些**根据标签挑选歌曲** / 歌单页的**那四个设置**可以隐藏了。
///
/// 两排都是 Spotify 自己的东西，AM 里没有：
///
/// ```
/// 歌单页    ┌ + 添加 ┐ ┌ ≡ 编辑 ┐ ┌ ↕ 排序 ┐ ┌ ✎ 姓名和详情 ┐      ← 149
/// 喜欢的歌曲 ┌ 放克 ┐ ┌ 节拍 ┐ ┌ 电子 ┐ ┌ 游戏 ┐ …              ← 148（按标签挑歌）
/// ```
///
/// ## 判据（每一族各三条，命中一条就够）
///
/// | 目标 | ① id 子串 | ② 类名子串 | ③ 文字 | 出处 |
/// |---|---|---|---|---|
/// | 那排 pill | `PlaylistCuration` | — | 四颗逐个整串相等 | 本仓库 `EntityPageSectionDrop.curationFragment`：真机日志里 `PlaylistCuration.Row.CurationActionsToolbar` 出现过 107 次、`PlaylistCuration.AddButton` 72 次 |
/// | 那排 chips | — | `ToolbarChipCollectionView` / `ToolbarChipCell` | — | 9.1.88 的类名 dump：`_TtC12Toolbar_Core25ToolbarChipCollectionView` / `…15ToolbarChipCell` |
///
/// ③ 那条**必须整串相等**：`添加歌曲`（148 里那行）含"添加"，子串匹配会把它一起藏掉。
///
/// ## 纪律
///
/// * **记原值**（`wasHidden`），关开关 / 换页时 `restore()` 原样写回 —— 与 `EntityPageAppearance`
///   其余十处同一个形状。
/// * 每拍有界（≤ 900 节点 / 命中 4 个就停），页面上没有这两排时**什么都不做**（只是多走一趟 BFS）。
/// * ⚠️ 藏的是**视图**，不是列表里的行高 ⇒ 若 Spotify 把这一排算进页头高度，藏完会留一条空档。
///   第一次命中时把类名 / 帧 / id 打进日志，下一份日志就能判断要不要再补一次"页头收高"。
enum EntityPageCurationHide {

    /// ① 那排 pill 的模块前缀。
    private static let identifierMarkers = [
        "PlaylistCuration",
    ]

    /// ② 那排 chips 的类名（dump 里的 Swift 名字含这两段）。
    private static let classMarkers = [
        "ToolbarChipCollectionView",
        "ToolbarChipCell",
    ]

    /// ③ 文字兜底：那一排四颗的字面（**整串相等**，见文件头）。
    private static let textMarkers: Set<String> = [
        "添加", "编辑", "排序", "姓名和详情",
        "add", "edit", "sort", "name & details", "name and details",
        "追加", "編集", "並び替え", "名前と詳細",
    ]

    /// 一个被我们藏掉的视图。
    ///
    /// ⚠️ 用 **class** 而不是 struct：`weak var` 不能写在 struct 里（编译器直接报错），
    /// 而这里必须用弱引用 —— 否则换页之后这些记录会把上一页的整棵子树吊住。
    private final class Hidden {
        weak var view: UIView?
        let wasHidden: Bool

        init(view: UIView) {
            self.view = view
            self.wasHidden = view.isHidden
        }
    }

    private static var hidden: [Hidden] = []
    private static var didReport = false

    // MARK: - 入口

    /// 每拍调一次。只在专辑 / 歌单页上由 `EntityPageAppearance.tick()` 调用。
    static func apply(to page: UIView) {
        guard page.window != nil else { return }

        var marked: [UIView] = []
        var labelled: [UIView] = []
        /// ★★ 2026-10-18（图片 148 的现场：那一排「放克 / 节拍 / 电子 / 游戏 …」**还在**）：
        /// ② 那条类名判据（`ToolbarChip*`）在这个 Spotify 版本上**一次都没命中**
        /// （日志 333 里 `[PageRepaint] hid … chrome row(s)` **0 行**）⇒ 只能按**形状**认。
        /// 这里只收集"自己那段文字很短（≤6 字）的 UIControl"，凑够 4 颗再取它们共同的那一行。
        var shortLabelled: [UIControl] = []

        var queue: [UIView] = [page]
        var visited = 0
        while !queue.isEmpty, visited < 900, marked.count < 4 {
            let view = queue.removeFirst()
            visited += 1

            if isMarked(view) {
                marked.append(view)
                continue
            }
            if let control = view as? UIControl, let text = ownText(of: control) {
                if textMarkers.contains(text) {
                    labelled.append(control)
                    continue
                }
                if text.count <= 6, shortLabelled.count < 16 {
                    shortLabelled.append(control)
                }
            }
            queue.append(contentsOf: view.subviews)
        }

        // ★★ 2026-10-18：**一排短标签**（≥ 4 颗、文字都 ≤ 6 字、共同祖先不超过 200pt 高）——
        //    148 那排 chips 的兜底。卡片横条（艺人之选 / 热门新歌）的文字是歌名、更长，
        //    而且它们不是 UIControl ⇒ 不会被这条吃掉。
        var chipRow: UIView?
        if marked.isEmpty, labelled.isEmpty, shortLabelled.count >= 4,
           let row = commonAncestor(of: shortLabelled), row.bounds.height >= 20 {
            chipRow = row
        }

        // 文字那条：四颗按钮要收**它们共同的那一行**（一颗颗藏会在原处留四个洞）。
        var targets = marked
        if labelled.count >= 2, let row = commonAncestor(of: labelled) {
            targets.append(row)
        }
        if let chipRow, !targets.contains(where: { $0 === chipRow }) {
            targets.append(chipRow)
        }
        guard !targets.isEmpty else { return }

        for view in targets where !hidden.contains(where: { $0.view === view }) {
            hidden.append(Hidden(view: view))
        }
        for view in targets where !view.isHidden {
            view.isHidden = true
        }

        guard !didReport else { return }
        didReport = true
        let described = targets.map { view -> String in
            let frame = view.convert(view.bounds, to: page)
            let size = "\(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))"
            let identifier = view.accessibilityIdentifier ?? "-"
            return "\(NSStringFromClass(type(of: view)))@\(size) id=\(identifier)"
        }
        // ⚠️ 不要在这条字符串的插值里写引号：`swift_member_check.py` 的去字符串扫描器会提前收尾。
        let joined = described.joined(separator: " | ")
        writeDebugLog(
            "[PageRepaint] hid \(targets.count) chrome row(s) the AM look does not have"
                + " (playlist pills / liked-songs chips): \(joined)"
        )
    }

    /// 关开关 / 换页 / 离开实体页时原样写回。
    static func restore() {
        for record in hidden {
            record.view?.isHidden = record.wasHidden
        }
        hidden.removeAll()
    }

    // MARK: - 判据

    private static func isMarked(_ view: UIView) -> Bool {
        let identifier = view.accessibilityIdentifier ?? ""
        if identifierMarkers.contains(where: { identifier.contains($0) }) {
            // 只收"一排"那么高的东西：真机里那排是 44~64pt；id 若落在页头容器上就别动。
            return view.bounds.height > 1 && view.bounds.height <= 200
        }
        let name = NSStringFromClass(type(of: view))
        if classMarkers.contains(where: { name.contains($0) }) {
            return view.bounds.height > 1 && view.bounds.height <= 200
        }
        return false
    }

    /// 只取**控件自己**那一段文字（不进子树）—— 进子树会把整行/整页的文字都带回来。
    private static func ownText(of view: UIView) -> String? {
        var raw = view.accessibilityLabel ?? ""
        if let button = view as? UIButton {
            let title = button.title(for: .normal) ?? button.title(for: .selected) ?? ""
            if raw.isEmpty { raw = title }
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.isEmpty ? nil : text
    }

    /// 几颗控件**共同**的那一层（往上找，要求它装得下全部、而且自己也不高）。
    private static func commonAncestor(of views: [UIView]) -> UIView? {
        guard let first = views.first else { return nil }
        var node: UIView? = first.superview
        var depth = 0
        while let current = node, depth < 8 {
            let holdsAll = views.allSatisfy { $0 === current || $0.isDescendant(of: current) }
            if holdsAll, current.bounds.height > 1, current.bounds.height <= 200 {
                return current
            }
            node = current.superview
            depth += 1
        }
        return nil
    }
}
