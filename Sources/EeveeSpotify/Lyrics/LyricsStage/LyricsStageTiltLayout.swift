import Foundation
import SwiftUI

// 歌词舞台的唯一排版：「更炫酷的逐词歌词」（仿 Folia 的 `tilt`）。
//
// ★★ 2026-10-24 重写（用户：「仿folia这件事情，接着做吧；还是那句话，不考虑性能开销」）：
//   上一版把「tilt」理解成了“焦点行 + 上下各一行上下文 + 3D 倾斜”，那不是 Folia 的
//   Tilt —— Folia 的 Tilt 是**把当前这一句歌词拆成 1~4 行大字**，其中一行随机用
//   斜体/错落字形；这一句的 1~4 行按时间**逐行出现**，每个字再按自己的起音时间
//   逐个浮起来、亮起来。整句换掉时，新的一句从下方升入、旧的一句向上飘走。
//
// 这一版按 Folia 的**行为**重写（只参考排版/参数，不复制它的 AGPL 代码）：
//
//   ① 1~4 段：按字数 + 一个由行起始时间决定的伪随机数决定拆几行；尽量在空格/
//      标点处断开；最后一段很短时（≤2 字）放大一点（Folia 的 short-last-line）。
//   ② 其中一段是 tilt：斜体、字重轻、字距宽、逐字上下错开（±size/6）；
//      其余段是 normal：常规字重、字距略宽。
//   ③ 逐字揭示：整段出现时每个字按 0.04s/0.05s 错开淡入（0.5s）；tilt 字从
//      2× 错落位落到 1×，normal 字没有位移。**不分“已唱/未唱”两种颜色、也不加光晕**
//      —— 双层光晕是 Folia Classic 的参数，Tilt 没有。
//   ④ 逐字脉冲：这个字起音后的一个短窗里放大 15%~18%（tilt 18 / normal 15），
//      随后快速回落 —— 这是“字在唱”的节奏，不是整行抖。
//   ⑤ 换行：**完全由 playbackTime 手工插值**（不依赖 SwiftUI 的 transition）：
//      新句 0.55s 从 +10pt / 0.98 倍淡入；旧句 0.45s 内淡出，只上飘 8pt。
//      Folia 的父容器换行就是纯 opacity 0.45s（旧句不往上飞）—— 我们上一版为了躲
//      重叠把它推到 -140pt，真机看起来就是“跳一下”，这一版改回淡出。
//   ⑥ 译文/罗马字：译文在整句块下方（15pt、0.62），罗马字在上方（12pt、0.45）；
//      两者都跟着整句的 enter 淡入。副唱在译文下方一行。
//   ⑦ 段**不做横向错位**：Folia 的段是 flex-col items-center，只有 tilt 段里的字
//      上下错开；上一版给每段 ±8/±10pt 的横向抖动，看起来是“乱”而不是“设计”。
//
// ⚠️ 只参考 Folia 的**效果与参数**：没有复制它的代码/注释（AGPL-3.0）。
// ⚠️ 性能：每帧给每个字建一个 Text + 逐字 scaleEffect；用户明确说过
//   “不考虑性能开销”，所以先按最好看的一档写。真机若掉帧，先砍逐字 scaleEffect，
//   最后才把逐字 HStack 换成整段 Text。
//
// 数据层：字的时间来自 `LyricLine.syllables`（逐字/逐词源）；没有时就按整句时长
// 均分给非空格字符（行级同步源）。

@available(iOS 26.0, *)
struct LyricsStageTiltLayout: View {

    /// 整首的行模型（与全屏页同一份 `toAppleMusicLyricLines()`）。
    let lines: [LyricLine]
    /// 每帧变化的播放时间（秒）。
    let playbackTime: TimeInterval
    let primaryColor: Color
    /// 舞台口径：有译文且用户没关「隐藏译文」时才画。
    let showsTranslation: Bool

    /// 换行动画：新句进入 0.55s；旧句在结束后 0.45s 内淡出（Folia 的父容器 exit 是
    /// 纯 opacity 0.45s，**不往上飞** —— 见 §24 的对照）。
    private static let enterDuration: Double = 0.55
    private static let exitDuration: Double = 0.45

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(geometry.size.width, 1)
            let focus = Self.focusIndex(in: lines, at: playbackTime)
            let current: LyricLine? = focus.map { lines[$0] }
            let previous: LyricLine? = (focus ?? 0) > 0 ? lines[(focus ?? 1) - 1] : nil

