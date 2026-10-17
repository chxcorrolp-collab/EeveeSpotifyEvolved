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
/// ⚠️ **"默认关"有一个已记录的例外**：「NetEase 交叉验证」（2026-10-17）。
///    它是**给非中国大陆 IP 的用户兜错歌**的，而"要不要它"取决于出口 IP 而不是
///    用户看不看这一页 —— 默认关等于让唯一需要它的人永远发现不了它。
///    默认值改成"地区或时区任一指向非中国大陆就默认开"，理由与代价权衡见
///    `ExperimentsOptions.defaultNeteaseCrossValidation` 上方那段。
///    其余实验仍然一律默认关，这条例外不外扩。
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
            // （「分享到 LiveContainer」2026-10-17 搬到「杂项设定」。理由见文件头的准入三条：
            //   它的行为早就定死了 —— 链接打不开就转给 LC、失败就把 URL 复制到剪贴板；
            //   真正"没定性"的是 LC 那一侧的私有深链，不是这个开关。）

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

            Section(footer: Text("petit_fallback_netease_description".localized)) {
                Toggle(
                    "petit_fallback_netease".localized,
                    isOn: $experimentsOptions.petitLyricsNetEaseFallback
                )
            }

            Section(footer: Text("amll_fuzzy_search_description".localized)) {
                Toggle(
                    "amll_fuzzy_search".localized,
                    isOn: $experimentsOptions.amllFuzzySearch
                )
            }

            // ★ 2026-10-17：NetEase 交叉验证。
            //   开关本身只改一个 Bool —— 判据与执行全在
            //   `NetEaseCrossValidation.swift` / `NeteaseCrossValidationRunner.swift`，
            //   接在 `NeteaseLyricsRepository.getLyrics` 的选歌那一步上。
            //   footer 里那句"会增加歌曲请求用时"是用户要求写进去的，也是真的：
            //   只有**低置信度候选**才会去问裁判源（高置信度一律零开销）。
            Section(footer: Text("netease_cross_validation_description".localized)) {
                Toggle(
                    "netease_cross_validation".localized,
                    isOn: $experimentsOptions.neteaseCrossValidation
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
