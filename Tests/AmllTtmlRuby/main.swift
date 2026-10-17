import Foundation

// MARK: - AMLL TTML 的 ruby 注音不能被当成歌词
//
// 跑法（CI 里就是这条，见 `.github/workflows/tests.yml`）：
//   swiftc Sources/EeveeSpotify/Lyrics/Models/Amll/AmllTtmlDocument.swift \
//          Sources/EeveeSpotify/Lyrics/Models/Amll/AmllTtmlParser.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsError.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsWordDto.swift \
//          Sources/EeveeSpotify/Lyrics/Models/LyricsBackgroundVocalDto.swift \
//          Sources/EeveeSpotify/Lyrics/Repositories/LyricsMarkers.swift \
//          Tests/AmllTtmlRuby/main.swift -o amll-ttml-ruby-tests
//
// 两种写法都要成立（细节见 `MEMORY_2026-10-16_EeveeSpotify-ng_AMLL-TTML-Gaps.md` §一·③）：
//
//   ① **AMLL 真正的写法** —— `tts:ruby` 属性（官方文档 https://amll.dev/guides/lyric/ttml
//      的「Ruby 注音」一节）：
//        <span tts:ruby="container">
//          <span tts:ruby="base">所</span>
//          <span tts:ruby="textContainer">
//            <span tts:ruby="text" begin="00:27.690" end="00:27.820">しょ</span>
//          </span>
//        </span>
//      正文（base）与注音**都没有 begin/end**，时间只挂在 `tts:ruby="text"` 上。
//      不特判的后果是**正文丢了**（容器被整段跳过），而 `plainText` 会把注音拼进来
//      ⇒ 屏幕上那一行变成「所しょ詮せん」。
//
//   ② HTML 风格 `<ruby>漢<rt>かん</rt></ruby>`（别的工具可能这么导出）—— `<rt>` 的读音
//      不能进正文。
//
// 顺带钉住"没有注音的行一个字节都不变"，免得跳过注音的判据写宽了、把正常文本也吃掉。

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

func requireEqual(_ actual: Int, _ expected: Int, _ message: String) {
    if actual == expected {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message) — got \(actual), expected \(expected)")
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

// MARK: - ① `tts:ruby`（AMLL 的真写法）

let rubyStyledTtml = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:tts="http://www.w3.org/ns/ttml#styling" xml:lang="ja">
  <body dur="30s">
    <div>
      <p begin="20s" end="22s">
        <span tts:ruby="container"><span tts:ruby="base">所</span><span tts:ruby="textContainer"><span tts:ruby="text" begin="20.1s" end="20.4s">しょ</span></span></span><span tts:ruby="container"><span tts:ruby="base">詮</span><span tts:ruby="textContainer"><span tts:ruby="text" begin="20.4s" end="21s">せん</span></span></span>
      </p>
    </div>
  </body>
</tt>
"""

do {
    let parsed = try AmllTtmlParser.parse(rubyStyledTtml)

    require(parsed.lines.count == 1, "tts:ruby — one lyric line parsed (got \(parsed.lines.count))")

    if parsed.lines.count == 1 {
        let line = parsed.lines[0]
        requireEqual(line.primaryText, "所詮", "tts:ruby — the line text is the base text, not the reading")
        requireEqual(line.plainText, "所詮", "tts:ruby — plain text excludes <rt>/tts:ruby=text")
        requireEqual(line.syllables.count, 2, "tts:ruby — two syllables, one per container")
        requireEqual(
            line.syllables.map(\.text).joined(),
            "所詮",
            "tts:ruby — syllable join matches the line text"
        )
        if line.syllables.count == 2 {
            requireEqual(line.syllables[0].startMs, 20100, "tts:ruby — first syllable starts at the annotation time")
            requireEqual(line.syllables[0].endMs, 20400, "tts:ruby — first syllable ends at the annotation time")
            requireEqual(line.syllables[1].startMs, 20400, "tts:ruby — second syllable starts at the second annotation")
            requireEqual(line.syllables[1].endMs, 21000, "tts:ruby — second syllable ends at the second annotation")
        }
    }
} catch {
    failures += 1
    print("  FAIL tts:ruby parsing threw \(error)")
}

// 注音**完全没有时间**时：不产生词条，正文仍然要留下（走 plainText 那条）。
let rubyUntimedTtml = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:tts="http://www.w3.org/ns/ttml#styling" xml:lang="ja">
  <body>
    <div>
      <p begin="1s" end="3s">
        <span tts:ruby="container"><span tts:ruby="base">愛</span><span tts:ruby="textContainer"><span tts:ruby="text">あい</span></span></span>
      </p>
    </div>
  </body>
</tt>
"""

do {
    let parsed = try AmllTtmlParser.parse(rubyUntimedTtml)
    require(parsed.lines.count == 1, "untimed ruby — the line survives (got \(parsed.lines.count))")
    if parsed.lines.count == 1 {
        requireEqual(parsed.lines[0].primaryText, "愛", "untimed ruby — the base text is kept")
        requireEqual(parsed.lines[0].syllables.count, 0, "untimed ruby — no syllable without a timestamp")
    }
} catch {
    failures += 1
    print("  FAIL untimed ruby parsing threw \(error)")
}

// MARK: - ② HTML 风格 `<ruby>/<rt>`

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

    require(parsed.lines.count == 2, "html ruby — two lyric lines parsed (got \(parsed.lines.count))")

    if parsed.lines.count == 2 {
        let withRuby = parsed.lines[0]
        requireEqual(withRuby.primaryText, "漢字", "html ruby — the <rt> reading is not part of the line text")
        requireEqual(withRuby.plainText, "漢字", "html ruby — plain text also excludes <rt>")
        requireEqual(withRuby.syllables.map(\.text).joined(), "漢字", "html ruby — syllable join matches the line text")
        requireEqual(withRuby.syllables.count, 2, "html ruby — two timed syllables survive")

        let withoutRuby = parsed.lines[1]
        requireEqual(withoutRuby.primaryText, "読みなし", "a line without ruby is untouched")
    }
} catch {
    failures += 1
    print("  FAIL html ruby parsing threw \(error)")
}

// MARK: - ③ 副唱 DTO 的 `translation`（§A·24）

let background = LyricsBackgroundVocalDto(
    syllables: [
        LyricsWordDto(text: "秘密", startMs: 30_500, endMs: 31_500),
        LyricsWordDto(text: "だよ", startMs: 31_600, endMs: 32_500),
    ],
    isBeforePrimary: false,
    translation: "是秘密哦"
)
requireEqual(background.text, "秘密だよ", "bg dto — the text is the syllables joined")
requireEqual(
    background.translation ?? "",
    "是秘密哦",
    "bg dto — the background vocal's own translation survives the DTO"
)
requireEqual(
    LyricsBackgroundVocalDto(
        syllables: [LyricsWordDto(text: "x", startMs: 0)],
        isBeforePrimary: true
    ).translation ?? "",
    "",
    "bg dto — translation defaults to nil when absent"
)

if failures == 0 {
    print("AmllTtmlRuby: all assertions passed")
} else {
    print("AmllTtmlRuby: \(failures) failure(s)")
    exit(1)
}
