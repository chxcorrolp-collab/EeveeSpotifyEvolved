import SwiftUI

// 歌词舞台的「大字错落」排版（样式：`tilt`）。
//
// 设计**参考** Folia 的 `tilt`（`folia-major/src/components/visualizer/tilt/`）：
//   · 一屏只留 3~4 行 —— 不是"歌词列表"，是"舞台上的一句话"；
//   · 焦点行明显更大，上下两行按距离缩下去、变淡；
//   · 每一行按距离轻微斜排、左右错开一点，避免整块像一份文档；
//   · 逐字点亮仍然由 `SynchronizedLyricText` 负责（和全屏歌词页**同一套**
//     光晕 / 填充前沿 / 长音强调），所以两档的"唱到哪一个字"在视觉上是一致的。
//
// ⚠️ 只参考**排版思路与参数**，不复制 Folia 的代码/注释（它是 AGPL-3.0，我们是 GPL-3.0；
//   见 `C:\dsh\me\HANDOFF_2026-10-23_EeveeSpotify-ng_LyricsStage-Folia.md` §4 的 C 档）。
// ⚠️ 这里**不给滚动**：一屏就那几行（Folia 的 tilt 同样不滚动）。要翻歌词请切回
//   `appleMusic` 那一档（设置 → 实验 → 歌词舞台 → 样式）。
//
// 性能（交接文档 §5 / §6 的教训）：
//   · 只有焦点行开逐字特效（`appliesTimingEffects`），其余三行是**静态绘制**；
//   · 不重建布局：每帧只是"换一个 `playbackTime` 交给渲染器"，行窗口只在换行时变；
//   · 不给 `ForEach` 做任何逐帧变化的 identity —— 行 id 稳定，SwiftUI 只重算内容。

@available(iOS 26.0, *)
struct LyricsStageTiltLayout: View {

    /// 行模型（来自 `LyricsDto.toAppleMusicLyricLines()`）。
    let lines: [LyricLine]
    /// 当前播放时间（秒）。
    let playbackTime: TimeInterval
    let primaryColor: Color
    /// 是否画行译文（与舞台其它两档同一口径，由宿主判好传进来）。
    let showsTranslation: Bool

    /// 焦点行前后各留几行（-1 … +2 ⇒ 最多 4 行）。
    private static let leadingContext = 1
    private static let trailingContext = 2
    /// 行与行之间的间距（大字档，比全屏歌词页更大）。
    private static let rowSpacing: CGFloat = 20
    /// 左右内边距。
    private static let sideInset: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - Self.sideInset * 2, 1)
            let focus = focusIndex
            let indices = visibleIndices(focus: focus)

            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(indices, id: \.self) { index in
                    row(index: index, focus: focus, width: width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, Self.sideInset)
            // 换行时整块淡入淡出（只在焦点行变化时触发，不是每帧）。
            .animation(.easeInOut(duration: 0.22), value: focus)
        }
    }

    // MARK: - 焦点行

    /// 当前焦点行的下标。播放位置在第一行之前时落在 0（否则开场会一片空）。
    private var focusIndex: Int {
        guard !lines.isEmpty else { return 0 }
        let position = LyricPlaybackTimeline.position(at: playbackTime, in: lines)
        guard let id = position.highlightedLyricID,
              let index = lines.firstIndex(where: { $0.id == id }) else {
            return 0
        }
        return index
    }

    /// 这一屏要画哪几行：焦点前 1 行 + 焦点 + 后 2 行，越界就裁掉。
    private func visibleIndices(focus: Int) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(Self.leadingContext + Self.trailingContext + 1)
        for offset in -Self.leadingContext...Self.trailingContext {
            let index = focus + offset
            guard index >= 0, index < lines.count else { continue }
            result.append(index)
        }
        return result
    }

    // MARK: - 单行

    private func row(index: Int, focus: Int, width: CGFloat) -> some View {
        let line = lines[index]
        let distance = index - focus
        let isFocus = distance == 0

        return SynchronizedLyricText(
            syllables: line.syllables,
            text: line.text,
            playbackTime: playbackTime,
            isFocused: isFocus,
            // 非焦点行直接按 0 画（不模糊、不缩放、不发光）——
            // 舞台的"层次"靠字号与不透明度表达，再叠一层模糊会糊成一团。
            focusStrength: isFocus ? 1 : 0,
            translation: line.translation,
            romanization: line.romanization,
            backgroundVocal: line.backgroundVocal,
            constrainedWidth: width,
            alignment: .leading,
            typography: Self.typography(for: distance),
            primaryColor: primaryColor,
            appliesTimingEffects: isFocus,
            showsBackgroundVocals: true,
            showsTranslation: showsTranslation
        )
        .opacity(Self.opacity(for: distance))
        .rotationEffect(.degrees(Self.rotation(for: distance)), anchor: .leading)
        .padding(.leading, Self.leading(for: distance))
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    // MARK: - 按距离取参数

    /// 字号分档：焦点 34pt、上下各一档、再远一档。
    ///
    /// 34 这个数不是拍的：全屏歌词页是 22、`.player` 也是 22，而这一档**一屏只有 4 行**、
    /// 左右各留 28pt ⇒ 366pt 宽的容器放 34pt 的拉丁文一行约 18~22 字符，长句会折成两行
    /// （折行由 `SynchronizedLyricText` 自带的构建器处理，不用这里管）。
    /// 再大就会在中文长句上折成三行、把下面几行挤出屏幕。
    private static func typography(for distance: Int) -> LyricsTypographyScale {
        let size: CGFloat
        switch distance {
        case 0: size = 34
        case 1, -1: size = 22
        default: size = 17
        }
        return LyricsTypographyScale(
            primaryFontSize: size,
            supplementalFontSize: max(size * 0.52, 12),
            lineSpacing: 8,
            wrappedLineSpacing: 4,
            supplementalSpacing: 4
        )
    }

    /// 不按距离发糊，只变淡（发糊在深色舞台上会读成"没加载出来"）。
    private static func opacity(for distance: Int) -> Double {
        switch distance {
        case 0: return 1
        case 1, -1: return 0.42
        default: return 0.22
        }
    }

    /// 轻微斜排：焦点行水平，往后的行角度递增（Folia 的 tilt 是整行斜着摆，
    /// 这里只取 ±3° 以内 —— 手机屏幕窄，再斜就读不动了）。
    private static func rotation(for distance: Int) -> Double {
        switch distance {
        case 0: return 0
        case 1: return 1.6
        case -1: return -1.6
        default: return 3
        }
    }

    /// 左右错开：焦点行贴齐左边，后续行往右让一点，形成"斜着落下来"的感觉。
    private static func leading(for distance: Int) -> CGFloat {
        switch distance {
        case 0: return 0
        case 1: return 16
        case -1: return 8
        default: return 24
        }
    }
}
