import Foundation

// MARK: - NetEase 交叉验证（纯逻辑）
//
// 2026-10-17（用户）：**非中国大陆 IP 下 NetEase 会选错歌。**
// 直接原因是网易的搜索**排序按地区变**（同一首歌一次 `Chosen[6]`、一次 `Chosen[0]`），
// 而"挑哪一条"这一步是**我们自己做**的 —— 网易只是给了一个排名列表。
//
// 所以这里做的事与上游 `LyricsUncensorFill` 同构：**不猜，只核对**。
// 只不过上游核对的是"被打码的那几个词 vs 同一行里完好的词"，
// 这里核对的是"网易选中的这份文本 vs 另一个源里同一首轨道的文本"。
//
// ★ 为什么不能照搬上游的词级精确判据：那一层的**输入身份是可靠的**（锚在 Spotify 的
//   title/artist/duration 上），所以可以要求"非打码词逐词全等"。歌这一层不行 ——
//   连身份都是可疑的，行切分/版本/书写系统全都可能不同。因此判据必须换成
//   **语言无关、切分无关**的字符 n-gram 重合率。
//
// ★ 为什么只有"一级裁判"能判错：判"网易选错了"要求裁判源**自己不会犯同一个错**。
//   · 一级（身份由 **Spotify Track ID** 锚定，根本不经过歌名）：
//     SpicyLyrics `v1/lyrics/<trackId>`、AMLL `?spotifyId=`、Musixmatch `track_spotify_id`。
//     ⇒ 它们**不可能返回"另一首歌"**，所以它们与网易不重合 ⇒ 网易确实选错了。
//   · 二级（按 (歌名, 歌手) 精确键、服务端最多回一条）：PetitLyrics `max_count: 1`、
//     LRCLIB `/api/get`。它们"不会选错"是因为**接口形状里没有选择步骤**，不是因为更精确；
//     但它们仍按**名字**锚定，可能命中"同名的另一个版本"（重录 / 单曲版 vs 专辑版），
//     所以只配当"加分项"，不配判错 —— 见 `NeteaseCrossValidationRunner` 里的分级。
//   · 不能当裁判：Genius / LRCLIB 的 search 形态 —— 它们和网易一样有"我们挑"这一步。
//
// 本文件**只放纯逻辑**（无网络、无 DTO），这样 `Tests/NeteaseCrossValidation` 能用
// `swiftc` 单独把它编进来跑；执行层在 `NeteaseCrossValidationRunner.swift`。

/// 三态判定。**默认什么都不做** —— 只有拿到明确证据才动手（与上游"宁留星号不猜"同一条纪律）。
enum NeteaseCrossVerdict: String {
    /// 两份文本高度重合 ⇒ 网易选中的就是同一首歌，照常用它（保住 yrc 逐字 / 翻译 / 罗马音）。
    case confirm
    /// 两份文本几乎不重合、且两边书写系统可比 ⇒ **网易选错歌了**。
    case reject
    /// 信息不足（文本太短 / 落在中间带 / 书写系统不可比）⇒ 不判定，按原逻辑走。
    case unknown
}

/// 一次比对的结论（连同进日志的细节）。
struct NeteaseCrossResult: Equatable {
    let verdict: NeteaseCrossVerdict
    /// `|A ∩ B| / min(|A|, |B|)`。`unknown`（太短 / 不可比）时为 0。
    let overlap: Double
    /// 判定理由，进日志用：`overlap` / `too-short` / `script-mismatch` / `inconclusive`。
    let reason: String
}

enum NeteaseCrossValidation {

    // MARK: 阈值

    /// 两边文本**各自**至少要有这么多 5-gram 才参与判定。
    /// 太短的歌词（间奏多的短曲、翻来覆去就两句的曲子）重合率极不稳定 ——
    /// 两个完全不同的短句集合也可能撞出很高的包含率，所以短文本一律"不判定"。
    static let minimumShingleCount = 40

    /// ≥ 这个重合率 ⇒ 同一首歌。
    ///
    /// 定在 0.5 而不是更高，是因为：**同一个源族的文本重合率会很高**（网易的 LRC 与
    /// MXM / Spicy Lyrics 常常本来就同源，实测往往 > 0.8），而**不同歌通常 < 0.1** ——
    /// 中间地带很窄，所以这个阈值不敏感。真正要防的是"短文本撞车"，那由
    /// `minimumShingleCount` 兜。
    static let confirmThreshold = 0.5

    /// < 这个重合率、且书写系统可比 ⇒ 不同歌。
    ///
    /// 与 `confirmThreshold` 之间那一段（0.15~0.5）是**故意留的空档**：
    /// 落到那里说明"像又不像"（现场版 / 剪辑版 / 大量重复段），此时不动手比动手安全。
    static let rejectThreshold = 0.15

    /// 字符 n-gram 的 n。
    ///
    /// 用**字符**而不是**词**：中日韩没有空格分词，词级切分本身就是一个不可靠的假设；
    /// 5 个字符在拉丁文里约等于一个词的长度，在 CJK 里足以定位半句话 —— 两边都够用。
    static let shingleSize = 5

    // MARK: 比对

