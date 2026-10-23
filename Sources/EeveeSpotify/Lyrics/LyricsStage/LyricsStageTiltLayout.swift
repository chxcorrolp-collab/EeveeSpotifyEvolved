import SwiftUI

// 歌词舞台的唯一排版：「更炫酷的逐词歌词」（参考 Folia 的 `tilt`）。
//
// ★ 2026-10-24（用户拍板）：「歌词舞台就只留这个仿 fo 的就好，另外一个没必要留着 ——
//   除了仿 fo，正常的逐词歌词都是要进播放器的」。⇒ `appleMusic` 那一档（复用
//   `AppleMusicLyricsPage` 的整屏滚动版）**整条删掉**，舞台只剩这一种观感。
//
// ## 为什么第一版"不炫"（2026-10-24 复盘）
//
//   原来只做了「字号 34/20 + 缩进 + 透明度」，那是**排版**，不是**舞台**：
//     · 没有 z 深度 / 没有透视 ⇒ 画面是平的；
//     · 换行只是整块淡一下，没有"新行落位、旧行飘走"；
//     · 光晕是 22pt 正文那一档（`glowRadius = 5pt` 固定值），34pt 上几乎看不见；
//     · 没有节奏 —— Folia 的"活"有一半来自随拍脉冲。
//
// ## 这一版（v2）做了什么
//
//   ① **3D 层叠**：上下文行 `rotation3DEffect`（±18°、perspective 0.55）+ 缩放 + 纵向偏移
//      ⇒ 是"插进屏幕的层"，不是"缩小的文字"；
//   ② **进出场**：新行从下方 44pt / 0.9 倍 / 透明滑入，旧行向上飘走并淡出（`transition`）；
//   ③ **真的有光**：焦点行叠两层 shadow（9pt 紧光 + 24pt 大光晕），上下文行改用 0.7pt 模糊
//      （景深），不再靠压透明度；
//   ④ **节奏**：用**音节 onset** 当伪节拍（逐词时间轴本身就是节奏轨，不需要音频）——
//      每个字起音后 0.22s 内焦点行有最多 +3.5% 的脉冲；
//   ⑤ **光带**：焦点行下方一条 2pt 进度光带，长度 = 本行已唱比例。
//
// ⚠️ 只参考 Folia 的**排版思路与参数**，不复制它的代码/注释（它是 AGPL-3.0，我们是 GPL-3.0）。
// ⚠️ 性能：120Hz 屏 + 每帧 3 行 AttributedString + 两层 shadow + 3D 变换，开销**显著上升**
//   （设置页文案已写明）。真机上若掉帧，先砍 shadow 的第二层、再砍 3D 透视。
//
// 数据层（`LyricSyllable` 的起止时间）全部来自各歌词源，不在这里算。

@available(iOS 26.0, *)
struct LyricsStageTiltLayout: View {

    /// 行模型（来自 `LyricsDto.toAppleMusicLyricLines()`）。
    let lines: [LyricLine]
    /// 当前播放时间（秒）。
    let playbackTime: TimeInterval
    let primaryColor: Color
    /// 是否画行译文（舞台口径，由宿主判好传进来）。
    let showsTranslation: Bool

    /// 焦点行上下各留一行（-1 … +1 ⇒ 最多 3 行）。
    private static let leadingContext = 1
    private static let trailingContext = 1
    /// 行与行之间的间距。
    private static let rowSpacing: CGFloat = 22
    /// 左右内边距。
    private static let sideInset: CGFloat = 26
    /// 上下文行往右让出的距离（焦点行凸出来）。
    private static let contextIndent: CGFloat = 18
    /// 上下文行的 3D 倾角（度）与透视系数。
    private static let contextTiltDegrees: Double = 18
    private static let perspective: CGFloat = 0.55
    /// 音节脉冲时长（秒）与幅度。
    private static let pulseWindow: TimeInterval = 0.22
    private static let pulseAmount: CGFloat = 0.035

