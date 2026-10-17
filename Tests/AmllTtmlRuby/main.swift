import Foundation

// MARK: - AMLL TTML 的 ruby 注音（`<rt>`）不能被当成歌词
//
// 跑法（CI 里就是这条，见 `.github/workflows/tests.yml`）：
//   swiftc Sources/EeveeSpotify/Lyrics/Models/Amll/AmllTtmlDocument.swift \
//          Sources/EeveeSpotify/Lyrics/Models/Amll/AmllTtmlParser.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsError.swift \
//          Sources/EeveeSpotify/Lyrics/Repositories/LyricsMarkers.swift \
//          Tests/AmllTtmlRuby/main.swift -o amll-ttml-ruby-tests
//
// 为什么要有这个测试（细节见 `MEMORY_2026-10-16_EeveeSpotify-ng_AMLL-TTML-Gaps.md` §一·③）：
// 注音在 TTML 里写成 `<ruby>漢<rt>かん</rt></ruby>`，`rt` 里是**读音**。`text()` 原来会把它
// 一起拼进正文，于是：
//   ① 屏幕上那一行多出读音；
//   ② 更糟的是有逐词 span 的行 —— `primaryText` 含读音，而词条拼接结果与它不一致 ⇒
//      `AmllLyricsMapper` 的"content == words 拼接"不变量失败 ⇒ **整行降级为逐行**，
//      逐词高亮消失（用户看到的是"这首歌突然不逐词了"）。
//
// 顺带钉住"没有注音的行一个字节都不变"，免得跳过 `rt` 的判据写宽了、把正常的 `text` 也吃掉。

func writeDebugLog(_ message: String) {}

extension String {
    var localized: String { self }
}

var failures = 0

func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

func requireEqual(_ actual: String, _ expected: String, _ message: String) {
    if actual == expected {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message) — got \(actual), expected \(expected)")
    }
}

let ttml = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://itunes.apple.com/lyric-sync" xml:lang="ja">
  <body dur="10s">
    <div>
      <p begin="1s" end="3s" itunes:key="L1">
        <span begin="1s" end="2s"><ruby>漢<rt>かん</rt></ruby></span><span begin="2s" end="3s">字</span>
      </p>
      <p begin="4s" end="6s" itunes:key="L2">
        <span begin="4s" end="6s">読みなし</span>
      </p>
    </div>
  </body>
</tt>
"""

do {
    let parsed = try AmllTtmlParser.parse(ttml)

    require(parsed.lines.count == 2, "two lyric lines parsed (got \(parsed.lines.count))")

    if parsed.lines.count == 2 {
        let withRuby = parsed.lines[0]
        requireEqual(withRuby.primaryText, "漢字", "the <rt> reading is not part of the line text")
        requireEqual(withRuby.plainText, "漢字", "plain text also excludes <rt>")
        requireEqual(withRuby.syllables.map(\.text).joined(), "漢字", "syllable join matches the line text")
        require(withRuby.syllables.count == 2, "two timed syllables survive (got \(withRuby.syllables.count))")

        let withoutRuby = parsed.lines[1]
        requireEqual(withoutRuby.primaryText, "読みなし", "a line without ruby is untouched")
    }
} catch {
    failures += 1
    print("  FAIL parsing threw \(error)")
}

if failures == 0 {
    print("AmllTtmlRuby: all assertions passed")
} else {
    print("AmllTtmlRuby: \(failures) failure(s)")
    exit(1)
}
