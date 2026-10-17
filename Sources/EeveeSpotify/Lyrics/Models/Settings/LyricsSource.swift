import Foundation

enum LyricsSource: Int, CaseIterable, CustomStringConvertible {
    case genius
    case lrclib
    case musixmatch
    case petit
    case notReplaced
    // 新增分支追加在末尾，避免改变既有 rawValue 导致已存设置错位。
    case spicy
    case netease
    /// 多级回退：不是单一来源，而是固定顺序的链路（Mxm → PL → LRC → Gen）。
    /// 作为来源选择器里的一项，与具体来源互斥。
    case multiLevel
    /// AMLL：提供高质量逐词歌词与丰富的歌词结构（amll.dev）。
    /// 追加在末尾，避免改变既有 rawValue。
    case amllTtml
    /// Apple Music **官方** TTML（实验）。追加在末尾，避免改变既有 rawValue。
    ///
    /// ★ 2026-10-17：**刻意不出现在 `allCases` 里** —— 它不是用户在来源选择器里挑的一项，
    ///   而是由「设置 → 实验 → 启用Apple Music官方TTML歌词」这个总开关**强制**启用的
    ///   （那个开关的语义就是"忽略当前所有有关于歌词的设置"）。
    ///   所以它只会在 `CustomLyrics.loadCustomLyricsForCurrentTrack` 的覆盖分支里出现，
    ///   rawValue 也永远不会被写进 `lyricsSource` 这个 UserDefault。
    case appleMusicOfficialTtml
    
    static var allCases: [LyricsSource] {
        return [.genius, .lrclib, .amllTtml, .musixmatch, .petit, .spicy, .netease, .multiLevel]
    }

    // swift 5.8 compatible
    var description: String {
    switch self {
    case .genius:
        return "Genius"
    case .lrclib:
        return "LRCLIB"
    case .musixmatch:
        return "Musixmatch"
    case .petit:
        return "PetitLyrics"
    case .notReplaced:
        return "Spotify"
    case .spicy:
        // ★ 2026-10-13（用户）：连写的那版 `SpicyLyrics` 全部改成官方写法 `Spicy Lyrics`。
        //   这一串有三个去处：来源选择器的标签、署名兜底（`toSpotifyLyricsData` 的
        //   `providedBy`）、以及日志。SL 的站点 / 条款 / attribution 文档一律写两词；
        //   API 里的 `spicy_lyrics` 是**字段值**（标识符），不是展示名。
        return "Spicy Lyrics"
    case .netease:
        return "NetEase"
    case .multiLevel:
        return "ngzhwm_multi_level_fallback".localized
    case .amllTtml:
        return "AMLL"
    case .appleMusicOfficialTtml:
        // 这是**提供者署名**（注入 payload 的 `providedBy` / 页脚那一行），不是源选择器的标签。
        return "Apple Music"
    }
    }

    
    var isReplacingLyrics: Bool { self != .notReplaced }
    
    static var defaultSource: LyricsSource {
        Locale.isInRegion("JP", orHasLanguage: "ja")
            ? .petit
            : .spicy
    }
}
