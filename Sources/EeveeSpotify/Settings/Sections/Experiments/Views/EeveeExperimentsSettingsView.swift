import SwiftUI
import UIKit

/// 「实验」页：只放**尚未真机定性**的功能（默认关，用户主动开）。
///
/// 准入三条（2026-10-17 与用户对齐）：
///   ① 还没在真机上验证过效果；
///   ② 依赖会变的外部契约（服务端 flag / 私有类 / 第三方 App）；
///   ③ 改完要重启或清缓存才生效。
/// 三条里占一条才进来。**行为早已定性、只是"依赖外部"的开关不属于这里** ——
/// 「分享到 LiveContainer」因此于 2026-10-17 搬到「杂项设定」（见 `EeveeMiscellaneousSettingsView`）。
///
/// ⚠️ 2026-10-18：「NetEase 交叉验证」与「PetitLyrics 回退 NetEase」两个实验**已整体撤掉**
///    （用户拍板：这周关于网易云的改动全部回退，NE 目前只在来源说明里标注"不推荐非中国用户使用"）。
///    这一页现在只留 Instagram 分享位、AMLL 模糊搜索、SpicyLyrics 交叉验证、Apple 官方 TTML。
/// ★ 2026-10-24：加**歌词舞台**（`Lyrics/LyricsStage/`，默认关 + 两档样式）——
///   它是一条整屏型的新界面，符合本页准入条件 ①（还没在真机上定过性）。
struct EeveeExperimentsSettingsView: View {
    @State var experimentsOptions = UserDefaults.experimentsOptions

    /// 「启用Apple Music官方TTML歌词」那一栏的令牌输入框（见 `appleMusicTokenField()`）。
    ///
    /// 用 `@State` 而不是直接绑 `UserDefaults.appleMusicMediaUserToken`：那个 getter 带
    /// `trimmingCharacters`，绑定到 `TextField` 会**一边输入一边 trim**，光标位置跟着乱跳
    /// （粘贴含前后空格时尤其明显）。这里让输入框只认本地副本，落盘与"清 storefront 缓存"
    /// 都在 `onChange` 里做。
    @State private var appleMusicMediaUserToken = UserDefaults.appleMusicMediaUserToken

