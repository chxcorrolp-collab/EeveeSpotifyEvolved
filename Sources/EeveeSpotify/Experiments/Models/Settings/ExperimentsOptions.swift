// ⚠️ 这个文件**必须** `import Foundation`：2026-10-17 之前它只有 `Bool` 字段，
//    `Codable` / `Decoder` 都在 stdlib 里，所以不 import 也能编过；一旦用到
//    `Locale` / `TimeZone`（下面那个地区判断）就编不过了 —— `swiftc -parse` 不解析
//    import，CI 的语法门挡不住这一类，只能在真机 build 里暴露。
import Foundation

struct ExperimentsOptions: Codable, Equatable {
    var liveContainerSharing: Bool
    /// 「显示 Instagram 分享位」—— 2026-10-02 删过一次（它挂的 `SPTSharingSDK` /
    /// `SPTShare_FoundationImplProperties` 只在 Spotify 9.1.0 上存在），2026-10-16 按
    /// **9.1.88 的真实形态**重做：不再 hook 类，改成强制三条服务端 flag（见
    /// `ExperimentFlagReplacements`，与用户自己的「Flag 覆盖」走同一条管线）。
    var showInstagramDestination: Bool
    /// 「PetitLyrics 回退 NetEase」—— 来源选 PetitLyrics + 「AMLL 优先」+「Genius 回退」都为开时，
    /// 在 PetitLyrics 与 Genius 之间多插一跳网易云（见 `CustomLyrics` 里 `amllPreferred` 那一段）。
    var petitLyricsNetEaseFallback: Bool
    /// 「AMLL 模糊搜索」—— AMLL 的精确（spotifyId）查不到时，按歌名再搜一次
    /// （见 `AmllTtmlLyricsRepository.fuzzySearchItem`）。逐词质量闸门不受影响。
    var amllFuzzySearch: Bool
    /// 「NetEase 交叉验证」—— 2026-10-17（用户）：非中国大陆 IP 下网易的搜索**排序按地区变**
    /// ⇒ 我们会从它的排名列表里挑错歌。这个开关打开后，**只在"三道闸门没全过"的候选上**
    /// 拿一级裁判源（SpicyLyrics / AMLL / Musixmatch —— 身份由 Spotify Track ID 锚定）
    /// 的歌词来核对；重合率不足就回到网易自己的候选表里换下一条（换不出来才交给下一个源）。
    ///
    /// 判据与分级见 `NetEaseCrossValidation.swift` / `NeteaseCrossValidationRunner.swift`。
    var neteaseCrossValidation: Bool
    /// 「SpicyLyrics 交叉验证」—— 2026-10-17（用户）：SpicyLyrics 的上游会把部分词和谐成
    /// 星号（`my **** line`）。打开后拿**同一首歌**在另一个源里的文本找回同一句，
    /// 只把星号那几段换掉（见 `LyricsCensorFill` / `LyricsUncensorFill`）。
    ///
    /// **默认关**（用户明确要求）：它会为每首"确实有星号"的歌多发 1~5 次请求。
    /// ⚠️ 历史：这个功能在 2026-10-17 之前是**无条件开着**的，但那时它的检测正则是
    /// `\b\*{3,}\b`，实测只命中 `f***k` 这种写法、`my **** line` 一个都不命中
    /// ⇒ 实际上等于没接线。所以"改成默认关"对绝大多数用户**不是行为倒退**，
    /// 而是把一个本来就没生效的东西改成显式可选。
    var spicyLyricsCrossValidation: Bool
    /// 「启用Apple Music官方TTML歌词」—— 2026-10-17（用户）：直接接 **Apple Music 官方**的
    /// TTML（不是 AMLL 那份社区库）。
    ///
    /// 语义是**总覆盖**：打开后这一首只问 Apple Music，忽略「歌词来源」「AMLL 优先」
    /// 「Genius 回退」「多级回退」以及各来源自己的设置，失败也**不兜底**
    /// （见 `CustomLyrics.loadCustomLyricsForCurrentTrack` 顶部那一段）。
    ///
    /// ⚠️ 它需要用户在同一个设置页里粘一个 `media-user-token`（Apple 没有公开歌词 API，
    /// 见 `AppleMusicTtml+UserDefaults.swift`）。没填令牌时这一源直接抛
    /// `.missingAppleMusicToken`，界面上表现为"未找到歌词" + 一次提示弹窗。
    var appleMusicOfficialTtml: Bool

