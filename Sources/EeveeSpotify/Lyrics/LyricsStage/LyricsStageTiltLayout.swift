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
//   ③ 逐字揭示：每个字从下方 12~18pt、透明度 0 浮到 0/1，起音后 0.38s 完成；
//      已唱的字亮到 1.0 并带两层光晕，未唱的字 0.5 透明度。
//   ④ 逐字脉冲：这个字起音后的一个短窗里放大 12~16%（Folia 的 char pulse），
//      随后快速回落 —— 这是“字在唱”的节奏，不是整行抖。
//   ⑤ 换行：**完全由 playbackTime 手工插值**（不依赖 SwiftUI 的 transition）：
//      新句 0.42s 从 +28pt / 0.97 倍淡入；旧句在它结束后的 0.30s 内向上 24pt 淡出。
//      上一版靠 `.transition + .animation(value: focus)`，真机上很可能硬切；现在
//      每一帧都能算出来，动画一定跑。
//   ⑥ 译文/罗马字：译文在整句块下方（15pt、0.62），罗马字在上方（12pt、0.45）；
//      两者都跟着整句的 enter 淡入。副唱在译文下方一行。
//
// ⚠️ 只参考 Folia 的**效果与参数**：没有复制它的代码/注释（AGPL-3.0）。
// ⚠️ 性能：每帧给每个字建一个 Text + 两层 shadow，开销显著；用户明确说过
//   “不考虑性能开销”，所以先按最好看的一档写。真机若掉帧，先砍第二层 shadow，
//   再砍逐字 scaleEffect，最后才砍逐字视图（改成整段 Text）。
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

    /// 换行动画：新句进入 0.42s；旧句在结束后 0.30s 内退出。
    private static let enterDuration: Double = 0.42
    private static let exitDuration: Double = 0.30

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
                    let exit = Self.exitProgress(
                        previous: previous,
                        previousIndex: previousIndex,
                        lines: lines,
                        at: playbackTime
                    )
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

    /// 这句唱完之后还有多少（0 = 刚结束，1 = 已经退出）。
    private static func exitProgress(
        previous: LyricLine,
        previousIndex: Int,
        lines: [LyricLine],
        at time: TimeInterval
    ) -> Double {
        let end = lineEnd(previous, in: lines, index: previousIndex)
        return (time - end) / exitDuration
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
        .offset(y: CGFloat(outgoing ? -24 * exit : (1 - enter) * 28))
        .scaleEffect(CGFloat(outgoing ? 1 - 0.02 * exit : 0.97 + 0.03 * enter))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(line.text))
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

        HStack(alignment: .center, spacing: spacing) {
            ForEach(segment.chars.indices, id: \.self) { index in
                glyph(segment.chars[index], position: index, size: size)
            }
        }
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .center)
        .offset(x: segment.horizontalOffset)
    }

    @ViewBuilder
    private func glyph(_ char: TiltChar, position: Int, size: CGFloat) -> some View {
        if char.isSpace {
            // 空格不参与逐字动画，只占位。
            Color.clear.frame(width: size * 0.28, height: size * 0.8)
        } else {
            let reveal = outgoing ? 1 : revealProgress(for: char, position: position)
            let sung = outgoing || playbackTime >= char.startTime
            let pulse = outgoing ? 0 : pulseAmount(for: char)
            let tiltY: CGFloat = segment.isTilt
                ? (char.index.isMultiple(of: 2) ? -size / 6 : size / 6)
                : 0
            let rise = CGFloat(1 - reveal) * (segment.isTilt ? 18 : 12)

            glyphText(char, size: size)
                .foregroundColor(primaryColor.opacity(sung ? 1 : 0.5))
                .shadow(color: sung ? primaryColor.opacity(0.50) : .clear, radius: sung ? 8 : 0)
                .shadow(color: sung ? primaryColor.opacity(0.22) : .clear, radius: sung ? 20 : 0)
                .scaleEffect(1 + pulse * (segment.isTilt ? 0.16 : 0.12))
                .offset(y: tiltY + rise)
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

    /// 这个字在**这一段出现之后**的第 `position` 个：每字错开 0.04s，0.38s 完成。
    ///
    /// 这是 Folia Tilt 的“逐字落下”：段的出现由第一个字的起音时间决定，段内其余字
    /// 按固定 0.04s 的 stagger 跟上；每个字**亮起来**仍然按它自己的 `startTime`（见
    /// `sung`），所以是“先落位、后点亮”。
    private func revealProgress(for char: TiltChar, position: Int) -> Double {
        let segmentStart = segment.startTime - 0.10
        let start = segmentStart + Double(position) * 0.04
        return min(max((playbackTime - start) / 0.38, 0), 1)
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
        let offsets: [CGFloat] = [-8, 10, -6, 8]

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
                horizontalOffset: offsets[index % offsets.count]
            )
        }
    }

    /// 按字数决定 1~4 段，再用行起始时间做一点伪随机抖动；尽量在空格/标点后断开。
    private static func splitRanges(_ characters: [Character], seed: TimeInterval) -> [Range<Int>] {
        let count = characters.count
        guard count > 0 else { return [] }
        let base: Int
        switch count {
        case ...10: base = 1
        case ...20: base = 2
        case ...34: base = 3
        default: base = 4
        }
        let roll = seedRandom(seed, 7)
        let target = min(4, max(1, base + (roll < 0.30 ? 1 : 0)))
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
            if timed.map({ $0.character }) == expected {
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

    /// 这一段的字号：base 42（tilt 46、短尾 48），再按估算宽度缩到可用宽度内。
    ///
    /// 逐字 HStack 不能自动换行，也不能靠 `minimumScaleFactor`；所以用字宽估算
    /// （CJK≈1em、拉丁≈0.58em、空格 0.3em）先把字号压到放得下，再留 4% 余量。
    static func fontSize(for segment: TiltSegment, availableWidth: CGFloat) -> CGFloat {
        let base: CGFloat = segment.isTilt ? 46 : (segment.isShortLast ? 48 : 42)
        let characterWidth = segment.chars.reduce(CGFloat(0)) { partial, char in
            partial + emWidth(char.character)
        }
        let widthUnits = characterWidth
            + tracking(for: segment) * CGFloat(max(segment.chars.count - 1, 0))
        guard widthUnits > 0 else { return base }
        let fitted = (availableWidth - 10) / widthUnits * 0.96
        return max(20, min(base, fitted))
    }

    /// 字距（em）：tilt 段宽一些，normal 段略宽（Folia 的 0.08 / 0.15em 的近似）。
    static func tracking(for segment: TiltSegment) -> CGFloat {
        segment.isTilt ? 0.10 : 0.06
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
