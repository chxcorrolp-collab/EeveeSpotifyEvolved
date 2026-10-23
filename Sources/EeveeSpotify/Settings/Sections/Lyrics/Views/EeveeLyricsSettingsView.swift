import Foundation
import SwiftUI

struct EeveeLyricsSettingsView: View {
    @StateObject var viewModel = EeveeLyricsSettingsViewModel()

    // 网易云时间轴偏移（只对网易云生效）。默认值来自 `NeteaseTimingOffset`；
    // 当前歌曲那一行只在“这份歌词实际来自网易云”时有内容。
    @State private var neteaseOffsetMs = NeteaseTimingOffset.sourceOffsetMs
    @State private var currentSongTrackId = ""
    @State private var currentSongOffsetMs = 0
    @State private var currentSongHasOverride = false
    /// 当前播放这首的显示名（只给"当前歌曲"那一行做副标题，不改任何存储）。
    @State private var currentSongTitle = ""
    @State private var currentSongArtist = ""
    /// 已保存的单曲偏移（**不含当前播放这首**；它在下面单独一行，避免同一首出现两次）。
    @State private var savedSongOffsets: [SavedSongOffset] = []

    private struct SavedSongOffset: Identifiable {
        let id: String
        let title: String
        let offsetMs: Int
    }

    var body: some View {
        List {
            wordByWordLyricsSection()

            // 「更好的逐词歌词」是「开启逐词歌词」的子项：**必须紧跟主开关**，
            // 中间不插别的 section。主开关没开时整项不展示
            // （与下面 NetEase 那几项同一套写法）。
            if viewModel.wordByWordLyrics {
                betterWordByWordLyricsSection()
            }

            lyricsSourceSection()
            
            // 「禁用歌词功能」作为「禁用歌词替换功能」的二级菜单：
            // 仅当「禁用歌词替换功能」开启（lyricsSource == .notReplaced）时显示，
            // 写法与下方两个 NetEase 设置的条件显示一致。
            if viewModel.lyricsSource == .notReplaced {
                disableLyricsSection()
            }
            
            if viewModel.lyricsSource == .netease {
                neteaseRomajiLocalSection()
                neteaseHideTranslationSection()
                neteaseTimingOffsetSection()
            }
            
            if viewModel.lyricsSource != .notReplaced {
                // 「AMLL 优先」需要有一个「用户自己选的源」作为回退目标，
                // 所以来源为 Genius / 多级回退 / LRCLIB / AMLL 时不展示。
                // ★ 2026-10-02 恢复（2026-09-25 曾整段删除）。
                if viewModel.lyricsSource != .genius
                    && viewModel.lyricsSource != .multiLevel
                    && viewModel.lyricsSource != .lrclib
                    && viewModel.lyricsSource != .amllTtml {
                    amllPreferredSection()
                }
                
                // Genius 回退保持原有条件：多级回退链路本身以 Genius 收尾，
                // 不再重复提供该开关；来源为 Genius 时自己回退给自己没有意义。
                if viewModel.lyricsSource != .genius && viewModel.lyricsSource != .multiLevel {
                    geniusFallbackSection()
                }
                
                hideOnErrorSection()
                // 「补时间轴」/「补卡片元素」/「强制歌词入口」三个**排查型**开关
                // 已挪到「调试」页（见 `EeveeDebugSettingsViewModel`）：
                // 它们验证完就该写死或删掉，放在用户偏好旁边只会让人面对一堆不该动的东西。
                // ⚠️ 它们的 UserDefaults key 没有变，设备上已设的值原样保留。
                // 「隐藏官方歌词」已写死启用（见 `NgzhwmSettingsViewModel` 里那个
                // getter），不再有开关。
                romanizationSection()
                
                // 多级回退链路包含 Musixmatch，其语言项同样可配置。
                if viewModel.lyricsSource == .musixmatch || viewModel.lyricsSource == .multiLevel {
                    musixmatchLanguageSection()
                }
            }
            
            // 已移除一节（2026-10-18）：「删除间奏符号 ♪」那颗 Toggle。
            // 它的行为已经无条件生效（间奏行整行丢弃），开关留着只是个空壳 ——
            // 键、属性、绑定日志与 l10n 一起摘掉，理由见 `NgzhwmSettingsViewModel` 顶部。
            
            NonIPadSpacerView()
        }
        // ⚠️ 这里曾经有一个 `.onReceive(viewModel.musixmatchTokenInputAlertPublisher)`，
        // 用 `showAnonymousTokenOption` 决定弹窗里要不要显示「请求匿名令牌」。
        // 那个 publisher 全工程没有任何一处 `send`（死订阅），而匿名令牌选项本身
        // 也已整体移除 —— 两个一起去掉。
        // 手动填令牌的弹窗保留，改由下面这个绑定在"选中 Musixmatch 那一刻"调用。
                // ★ 2026-10-12：inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .animation(.default, value: viewModel.animationValues)
    }
    
