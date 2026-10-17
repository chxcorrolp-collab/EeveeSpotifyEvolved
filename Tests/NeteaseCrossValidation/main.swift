import Foundation

/// `NeteaseCrossValidation` 的断言程序（纯逻辑，CI 跑；见 `.github/workflows/tests.yml`）。
///
/// 背景：非中国大陆 IP 下网易的搜索**排序按地区变**，而"从排名列表里挑哪一条"是**我们**
/// 做的 ⇒ 会挑到另一首歌的词。修法是拿一级裁判源（身份锚在 Spotify Track ID 上）的
/// 文本去核对。这个测试钉住**判据本身**，尤其钉住"判不了就不判"这一侧 ——
/// 误判成"选错歌"会害得本来对的候选被丢掉。
///
/// 钉住的六件事：
///   ① 同一首歌（只有标点 / 全半角 / 大小写差异）⇒ `confirm`；
///   ② 裁判源只有 TV-size / 剪辑版（是网易那份的**前缀子集**）⇒ 仍然 `confirm`；
///   ③ 完全不同的歌 ⇒ `reject`（两种构造：换文字系统、整段倒序）；
///   ④ ★ 罗马字 vs 日文原文 ⇒ `unknown`（**绝不能**当成"选错歌"）；
///   ⑤ 歌词太短 ⇒ `unknown`；
///   ⑥ 归一化：全角折半角、大小写折叠、标点/空白全丢。

var failures = 0

func requireEqual(_ actual: String, _ expected: String, _ message: String) {
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

func requireVerdict(
    _ reference: [String],
    _ candidate: [String],
    _ expected: NeteaseCrossVerdict,
    _ expectedReason: String,
    _ message: String
) {
    let result = NeteaseCrossValidation.compare(reference: reference, candidate: candidate)
    if result.verdict == expected && result.reason == expectedReason {
        let percent = String(format: "%.2f", result.overlap)
        print("  ok   \(message) (overlap \(percent))")
    } else {
        failures += 1
        let percent = String(format: "%.2f", result.overlap)
        print(
            "  FAIL \(message) — got \(result.verdict.rawValue)/\(result.reason)"
                + " (\(percent)), expected \(expected.rawValue)/\(expectedReason)"
        )
    }
}

// MARK: 固定语料

/// 一份"网易选中的候选"（日文原文）。
let japaneseLines = [
    "夜の街に溶けていく",
    "君の声だけが残って",
    "遠くで鳴る電車の音",
    "僕はまだここに立ってる",
    "秘密にした約束を",
    "ポケットの中で握りしめた",
    "明日が来なければいいと",
    "そう願ってた夜もある",
]

/// 同一首歌：加标点、全角空格、改标点宽度 —— 折算后应当**逐字相同**。
let japaneseLinesWithNoise = [
    "夜の街に溶けていく。",
    "君の声だけが残って！？",
    "遠くで鳴る電車の音、",
    "僕はまだここに立ってる　",
    "秘密にした約束を…",
    "ポケットの中で握りしめた",
    "明日が来なければいいと",
    "そう願ってた夜もある",
]

/// 裁判源只有 TV-size（前 6 行）：是上面那份的**前缀子集**。
///
/// 取 6 行而不是 5 行，是为了给 `minimumShingleCount`（40）留出余量：
/// 5 行只有 42 个 gram，离门槛只差 2 —— 语料一改就会假红。
let japaneseTvSize = Array(japaneseLines.prefix(6))

/// 完全不同的歌 —— 换成谚文（同属 CJK 类，所以"书写系统可比"这一关会放行，
/// 但字符集完全不相交 ⇒ 重合率应当接近 0）。
let koreanOtherSong = [
    "밤거리를 걸으면서",
    "너의 목소리만 남아서",
    "멀리서 들리는 기차 소리",
    "나는 아직 여기 서 있어",
    "비밀로 했던 약속을",
    "주머니 속에 쥐고서",
    "내일이 오지 않으면 좋겠다고",
    "그렇게 빌었던 밤도 있어",
]

/// 罗马字形态：网易有时把罗马音当正文下发 —— 与日文原文重合率天然为 0，
/// 但那是"不可比"，**不是**"选错歌"。
let japaneseRomaji = [
    "yoru no machi ni tokete iku",
    "kimi no koe dake ga nokotte",
    "tooku de naru densha no oto",
    "boku wa mada koko ni tatteru",
    "himitsu ni shita yakusoku wo",
    "poketto no naka de nigirishimeta",
    "ashita ga konakereba ii to",
    "sou negatteta yoru mo aru",
]

// MARK: ① 同一首歌

requireVerdict(
    japaneseLines,
    japaneseLines,
    .confirm,
    "overlap",
    "identical lyrics are confirmed"
)

requireVerdict(
    japaneseLines,
    japaneseLinesWithNoise,
    .confirm,
    "overlap",
    "punctuation / width noise does not change the verdict"
)

// MARK: ② 裁判源只有子集（TV-size / 剪辑版）

requireVerdict(
    japaneseTvSize,
    japaneseLines,
    .confirm,
    "overlap",
    "an arbiter with only the TV-size part still confirms"
)

// MARK: ③ 完全不同的歌

requireVerdict(
    koreanOtherSong,
    japaneseLines,
    .reject,
    "overlap",
    "a different song (disjoint text) is rejected"
)

// 整段倒序：字符集相同（书写系统可比），但 5-gram 几乎全不同 ⇒ 必须判成不同的歌。
let reversedJapanese = Array(japaneseLines.map { String($0.reversed()) }.reversed())
requireVerdict(
    reversedJapanese,
    japaneseLines,
    .reject,
    "overlap",
    "reversed text is rejected as a different song"
)

// MARK: ④ ★ 不可比：罗马字 / 译文

requireVerdict(
    japaneseLines,
    japaneseRomaji,
    .unknown,
    "script-mismatch",
    "romaji against Japanese original is incomparable, never a rejection"
)

// MARK: ⑤ 太短 ⇒ 不判定

requireVerdict(
    japaneseLines,
    ["夜の街", "君の声"],
    .unknown,
    "too-short",
    "very short lyrics are not judged"
)

requireVerdict(
    [],
    japaneseLines,
    .unknown,
    "empty",
    "empty input is not judged"
)

// MARK: ⑥ 归一化

requireEqual(
    NeteaseCrossValidation.normalizedText(["ＡＢＣ！", "　def？"]),
    "abcdef",
    "normalisation folds width, case, punctuation and spaces"
)

requireEqual(
    NeteaseCrossValidation.normalizedText(["♪", "。、", ""]),
    "",
    "interlude / punctuation-only lines normalise to nothing"
)

require(
    NeteaseCrossValidation.cjkRatio("夜の街に溶けていく") > 0.9,
    "Japanese text is measured as CJK"
)

require(
    NeteaseCrossValidation.cjkRatio("yoru no machi") < 0.05,
    "romaji is measured as non-CJK"
)

// 5-gram 的基本性质：长度 n 的串有 n-size+1 个 gram（去重前）。
require(
    NeteaseCrossValidation.shingles(of: "abcdefghij").count == 6,
    "ten characters produce six 5-grams"
)

require(
    NeteaseCrossValidation.shingles(of: "abcd").isEmpty,
    "shorter than the window produces no grams"
)

if failures == 0 {
    print("NeteaseCrossValidation: all assertions passed")
} else {
    print("NeteaseCrossValidation: \(failures) failure(s)")
    exit(1)
}
