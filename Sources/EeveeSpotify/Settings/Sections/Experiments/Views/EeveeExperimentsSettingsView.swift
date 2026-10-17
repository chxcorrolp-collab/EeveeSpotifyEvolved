import SwiftUI
import UIKit

/// 「实验」页：只放**尚未真机定性**的功能（一律默认关，用户主动开）。
///
/// 准入三条（2026-10-17 与用户对齐）：
///   ① 还没在真机上验证过效果；
///   ② 依赖会变的外部契约（服务端 flag / 私有类 / 第三方 App）；
///   ③ 改完要重启或清缓存才生效。
/// 三条里占一条才进来。**行为早已定性、只是"依赖外部"的开关不属于这里** ——
/// 「分享到 LiveContainer」因此于 2026-10-17 搬到「杂项设定」（见 `EeveeMiscellaneousSettingsView`）。
struct EeveeExperimentsSettingsView: View {
    @State var experimentsOptions = UserDefaults.experimentsOptions

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
    }
}
