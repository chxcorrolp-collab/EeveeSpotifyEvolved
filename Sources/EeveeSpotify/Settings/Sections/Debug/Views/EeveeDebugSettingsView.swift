import SwiftUI

/// 「调试」页：排查/验证型开关 + 只读转储工具（见 `EeveeDebugSettingsViewModel` 的说明）。
///
/// 现在的几行分三类：
///   · **A/B 开关**（补充模块5 / 歌词入口开关）—— 会改行为、待定性，验完就写死 + 删 key + 删 l10n；
///   · **只读转储**（视图树 / 某个类 / customize 响应体）—— 只往日志里写，不改任何行为；
///   · **两个长期住户**：导出前脱敏（2026-10-17 从主设置页的「Debug」区搬来，默认开）
///     与歌词占位符彩蛋 —— 将来清理这一页时**别顺手删这两节**。
///
/// 所有 l10n 键与 UserDefaults 键**都沿用旧的**（`ngzhwm_inject_lyrics_card_element` /
/// `redact_shared_log` 等）⇒ 没有新增翻译，设备上已设的值原样保留。
struct EeveeDebugSettingsView: View {
    @StateObject var viewModel = EeveeDebugSettingsViewModel()

    /// 「转储某个类」那个输入框的内容（本页唯一一处不需要 view model 的状态，
    /// 照 `dumpCustomizeBodySection` 的先例直接用 `@State`）。
    @State private var dumpClassName = ""

    var body: some View {
        List {
            // 「补充模块5」：往元素列表里补 `5`。
            // 没有 footer —— 用途是判定"404 曲目上那张卡是不是这个元素渲出来的"。
            injectLyricsCardElementSection()

            // 「歌词入口开关」：把服务端那条 `lyrics_entry_point_enabled` 钉成 true。
            lyricsEntryPointFlagSection()

            // 「转储视图树」：给还没写的界面 hook 铺路（AMOLED / 隐藏区块 / 手势）。
            dumpViewTreeSection()

            // 「转储某个类的方法/ivar」：与上面同一目的、答的是另一半问题
            //   —— 视图树给"谁在谁里面"，这个给"这个类里有什么"。
            dumpClassSection()

            // 「转储 customize 响应体」：**2026-10-13 用户要求从主设置页搬过来**，位置就是这里
            //   —— 「转储视图树」的**下面**、「替换寻找歌词时的占位符」的**上面**。
            //   它只为一件事存在：换掉随包的 customize 种子快照（见 `SpotifyResponsePatcher`）。
            dumpCustomizeBodySection()

            // 「分享日志前脱敏」：**2026-10-17 用户要求从主设置页的「Debug」区搬进这里**。
            //   三个"转储"是把东西写进日志，这一条是"把日志发出去之前先假名化" —— 同一条线的最后一环。
            redactSharedLogSection()

            // 「替换寻找歌词时的占位符」：**彩蛋**（用户 2026-10-12 点名要的），放在上面那一节下面。
            lyricsSearchPlaceholderEasterEggSection()
        }
                // ★ 2026-10-12：inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .animation(.default, value: viewModel.animationValues)
    }

    /// 「补充模块5」（往元素列表里补 `5` = 保留官方布局时那个歌词预览模块）。
    @ViewBuilder private func injectLyricsCardElementSection() -> some View {
        Section {
            Toggle(
                "ngzhwm_inject_lyrics_card_element".localized,
                isOn: $viewModel.injectLyricsCardElement
            )
        }
    }

    /// 「把服务端那条 `lyrics_entry_point_enabled` 钉成 true」。
    @ViewBuilder private func lyricsEntryPointFlagSection() -> some View {
        Section {
            Toggle(
                "ngzhwm_lyrics_entry_point_flag".localized,
                isOn: $viewModel.lyricsEntryPointFlag
            )
        }
    }

    /// 「转储视图树」：把当前屏幕的视图结构每 2s 写一行进调试日志。
    ///
    /// ⚠️ 这也是**临时工具**（本页的定位就是"验证完就删"）：类名拿到之后就去写真正的
    /// hook，那时这一节连同 key 一起删。三条纪律见 `ViewTreeDumper` 的说明。
    @ViewBuilder private func dumpViewTreeSection() -> some View {
        Section(footer: Text("dump_view_tree_description".localized)) {
            Toggle(
                "dump_view_tree".localized,
                isOn: $viewModel.dumpViewTree
            )
        }
    }

