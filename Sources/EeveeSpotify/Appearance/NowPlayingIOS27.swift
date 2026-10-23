// 「iOS 27 听歌页」—— 把听歌页做成 Apple Music（iOS 27）那一版的样子。
//
// 2026-10-23（用户）：`C:\dsh\am\1.jpg` 是 iOS 27 在 Apple Music 上的表现，问"我们可以做吗"，
// 随后拍板："和现在的『修改Spotify听歌页布局』这个按钮，直接做新的就好了。"
// ⇒ 这是一颗**独立的新开关**（`UserDefaults.nowPlayingIOS27`），默认关；
//    和旧那套（`NowPlayingLyricsPlate` 的"歌词进播放器"）**互斥**：新的开着时旧的自动让位
//    （`NowPlayingLyricsPlate.isEnabled` 的 `!nowPlayingIOS27` 那道门）。
//
// ## 这一版（v1）做什么
//
// 目标图逐条拆开（`C:\dsh\am\1.jpg`，628×1055）：
//   ① **封面满血**：不是 366pt 的圆角方块，而是顶到屏幕左右两边、从屏幕最顶上开始画；
//   ② 封面**下沿柔和过渡**到深色：不是硬切，也不是整页模糊（一层"模糊 + 压黑"的带子）；
//   ③ **标题叠在过渡带上**（白色粗体、左对齐）—— v1 先把原生标题行挪下来；
//   ④ 极细进度条 + 两端时间 —— 原生那条先不动（v2）；
//   ⑤ 三个传输键 —— 原生（「控制键本地字形」那颗子开关照旧生效）；
//   ⑥ 底部细音量条（两端小喇叭）—— 复用 `NowPlayingPageOverlay` 已经写好的那一行；
//   ⑦ 底部工具行 —— 原生（v2）。
//
// ⇒ v1 = ① + ② + ③ + ⑥。**不碰 Spotify 的属性值**（除了四处可还原的：封面壳的
//    `transform` 与圆角、标题行的 `transform`、祖先链上的 `clipsToBounds`）：
//    关开关 = 逐个写回原位 + 拆掉我们自己的那层视图。
//
// ## 为什么是"缩放原生封面"而不是自绘一张
//
// 仓库里已经有两套拿封面的办法：`NowPlayingLyricsPlate` 自己画一张（要藏原生那张、
// 还要处理换歌闪图），以及"直接用原生那张"。这里选后者：
//   · 零取图、零缓存、零换歌空档 —— 原生那个 `Encore.ImageView` 换图由 Spotify 自己管；
//   · 层次天然正确：封面在 **contentlayer** 里（整页背景层，`CoverArtCellImpl@0,0,414,896`），
//     标题 / 进度 / 控件在它上面 ⇒ 放大封面**不需要跟任何人的 z-order 打架**；
//   · 代价是圆角与裁剪要自己收：下面那三处写入都**记原值**、收尾原样写回。
//
// ## 几何（按页宽推，不写死像素）
//
//   封面方块：`(0, 0, W, W)` —— 方图按屏宽铺满，并从 y = 0 起（AM 就是这么**裁**的）。
//   模糊带  ：`(0, W−2, W, bandHeight+2)`，底下压一条从透明到黑的渐变（`scrim`）。
//   标题行  ：顶边 = `W + titleTopGap`，左边 = `titleLeadInset`（AM 是 16pt）。
//   音量条  ：`NowPlayingPageOverlay` 里按 iOS 27 分支摆在"控件行与 footer 之间"。
//
// ## 时序
//
//   · 进页面：`NPVScrollViewControllerHook.viewWillAppear/.viewDidAppear` → `apply(in:)`；
//   · 每 0.3s：蹭 `DeclutterChrome` 既有的复查节拍 → `reconcile()`（不新开定时器）；
//   · 换歌：`CoverArtTiltLayoutHook` 多转发一次 → `coverDidLayOut(from:)`（新封面对象
//     当场摆好、不等下一拍，否则会闪一下 366pt 的原生封面）；
//   · 关开关：设置页 → `reapply()` → 里面的 `restore()`。
//
// 日志 tag：`[iOS27]`。排查先看：`cover scaled` / `title row moved` / `band mounted` / `restored`。
import Foundation
import UIKit
import CoreImage
import ObjectiveC.runtime