    @ViewBuilder private func wordByWordLyricsSection() -> some View {
        Section(
            footer: Text("ngzhwm_word_by_word_lyrics_description".localized)
        ) {
            Toggle(
                "ngzhwm_word_by_word_lyrics".localized,
                isOn: $viewModel.wordByWordLyrics
            )
        }
    }

    /// 「更好的逐词歌词」：**跟着主开关显示/隐藏的子项**，不单独占一个平级位置。
    ///
    /// 与文件里其它条件项同一套写法（例如
    /// `if viewModel.lyricsSource == .netease { ... }`）：
    /// 逐词歌词没开时它没有任何意义，所以整项不展示，而不是置灰。
    ///
    /// 页脚里把"开启后自动带上什么"说清楚，免得用户去找已经不存在的
    /// 模糊封面 / 系统材质开关（那两个已改为跟随本项自动启用）。
    ///
    /// ⚠️ 文案 key 是 `_description` 而不是 `_footer`：本文件里所有页脚都用
    /// `<开关名>_description`（逐词歌词、更好的逐词歌词、禁用歌词、多级回退……一致）。
    /// 这里曾经多出一个 `ngzhwm_better_word_by_word_lyrics_footer`，是**同一个开关
    /// 两份文案** —— 改文案时只改一处、另一处悄悄过期，正是那种"看起来改过了、
    /// 界面上还是旧话"的坑。现在合并成一条。
    @ViewBuilder private func betterWordByWordLyricsSection() -> some View {
        Section(
            footer: Text("ngzhwm_better_word_by_word_lyrics_description".localized)
        ) {
            Toggle(
                "ngzhwm_better_word_by_word_lyrics".localized,
                isOn: $viewModel.betterWordByWordLyrics
            )
        }
    }
    
    @ViewBuilder private func disableLyricsSection() -> some View {
        Section(
            footer: Text("ngzhwm_disable_lyrics_feature_description".localized)
        ) {
            Toggle(
                "ngzhwm_disable_lyrics_feature".localized,
                isOn: $viewModel.disableLyricsFeature
            )
        }
    }
    
    @ViewBuilder private func geniusFallbackSection() -> some View {
        Section {
            Toggle(
                "genius_fallback".localized,
                isOn: $viewModel.lyricsOptions.geniusFallback
            )
            
        } footer: {
            Text("genius_fallback_description"
                .localizeWithFormat(viewModel.lyricsSource.description))
        }
    }
    
    /// 「AMLL 优先」：勾选后先向 AMLL 要逐词歌词，没正常返回再回退到
    /// 用户在来源选择器里设置的那个源。选项依赖逐词歌词，未开启时整体禁用。
    ///
    /// ★ 2026-10-02 恢复（2026-09-25 曾整段删除，连带两个 l10n 键）。
    @ViewBuilder private func amllPreferredSection() -> some View {
        Section {
            Toggle(
                "ngzhwm_amll_preferred".localized,
                isOn: $viewModel.amllPreferred
            )
            .disabled(!viewModel.wordByWordLyrics)
        } footer: {
            Text("ngzhwm_amll_preferred_description".localized)
        }
    }
    
