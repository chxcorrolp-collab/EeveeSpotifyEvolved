import Foundation

/// `LyricsLineSplitting` 的断言程序（纯逻辑，CI 跑；见 `.github/workflows/tests.yml`）。
///
/// 现场：LRCLIB 的两条路都写 `components(separatedBy: "\n").dropLast()` —— 假定响应末尾有换行。
/// 没有尾换行的响应里，`dropLast()` 丢的是**最后一行真歌词**，而且静默（日志只少一个数字）。
/// 这个测试钉住两件事：有尾换行时与旧行为**逐字节一致**，没有尾换行时**最后一行还在**。

var failures = 0

func requireEqual(_ actual: [String], _ expected: [String], _ message: String) {
    if actual == expected {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message) — got \(actual), expected \(expected)")
    }
}

// 1) 有尾换行：与旧的 `dropLast()` 结果一致。
requireEqual(
    LyricsLineSplitting.splitDroppingTrailingNewline("a\nb\n"),
    ["a", "b"],
    "trailing newline is dropped"
)

// 2) ★ 没有尾换行：旧代码会把 "b" 吃掉 —— 这就是那条 bug。
requireEqual(
    LyricsLineSplitting.splitDroppingTrailingNewline("a\nb"),
    ["a", "b"],
    "last lyric line survives without a trailing newline"
)

// 3) 单行、无换行。
requireEqual(
    LyricsLineSplitting.splitDroppingTrailingNewline("only line"),
    ["only line"],
    "single line without newline"
)

// 4) 空串：没有行（旧行为相同）。
requireEqual(
    LyricsLineSplitting.splitDroppingTrailingNewline(""),
    [],
    "empty input"
)

// 5) 两个尾换行：只丢最后那个空串（与旧 `dropLast()` 一致；中间的空行归"空行"那条规则管）。
requireEqual(
    LyricsLineSplitting.splitDroppingTrailingNewline("a\n\n"),
    ["a", ""],
    "only one trailing newline is dropped"
)

// 6) CRLF 收束：与旧行为一致（`\r` 由调用方处理）。
requireEqual(
    LyricsLineSplitting.splitDroppingTrailingNewline("a\r\nb\r\n"),
    ["a\r", "b\r"],
    "CRLF behaves like before"
)

if failures == 0 {
    print("LyricsLineSplitting: all assertions passed")
} else {
    print("LyricsLineSplitting: \(failures) failure(s)")
    exit(1)
}