    var body: some View {
        List {
            // ★★ 2026-10-17（用户：「在**实验**这个模块的『显示 ins 分享目标』上面，写一行字：
            //   请注意，以下这些功能要么未经测试，要么有阻碍正常使用的 Bug……
            //   请谨慎开启此页面里面的任何功能」）：
            //   这一页按文件头那三条准入收进来，本来就该先示警 —— 放在**第一格之前的独立 section**，
            //   用 footnote + 次要色（不抢标题，但一定看得见；inset-grouped 下自成一张卡片）。
            Section {
                Text("experiments_page_warning".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // （「分享到 LiveContainer」2026-10-17 搬到「杂项设定」。理由见文件头的准入三条：
            //   它的行为早就定死了 —— 链接打不开就转给 LC、失败就把 URL 复制到剪贴板；
            //   真正"没定性"的是 LC 那一侧的私有深链，不是这个开关。）

            // ★★ 2026-10-24（用户：「功能开关放在实验里面」）：**歌词舞台**。
            //   一条整屏型的新界面，还没在真机上定过性 ⇒ 按本页准入条件 ① 放这里，默认关。
            //   实现见 `Lyrics/LyricsStage/`，设计依据见
            //   `C:\dsh\me\HANDOFF_2026-10-23_EeveeSpotify-ng_LyricsStage-Folia.md`。
            //   打开后听歌页（iOS 27 布局）底排左边那颗歌词气泡改成开我们自己的全屏窗口，
            //   不再转发给 Spotify 的 `ShowLyricsButton`（`NowPlayingIOS27+Footer.swift`）。
            //   样式选择器只在开关打开时出现 —— 关着的时候不占版面。
            Section(footer: Text(lyricsStageFooter)) {
                Toggle(
                    "lyrics_stage".localized,
                    isOn: $experimentsOptions.lyricsStage
                )

                if experimentsOptions.lyricsStage {
                    Picker(
                        "lyrics_stage_style".localized,
                        selection: $experimentsOptions.lyricsStageStyle
                    ) {
                        ForEach(LyricsStageStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
            }

            // ★★ 2026-10-16：这个实验 2026-10-02 删过一次 —— 它当时挂的
            //    `SPTSharingSDK` / `SPTShare_FoundationImplProperties` 只在 Spotify 9.1.0 上存在。
            //    这次按 **9.1.88** 的真实形态重做，两条腿一起上：
            //      · 强制三条服务端 flag（`ExperimentFlagReplacements`，与「Flag 覆盖」同一条管线）；
            //      · hook `Share_FoundationSwiftImpl…Properties` 的 init
            //        （`Experiments/Instagram/ShowInstagramDestination.x.swift`，dump:26180）。
            //    footer 的写法照上游：`%@` = 那句通用的"改完要重启"。
            Section(
                footer: Text("show_instagram_destination_description"
                    .localizeWithFormat("restart_is_required_description".localized))
            ) {
                Toggle(
                    "show_instagram_destination".localized,
                    isOn: $experimentsOptions.showInstagramDestination
                )
            }

            Section(footer: Text("amll_fuzzy_search_description".localized)) {
                Toggle(
                    "amll_fuzzy_search".localized,
                    isOn: $experimentsOptions.amllFuzzySearch
                )
            }

            // ★ 2026-10-17：SpicyLyrics 交叉验证（**默认关**）。
            //   补的是"上游把词和谐成星号"，判据在 `LyricsCensorFill`，
            //   接线在 `LyricsUncensorFill`（挂在 `SpicyLyricsRepository.parseLyricsData` 之后）。
            //   只有真的出现 `***` 时才发请求；一个源补完即停。
            Section(footer: Text("spicy_cross_validation_description".localized)) {
                Toggle(
                    "spicy_cross_validation".localized,
                    isOn: $experimentsOptions.spicyLyricsCrossValidation
                )
            }

            // ★★ 2026-10-17：Apple Music **官方** TTML（不是 AMLL 那份社区库）。
            //   这是本页唯一一个「**总覆盖**」型开关 —— 打开后忽略当前所有有关于歌词的设置
            //   （来源选择 / AMLL 优先 / Genius 回退 / 多级回退），失败也不兜底。
            //   实现见 `AppleMusicOfficialTtmlLyricsRepository` 与
            //   `CustomLyrics.loadCustomLyricsForCurrentTrack` 顶部那一段。
            //
            //   ⚠️ 它**必须**配一个 `media-user-token`：苹果没有公开的歌词 API，
            //   搜索只要网页令牌（我们自动抓），但取词要用户自己的 Apple Music 登录态。
            //   所以开关打开时才展开输入框 —— 没开的时候不占版面。
            Section(footer: Text(appleMusicOfficialTtmlFooter)) {
                Toggle(
                    "apple_music_official_ttml".localized,
                    isOn: $experimentsOptions.appleMusicOfficialTtml
                )

                if experimentsOptions.appleMusicOfficialTtml {
                    appleMusicTokenField()
                }
            }
        }
        .onChange(of: experimentsOptions) { options in
            UserDefaults.experimentsOptions = options

            // ★★ 2026-10-16（照上游 `EeveeSpotifyReincarnated` 的做法）：打开这一刻就把
            //    Spotify 的 **PersistentCache + remote-config** 清掉 ⇒ 它会重新拉/重算配置，
            //    不必让用户手动重启。清不掉也只是"这次要重启"，不影响正确性
            //    （`OfflineHelper.resetData` 里全是 `try?`）。
            if options.showInstagramDestination {
                OfflineHelper.resetData()
            }

            // ★ 2026-10-24：舞台开关关掉时**当场收窗口** —— 它是一扇独立窗口，
            //   不跟着开关收的话只能等用户自己下拉，那看起来就像"开关没生效"。
            //   样式那一颗不用管：宿主每 0.25s 对齐一次，打开着的舞台会就地换样式。
            if !options.lyricsStage {
                LyricsStageEntry.dismissIfPresented()
            }
        }

                // ★ 2026-10-12：inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .animation(.default, value: experimentsOptions)
        // 令牌落盘 + 缓存失效（见上面 `appleMusicMediaUserToken` 的说明）。
        .onChange(of: appleMusicMediaUserToken) { token in
            // ⚠️ 先把旧值抓出来再写盘 —— 写完再比就永远相等了。
            let previous = UserDefaults.appleMusicMediaUserToken
            UserDefaults.appleMusicMediaUserToken = token

            // 令牌变了 ⇒ 账号可能也变了（storefront / 默认语言都会变）：
            // 把 `accountContext` 那份缓存清掉，下一首重新问一次 `/v1/me/storefront`。
            if token != previous {
                writeDebugLog("[AMTTML] media-user-token changed — storefront cache dropped")
                AppleMusicOfficialTtmlLyricsRepository.invalidateAccountCache()
            }
        }
    }

    /// 开关下方那段说明：开关关闭时只讲"这是什么"，打开后再追加"怎么拿令牌"。
    private var appleMusicOfficialTtmlFooter: String {
        var text = "apple_music_official_ttml_description".localized

        if experimentsOptions.appleMusicOfficialTtml {
            text.append("\n\n")
            text.append("apple_music_official_ttml_token_hint".localized)
        }

        return text
    }

    /// 开关下方那段说明：关着时只讲"这是什么 + 入口在哪"，打开后再补一句"两档样式怎么选"。
    ///
    /// ⚠️ 必须写明"入口在 iOS 27 听歌页底排左边那颗气泡"：舞台的入口只挂在
    ///   `NowPlayingIOS27+Footer` 上（旧布局那一套没动），用户没开那一版布局时
    ///   会觉得"开了没反应"。
    private var lyricsStageFooter: String {
        var text = "lyrics_stage_description".localized

        if experimentsOptions.lyricsStage {
            text.append("\n\n")
            text.append("lyrics_stage_style_hint".localized)
        }

        return text
    }

    /// `media-user-token` 输入框（开关打开时才出现）。
    ///
    /// ⚠️ 它是**账号级凭据**：不内置、不外传，只存在本机的 UserDefaults 里
    /// （见 `AppleMusicTtml+UserDefaults.swift` 开头那段"为什么必须用户自己粘"）。
    @ViewBuilder private func appleMusicTokenField() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("apple_music_official_ttml_token".localized)

            TextField(
                "apple_music_official_ttml_token_placeholder".localized,
                text: $appleMusicMediaUserToken
            )
            .foregroundColor(.gray)
            .autocapitalization(.none)
            .disableAutocorrection(true)
            .lineLimit(1)

            if !UserDefaults.hasAppleMusicMediaUserToken {
                Label(
                    "apple_music_official_ttml_token_missing_inline".localized,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
