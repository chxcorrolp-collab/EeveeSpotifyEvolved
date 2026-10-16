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
            //    这次按 **9.1.88** 的真实形态重做：**不 hook 任何类**，改成强制三条服务端 flag
            //    （`ExperimentFlagReplacements`），与用户自己的「Flag 覆盖」共用同一条管线。
            //    ⇒ 副作用：和 flag 一样在**启动改写配置**时才生效，改完要重启 Spotify。
            Section(footer: Text("show_instagram_destination_description".localized)) {
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
        }

                // ★ 2026-10-12：inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .animation(.default, value: experimentsOptions)
    }
}