    /// 一屏里的三行（带它在 `lines` 里的下标，用来算"离焦点多远"）。
    private struct Row: Identifiable {
        let index: Int
        let line: LyricLine
        var id: LyricLine.ID { line.id }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - Self.sideInset * 2, 1)
            let focus = focusIndex
            let rows = visibleRows(focus: focus)

            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(rows) { row in
                    self.row(row, focus: focus, width: width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, Self.sideInset)
            // 换行时：位置/缩放/倾角走弹簧；新行旧行走上面的 `transition`。
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: focus)
        }
    }

    // MARK: - 焦点

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

    /// 这一屏要画哪几行：焦点前 1 行 + 焦点 + 后 1 行，越界就裁掉。
    private func visibleRows(focus: Int) -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(Self.leadingContext + Self.trailingContext + 1)
        for offset in -Self.leadingContext...Self.trailingContext {
            let index = focus + offset
            guard index >= 0, index < lines.count else { continue }
            rows.append(Row(index: index, line: lines[index]))
        }
        return rows
    }

    // MARK: - 单行

    private func row(_ row: Row, focus: Int, width: CGFloat) -> some View {
        let line = row.line
        let distance = row.index - focus
        let isFocus = distance == 0
        // ④ 伪节拍：这个字起音后的一小段里，焦点行轻轻"顶"一下。
        let pulse = isFocus ? syllablePulse(for: line) : 0

        return ZStack(alignment: .bottomLeading) {
            // ⑤ 光带：本行已唱比例（放在文字**下面** 10pt 处）。
            if isFocus {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [primaryColor.opacity(0.9), primaryColor.opacity(0.15)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(width * lineProgress(for: line), 3), height: 2)
                    .offset(y: 12)
                    .blur(radius: 0.4)
            }

            SynchronizedLyricText(
                syllables: line.syllables,
                text: line.text,
                playbackTime: playbackTime,
                isFocused: isFocus,
                focusStrength: isFocus ? 1 : 0,
                // 上下文行只留主歌词：11pt × 0.32 的译文在深色底上读不出来、还把三行挤成六行。
                translation: isFocus && showsTranslation ? line.translation : nil,
                romanization: isFocus ? line.romanization : nil,
                backgroundVocal: isFocus ? line.backgroundVocal : nil,
                constrainedWidth: width,
                alignment: .leading,
                typography: Self.typography(for: distance),
                primaryColor: primaryColor,
                appliesTimingEffects: isFocus,
                showsBackgroundVocals: isFocus,
                showsTranslation: isFocus && showsTranslation
            )
        }
        // ④ 音节脉冲
        .scaleEffect(isFocus ? 1 + pulse : 0.93, anchor: .leading)
        // ① 3D 层叠：上下文行分别向前/向后倾，焦点行水平
        .rotation3DEffect(
            .degrees(isFocus ? 0 : Self.contextTiltDegrees * (distance < 0 ? 1 : -1)),
            axis: (x: 1, y: 0, z: 0),
            anchor: .leading,
            perspective: Self.perspective
        )
        .offset(y: isFocus ? 0 : (distance < 0 ? -4 : 8))
        .padding(.leading, isFocus ? 0 : Self.contextIndent)
        // ③ 光：焦点行两层 shadow（紧光 + 大光晕）；上下文行用景深模糊代替压暗
        .shadow(color: isFocus ? primaryColor.opacity(0.45) : .clear, radius: isFocus ? 9 : 0)
        .shadow(color: isFocus ? primaryColor.opacity(0.20) : .clear, radius: isFocus ? 24 : 0)
        .blur(radius: isFocus ? 0 : 0.7)
        .opacity(isFocus ? 1 : 0.32)
        .frame(maxWidth: .infinity, alignment: .leading)
        // ② 进出场
        .transition(
            .asymmetric(
                insertion: .offset(y: 44)
                    .combined(with: .opacity)
                    .combined(with: .scale(scale: 0.9)),
                removal: .offset(y: -30).combined(with: .opacity)
            )
        )
    }

    // MARK: - 数据

    /// 4 伪节拍：这一个字起音之后 `pulseWindow` 内给一个衰减的放大。
    ///
    /// 为什么用音节、不用音频：我们是注入式 tweak，拿不到 Spotify 的 PCM（做音频分析得先做
    /// Core Audio 重绑）。而逐词时间轴里每个字的 onset 就是**歌声音头**，与拍点的相关性很高 ——
    /// 用它能拿到 Folia 那种"随唱顶一下"的节奏感。
    private func syllablePulse(for line: LyricLine) -> CGFloat {
        guard let onset = line.syllables.last(where: { $0.startTime <= playbackTime + 0.001 })
        else { return 0 }
        let age = playbackTime - onset.startTime
        guard age >= 0, age < Self.pulseWindow else { return 0 }
        return Self.pulseAmount * CGFloat(1 - age / Self.pulseWindow)
    }

    /// 这一行已经唱了多少（0…1），给光带用。
    private func lineProgress(for line: LyricLine) -> CGFloat {
        // 行级同步的来源没有 `duration`（只有"下一行什么时候来"），退一个常见行时长。
        let duration = line.duration ?? 3
        guard duration > 0 else { return 0 }
        return CGFloat(min(max((playbackTime - line.time) / duration, 0), 1))
    }

    /// 字号/译文分档：焦点 34pt（译文 15pt），上下文 20pt（不画译文）。
    private static func typography(for distance: Int) -> LyricsTypographyScale {
        let size: CGFloat = distance == 0 ? 34 : 20
        return LyricsTypographyScale(
            primaryFontSize: size,
            supplementalFontSize: distance == 0 ? 15 : 11,
            lineSpacing: 8,
            wrappedLineSpacing: 4,
            supplementalSpacing: 4
        )
    }
}