    /// - Parameters:
    ///   - reference: **裁判源**的歌词行（权威，身份已由 track id 锚定）。
    ///   - candidate: **网易选中的候选**的歌词行。
    static func compare(reference: [String], candidate: [String]) -> NeteaseCrossResult {
        let referenceText = normalizedText(reference)
        let candidateText = normalizedText(candidate)

        guard !referenceText.isEmpty, !candidateText.isEmpty else {
            return NeteaseCrossResult(verdict: .unknown, overlap: 0, reason: "empty")
        }

        let referenceShingles = shingles(of: referenceText)
        let candidateShingles = shingles(of: candidateText)

        guard referenceShingles.count >= minimumShingleCount,
              candidateShingles.count >= minimumShingleCount else {
            return NeteaseCrossResult(verdict: .unknown, overlap: 0, reason: "too-short")
        }

        // ★ 书写系统可比性：**网易有时把罗马字／译文当正文下发**（日语歌尤其常见）。
        //   那时它与裁判源的日文原文重合率天然接近 0 —— 那不是"选错歌"，
        //   是"两份文本根本不在同一个书写系统里，没法比"。这种情况一律不判定。
        if scriptsAreIncomparable(referenceText, candidateText) {
            return NeteaseCrossResult(verdict: .unknown, overlap: 0, reason: "script-mismatch")
        }

        let intersection = referenceShingles.intersection(candidateShingles).count
        let denominator = min(referenceShingles.count, candidateShingles.count)
        let overlap = denominator == 0 ? 0 : Double(intersection) / Double(denominator)

        if overlap >= confirmThreshold {
            return NeteaseCrossResult(verdict: .confirm, overlap: overlap, reason: "overlap")
        }
        if overlap < rejectThreshold {
            return NeteaseCrossResult(verdict: .reject, overlap: overlap, reason: "overlap")
        }
        return NeteaseCrossResult(verdict: .unknown, overlap: overlap, reason: "inconclusive")
    }

    // MARK: 归一化

    /// 把所有行压成**一条**只含字母/数字的串。
    ///
    /// 三次折叠 + 一次小写 + 一次过滤：
    ///   · `caseInsensitive` / `lowercased()` —— 大小写不算差异（`lowercased()` 是显式的，
    ///     不指望 `folding(.caseInsensitive)` 一定给小写 —— 两边都走同一条归一化，
    ///     多这一步只会让结论更稳）；
    ///   · `widthInsensitive` —— 全角/半角不算差异（日文歌名与韩文歌词里很常见）；
    ///   · `diacriticInsensitive` —— `ü` 与 `u` 不算差异；
    ///   · 只留 `isLetter || isNumber` —— 标点、空白、`♪`、时间戳残留、`[00:12.34]` 全在这一步消失，
    ///     不需要为每个源单独写剥离规则。
    ///
    /// 行与行**直接拼接**（不加分隔符）：两边行切分本来就不同，加分隔符等于把
    /// "网易切 30 行、裁判源切 45 行"变成系统性差异。
    static func normalizedText(_ lines: [String]) -> String {
        var parts = [String]()
        for line in lines {
            let folded = line.folding(
                options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ).lowercased()
            var kept = String()
            for character in folded where character.isLetter || character.isNumber {
                kept.append(character)
            }
            // 单独的 `♪` / 纯标点行归一化后为空，直接丢掉（不占 gram）。
            if !kept.isEmpty {
                parts.append(kept)
            }
        }
        return parts.joined()
    }

    /// 字符 n-gram 集合（滑动窗口，去重）。
    static func shingles(of text: String, size: Int = NeteaseCrossValidation.shingleSize) -> Set<String> {
        let characters = Array(text)
        guard size > 0, characters.count >= size else { return [] }
        var result = Set<String>()
        result.reserveCapacity(characters.count - size + 1)
        for start in 0...(characters.count - size) {
            result.insert(String(characters[start..<(start + size)]))
        }
        return result
    }

    // MARK: 书写系统

    /// 文本里"CJK 类字符"（假名 / 汉字 / 谚文 / 半角片假名）所占比例。
    static func cjkRatio(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var cjkCount = 0
        var total = 0
        for scalar in text.unicodeScalars {
            total += 1
            switch scalar.value {
            case 0x3040...0x30FF, // 平假名 + 片假名
                 0x31F0...0x31FF, // 片假名拼音扩展
                 0x3400...0x4DBF, // CJK 扩展 A
                 0x4E00...0x9FFF, // CJK 统一表意文字
                 0xAC00...0xD7AF, // 谚文音节
                 0xF900...0xFAFF, // CJK 兼容表意文字
                 0xFF66...0xFF9D: // 半角片假名
                cjkCount += 1
            default:
                break
            }
        }
        guard total > 0 else { return 0 }
        return Double(cjkCount) / Double(total)
    }

    /// 一份"基本是 CJK"、另一份"基本没有 CJK" ⇒ 不可比（十有八九是罗马字 / 译文 vs 原文）。
    static func scriptsAreIncomparable(_ lhs: String, _ rhs: String) -> Bool {
        let lhsRatio = cjkRatio(lhs)
        let rhsRatio = cjkRatio(rhs)
        let oneIsMostlyCJK = lhsRatio >= 0.5 || rhsRatio >= 0.5
        let oneIsAlmostNoCJK = lhsRatio <= 0.05 || rhsRatio <= 0.05
        return oneIsMostlyCJK && oneIsAlmostNoCJK
    }
}