@MainActor
enum NowPlayingIOS27 {

    static let logTag = "iOS27"

    // MARK: - 几何

    /// 标题行顶边离封面底边的距离（pt）。AM 截图里 ≈ 64；取 56 是给长标题与进度条之间留口气
    /// （W + 56，而进度条顶边 ≈ 560）。
    static let titleTopGap: CGFloat = 56
    /// 标题行左边距（AM 16pt；Spotify 原生 28pt）。
    static let titleLeadInset: CGFloat = 16
    /// 模糊带在封面底边以下的高度。
    static let bandHeight: CGFloat = 52
    /// 压黑渐变从封面高度的哪一档开始（0.55 = 封面下半段开始转暗）。
    static let scrimTopFraction: CGFloat = 0.55
    /// 高斯模糊半径。
    static let blurRadius: CGFloat = 26
    /// 走查上限（本仓库纪律）。
    static let maxNodes = 2000

    /// 这颗开关自己就是全部条件（旧的"歌词进播放器"在它那边让位，见文件头）。
    static var isEnabled: Bool { UserDefaults.nowPlayingIOS27 }

    // MARK: - 状态

    static weak var lastPage: UIView?
    /// Spotify 那张**真正画封面**的壳（`Encore.ImageView`，366×366）。
    static weak var artworkShell: UIView?
    /// 被我们摆过的每一个壳：原 `transform` / 原**位置** / 原圆角
    /// （换歌会换对象，所以是复数）。
    ///
    /// ⚠️ 必须记"接管那一刻的矩形"：`untransformed()` 只减平移、不减缩放 ——
    ///    已经被我们缩过的那张壳，`natural.width` 就是**目标宽**，再按它算缩放会得到 1、
    ///    位移得到 0，于是每一拍都把封面**还原回 366pt**（第一版就是这么写的）。
    static let touchedShells = NSHashTable<UIView>.weakObjects()
    static var shellBaseTransforms: [ObjectIdentifier: CGAffineTransform] = [:]
    static var shellBaseRects: [ObjectIdentifier: CGRect] = [:]
    static var shellBaseRadii: [ObjectIdentifier: CGFloat] = [:]
    /// 记这些矩形时的页宽：转屏 / 分屏换了宽度就作废重记。
    static var recordedPageWidth: CGFloat = 0
    /// 被我们放开裁剪的祖先（按各自原值写回）。
    static let unclippedViews = NSHashTable<UIView>.weakObjects()
    static var unclippedOriginals: [ObjectIdentifier: Bool] = [:]

    /// 我们自己那层（挂在 contentlayer 那个整页 cell 的最底层）：模糊带 + 压黑渐变。
    static weak var bandHost: UIView?
    static weak var bandImage: UIImageView?
    static weak var scrim: UIView?

    /// 被我们挪下来的标题行，以及它原来的 `transform` 与**原生位置**（理由同 `shellBaseRects`）。
    static weak var titleRow: UIView?
    static var titleRowBase: (ObjectIdentifier, CGAffineTransform)?
    static var titleRowBaseRect: (ObjectIdentifier, CGRect)?

    /// 按曲目 id 记"模糊带那张图什么时候要重做"。
    static var lastBandTrackId = ""

    static var didLogCover = false
    static var didLogTitle = false
    static var didLogBand = false
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
    /// ⚠️ **关掉时不管页面在不在都要收尾**：壳与 cell 会被复用，留着放大后的
    /// `transform` 就是下一次在别处显形的错。`restore()` 不依赖页面对象。
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
    /// 需要它的两个理由：
    ///   · 换歌会换一个**新的封面对象**（旧的 `transform` 跟着旧对象走）；
    ///   · 标题行在 stack 里，布局回合会重写 `frame`（`transform` 不会被抹，但仍要保证
    ///     "这一拍量到的位置还是我们摆的那个"）。
    ///
    /// - Returns: 这一拍真的改了东西吗（给排查用）。
    @discardableResult
    static func reconcile() -> Bool {
        // 页面真的不在窗口里了 ⇒ 把写过的每一处还回去。封面壳与它那个 cell 都是**会被复用**的，
        // 留着放大后的 `transform`，下一次在别处复用那一格就是错的（本仓库最不能接受的失败）。
        // ⚠️ 这一步**不能**放在 `isEnabled` 后面：用户可能"先离开播放器、再在设置里关掉"。
        if let page = lastPage, page.window == nil {
            restore(reason: "page disappeared")
        }
        guard isEnabled else { return false }
        guard let page = lastPage, page.window != nil else { return false }
        return layout(in: page)
    }