            ZStack {
                // 旧句：只在上句结束后 0.30s 内出现，向上飘走。
                if let previous, let current, previous.id != current.id {
                    let previousIndex = (focus ?? 1) - 1
                    // ★★ 旧句的“推出”从**新句开始的那一刻**算起，而不是旧句自己
                    //   `lineEnd`（精确时长的行可能比下一句早结束，按 lineEnd 算会在
                    //   下一句出现前就淡完，下一句一来直接“啪”地消失）。新句开始时
                    //   exit = 0，0.30s 推完。
                    let exit = Self.exitProgress(next: current, at: playbackTime)
                    if exit >= 0, exit < 1 {
                        TiltLineBlock(
                            line: previous,
                            lines: lines,
                            index: previousIndex,
                            playbackTime: playbackTime,
                            primaryColor: primaryColor,
                            showsTranslation: false,
                            availableWidth: availableWidth,
                            enter: 1,
                            exit: exit,
                            outgoing: true
                        )
                    }
                }

                // 新句：从下方升入。
                if let current, let focus {
                    TiltLineBlock(
                        line: current,
                        lines: lines,
                        index: focus,
                        playbackTime: playbackTime,
                        primaryColor: primaryColor,
                        showsTranslation: showsTranslation,
                        availableWidth: availableWidth,
                        enter: Self.enterProgress(for: current, at: playbackTime),
                        exit: 0,
                        outgoing: false
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 26)
    }

    // MARK: - 行索引 / 进出场

    /// 当前焦点行的下标：优先用 `LyricPlaybackTimeline` 的高亮行；没有时取
    /// “最后一个 time ≤ 当前播放位置”的行（第一句之前落在 0）。
    private static func focusIndex(in lines: [LyricLine], at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        let position = LyricPlaybackTimeline.position(at: time, in: lines)
        if let id = position.highlightedLyricID,
           let index = lines.firstIndex(where: { $0.id == id }) {
            return index
        }
        var fallback = 0
        for (index, line) in lines.enumerated() where line.time <= time {
            fallback = index
        }
        return fallback
    }

    /// 旧句的退出进度：**下一句开始时**为 0，0.30s 后为 1。
    ///
    /// 不能用旧句自己的 `lineEnd`：精确时长的行会比下一句早结束，按 lineEnd 算的话
    /// 下一句出现时 exit 已经 >1，旧句直接消失（用户要的“推出”就没了）。
    private static func exitProgress(next: LyricLine, at time: TimeInterval) -> Double {
        (time - next.time) / exitDuration
    }

    /// 整句进入进度（0 = 还没开始，1 = 完全就位）。
    private static func enterProgress(for line: LyricLine, at time: TimeInterval) -> Double {
        clamp01((time - (line.time - 0.10)) / enterDuration)
    }

    /// 这一句“唱完”的时间：有精确时长就用它；否则用下一句的时间（LRC 行级同步），
    /// 最后一句退 4s。
    fileprivate static func lineEnd(_ line: LyricLine, in lines: [LyricLine], index: Int) -> TimeInterval {
        if let duration = line.duration, duration > 0.1 {
            return line.time + duration
        }
        if index + 1 < lines.count {
            return max(line.time + 0.8, lines[index + 1].time)
        }
        return line.time + 4
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

// MARK: - 整句块（1~4 段 + 译文/罗马字）

@available(iOS 26.0, *)
private struct TiltLineBlock: View {

    let line: LyricLine
    let lines: [LyricLine]
    let index: Int
    let playbackTime: TimeInterval
    let primaryColor: Color
    let showsTranslation: Bool
    let availableWidth: CGFloat
    let enter: Double
    let exit: Double
    let outgoing: Bool

    var body: some View {
        let endTime = LyricsStageTiltLayout.lineEnd(line, in: lines, index: index)
        let segments = TiltLayout.segments(for: line, lineEnd: endTime)

        VStack(spacing: 12) {
            if let romanization = line.romanization,
               !romanization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(romanization)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(primaryColor.opacity(0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                    .opacity(enter)
            }

            ForEach(segments) { segment in
                TiltSegmentRow(
                    segment: segment,
                    playbackTime: playbackTime,
                    primaryColor: primaryColor,
                    availableWidth: availableWidth,
                    outgoing: outgoing
                )
            }

            if showsTranslation,
               let translation = line.translation,
               !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(translation)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(primaryColor.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 6)
                    .opacity(enter)
            }

            if let background = line.backgroundVocal?.text,
               !background.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(background)
                    .font(.system(size: 12, weight: .regular))
                    .italic()
                    .foregroundColor(primaryColor.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .opacity(enter)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .opacity(outgoing ? 1 - exit : enter)
        // ★ 2026-10-24（用户：「这个 folia 感觉不咋地啊」）：原来看旧句向上飞 **-140pt**，
        //   那是为了在 ZStack 里躲开新句；但 Folia 的 Tilt 换行只是**淡出**（父容器
        //   exit 0.45s，没有位移），真正躲不开的重叠交给交叉淡出。140pt 的大位移正是
        //   看起来"跳一下"的来源。现在只留 8pt 的上飘，幅度与 Folia 的 -12/-16 同档。
        .offset(y: CGFloat(outgoing ? -8 * exit : (1 - enter) * 10))
        .scaleEffect(CGFloat(outgoing ? 1 : 0.98 + 0.02 * enter))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(line.text))
        .accessibilityHidden(outgoing)
    }
}

// MARK: - 单段（一行大字）

@available(iOS 26.0, *)
private struct TiltSegmentRow: View {

    let segment: TiltSegment
    let playbackTime: TimeInterval
    let primaryColor: Color
    let availableWidth: CGFloat
    let outgoing: Bool

    var body: some View {
        let size = TiltLayout.fontSize(for: segment, availableWidth: availableWidth)
        let tracking = TiltLayout.tracking(for: segment)
        let spacing = size * tracking
        // ★ 每一行（段）自己也有“推进”感：Folia 的段容器 initial
        //   `{ opacity: 0, y: 24, scale: 0.92 }` → animate `{ opacity: 1, y: 0, scale: 1 }`，
        //   时长 0.6s；它的 `visibleSegmentIndex` 在段首字前 0.25s 就翻真。
        let row = outgoing ? 1 : min(max((playbackTime - (segment.startTime - 0.25)) / 0.55, 0), 1)

        HStack(alignment: .center, spacing: spacing) {
            ForEach(segment.chars.indices, id: \.self) { index in
                glyph(segment.chars[index], position: index, size: size)
            }
        }
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .center)
        .opacity(row)
        // ★ 2026-10-24（用户：「这个 folia 感觉不咋地啊」）：这里原来按段加 ±8/±10pt 的
        //   **横向抖动**（`segment.horizontalOffset`）。Folia 的段是 flex-col items-center，
        //   一行都不横移；只有 tilt 段里的**字**上下错开。横向随机偏移正是"看着乱"的来源。
        .offset(y: CGFloat((1 - row) * 24))
        .scaleEffect(CGFloat(0.92 + 0.08 * row))
    }

    @ViewBuilder
    private func glyph(_ char: TiltChar, position: Int, size: CGFloat) -> some View {
        if char.isSpace {
            // 空格不参与逐字动画，只占位。
            Color.clear.frame(width: size * 0.28, height: size * 0.8)
        } else {
            let reveal = outgoing ? 1 : revealProgress(for: char, position: position)
            let pulse = outgoing ? 0 : pulseAmount(for: char)
            let tiltY: CGFloat = segment.isTilt
                ? (char.index.isMultiple(of: 2) ? -size / 6 : size / 6)
                : 0
            // Folia 的 tilt 字是 `y: ±yOffset*2 → ±yOffset`（**朝着自己的错落位落下**），
            // normal 字只有 opacity、没有 y。原来这里让每个字都从下方升 12/18pt，
            // 观感是"波浪上浮"，不是 Folia 的"字落位"。
            let settle = CGFloat(1 - reveal) * tiltY

            glyphText(char, size: size)
                // Folia 的 Tilt **没有光晕**（那是 Classic 模式的参数）。原来每个字两层
                // 白色 shadow（8/20pt）会让大字糊成一团，尤其配我们的模糊封面底。
                .foregroundColor(primaryColor)
                .scaleEffect(1 + pulse * (segment.isTilt ? 0.18 : 0.15))
                .offset(y: tiltY + settle)
                .opacity(reveal)
        }
    }

    private func glyphText(_ char: TiltChar, size: CGFloat) -> Text {
        var text = Text(String(char.character))
            .font(.system(size: size, weight: segment.isTilt ? .light : .regular))
        if segment.isTilt {
            text = text.italic()
        }
        return text
    }

    /// 这个字在**这一段出现之后**的第 `position` 个：Folia 的 delay 是 0.04s/字（tilt 0.05s），
    /// 每个字 opacity 0→1 用 0.5s；段的 visible 在段首字前 0.25s 翻真。
    private func revealProgress(for char: TiltChar, position: Int) -> Double {
        let segmentStart = segment.startTime - 0.20
        let stagger = segment.isTilt ? 0.05 : 0.04
        let start = segmentStart + Double(position) * stagger
        return min(max((playbackTime - start) / 0.5, 0), 1)
    }

    /// 逐字脉冲：起音后 0.2~0.9s 内按正弦放大，随后 0.25 的余晖在 ~1.2 倍时长里
    /// 回落到 0。只作用于这一个字，不会让整行抖。
    private func pulseAmount(for char: TiltChar) -> CGFloat {
        let duration = max(char.endTime - char.startTime, 0.08)
        let elapsed = playbackTime - char.startTime
        if elapsed < 0 { return 0 }
        if elapsed <= duration {
            return CGFloat(sin(elapsed / duration * Double.pi))
        }
        let after = elapsed - duration
        let ramp = max(duration * 1.2, 0.16)
        if after >= ramp { return 0 }
        return CGFloat(0.25 * (1 - after / ramp))
    }
}

// MARK: - 纯数据：拆段 / 逐字时间 / 字号

@available(iOS 26.0, *)
private struct TiltChar: Identifiable {
    let index: Int
    let character: Character
    let startTime: TimeInterval
    let endTime: TimeInterval
    let isSpace: Bool

    var id: Int { index }
}

@available(iOS 26.0, *)
private struct TiltSegment: Identifiable {
    let id: Int
    let text: String
    let chars: [TiltChar]
    let isTilt: Bool
    let isShortLast: Bool
    let startTime: TimeInterval
    let endTime: TimeInterval
    let horizontalOffset: CGFloat
}

@available(iOS 26.0, *)
private enum TiltLayout {

    // MARK: 拆段

    static func segments(for line: LyricLine, lineEnd: TimeInterval) -> [TiltSegment] {
        let characters = Array(line.text)
        guard !characters.isEmpty else { return [] }
        let timings = characterTimings(for: line, characters: characters, lineEnd: lineEnd)
        let ranges = splitRanges(characters, seed: line.time)
        let tiltIndex = chooseTiltIndex(count: ranges.count, seed: line.time)

        return ranges.enumerated().compactMap { index, range in
            guard !range.isEmpty else { return nil }
            let segmentChars = Array(timings[range])
            let text = String(Array(characters[range]))
            let first = segmentChars.first(where: { !$0.isSpace })
            let last = segmentChars.last(where: { !$0.isSpace })
            let start = first?.startTime ?? line.time
            let end = last?.endTime ?? (start + 0.4)
            let shortLast = index == ranges.count - 1
                && ranges.count > 1
                && text.trimmingCharacters(in: .whitespacesAndNewlines).count <= 2
            return TiltSegment(
                id: index,
                text: text,
                chars: segmentChars,
                isTilt: index == tiltIndex,
                isShortLast: shortLast,
                startTime: start,
                endTime: end,
                // Folia 的段是居中的（flex-col items-center），**不做横向错位**；
                // 只有 tilt 段里的字上下错开。这里保留字段只为兼容旧调用，值恒 0。
                horizontalOffset: 0
            )
        }
    }

    /// 按字数决定 1~4 段，再用行起始时间做一点伪随机抖动；尽量在空格/标点后断开。
    ///
    /// ★ 2026-10-24（用户：「这个 folia 感觉不咋地啊」）：行数改成 Folia 的公式
    ///   `log(charCount+4)/log(24) × jitter(0.7…1.3) × splitProbability(0.75)`，
    ///   阈值 0.45 / 1.05 / 1.7。原来那句 `≤10→1、≤20→2、≤34→3` 的台阶**太保守**：
    ///   一句 10 字的词只出 1 行大字（还会因为要放下而被压到 30pt），而 Folia 会出
    ///   2 行、每行 5 字、字号接近满档 —— 两种版式看起来完全不是一回事。
    private static func splitRanges(_ characters: [Character], seed: TimeInterval) -> [Range<Int>] {
        let count = characters.count
        guard count > 0 else { return [] }
        let normalized = log(Double(count) + 4) / log(24.0)
        let jitter = seedRandom(seed, 1) * 0.6 + 0.7
        let score = normalized * jitter * 0.75
        let target: Int
        if score < 0.45 {
            target = 1
        } else if score < 1.05 {
            target = 2
        } else if score < 1.7 {
            target = 3
        } else {
            target = 4
        }
        guard target > 1 else { return [0..<count] }

        var cuts: [Int] = []
        for step in 1..<target {
            let ideal = Int((Double(count) * Double(step) / Double(target)).rounded())
            let chosen = nearestBreak(characters, around: ideal) ?? ideal
            if chosen > 0, chosen < count, !cuts.contains(chosen) {
                cuts.append(chosen)
            }
        }
        let edges = ([0] + cuts.sorted() + [count])
        var ranges: [Range<Int>] = []
        for index in 0..<(edges.count - 1) where edges[index + 1] > edges[index] {
            ranges.append(edges[index]..<edges[index + 1])
        }
        return ranges.isEmpty ? [0..<count] : ranges
    }

    /// 在 `index` 附近 0…4 个字符内找“可以断”的位置（空格或常见标点之后）。
    private static func nearestBreak(_ characters: [Character], around index: Int) -> Int? {
        for delta in 0...4 {
            for candidate in [index - delta, index + delta] where candidate > 0 && candidate < characters.count {
                let previous = characters[candidate - 1]
                if previous.isWhitespace || punctuationCharacters.contains(previous) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// 哪一段用斜体/错落字形。Folia 的 `tiltStyleProbability` 默认 0.35：
    /// 每段各有 35% 的机会成为 tilt，一段都没有时就整句 normal（不是每句都斜）。
    private static func chooseTiltIndex(count: Int, seed: TimeInterval) -> Int {
        guard count > 0 else { return -1 }
        var candidates: [Int] = []
        for index in 0..<count where seedRandom(seed, 100 + Double(index)) < 0.35 {
            candidates.append(index)
        }
        guard !candidates.isEmpty else { return -1 }
        let choice = Int(seedRandom(seed, 300) * Double(candidates.count)) % candidates.count
        return candidates[choice]
    }

    // MARK: 逐字时间

    /// 给 `line.text` 的每个字符一个起止时间。
    ///
    /// 优先用 `line.syllables`（逐字/逐词源）：把每个 syllable 的时长均分给它的
    /// 非空格字符，再按字符顺序映射回整行（空格不参与、沿用前一个时间）。
    /// syllable 文本与整行对不上时（译文/罗马化混入等）退回“整句时长均分”。
    private static func characterTimings(
        for line: LyricLine,
        characters: [Character],
        lineEnd: TimeInterval
    ) -> [TiltChar] {
        if !line.syllables.isEmpty {
            var timed: [(character: Character, start: TimeInterval, end: TimeInterval)] = []
            for syllable in line.syllables {
                let nonSpace = Array(syllable.text).filter { !$0.isWhitespace }
                guard !nonSpace.isEmpty else { continue }
                let duration = max(syllable.endTime - syllable.startTime, 0.05)
                let step = duration / Double(nonSpace.count)
                for (index, character) in nonSpace.enumerated() {
                    let start = syllable.startTime + Double(index) * step
                    timed.append((character: character, start: start, end: start + step))
                }
            }
            let expected = characters.filter { !$0.isWhitespace }
            // 只比**数量**：大小写/标点归一化可能让 Character 不完全相等，但顺序和数量
            // 一致时按顺序映射仍然是对的（比整句均分准得多）。
            if timed.count == expected.count {
                var result: [TiltChar] = []
                result.reserveCapacity(characters.count)
                var cursor = 0
                for (index, character) in characters.enumerated() {
                    if character.isWhitespace {
                        let start = result.last?.startTime ?? line.time
                        result.append(TiltChar(
                            index: index,
                            character: character,
                            startTime: start,
                            endTime: start,
                            isSpace: true
                        ))
                        continue
                    }
                    guard cursor < timed.count else { break }
                    let timing = timed[cursor]
                    cursor += 1
                    result.append(TiltChar(
                        index: index,
                        character: character,
                        startTime: timing.start,
                        endTime: timing.end,
                        isSpace: false
                    ))
                }
                if result.count == characters.count { return result }
            }
        }

        // 行级同步 / 对不上：整句时长均分给非空格字符。
        let duration = max(lineEnd - line.time, 0.9)
        let nonSpaceCount = characters.filter { !$0.isWhitespace }.count
        let step = duration / Double(max(nonSpaceCount, 1))
        var order = 0
        var result: [TiltChar] = []
        result.reserveCapacity(characters.count)
        for (index, character) in characters.enumerated() {
            if character.isWhitespace {
                let start = line.time + Double(order) * step
                result.append(TiltChar(
                    index: index,
                    character: character,
                    startTime: start,
                    endTime: start,
                    isSpace: true
                ))
                continue
            }
            let start = line.time + Double(order) * step
            order += 1
            result.append(TiltChar(
                index: index,
                character: character,
                startTime: start,
                endTime: start + step,
                isSpace: false
            ))
        }
        return result
    }

    // MARK: 字号

    /// 这一段的字号：base 50（短尾 58），再按估算宽度缩到可用宽度内。
    ///
    /// 逐字 HStack 不能自动换行，也不能靠 `minimumScaleFactor`；所以用字宽估算
    /// （CJK≈1em、拉丁≈0.58em、空格 0.3em）先把字号压到放得下，再留 4% 余量。
    static func fontSize(for segment: TiltSegment, availableWidth: CGFloat) -> CGFloat {
        // Folia 在 414pt 宽屏上的字号是 **50pt**（`clamp(3.125rem, 6.875vw, 5.625rem)`
        // 在 414 宽下取 min=50）；短尾行再乘 1.18 ⇒ 约 59。原来用 42/48 偏小，
        // 大字撑不满一屏，是"不够 Folia"的观感来源之一。
        // 只有放不下时才会被下面的 fitted 压下去（长句仍然能排进屏幕）。
        let base: CGFloat = segment.isShortLast ? 58 : 50
        let characterWidth = segment.chars.reduce(CGFloat(0)) { partial, char in
            partial + emWidth(char.character)
        }
        let widthUnits = characterWidth
            + tracking(for: segment) * CGFloat(max(segment.chars.count - 1, 0))
        guard widthUnits > 0 else { return base }
        let fitted = (availableWidth - 10) / widthUnits * 0.96
        // 下限 14（原来 20）：20pt 时 25 字 CJK 就已经 500pt 宽，长句会直接冲出屏幕；
        // 14pt 能兜住 ~25 字/段的一行。正常歌词几乎不会落到这一档。
        return max(14, min(base, fitted))
    }

    /// 字距（em）：Folia 的 Tilt 是 0.08（normal）/ 0.15（tilt）。
    static func tracking(for segment: TiltSegment) -> CGFloat {
        segment.isTilt ? 0.15 : 0.08
    }

    private static func emWidth(_ character: Character) -> CGFloat {
        if character.isWhitespace { return 0.30 }
        guard let scalar = character.unicodeScalars.first?.value else { return 0.58 }
        if (0x4E00...0x9FFF).contains(scalar)
            || (0x3040...0x30FF).contains(scalar)
            || (0xAC00...0xD7AF).contains(scalar)
            || (0xFF00...0xFFEF).contains(scalar) {
            return 1.0
        }
        if punctuationCharacters.contains(character) { return 0.55 }
        return 0.58
    }

    /// 拆段/估宽共用的标点集（全角与半角）。
    private static let punctuationCharacters: Set<Character> = Set(
        "、，。！？…・,.!?;:—()[]{}<>《》「」『』"
    )

    // MARK: 伪随机

    /// 与行起始时间绑定的确定性伪随机（同一句永远拆成同一组段、同一个 tilt 段）。
    private static func seedRandom(_ seed: TimeInterval, _ offset: Double) -> Double {
        let value = sin(seed * 1000 + offset) * 10000
        return value - floor(value)
    }
}
