import SwiftUI
import UIKit

struct EeveeExperimentsSettingsView: View {
    @State var experimentsOptions = UserDefaults.experimentsOptions

    var body: some View {
        List {
            Section(footer: Text("livecontainer_sharing_description".localized)) {
                Toggle(
                    "livecontainer_sharing".localized,
                    isOn: $experimentsOptions.liveContainerSharing
                )
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