    /// 封面自己被布局的那一刻（`CoverArtTiltLayoutHook` 转发进来）。
    ///
    /// 只做一件事：当前这张壳如果还没被我们摆过，就**当场**接管 —— 换歌那一瞬间原生封面
    /// 先以 366pt 出现，靠这一条把空档变成 0。
    static func coverDidLayOut(from tilt: UIView) {
        guard isEnabled, let page = lastPage, page.window != nil, tilt.window != nil else { return }
        guard tilt.bounds.width >= 200, tilt.isDescendant(of: page) else { return }
        guard let shell = shell(in: tilt) else { return }
        _ = applyCoverTransform(shell, in: page, log: false)
    }

    // MARK: - 布局

    @discardableResult
    private static func layout(in page: UIView) -> Bool {
        guard let list = NowPlayingLyricsPlate.findByIdentifier(
            NowPlayingLyricsPlate.listIdentifier,
            in: page
        ), let shell = NowPlayingLyricsPlate.visibleCover(in: list, page: page) else {
            if !didLogMissingCover {
                didLogMissingCover = true
                writeDebugLog("[\(logTag)] no visible artwork yet — nothing to scale this tick")
            }
            return false
        }
        didLogMissingCover = false
        artworkShell = shell

        var changed = applyCoverTransform(shell, in: page, log: true)
        if placeTitleRow(in: page) { changed = true }
        if mountBand(over: shell, in: page) { changed = true }
        return changed
    }

