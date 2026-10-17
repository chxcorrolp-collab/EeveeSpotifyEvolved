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

    init(
        liveContainerSharing: Bool,
        showInstagramDestination: Bool = false,
        petitLyricsNetEaseFallback: Bool = false,
        amllFuzzySearch: Bool = false,
        neteaseCrossValidation: Bool = ExperimentsOptions.defaultNeteaseCrossValidation,
        spicyLyricsCrossValidation: Bool = false
    ) {
        self.liveContainerSharing = liveContainerSharing
        self.showInstagramDestination = showInstagramDestination
        self.petitLyricsNetEaseFallback = petitLyricsNetEaseFallback
        self.amllFuzzySearch = amllFuzzySearch
        self.neteaseCrossValidation = neteaseCrossValidation
        self.spicyLyricsCrossValidation = spicyLyricsCrossValidation
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
    }

    // MARK: - 「NetEase 交叉验证」的默认值

    /// **只在"地区 + 时区都指向中国大陆"时默认关，其余一律默认开。**
    ///
    /// 为什么这样定（2026-10-17 与用户对齐）：
    ///
    /// 1. **真正的因果变量是出口 IP**，不是时区、也不是语言 —— 网易的排序是它服务端按
    ///    请求来源判的。设备上的地区/时区只是**代理信号**，两者都可能与真实 IP 错配
    ///    （中国用户挂着亚洲时区在国外；外国用户在上海用英文界面）。任何代理都会误判，
    ///    所以规则的目标不是"判准"，而是"**让误判落在便宜的那一侧**"。
    ///
    /// 2. **代价不对称**：默认开 ⇒ 误报的代价是"低置信度歌曲多 1~3 次裁判请求"（只是延迟）；
    ///    默认关 ⇒ 漏报的代价是"用户继续看到别人的歌词"（内容错）。**内容错比延迟严重。**
    ///    所以只要不是"明确在大陆"，就偏向开。
    ///
    /// 3. **时区比地区更接近"人在哪"**：地区（`Locale.regionCode`）是用户在设置里**手选**
    ///    的区域格式偏好，换手机时会沿用旧值；时区通常是系统跟着定位/运营商自动走的。
    ///    因此两者**同时**指向大陆才算"明确在大陆"。留学生把地区留成 CN、时区被系统改成
    ///    当地 ⇒ 这里判"开"，正好是需要保护的那批人。
    ///
    /// 4. 这个默认值**只在首次写入时算一次**（跟着 `decodeIfPresent ?? …` 的既有约定），
    ///    之后一直听用户的；不随旅行自动翻转 —— 一个会自己变的开关比一个定错值的开关更难查。
    static var defaultNeteaseCrossValidation: Bool {
        let isMainlandRegion = Locale.current.regionCode == "CN"
        let isMainlandTimeZone = mainlandTimeZoneIdentifiers.contains(TimeZone.current.identifier)
        return !(isMainlandRegion && isMainlandTimeZone)
    }

    /// 中国大陆时区（含历史别名/拼法）。只用于上面那个"明确在大陆"的判断。
    private static let mainlandTimeZoneIdentifiers: Set<String> = [
        "Asia/Shanghai",   // 标准名（历史别名 PRC / ROC 在某些系统上也指它）
        "Asia/Chongqing",
        "Asia/Chungking",
        "Asia/Harbin",
        "Asia/Urumqi",
        "Asia/Kashgar",
        "Asia/Beijing",
        "PRC",
        "ROC",
    ]
}