    @ViewBuilder private func romanizationSection() -> some View {
        Section(
            footer: Text("ngzhwm_romanization_description".localized)
        ) {
            Toggle("ngzhwm_chinese_romanization".localized, isOn: $viewModel.chineseRomanization)
            Toggle("ngzhwm_japanese_romanization".localized, isOn: $viewModel.japaneseRomanization)
            Toggle("ngzhwm_korean_romanization".localized, isOn: $viewModel.koreanRomanization)
        }
    }

    @ViewBuilder private func hideOnErrorSection() -> some View {
        Section {
            Toggle(
                "hide_lyrics_on_error".localized,
                isOn: $viewModel.lyricsOptions.hideOnError
            )
        } footer: {
            Text("hide_lyrics_on_error_description".localized)
        }
    }

    // 已移除两个 Section（2026-09-27）：`injectLyricsCardElementSection()` /
    // `lyricsEntryPointFlagSection()` —— 它们是**排查/验证型**开关，已整体挪到
    // 「调试」页（`EeveeDebugSettingsView`）。key 与 l10n 都没变，用户已设的值照旧生效。
    // 同批**删除**的 `syntheticLineTimingSection()`（「补全歌词时间轴」）是另一回事：
    // 验证完毕、功能整体删掉，key 与 l10n 也一起删了，不再有任何入口。

    // 已移除一个 Section（2026-09-25）：`hideOfficialLyricsSection()` ——
    // 它的开关价值只在"验证修复有没有用"那一步，验证完就写死启用了。
    // 那个 l10n 键也一并删除（见 en/zh-CN 的 Localizable.strings）。

    @ViewBuilder private func neteaseRomajiLocalSection() -> some View {
        Section(
            footer: Text("ngzhwm_netease_romaji_local_description".localized)
        ) {
            Toggle(
                "ngzhwm_netease_romaji_local".localized,
                isOn: $viewModel.neteaseRomajiLocal
            )
        }
    }

    @ViewBuilder private func neteaseHideTranslationSection() -> some View {
        Section(
            footer: Text("ngzhwm_netease_hide_translation_description".localized)
        ) {
            Toggle(
                "ngzhwm_netease_hide_translation".localized,
                isOn: $viewModel.neteaseHideTranslation
            )
        }
    }

    @ViewBuilder private func musixmatchLanguageSection() -> some View {
        Section {
            HStack {
                Text("musixmatch_language".localized)
                
                Spacer()
                
                TextField("en", text: $viewModel.lyricsOptions.musixmatchLanguage)
                    .frame(maxWidth: 20)
                    .foregroundColor(.gray)
            }
            .icon(
                "exclamationmark.triangle.fill",
                color: .yellow,
                when: $viewModel.showMusixmatchInvalidLanguageWarning
            )
        } footer: {
            Text("musixmatch_language_description".localized)
        }
    }

