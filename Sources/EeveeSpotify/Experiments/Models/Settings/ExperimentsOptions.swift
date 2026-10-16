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

    init(
        liveContainerSharing: Bool,
        showInstagramDestination: Bool = false,
        petitLyricsNetEaseFallback: Bool = false,
        amllFuzzySearch: Bool = false
    ) {
        self.liveContainerSharing = liveContainerSharing
        self.showInstagramDestination = showInstagramDestination
        self.petitLyricsNetEaseFallback = petitLyricsNetEaseFallback
        self.amllFuzzySearch = amllFuzzySearch
    }

    /// 手写解码：`liveContainerSharing` 之外那三样都是**后加的**字段，早期盘上根本没有它们。
    /// 合成解码器遇到缺字段会抛，而 `@UserDefault` 解失败会**整份回落到 defaultValue**
    /// —— 那等于一次升级把用户已经关掉的 `liveContainerSharing` 又打开。
    /// 口径与 `FlagOverride.init(from:)` 一致：缺的键取"关"。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        liveContainerSharing = try container.decodeIfPresent(Bool.self, forKey: .liveContainerSharing) ?? true
        showInstagramDestination = try container.decodeIfPresent(Bool.self, forKey: .showInstagramDestination) ?? false
        petitLyricsNetEaseFallback = try container.decodeIfPresent(Bool.self, forKey: .petitLyricsNetEaseFallback) ?? false
        amllFuzzySearch = try container.decodeIfPresent(Bool.self, forKey: .amllFuzzySearch) ?? false
    }
}
