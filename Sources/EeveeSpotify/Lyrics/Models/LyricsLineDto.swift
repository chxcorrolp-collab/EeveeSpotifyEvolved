import Foundation

struct LyricsLineDto {
    var content: String
    var offsetMs: Int?
    var words: [LyricsWordDto]? = nil
    /// 背景人声/副唱（目前只有 AMLL 会给出）。
    ///
    /// 它**不属于** `content` / `words`：那些是主词序列。副唱与主词时间重叠，
    /// 由渲染层单独画一小行，而不是顺序拼进主歌。
    var backgroundVocal: LyricsBackgroundVocalDto? = nil

    /// ★ 2026-10-19：**空白行** —— 内容去掉空白就没了，而且这一行上**没有**词级数据、
    /// 也没有副唱。显示层/注入 payload 用它把这种行整行丢掉（判据**只有这一份**，
    /// 两个调用点见 `LyricsDto.droppingBlankLinesForDisplay()` 与
    /// `LyricsDto.toSpotifyLyricsData`）。
    ///
    /// 为什么要把 `words` / `backgroundVocal` 也写进判据：
    ///   · AMLL 的「纯副唱行」主词文本本来就是空的（`AmllLyricsMapper.makeDto` 特意保留它，
    ///     注释写着"只有副唱的行要保留，否则会丢掉纯副唱那几行的内容"）——
    ///     只看 `content` 会把那种行整行删掉；
    ///   · 词级序列在的行同样不该因为 `content` 空就被删（那是上游的形态，不是空行）。
    ///
    /// ⚠️ 它**不是**「间奏行」判据：这里只认真正的空白（空串 / 纯空格 / 纯换行），
    ///    `♪` `♫` 那类占位符一律不动 —— 音乐符号由各仓库自己更严格的判据管
    ///    （`NeteaseLyricsRepository.isInterludeRow` /
    ///     `MusixmatchLyricsRepository.isMxmInterludeRow`，2026-10-18 起无条件整行丢弃），
    ///    别在这里抢它们的活。
    var isBlankForDisplay: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (words?.isEmpty ?? true)
            && backgroundVocal == nil
    }
}