    /// 把封面壳缩放到 `(0, 0, W, W)`。
    ///
    /// 三步，顺序要紧：
    ///   ① 先让它自己那一套 `transform` 作用完、读**变换之后**的矩形
    ///      （`untransformed(bounds, to: page)` —— 本仓库纪律：`transform` 非恒等时 `frame` 不可信）；
    ///   ② 缩放比 = `W / 当前宽`；
    ///   ③ 位移 = 目标中心 − 当前中心，写在**最后** ⇒ 单位就是 pt，不会被缩放带跑。
    ///
    /// - Parameter log: 只在"真的改了"时打一行（`coverDidLayOut` 高频调用，不打日志）。
    @discardableResult
    private static func applyCoverTransform(_ shell: UIView, in page: UIView, log: Bool) -> Bool {
        if recordedPageWidth != page.bounds.width {
            resetRecordings()
            recordedPageWidth = page.bounds.width
        }

        let key = ObjectIdentifier(shell)
        let base: CGAffineTransform
        let baseRect: CGRect
        if let recorded = shellBaseTransforms[key], let rect = shellBaseRects[key] {
            base = recorded
            baseRect = rect
        } else {
            base = shell.transform
            baseRect = NowPlayingLyricsPlate.untransformed(shell, in: page)
            shellBaseTransforms[key] = base
            shellBaseRects[key] = baseRect
            shellBaseRadii[key] = shell.layer.cornerRadius
            touchedShells.add(shell)
            openClips(from: shell, upTo: page)
        }
        guard baseRect.width > 1, baseRect.height > 1 else { return false }

        let targetSide = page.bounds.width
        let scale = targetSide / baseRect.width
        let move = CGAffineTransform(
            translationX: (targetSide / 2 - baseRect.midX).rounded(),
            y: (targetSide / 2 - baseRect.midY).rounded()
        )
        let wanted = base
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(move)

        guard shell.transform != wanted else { return false }
        shell.transform = wanted
        shell.layer.cornerRadius = 0
        if log && !didLogCover {
            didLogCover = true
            writeDebugLog(
                "[\(logTag)] cover scaled — \(Int(baseRect.width))pt → \(Int(targetSide))pt"
                    + " at (0,0), corner radius 0 (Apple Music's full-bleed square)"
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

    /// 装"模糊带 + 压黑渐变"（一整个整页容器，挂在封面所在那个整页 cell 的最底层）。
    ///
    /// 挂不上（找不到那个整页祖先 / 拿不到图）就只保留"满血封面"这半个效果：
    /// 宁可少一层，也不往别人的视图里写。
    @discardableResult
    private static func mountBand(over shell: UIView, in page: UIView) -> Bool {
        guard let host = fullPageAncestor(of: shell, in: page) else { return false }

        let width = page.bounds.width
        let height = page.bounds.height

        if let existing = bandHost, existing.superview === host {
            var changed = false
            if existing.frame != CGRect(x: 0, y: 0, width: width, height: height) {
                existing.frame = CGRect(x: 0, y: 0, width: width, height: height)
                changed = true
            }
            if let image = bandImage, updateBandImage(image) { changed = true }
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

        let scrimView = UIView(frame: .zero)
        scrimView.isUserInteractionEnabled = false
        scrimView.accessibilityIdentifier = "eevee-ios27-scrim"
        let gradient = CAGradientLayer()
        gradient.name = "eevee-ios27-scrim-gradient"
        gradient.colors = [
            UIColor.black.withAlphaComponent(0.05).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.black.withAlphaComponent(0.92).cgColor,
        ]
        gradient.locations = [0, 0.55, 1]
        scrimView.layer.addSublayer(gradient)
        wrapper.addSubview(scrimView)

        // 封面下半段也压一点暗（AM 的封面往下走越来越沉）。
        let coverScrim = UIView(frame: .zero)
        coverScrim.isUserInteractionEnabled = false
        let coverGradient = CAGradientLayer()
        coverGradient.name = "eevee-ios27-cover-gradient"
        coverGradient.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.30).cgColor,
        ]
        coverScrim.layer.addSublayer(coverGradient)
        wrapper.addSubview(coverScrim)

        host.insertSubview(wrapper, at: 0)
        bandHost = wrapper
        bandImage = imageView
        scrim = scrimView
        layoutBandLayers(in: wrapper, scrim: scrimView)
        _ = updateBandImage(imageView)

        if !didLogBand {
            didLogBand = true
            writeDebugLog(
                "[\(logTag)] band mounted in \(NSStringFromClass(type(of: host)))"
                    + " — blurred strip \(Int(width))×\(Int(bandHeight)) under the square"
            )
        }
        return true
    }

    /// 我们那三个子视图各自的框（`wrapper` 是整页坐标，省得每次换算）。
    private static func layoutBandLayers(in wrapper: UIView, scrim scrimView: UIView) {
        let width = wrapper.bounds.width
        let coverSide = width
        // 贴着封面底边**再往上多 60pt**：上面那 60pt 被封面方块盖住 ⇒ 接缝看不出来，
        // 露在外面的只有 `bandHeight` 那一条（`scaleAspectFill` 从图的中下部取）。
        let strip = CGRect(x: 0, y: coverSide - 60, width: width, height: 60 + bandHeight)

        if let image = bandImage, image.frame != strip { image.frame = strip }
        if scrimView.frame != strip { scrimView.frame = strip }
        if let gradient = scrimView.layer.sublayers?.first as? CAGradientLayer,
           gradient.frame != scrimView.bounds {
            gradient.frame = scrimView.bounds
        }

        if let coverScrim = wrapper.subviews.last, coverScrim !== scrimView,
           coverScrim !== bandImage {
            let rect = CGRect(
                x: 0,
                y: coverSide * scrimTopFraction,
                width: width,
                height: coverSide * (1 - scrimTopFraction) + 2
            )
            if coverScrim.frame != rect { coverScrim.frame = rect }
            if let gradient = coverScrim.layer.sublayers?.first as? CAGradientLayer,
               gradient.frame != coverScrim.bounds {
                gradient.frame = coverScrim.bounds
            }
        }
    }

    /// 按曲目 id 更新模糊带那张图（同一首只做一次；换歌才重做）。
    @discardableResult
    private static func updateBandImage(_ imageView: UIImageView) -> Bool {
        let trackId = NowPlayingLyricsPlate.currentTrackId() ?? ""
        if trackId == lastBandTrackId, imageView.image != nil { return false }
        guard let shell = artworkShell,
              let image = NowPlayingLyricsPlate.firstImage(in: shell),
              let blurred = blurredImage(image) else { return false }
        imageView.image = blurred
        lastBandTrackId = trackId
        return true
    }

    // MARK: - 收尾

    /// 关开关 / 离开页面：把写过的每一处写回去，拆掉我们自己的视图。
    static func restore(reason: String) {
        let hadState = !shellBaseTransforms.isEmpty || bandHost != nil
            || titleRowBase != nil || !unclippedOriginals.isEmpty
        if didLogRestore || !hadState {
            clearState()
            return
        }
        didLogRestore = true

        for shell in touchedShells.allObjects {
            if let base = shellBaseTransforms[ObjectIdentifier(shell)],
               shell.transform != base {
                shell.transform = base
            }
            if let radius = shellBaseRadii[ObjectIdentifier(shell)],
               shell.layer.cornerRadius != radius {
                shell.layer.cornerRadius = radius
            }
        }
        if let row = titleRow, let recorded = titleRowBase,
           recorded.0 == ObjectIdentifier(row), row.transform != recorded.1 {
            row.transform = recorded.1
        }
        restoreClips()
        teardownBand()

        writeDebugLog("[\(logTag)] restored (\(reason)) — cover, title row and the band are back")
        clearState()
    }

    private static func clearState() {
        artworkShell = nil
        titleRow = nil
        titleRowBase = nil
        titleRowBaseRect = nil
        touchedShells.removeAllObjects()
        shellBaseTransforms.removeAll()
        shellBaseRects.removeAll()
        shellBaseRadii.removeAll()
        recordedPageWidth = 0
        lastBandTrackId = ""
        didLogCover = false
        didLogTitle = false
        didLogBand = false
        didLogRestore = false
    }

    private static func teardownBand() {
        bandHost?.removeFromSuperview()
        bandHost = nil
        bandImage = nil
        scrim = nil
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

    /// 把封面壳到页面之间的裁剪全部放开（记录原值，收尾写回）。
    ///
    /// 为什么必须放：放大之后那张图会顶出 `CoverArtTiltView` 的 bounds，链上只要有一层
    /// `clipsToBounds = true`，四边就会被切掉（AM 那张是齐边的）。
    private static func openClips(from shell: UIView, upTo page: UIView) {
        var current = shell.superview
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

    /// 换宽度：把上一套记录**先还原**再作废（下一拍按新宽度重记）。
    private static func resetRecordings() {
        for shell in touchedShells.allObjects {
            if let base = shellBaseTransforms[ObjectIdentifier(shell)],
               shell.transform != base {
                shell.transform = base
            }
            if let radius = shellBaseRadii[ObjectIdentifier(shell)],
               shell.layer.cornerRadius != radius {
                shell.layer.cornerRadius = radius
            }
        }
        if let row = titleRow, let recorded = titleRowBase,
           recorded.0 == ObjectIdentifier(row), row.transform != recorded.1 {
            row.transform = recorded.1
        }
        restoreClips()
        touchedShells.removeAllObjects()
        shellBaseTransforms.removeAll()
        shellBaseRects.removeAll()
        shellBaseRadii.removeAll()
        titleRowBase = nil
        titleRowBaseRect = nil
        didLogCover = false
        didLogTitle = false
    }

    private static func restoreClips() {
        for view in unclippedViews.allObjects {
            guard let original = unclippedOriginals[ObjectIdentifier(view)] else { continue }
            if view.clipsToBounds != original { view.clipsToBounds = original }
        }
        unclippedViews.removeAllObjects()
        unclippedOriginals.removeAll()
    }

    /// 高斯模糊（只给小带子用；一换歌才一次，不缓存 `CIContext` —— 那东西不是线程安全的）。
    private static func blurredImage(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(blurRadius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: nil)
        guard let rendered = context.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
    }
}
