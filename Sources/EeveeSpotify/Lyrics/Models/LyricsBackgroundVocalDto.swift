import Foundation

/// 背景人声/副唱（AMLL 的 `ttm:role="x-bg"`）。
///
/// 与主词**时间重叠**，所以不能用「主词 (副唱)」这种顺序拼接来表达 ——
/// 那样会把"同时"退化成"先唱完主词再唱副唱"。
///
/// 本类型是仓库层的中转结构；渲染层用的是 `LyricBackgroundVocal`（MeloX 模型），
/// 由 `LyricLinesAdapter` 负责转换。
struct LyricsBackgroundVocalDto {
    /// 副唱片段。按顺序拼接即为完整文本（含原有的词间空格）。
    var syllables: [LyricsWordDto]
    /// 是否出现在主词之前（决定它渲染在主歌上方还是下方）。
    var isBeforePrimary: Bool
    /// 副唱**自己的**译文。
    ///
    /// AMLL 的写法是「`<span ttm:role="x-bg">` 里再套一个
    /// `<span ttm:role="x-translation">`」（行内），或 `<iTunesMetadata>` 旁挂里同样嵌一层 ——
    /// parser 早就把它收进 `AmllTtmlBackgroundVocal.translation`，但这条链在这里断了：
    /// DTO 没字段 / mapper 没接 / `LyricLinesAdapter` 硬编码 `translation: nil`。
    /// 渲染层其实**一直**支持（`SynchronizedLyricText.backgroundVocalRow` 会把它画成副唱下面
    /// 那一小行，字号用 `translationBackgroundVocalsFontCoefficient`）。
    var translation: String? = nil

    var text: String {
        syllables.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool {
        text.isEmpty
    }
}