    /// 「转储某个类」—— 把类名 + 方法表 + ivar 表写进调试日志（见 `ClassDumper`）。
    ///
    /// 与上面那节的分工：`ViewTreeDumper` 答"谁在谁里面"，这里答"这个类里有什么"。
    /// 界面工作反复卡在后者上（AMOLED 的导航栏、隐藏区块、播放器手势都卡过）。
    ///
    /// ⚠️ 只读：runtime 反射**枚举**而已，找到的方法一个都不会被调用 ——
    /// 猜 `value(forKey:)` 在键不存在时会抛不可捕获的异常、把 Spotify 直接弄崩。
    /// 同样属于"验证完就删"的临时工具（本页定位）。
    @ViewBuilder private func dumpClassSection() -> some View {
        Section(footer: Text("dump_class_description".localized)) {
            TextField("dump_class_placeholder".localized, text: $dumpClassName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Button("dump_class_action".localized) {
                ClassDumper.dump(name: dumpClassName)
            }
            .disabled(dumpClassName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// 「转储 customize 响应体」—— **2026-10-13 用户要求从主设置页搬进「调试」**，
    /// 位置：**「转储视图树」下面、「替换寻找歌词时的占位符」上面**。
    ///
    /// 背景（原样保留）：flag 改写依赖 customize 的响应体，而 304 无 body 时只能回放种子
    /// （`SpotifyResponsePatcher.seedCustomizeDataIfNeeded`，用的是 9.1.76 时期转存的 `.bnk`）。
    /// 打开它 + 用一次「覆盖配置」（清缓存、逼服务器回 200）⇒ 下次启动就能从日志里取到**你这版**的真 body。
    ///
    /// ⚠️ 它**不在** `EeveeDebugSettingsViewModel` 里（本页另外两节都在那儿）：只是搬位置，
    ///    没有新的状态要记，所以照 `EeveeExtrasSettingsView` 的写法直接用 `Binding` 读写 ——
    ///    免得为一次搬家把 view model 也改一遍。l10n 键与 UserDefaults 键都没变。
    @ViewBuilder private func dumpCustomizeBodySection() -> some View {
        Section(footer: Text("dump_customize_body_description".localized)) {
            Toggle(
                "dump_customize_body".localized,
                isOn: Binding<Bool>(
                    get: { UserDefaults.dumpCustomizeBody },
                    set: { UserDefaults.dumpCustomizeBody = $0 }
                )
            )
        }
    }

    /// 「分享日志前脱敏」——**2026-10-17 用户要求从主设置页的「Debug」区搬进「调试」页**。
    ///
    /// 默认**开**（`UserDefaults.redactSharedLog` 的 getter：键不存在 ⇒ true）：
    /// 导出这个动作 99% 是为了把日志发给别人，而日志主体就是"你听了哪些歌"。
    ///
    /// 只影响**导出**的那一份（`DebugLogSanitizer.sharedLogFile(from:redact:)`，出口在
    /// `EeveeSettingsView` 的导出按钮那一节）：写入口的凭证/设备标识脱敏没有开关、也不受它控制。
    /// 脱敏版生成失败时导出会**直接报错**，绝不回退明文（fail-closed）。
    ///
    /// ⚠️ 这一节与上面几节不同：不是"验证完就删"的临时件，也不是彩蛋，而是**导出的隐私默认值**。
    ///    它不在 `EeveeDebugSettingsViewModel` 里（沿用 `dumpCustomizeBodySection` 的先例，
    ///    用 `Binding` 直接读写）—— 没有新状态要记，l10n 键与 UserDefaults 键都没变。
    @ViewBuilder private func redactSharedLogSection() -> some View {
        Section(footer: Text("redact_shared_log_description".localized)) {
            Toggle(
                "redact_shared_log".localized,
                isOn: Binding<Bool>(
                    get: { UserDefaults.redactSharedLog },
                    set: { UserDefaults.redactSharedLog = $0 }
                )
            )
        }
    }

    /// 「替换寻找歌词时的占位符」——用户 2026-10-12 点名要的**彩蛋**。**默认关**。
    ///
    /// 只做一件事：还在取词的时候，那句「正在查找歌词…」写成「少女祈祷中…」
    /// （改的只有 `NowPlayingLyricsPlate.noticeText()` 里"还在查"那一档，全仓库就那一处）。
    ///
    /// ★ 2026-10-13（用户）：「调试页面的那个『替换寻找歌词时的占位符』的那行介绍删掉」
    ///   ⇒ 那一行 `Section(footer:)` 的说明（`lyrics_search_placeholder_easter_egg_description`）
    ///   **已删除**（en/zh-CN 两个键一起删 —— 过期文案不留）。开关本身**保留**（那是个长期彩蛋）。
    ///   于是这一节现在与上面「转储视图树」那节一样，只有一行开关、没有 footer。
    ///
    /// ⚠️ 本页的定位是"排查工具、验证完就删"，这一节是**例外**（用户要求放这里，它是个长期彩蛋）：
    ///    将来清理这一页时**别顺手删它**。
    @ViewBuilder private func lyricsSearchPlaceholderEasterEggSection() -> some View {
        Section {
            Toggle(
                "lyrics_search_placeholder_easter_egg".localized,
                isOn: $viewModel.lyricsSearchPlaceholderEasterEgg
            )
        }
    }
}
