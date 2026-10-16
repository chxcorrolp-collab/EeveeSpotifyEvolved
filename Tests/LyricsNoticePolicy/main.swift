import Foundation

// 「没词可画时写哪一句」的判定回归测试（纯 Foundation，不需要设备 / Theos）。
//
// 跑法（需要 Swift 工具链；本仓库本机没有，所以由 CI 跑）：
//   swiftc Sources/EeveeSpotify/Appearance/LyricsNoticePolicy.swift \
//          Tests/LyricsNoticePolicy/main.swift \
//          -o /tmp/lyrics-notice-policy-tests && /tmp/lyrics-notice-policy-tests
//
// 锁的是**优先级**：每一档都对应一个用户能看见的错，混档就是误报。
// 本地化字符串长什么样、写在哪个 label 上，不在这个测试范围。

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private func notice(
    hasLines: Bool,
    drawable: Bool,
    instrumental: Bool = false,
    anyTimestamp: Bool = false,
    untimedText: Bool = false,
    lookingUp: Bool = false
) -> LyricsNotice? {
    LyricsNoticePolicy.notice(
        hasLines: hasLines,
        hasDrawableLines: drawable,
        isInstrumental: instrumental,
        hasAnyTimestamp: anyTimestamp,
        hasUntimedText: untimedText,
        isLookingUp: lookingUp
    )
}

// MARK: - ① 有行而且画得出来 ⇒ 正常画歌词

require(
    notice(hasLines: true, drawable: true) == nil,
    "lines that render need no notice at all"
)

// ⚠️ ①**先于**②：源说是纯音乐、但我们确实有能画的行 ⇒ 照样画歌词（这条优先级钉住）。
require(
    notice(hasLines: true, drawable: true, instrumental: true) == nil,
    "drawable lines win over the instrumental flag - the notice order is the contract"
)

// MARK: - ② 源明确说是纯音乐

require(
    notice(hasLines: false, drawable: false, instrumental: true) == .instrumental,
    "an explicitly instrumental track says instrumental"
)
require(
    notice(hasLines: false, drawable: false, instrumental: true, lookingUp: true) == .instrumental,
    "instrumental beats looking-up: the source already decided"
)
require(
    notice(hasLines: true, drawable: false, instrumental: true) == .instrumental,
    "instrumental beats the cannot-convert branch too"
)

// MARK: - ③ 有行、却画不出来：三种情况必须分开

require(
    notice(hasLines: true, drawable: false, anyTimestamp: false, untimedText: false) == .noTimeline,
    "lines with no timestamp at all and no text -> no timeline"
)
require(
    notice(hasLines: true, drawable: false, anyTimestamp: false, untimedText: true) == nil,
    "lines with no timestamp but with text -> draw static lyrics, no notice"
)
require(
    notice(hasLines: true, drawable: false, anyTimestamp: true) == .unavailable,
    "lines that do carry timestamps but still cannot render -> conversion failure, not no-timeline"
)
require(
    notice(hasLines: true, drawable: false) != .lookingUp,
    "a track with lines is never reported as still-searching"
)

// MARK: - ④ 数据还没到：正在查 vs 查完了没有

require(
    notice(hasLines: false, drawable: false, lookingUp: true) == .lookingUp,
    "no lines and still looking -> looking up"
)
require(
    notice(hasLines: false, drawable: false, lookingUp: false) == .unavailable,
    "no lines and the lookup finished -> not found"
)

// MARK: - 端到端：同一首歌从"正在查"走到"静态歌词"，中间的档不许跳
//
// 这条链上每一步都对应一个用户报过的现象：点下去没反应 / 说有词却说未找到 /
// 有一句"没有时间轴"却又画不出东西。

var current = notice(hasLines: false, drawable: false, lookingUp: true)
require(current == .lookingUp, "while the lookup runs the notice is looking-up")

// 歌词到了：有行、但没有一行带时间，而且文本提得出来。
current = notice(hasLines: true, drawable: false, anyTimestamp: false, untimedText: true)
require(current == nil, "untimed text must switch to static lyrics instead of a notice")

// 那些行后来有了时间轴，行模型也建起来了。
current = notice(hasLines: true, drawable: true, anyTimestamp: true)
require(current == nil, "a timed model renders normally")

// 换到一首源明确标注为纯音乐的歌。
current = notice(hasLines: false, drawable: false, instrumental: true)
require(current == .instrumental, "an instrumental track is announced as such")

print("lyrics notice policy: all assertions passed")
