import Foundation

/// `LyricsCensorFill` 的断言程序（纯逻辑，CI 跑；见 `.github/workflows/tests.yml`）。
///
/// 背景：SpicyLyrics 的上游会把部分词和谐成星号（`my **** line`）。回填的办法是拿
/// **同一首歌**在另一个源里的文本找回同一句，只替换星号那几段 —— 能唯一确定才填。
///
/// 这份测试钉住三件事：
///   ① **检测**：上游的 `\b\*{3,}\b` 只命中 `f***k`，`my **** line` 一个都不命中
///      ⇒ 整个功能等于没接线。现在必须是"任意 3+ 星号"。
///   ② **CJK 回归**：旧算法按空格切词，中日韩整行只有 1 个"词"，于是**任何**候选行
///      都会被当成匹配、整行被换成别的歌词。必须只换星号那一段。
///   ③ **不猜**：锚点不足（整行都是星号）或替换词不唯一（`**** you` 既可能是
///      `I love you` 也可能是 `thank you`）时一律保持原样。

var failures = 0

func requireEqual(_ actual: String, _ expected: String, _ message: String) {
    if actual == expected {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message) — got \(actual), expected \(expected)")
    }
}

func requireEqual(_ actual: Int, _ expected: Int, _ message: String) {
    if actual == expected {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message) — got \(actual), expected \(expected)")
    }
}

func requireEqual(_ actual: [String], _ expected: [String], _ message: String) {
    if actual == expected {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message) — got \(actual), expected \(expected)")
    }
}

func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

/// 跑一次回填并断言"第 0 行变成了什么 + 补了几行"。
func requireFill(
    _ line: String,
    _ candidates: [String],
    _ expectedLine: String,
    _ expectedResolved: Int,
    _ message: String
) {
    let result = LyricsCensorFill.fill(lines: [line], withCandidates: candidates)
    if result.lines.first == expectedLine && result.resolved == expectedResolved {
        print("  ok   \(message)")
    } else {
        failures += 1
        print(
            "  FAIL \(message) — got \(result.lines)/\(result.resolved),"
                + " expected [\(expectedLine)]/\(expectedResolved)"
        )
    }
}

// MARK: ① 检测（上游那条正则从来没命中的现场）

require(
    LyricsCensorFill.hasCensor("my **** line"),
    "a standalone asterisk run is detected"
)

require(
    LyricsCensorFill.hasCensor("well **** me"),
    "an asterisk run between words is detected"
)

require(
    LyricsCensorFill.hasCensor("i said ****!"),
    "an asterisk run before punctuation is detected"
)

require(
    LyricsCensorFill.hasCensor("**** you"),
    "an asterisk run at the start of a line is detected"
)

require(
    !LyricsCensorFill.hasCensor("f**k that"),
    "a two-asterisk self-censor is left alone"
)

require(
    !LyricsCensorFill.hasCensor("sh*t"),
    "a one-asterisk self-censor is left alone"
)

require(
    !LyricsCensorFill.hasCensor("just a normal line"),
    "a clean line is not treated as censored"
)

// MARK: ② 切段与锚点

requireEqual(
    LyricsCensorFill.literalSegments(of: "my **** line") ?? [],
    ["my ", " line"],
    "a censored run splits the line into two literal segments"
)

requireEqual(
    LyricsCensorFill.literalSegments(of: "**** you") ?? [],
    ["", " you"],
    "a leading run yields an empty leading segment"
)

require(
    LyricsCensorFill.literalSegments(of: "****") == nil,
    "a line that is only asterisks has no anchor at all"
)

require(
    LyricsCensorFill.literalSegments(of: "****!") == nil,
    "a line with a single character of anchor is not enough"
)

// MARK: ③ 回填

requireFill(
    "my **** line",
    ["my fuck line"],
    "my fuck line",
    1,
    "an English censored word is filled from the candidate"
)

requireFill(
    "**** you",
    ["I love you", "thank you"],
    "**** you",
    0,
    "an ambiguous replacement is never guessed"
)

requireFill(
    "**** you",
    ["I love you", "I love you"],
    "I love you",
    1,
    "a replacement repeated in the candidate source is unique enough"
)

requireFill(
    "my **** and ****",
    ["my shit and fuck"],
    "my shit and fuck",
    1,
    "two censored runs in one line are both filled"
)

requireFill(
    "clean line",
    ["whatever at all"],
    "clean line",
    0,
    "a clean line is returned untouched"
)

requireFill(
    "****",
    ["anything at all"],
    "****",
    0,
    "a whole-line censor is not replaced by an arbitrary candidate line"
)

// ★ CJK 回归：旧算法会把这行**整行换成第一行候选**（`夜の街に溶けていく`）。
requireFill(
    "***の中で君を",
    ["夜の街に溶けていく", "涙の中で君を"],
    "涙の中で君を",
    1,
    "CJK line only loses the censored run, not the whole line"
)

// MARK: ④ 行号对齐优先

do {
    let result = LyricsCensorFill.fill(
        lines: ["a **** b", "c **** d"],
        withCandidates: ["a xx b", "c yy d"]
    )
    requireEqual(result.lines, ["a xx b", "c yy d"], "same line count aligns by index first")
    requireEqual(result.resolved, 2, "both aligned lines are filled")
}

// 行数不同时退回"全份搜索 + 唯一性"。
do {
    let result = LyricsCensorFill.fill(
        lines: ["x **** y", "z"],
        withCandidates: ["x !! y"]
    )
    requireEqual(result.lines, ["x !! y", "z"], "falls back to a global search when counts differ")
    requireEqual(result.resolved, 1, "only the censored line is changed")
}

// 空候选 ⇒ 原样返回，不崩。
do {
    let result = LyricsCensorFill.fill(lines: ["my **** line"], withCandidates: [])
    requireEqual(result.lines, ["my **** line"], "empty candidates leave the input untouched")
    requireEqual(result.resolved, 0, "empty candidates resolve nothing")
}

if failures == 0 {
    print("LyricsCensorFill: all assertions passed")
} else {
    print("LyricsCensorFill: \(failures) failure(s)")
    exit(1)
}
