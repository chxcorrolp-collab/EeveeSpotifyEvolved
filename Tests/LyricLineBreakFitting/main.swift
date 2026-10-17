import CoreGraphics
import Foundation

/// `LyricLineBreakFitting` 的断言程序（纯逻辑，CI 跑；见 `.github/workflows/tests.yml`）。
///
/// 度量用一个**假的**函数：ASCII 每字符 10pt、CJK 每字符 20pt、空白 10pt —— 只要
/// "宽度 ≥ 实际" 这一条成立，复核器的行为就能被钉住（真机上的字体会换，算法不换）。

var failures = 0

func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok  \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

func requireClose(_ value: CGFloat, _ expected: CGFloat, _ message: String) {
    require(abs(value - expected) < 0.01, "\(message) (got \(value), expected \(expected))")
}

/// 假度量：按字符类别累加。
func fakeWidth(_ text: String) -> CGFloat {
    var total: CGFloat = 0
    for character in text {
        if character.isWhitespace {
            total += 10
        } else if character.unicodeScalars.allSatisfy({ $0.value < 0x2E80 }) {
            total += 10          // 拉丁 / 数字
        } else {
            total += 20          // CJK
        }
    }
    return total
}

private func makeMeasure(_ characters: [Character]) -> (Range<Int>) -> CGFloat {
    { range in
        guard range.lowerBound >= 0, range.upperBound <= characters.count else { return 0 }
        return fakeWidth(String(characters[range]))
    }
}

/// 复核之后：每一个视觉行都放得下（除非它只有一个字符 —— 那种拆不开）。
private func widestSegment(
    _ breaks: Set<Int>,
    _ characters: [Character],
    _ layoutWidth: CGFloat
) -> CGFloat {
    var widest: CGFloat = 0
    for segment in LyricLineBreakFitting.segments(count: characters.count, breaks: breaks) {
        let width = fakeWidth(String(characters[segment]))
        if segment.count > 1, width > layoutWidth {
            widest = max(widest, width)
        }
    }
    return widest
}

// MARK: - 1. `segments` 的边界

print("1. segments")
require(LyricLineBreakFitting.segments(count: 10, breaks: [4]) == [0..<4, 4..<10],
        "one break splits the range in two")
require(LyricLineBreakFitting.segments(count: 10, breaks: []) == [0..<10],
        "no break = one segment")
require(LyricLineBreakFitting.segments(count: 10, breaks: [0, 10, -3, 12]) == [0..<10],
        "0 / count / out-of-range breaks are ignored")
require(LyricLineBreakFitting.segments(count: 0, breaks: []) == [],
        "an empty line has no segments")

// MARK: - 2. 日志 104 的那一行：CoreText 一个断点都没给，但整行 405pt > 331.8pt 预算

print("2. the logged Starboy line (no CoreText break, but 405pt wide)")
let latinLine = "I'm tryna put you in the worst mood ah"
let latinCharacters = Array(latinLine)
let latinBreaks = LyricLineBreakFitting.verifiedBreaks(
    text: latinLine,
    count: latinCharacters.count,
    layoutWidth: 331.8,
    coreTextBreaks: [],
    measure: makeMeasure(latinCharacters)
)
require(!latinBreaks.isEmpty, "the repair adds at least one break (got \(latinBreaks.sorted()))")
requireClose(
    widestSegment(latinBreaks, latinCharacters, 331.8),
    0,
    "every resulting line fits in 331.8pt"
)
require(
    latinBreaks.sorted() != [latinCharacters.count],
    "the break is inside the line, not at its end"
)

// MARK: - 3. 断在**空白之后**（词边界），不是断在词中间

print("3. prefer breaking after whitespace")
let spacedLine = "aaaa bbbb cccc dddd eeee"
let spacedCharacters = Array(spacedLine)
let spacedBreaks = LyricLineBreakFitting.verifiedBreaks(
    text: spacedLine,
    count: spacedCharacters.count,
    layoutWidth: 100,          // 一次只放得下 10 个字符
    coreTextBreaks: [],
    measure: makeMeasure(spacedCharacters)
)
let spacedSegments = LyricLineBreakFitting.segments(count: spacedCharacters.count, breaks: spacedBreaks)
require(spacedSegments.count > 1, "a 24-character line at 100pt wraps")
require(
    spacedSegments.dropLast().allSatisfy { segment in
        segment.upperBound == spacedCharacters.count || spacedCharacters[segment.upperBound - 1].isWhitespace
    },
    "each line ends right after a space (word boundary)"
)
requireClose(widestSegment(spacedBreaks, spacedCharacters, 100), 0, "every line fits in 100pt")

// MARK: - 4. CJK：没有空白也要能在字符边界切开

print("4. CJK breaks on character boundaries")
let cjkLine = "ナナツカゼは日本を拠点とするにんぐみのユニット"
let cjkCharacters = Array(cjkLine)
let cjkBreaks = LyricLineBreakFitting.verifiedBreaks(
    text: cjkLine,
    count: cjkCharacters.count,
    layoutWidth: 200,          // 20pt/字 ⇒ 一行 10 字
    coreTextBreaks: [],
    measure: makeMeasure(cjkCharacters)
)
require(!cjkBreaks.isEmpty, "a 24-char CJK line at 200pt wraps (got \(cjkBreaks.sorted()))")
requireClose(widestSegment(cjkBreaks, cjkCharacters, 200), 0, "every CJK line fits in 200pt")

// MARK: - 5. CoreText 的断点**一个都不删**（只加不删）

print("5. never drops a CoreText break")
let original: Set<Int> = [8, 17]
let keptBreaks = LyricLineBreakFitting.verifiedBreaks(
    text: spacedLine,
    count: spacedCharacters.count,
    layoutWidth: 60,
    coreTextBreaks: original,
    measure: makeMeasure(spacedCharacters)
)
require(original.isSubset(of: keptBreaks), "the original breaks survive (got \(keptBreaks.sorted()))")
requireClose(widestSegment(keptBreaks, spacedCharacters, 60), 0, "every line fits in 60pt")

// MARK: - 6. 本来就放得下 ⇒ 一个断点都不加

print("6. a line that already fits is untouched")
let shortLine = "短い"
let shortCharacters = Array(shortLine)
let untouched = LyricLineBreakFitting.verifiedBreaks(
    text: shortLine,
    count: shortCharacters.count,
    layoutWidth: 500,
    coreTextBreaks: [],
    measure: makeMeasure(shortCharacters)
)
require(untouched.isEmpty, "nothing to repair")

// MARK: - 7. 退化输入不崩

print("7. degenerate inputs")
require(
    LyricLineBreakFitting.verifiedBreaks(
        text: "",
        count: 0,
        layoutWidth: 100,
        coreTextBreaks: [],
        measure: makeMeasure([])
    ).isEmpty,
    "empty text"
)
require(
    LyricLineBreakFitting.verifiedBreaks(
        text: "a",
        count: 1,
        layoutWidth: 0,
        coreTextBreaks: [],
        measure: makeMeasure(["a"])
    ).isEmpty,
    "zero width"
)
require(
    LyricLineBreakFitting.verifiedBreaks(
        text: "abc",
        count: 99,                 // 与 text 不符 ⇒ 原样返回，别硬猜
        layoutWidth: 100,
        coreTextBreaks: [1],
        measure: makeMeasure(Array("abc"))
    ) == [1],
    "a count that disagrees with the text returns the CoreText breaks unchanged"
)

print("")
if failures == 0 {
    print("OK — lyric line break fitting: all invariants hold")
} else {
    print("FAILED — \(failures) assertion(s)")
    exit(1)
}