    /// 网易云歌词时间轴偏移。
    ///
    /// 只对网易云生效：它的歌词是 UGC，同一首歌的不同上传版本时间轴质量参差不齐；
    /// 其它源来自官方/稳定库，偏差通常是个别歌，不值得为它们各配一套。
    ///
    /// 默认偏移作用于这个源的全部歌词；「当前歌曲」那一行是单曲覆盖，
    /// 只在当前这份歌词**实际来自网易云**时出现。
    ///
    /// ★ 2026-10-22（用户：「做成可以调整 A 歌曲偏移多少、B 歌曲偏移多少」）：
    ///    **按曲目分开存本来就有**（`NeteaseTimingOffset` 按 Spotify track id 存），只是设置页
    ///    以前只显示"正在播的那一首"，用户看不到另外那些。现在：
    ///     ① 当前歌曲那一行显示歌名（不再只写「当前歌曲」）；
    ///     ② 多出一节「已保存的单曲偏移」，每首一行、可单独 ±0.1s、左滑删除；
    ///     ③ 改当前歌曲时把歌名一起存下来（老数据没名字就显示「未知歌曲 · 后 6 位 id」）。
    @ViewBuilder private func neteaseTimingOffsetSection() -> some View {
        Section {
            HStack {
                Text("netease_offset_default".localized)
                Spacer()
                Text(formattedOffset(neteaseOffsetMs))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Stepper(value: $neteaseOffsetMs, in: -5000...5000, step: 50) {
                Text("netease_offset_step".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .onChange(of: neteaseOffsetMs) { newValue in
                NeteaseTimingOffset.sourceOffsetMs = newValue
                reapplyNeteaseTimingOffset()
                refreshCurrentSongOffset()
            }

            if !currentSongTrackId.isEmpty {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("netease_offset_current_song".localized)
                        if !currentSongTitle.isEmpty {
                            Text(currentSongTitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(formattedOffset(currentSongOffsetMs))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 12) {
                    Button("-0.1s") { adjustCurrentSong(by: -100) }
                    Button("+0.1s") { adjustCurrentSong(by: 100) }
                    Spacer()
                    if currentSongHasOverride {
                        // ★★ 2026-10-23（用户：「没看到保存/删除按键」）：单曲偏移一直是
                        // 「一按 ± 就立刻存」的，但之前只有左滑删除 —— 看不见就等于没有。
                        // 这里给一颗**明摆着的**删除键。
                        Button {
                            NeteaseTimingOffset.clearOverride(forTrackId: currentSongTrackId)
                            reapplyNeteaseTimingOffset()
                            refreshCurrentSongOffset()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .foregroundColor(.red)
                        .accessibilityLabel(Text("netease_offset_delete_song".localized))
                    } else {
                        // 没有覆盖时给一颗显式「保存」：按一下就为这一首建一条（存当前生效值）。
                        Button("netease_offset_save_song".localized) { saveCurrentSong() }
                            .font(.caption)
                        Text("netease_offset_autosave_hint".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text("netease_offset_description".localized)
        }
        .onAppear {
            neteaseOffsetMs = NeteaseTimingOffset.sourceOffsetMs
            refreshCurrentSongOffset()
        }

        // ★★ 2026-10-23：这一节**永远显示**（以前只有存在条目时才出现 ⇒ 用户以为"没有保存"）。
        // 空的时候给一句"怎么才能存进去"，有数据时每首一行（当前播放那首在上面单独一行）。
        Section(header: Text("netease_offset_saved".localized)) {
            if savedSongOffsets.isEmpty {
                // 当前播放这首是**单独一行**放在上一节的（列表里不重复它）⇒ 刚保存完当前歌时
                // 这里看起来还是"空"的。用一句不同的话说明，免得用户以为没存上。
                Text(currentSongHasOverride
                     ? "netease_offset_saved_only_current".localized
                     : "netease_offset_saved_empty".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(savedSongOffsets) { song in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(formattedOffset(song.offsetMs))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Spacer()
                        Button("-0.1s") { adjustSavedSong(song, by: -100) }
                        Button("+0.1s") { adjustSavedSong(song, by: 100) }
                        Button {
                            NeteaseTimingOffset.clearOverride(forTrackId: song.id)
                            reapplyNeteaseTimingOffset()
                            refreshCurrentSongOffset()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .foregroundColor(.red)
                        .accessibilityLabel(Text("netease_offset_delete_song".localized))
                    }
                    .buttonStyle(.borderless)
                }
                .onDelete(perform: deleteSavedSongs)
            }

            if !NeteaseTimingOffset.trackOffsets.isEmpty {
                Button("netease_offset_clear_all".localized) {
                    NeteaseTimingOffset.clearAllOverrides()
                    reapplyNeteaseTimingOffset()
                    refreshCurrentSongOffset()
                }
                .foregroundColor(.red)
            }
        } footer: {
            Text("netease_offset_saved_description".localized)
        }
    }

    private func formattedOffset(_ milliseconds: Int) -> String {
        String(format: "%+.2fs", Double(milliseconds) / 1000)
    }

    /// `"歌名 — 歌手"`（缺一项就只留另一项；两项都空 = 空串）。
    private var currentSongDisplayName: String {
        [currentSongTitle, currentSongArtist]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    /// 「当前歌曲」那一行：只在当前歌词**实际来自网易云**时取到 track id。
    private func refreshCurrentSongOffset() {
        let isNetease = currentLyricsProvider == LyricsSource.netease.description
        let trackId = isNetease ? currentLyricsDtoTrackId : ""
        currentSongTrackId = trackId
        currentSongHasOverride = !trackId.isEmpty && NeteaseTimingOffset.hasOverride(forTrackId: trackId)
        currentSongOffsetMs = trackId.isEmpty ? 0 : NeteaseTimingOffset.offsetMs(forTrackId: trackId)

        // 歌名只是给这一行做副标题（也用于把它写进"已保存"列表），取不到就留空。
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        currentSongTitle = track?.string(ifResponding: "trackTitle") ?? ""
        currentSongArtist = track?.string(ifResponding: "artistName")
            ?? track?.string(ifResponding: "artistTitle")
            ?? ""

        refreshSavedSongOffsets()
    }

    /// 已保存那一列：**不含当前播放这首**（它在上面单独一行，避免同一首出现两次）。
    private func refreshSavedSongOffsets() {
        let offsets = NeteaseTimingOffset.trackOffsets
        let titles = NeteaseTimingOffset.trackTitles
        let currentId = currentSongTrackId
        let unknownName = "netease_offset_unknown_song".localized

        savedSongOffsets = offsets.compactMap { entry -> SavedSongOffset? in
            if !currentId.isEmpty, entry.key == currentId { return nil }
            let stored = titles[entry.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = stored.isEmpty ? unknownName + " · " + shortTrackId(entry.key) : stored
            return SavedSongOffset(id: entry.key, title: name, offsetMs: entry.value)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 老数据没有存过歌名：只显示 track id 的后 6 位，不编造。
    private func shortTrackId(_ trackId: String) -> String {
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return trimmed }
        return String(trimmed.suffix(6))
    }

    private func adjustCurrentSong(by deltaMs: Int) {
        guard !currentSongTrackId.isEmpty else { return }
        let base = NeteaseTimingOffset.offsetMs(forTrackId: currentSongTrackId)
        NeteaseTimingOffset.setOffset(
            base + deltaMs,
            forTrackId: currentSongTrackId,
            trackTitle: currentSongDisplayName
        )
        reapplyNeteaseTimingOffset()
        refreshCurrentSongOffset()
    }

    /// 显式的「保存」：为当前这首建一条单曲覆盖（值 = 当前生效值）。
    ///
    /// 有它是因为 ±0.1s 虽然**当场就存**，但用户看不到"保存"这个动作，以为没存上。
    /// 存完 `currentSongHasOverride` 变真 ⇒ 这颗键换成删除键，列表里也多一行。
    private func saveCurrentSong() {
        guard !currentSongTrackId.isEmpty else { return }
        let value = NeteaseTimingOffset.offsetMs(forTrackId: currentSongTrackId)
        NeteaseTimingOffset.setOffset(
            value,
            forTrackId: currentSongTrackId,
            trackTitle: currentSongDisplayName
        )
        reapplyNeteaseTimingOffset()
        refreshCurrentSongOffset()
    }

    /// 已保存列表里的某一首：改的**不是当前播放这首**，不传歌名（保持已存的名字）。
    private func adjustSavedSong(_ song: SavedSongOffset, by deltaMs: Int) {
        let base = NeteaseTimingOffset.offsetMs(forTrackId: song.id)
        NeteaseTimingOffset.setOffset(base + deltaMs, forTrackId: song.id)
        reapplyNeteaseTimingOffset()
        refreshCurrentSongOffset()
    }

    private func deleteSavedSongs(at offsets: IndexSet) {
        for index in offsets where savedSongOffsets.indices.contains(index) {
            NeteaseTimingOffset.clearOverride(forTrackId: savedSongOffsets[index].id)
        }
        reapplyNeteaseTimingOffset()
        refreshCurrentSongOffset()
    }
}
