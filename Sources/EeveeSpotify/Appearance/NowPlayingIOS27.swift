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
//   ② 封面**下沿柔和过渡**：`(0, W−2, W, bandHeight)` 铺一张高斯模糊的同一张图 +
//      透明→黑渐变，把方图"融"进整页取色底；
//   ③ **标题叠在过渡带上**（原生标题行挪到 `W + 56`、左缩进 16pt）；
//   ④ 底部细音量条（两端小喇叭）—— 复用 `NowPlayingPageOverlay`；
//   ⑤ 极细进度条 / 底部工具行 / ☆ 与 ⋯ —— 留 v2（见 `HANDOFF_2026-10-23_…`）。
//
// ## 几何（按页宽推，不写死像素）
//
//   封面方块：`(0, 0, W, W)`；模糊带：`(0, W−2, W, bandHeight)`（bandHeight = 0.36W ≈ 149）；
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
    /// 模糊带高度占页宽的比例（0.36 ⇒ 414pt 上 ≈ 149pt）。
    static let bandHeightRatio: CGFloat = 0.36
    /// 高斯模糊半径。
    static let blurRadius: CGFloat = 24

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

    /// 我们那层"模糊带 + 渐变"（挂在同一个整页 cell 的最底层）。
    static weak var bandHost: UIView?
    static weak var bandImage: UIImageView?
    static weak var scrim: UIView?

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
        guard let shell = shell(in: tilt) else { return }
        _ = updateArtwork(shell, in: page)
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
                writeDebugLog("[\(logTag)] no visible artwork yet — nothing to draw this tick")
            }
            return false
        }
        didLogMissingCover = false
        artworkShell = shell

        var changed = updateArtwork(shell, in: page)
        if placeTitleRow(in: page) { changed = true }
        if mountBand(in: page) { changed = true }
        if !didLogFrames {
            didLogFrames = true
            logFrames(in: page)
        }
        return changed
    }

    /// 把"我们要画的那张封面"摆上去 —— 有图就画我们的、把原生的按下去；
    /// 没图就让原生那张先露着（**绝不空白**）。
    @discardableResult
    private static func updateArtwork(_ shell: UIView, in page: UIView) -> Bool {
        let trackId = NowPlayingLyricsPlate.currentTrackId() ?? ""

        // 图：缓存优先（按曲目 id），再退回树里真实那张。
        var image: UIImage? = NowPlayingLyricsPlate.rememberArtworkIfNeeded(in: page)
        if image == nil { image = NowPlayingLyricsPlate.firstImage(in: shell) }

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
        // 我们的封面在原生那张**上面**（同一个 cell 里），原生那张必须按下去。
        hideShell(shell)
        return changed
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
        let bandHeight = (width * bandHeightRatio).rounded()

        if let existing = bandHost, existing.superview === host {
            var changed = false
            if existing.frame != CGRect(x: 0, y: 0, width: width, height: height) {
                existing.frame = CGRect(x: 0, y: 0, width: width, height: height)
                changed = true
            }
            if let image = bandImage, updateBandImage(image, shell: shell) { changed = true }
            if let scrim { layoutBandLayers(in: existing, scrim: scrim, bandHeight: bandHeight) }
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
            UIColor.black.withAlphaComponent(0.45).cgColor,
            UIColor.black.withAlphaComponent(0.88).cgColor,
        ]
        gradient.locations = [0, 0.6, 1]
        scrimView.layer.addSublayer(gradient)
        wrapper.addSubview(scrimView)

        // 同一条：整页 cell 的最上层（它在 UI 栈下面，见文件头）。
        host.addSubview(wrapper)
        bandHost = wrapper
        bandImage = imageView
        scrim = scrimView
        layoutBandLayers(in: wrapper, scrim: scrimView, bandHeight: bandHeight)
        _ = updateBandImage(imageView, shell: shell)

        if !didLogBand {
            didLogBand = true
            writeDebugLog(
                "[\(logTag)] band mounted in \(NSStringFromClass(type(of: host)))"
                    + " — blurred strip \(Int(width))×\(Int(bandHeight)) under the square"
            )
        }
        return true
    }

    /// 我们那两个子视图各自的框（wrapper 是整页坐标，省得每次换算）。
    private static func layoutBandLayers(
        in wrapper: UIView,
        scrim scrimView: UIView,
        bandHeight: CGFloat
    ) {
        let width = wrapper.bounds.width
        let coverSide = width
        // 上沿压在封面里 2pt：接缝被我们自己那张不透明的封面盖住。
        let strip = CGRect(x: 0, y: coverSide - 2, width: width, height: bandHeight + 2)

        if let image = bandImage, image.frame != strip { image.frame = strip }
        if scrimView.frame != strip { scrimView.frame = strip }
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
            || !shellAlphas.isEmpty
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
        hiddenShells.removeAllObjects()
        shellAlphas.removeAll()
        lastTrackId = ""
        didLogArtwork = false
        didLogTitle = false
        didLogBand = false
        didLogFrames = false
        didLogRestore = false
    }

    private static func teardownBand() {
        bandHost?.removeFromSuperview()
        bandHost = nil
        bandImage = nil
        scrim = nil
    }

    private static func teardownArtwork() {
        artworkView?.removeFromSuperview()
        artworkView = nil
        artworkHost = nil
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
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(blurRadius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: nil)
        guard let rendered = context.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
    }
}