    init(
        liveContainerSharing: Bool,
        showInstagramDestination: Bool = false,
        petitLyricsNetEaseFallback: Bool = false,
        amllFuzzySearch: Bool = false,
        neteaseCrossValidation: Bool = ExperimentsOptions.defaultNeteaseCrossValidation,
        spicyLyricsCrossValidation: Bool = false,
        appleMusicOfficialTtml: Bool = false
    ) {
        self.liveContainerSharing = liveContainerSharing
        self.showInstagramDestination = showInstagramDestination
        self.petitLyricsNetEaseFallback = petitLyricsNetEaseFallback
        self.amllFuzzySearch = amllFuzzySearch
        self.neteaseCrossValidation = neteaseCrossValidation
        self.spicyLyricsCrossValidation = spicyLyricsCrossValidation
        self.appleMusicOfficialTtml = appleMusicOfficialTtml
    }

    /// 手写解码：`liveContainerSharing` 之外那些都是**后加的**字段，早期盘上根本没有它们。
    /// 合成解码器遇到缺字段会抛，而 `@UserDefault` 解失败会**整份回落到 defaultValue**
    /// —— 那等于一次升级把用户已经关掉的 `liveContainerSharing` 又打开。
    /// 口径与 `FlagOverride.init(from:)` 一致：缺的键取"默认值"。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        liveContainerSharing = try container.decodeIfPresent(Bool.self, forKey: .liveContainerSharing) ?? true
        showInstagramDestination = try container.decodeIfPresent(Bool.self, forKey: .showInstagramDestination) ?? false
        petitLyricsNetEaseFallback = try container.decodeIfPresent(Bool.self, forKey: .petitLyricsNetEaseFallback) ?? false
        amllFuzzySearch = try container.decodeIfPresent(Bool.self, forKey: .amllFuzzySearch) ?? false
        neteaseCrossValidation = try container.decodeIfPresent(Bool.self, forKey: .neteaseCrossValidation)
            ?? ExperimentsOptions.defaultNeteaseCrossValidation
        spicyLyricsCrossValidation = try container.decodeIfPresent(Bool.self, forKey: .spicyLyricsCrossValidation)
            ?? false
        appleMusicOfficialTtml = try container.decodeIfPresent(Bool.self, forKey: .appleMusicOfficialTtml)
            ?? false
    }

    // MARK: - 「NetEase 交叉验证」的默认值

    /// ★★★ 2026-10-17（用户拍板）：「把 实验 里面的那个 ne 的设置**改成默认关闭**」。
    ///
    /// 下面那段 2026-10-17 早先的权衡（"明确在大陆才默认关"）**作废** —— 用户是这套东西的
    /// 唯一真机用户，他明确要求默认关，那就默认关，不再按地区/时区猜。
    ///
    /// 为什么听用户的也对：那套代理信号有两个代价是他在真机上真付了的 ——
    /// ① 交叉验证会**多打 1~3 次裁判请求**，正好压在他抱怨的"播放页反应慢"上；
    /// ② 它换候选时会把**带 yrc 的那条**换成没 yrc 的，于是"逐词退化成逐行"
    ///    （日志 112 里 `独白` 那种现场）。
    ///
    /// 想开的人自己去「实验」页打开；默认值只在**首次写入**时算一次（`decodeIfPresent ??`），
    /// 之后一直听用户的。
    static var defaultNeteaseCrossValidation: Bool {
        false
    }
}
