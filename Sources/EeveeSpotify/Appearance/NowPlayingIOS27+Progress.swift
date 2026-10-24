// 「iOS 27 听歌页」的**进度条**（待办 T1：细轨 + 两端时间）。
//
// ## 目标（`C:\dsh\am\1.jpg`，AM 的播放页）
//
//   · 轨道约 4pt，**没有那颗白色圆钮**；
//   · 已播部分接近纯白、未播部分是半透明白（深色背景上就是一条浅灰）；
//   · 时间在轨道**下面**两端（左 `1:21`、右 `−2:06`），数字**等宽** ——
//     否则每秒走字时宽度会跳，整行跟着一抖（pw `PlayerControls.x` 就是为这个才换的字体）。
//
// ## 真机现状（照片 163，9.1.88）
//
//   单元：`AutoLayoutStackView@28,660 358×41,id=Components.UI.ProgressBarUnitNowPlaying`
//     → `Slider@-2,0,362,17,id=SPTNowPlayingSliderV2`
//        （运行时类 `_TtCO17NowPlaying_ECMKit11ProgressBar6Slider`，UISlider 子类）
//        → `_UISlideriOSVisualElement 362×17`（轨道画在它里面）
//        → `SliderBufferingAnimationView y=7 h=4`（⇒ 轨道中线就在 y≈7…11 那一条）
//     → **两颗时间标签**（原生就有：`0:42` / `-3:13`，见照片 163 轨道下面那一行）
//
//   ⇒ 所以这一轮**不画自己的时间**，只把原生的那两颗换成等宽数字；
//     只有"一颗都没找到"的版本才退到自绘（见 `progressTimeLabels` 的注释）。
//
// ## 这一轮只做三件事，**不动任何几何、不动触摸**
//
//   ① 轨道换成 4pt：`setMinimumTrackImage` / `setMaximumTrackImage` 给一张 1×N 纯色图，
//      UISlider 横向拉伸它、高度保持 N（这样比"盖一条自己的轨道"安全得多 —— 拖动手势
//      在 UISlider 自己身上，盖上去的层要么吃触摸、要么得靠替身转发）；
//   ② 圆钮换成 4×4 全透明图 ⇒ 看不见，但点击跳播 / 拖动 / 无障碍全部还是 Spotify 原生行为；
//   ③ 两颗时间标签的字体换成 `monospacedDigitSystemFont`（宽度恒定 ⇒ 不抖）。
//
// ## 为什么端头是**方的**（AM 是胶囊）
//
// 胶囊要靠 `resizableImage(withCapInsets:)` 的端帽，而 `UIImageView` 渲染时**未必**认端帽：
// 认了是胶囊，不认就被横向拉成一只长椭圆（比方头难看得多）。本机没有 Swift 编译器，
// 一次 CI 很贵 ⇒ 先出"方头 4pt"这条零风险的；端帽等下一张截图再定要不要赌。
//
// ## 收尾
//
// 三张原图 + 每个标签的原字体都在第一次改之前记下来了（`progressOriginal*`），
// `teardownProgress()` 按原值写回；开关关掉 / 离开播放页都会走到它。
//
// 日志 tag：`[iOS27]`，一次性一行 `progress styled — …`。
import Foundation
import UIKit
import ObjectiveC.runtime

@MainActor
extension NowPlayingIOS27 {

    // MARK: - 常量

    /// 进度条那颗 `UISlider` 的 id（真机树：`Slider@-2,0,362,17,id=SPTNowPlayingSliderV2`）。
    static let progressSliderIdentifier = "SPTNowPlayingSliderV2"
    /// 轨道厚度（AM 那条按 414pt 宽量 ≈ 4pt；原生是 2–3pt）。
    static let progressTrackHeight: CGFloat = 4
    /// 已播部分：接近纯白。
    static let progressPlayedColour = UIColor(white: 1, alpha: 0.95)
    /// 未播部分：半透明白。
    static let progressRestColour = UIColor(white: 1, alpha: 0.30)
    /// 透明圆钮的边长 —— 留一点尺寸，免得 UISlider 把轨道算成整宽。
    static let progressThumbSide: CGFloat = 4
    /// 时间标签换的字体权重。
    static let progressTimeWeight: UIFont.Weight = .semibold

    // MARK: - 缓存图（只生成一次；UISlider 只有"指针不同"才会重画）

    static let progressPlayedImage: UIImage? = progressTrackImage(colour: progressPlayedColour)
    static let progressRestImage: UIImage? = progressTrackImage(colour: progressRestColour)
    static let progressThumbImage: UIImage? = progressTransparentImage(side: progressThumbSide)

    // MARK: - 状态

    /// 进度条单元（`Components.UI.ProgressBarUnitNowPlaying`）。
    static weak var progressUnitView: UIView?
    /// 我们改过的那一颗（记原图就记在它身上）。
    static weak var progressStyledSlider: UISlider?

    static var progressOriginalMinImage: UIImage?
    static var progressOriginalMaxImage: UIImage?
    static var progressOriginalThumbImage: UIImage?

    /// 被我们换成等宽数字的时间标签（弱引用，Spotify 重建时自己掉出去）。
    static let progressTimeLabelViews = NSHashTable<UILabel>.weakObjects()
    static var progressOriginalFonts: [ObjectIdentifier: UIFont] = [:]
    static var progressAppliedFonts: [ObjectIdentifier: UIFont] = [:]
    /// 上一次真机上量到的标签数（一次性日志用）。
    static var progressTimeLabelCount = 0

    static var didLogProgress = false

    // MARK: - 每拍入口

    /// 把轨道换成 4pt、圆钮藏掉、时间改等宽。页面里没有进度条就返回 false。
    @discardableResult
    static func placeProgress(in page: UIView) -> Bool {
        guard let unit = progressUnit(in: page), let track = trackSlider(in: unit) else {
            return false
        }
        progressUnitView = unit

        var changed = false
        if let slider = track as? UISlider, styleProgressTrack(slider) { changed = true }
        let styled = styleProgressTimeLabels(in: unit)
        changed = styled.changed || changed

        if !didLogProgress {
            didLogProgress = true
            writeDebugLog(
                "[\(logTag)] progress styled — \(NSStringFromClass(type(of: track)))"
                    + " \(Int(track.bounds.width))×\(Int(track.bounds.height)),"
                    + " track \(Int(progressTrackHeight))pt, thumb hidden,"
                    + " \(progressTimeLabelCount) time label(s) set to tabular digits"
            )
        }
        return changed
    }

    // MARK: - 找单元 / 找滑块

    /// 进度条单元：**只认当前可见页**那一个。
    ///
    /// ★ 2026-10-24（日志 20 的同类现场）：听歌页的 pager 里同时留着相邻页的 cell，
    ///   旧写法先问 `SPTNowPlayingView` 再整页 BFS ⇒ 经常先撞上**离屏**那一份。
    ///   后果不只是进度条样式没上：`lyricsStageFrame` 用它的 y 算歌词区高度，离屏
    ///   那一份在 y≈-413 ⇒ 高度算成负数 ⇒ 歌词容器永远不铺（点了没反应）。
    ///   这里和底排/标题一样，只接 `isControlOnPage` 的那一份。
    static func progressUnit(in page: UIView) -> UIView? {
        if let unit = progressUnitView, unit.window != nil,
           isControlOnPage(unit, in: page, requireAlpha: false) {
            return unit
        }
        var queue: [UIView] = [page]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let view = queue.removeFirst()
            visited += 1
            if view.accessibilityIdentifier == NowPlayingLyricsPlate.progressUnitIdentifier,
               isControlOnPage(view, in: page, requireAlpha: false) {
                return view
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// 单元里那颗滑块：先按 id，再退回"单元里第一颗 UISlider"。
    private static func trackSlider(in unit: UIView) -> UIView? {
        if let direct = NowPlayingLyricsPlate.findByIdentifier(progressSliderIdentifier, in: unit) {
            return direct
        }
        var queue: [UIView] = [unit]
        var visited = 0
        while !queue.isEmpty, visited < 200 {
            let view = queue.removeFirst()
            visited += 1
            if view is UISlider { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    // MARK: - 轨道 / 圆钮

    /// 换轨道图 + 藏圆钮。**原值只在第一次（或换了新滑块）时记**。
    private static func styleProgressTrack(_ slider: UISlider) -> Bool {
        if progressStyledSlider !== slider {
            progressStyledSlider = slider
            progressOriginalMinImage = slider.minimumTrackImage(for: .normal)
            progressOriginalMaxImage = slider.maximumTrackImage(for: .normal)
            progressOriginalThumbImage = slider.thumbImage(for: .normal)
        }
        var changed = false
        if let image = progressPlayedImage, slider.minimumTrackImage(for: .normal) !== image {
            slider.setMinimumTrackImage(image, for: .normal)
            changed = true
        }
        if let image = progressRestImage, slider.maximumTrackImage(for: .normal) !== image {
            slider.setMaximumTrackImage(image, for: .normal)
            changed = true
        }
        if let image = progressThumbImage, slider.thumbImage(for: .normal) !== image {
            slider.setThumbImage(image, for: .normal)
            changed = true
        }
        return changed
    }

    /// 一条 1×N 的纯色图（UISlider 横向拉伸它、高度保持 N ⇒ 就是 N pt 的轨）。
    ///
    /// ⚠️ 宽度写 1：写宽了又不用端帽的话，拉伸时端头会被拉成椭圆。
    private static func progressTrackImage(colour: UIColor) -> UIImage? {
        let size = CGSize(width: 1, height: progressTrackHeight)
        guard size.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            colour.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// 全透明的小方块（当圆钮用 ⇒ 看得见的是"没有钮"，但触摸/拖动还是 UISlider 自己的）。
    private static func progressTransparentImage(side: CGFloat) -> UIImage? {
        let size = CGSize(width: max(1, side), height: max(1, side))
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            UIColor.clear.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - 时间标签

    /// 进度条单元里的时间标签（原生那两颗），换成**等宽数字**字体。
    ///
    /// 只认"看得见"的（`isHidden` / `alpha` 都排除），并且**跳过我们自己画的**
    /// （id 前缀 `eevee-ios27-`）—— 老版本没有原生标签时，这条会返回 0，
    /// `placeProgress` 的日志会如实写 `0 time label(s)`，不会假装成功。
    private static func styleProgressTimeLabels(in unit: UIView) -> (changed: Bool, count: Int) {
        var changed = false
        var count = 0
        for label in progressTimeLabels(in: unit) {
            count += 1
            let key = ObjectIdentifier(label)
            if !progressTimeLabelViews.contains(label) {
                progressTimeLabelViews.add(label)
                if let font = label.font { progressOriginalFonts[key] = font }
            }
            guard let current = label.font else { continue }
            let wanted = UIFont.monospacedDigitSystemFont(
                ofSize: current.pointSize,
                weight: progressTimeWeight
            )
            if progressAppliedFonts[key] != wanted {
                label.font = wanted
                progressAppliedFonts[key] = wanted
                changed = true
            }
        }
        progressTimeLabelCount = count
        return (changed, count)
    }

    /// 单元子树里所有看得见的 `UILabel`（预算 200 个视图，够覆盖这一小块）。
    private static func progressTimeLabels(in unit: UIView) -> [UILabel] {
        var result: [UILabel] = []
        var queue: [UIView] = [unit]
        var visited = 0
        while !queue.isEmpty, visited < 200 {
            let view = queue.removeFirst()
            visited += 1
            queue.append(contentsOf: view.subviews)
            guard let label = view as? UILabel, !label.isHidden, label.alpha > 0.01 else { continue }
            let identifier = label.accessibilityIdentifier ?? ""
            guard !identifier.hasPrefix("eevee-ios27-") else { continue }
            result.append(label)
        }
        return result
    }

    // MARK: - 收尾

    /// 把轨道那三张图与时间标签的原字体写回去（开关关掉 / 离开播放页）。
    static func teardownProgress() {
        if let slider = progressStyledSlider {
            if slider.minimumTrackImage(for: .normal) !== progressOriginalMinImage {
                slider.setMinimumTrackImage(progressOriginalMinImage, for: .normal)
            }
            if slider.maximumTrackImage(for: .normal) !== progressOriginalMaxImage {
                slider.setMaximumTrackImage(progressOriginalMaxImage, for: .normal)
            }
            if slider.thumbImage(for: .normal) !== progressOriginalThumbImage {
                slider.setThumbImage(progressOriginalThumbImage, for: .normal)
            }
        }
        for label in progressTimeLabelViews.allObjects {
            guard let font = progressOriginalFonts[ObjectIdentifier(label)] else { continue }
            if label.font != font { label.font = font }
        }
    }

    /// 状态清空（`clearState()` 里调用）。
    static func clearProgressState() {
        progressUnitView = nil
        progressStyledSlider = nil
        progressOriginalMinImage = nil
        progressOriginalMaxImage = nil
        progressOriginalThumbImage = nil
        progressTimeLabelViews.removeAllObjects()
        progressOriginalFonts.removeAll()
        progressAppliedFonts.removeAll()
        progressTimeLabelCount = 0
        didLogProgress = false
    }
}
