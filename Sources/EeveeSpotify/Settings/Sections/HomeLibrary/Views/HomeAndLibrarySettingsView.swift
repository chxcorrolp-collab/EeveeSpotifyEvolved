import SwiftUI
import UIKit

/// 「首页与音乐库」—— 主页头部、音乐库观感、首页小卡片。
///
/// ── ★ 2026-10-17 重排（用户：「我一直不理解 首页与音乐库 的为什么是那样设置的」）────────
///
/// 这一页原来是**三个抽屉塞进一页**：
///   ① 首页头部三态（原样 / Apple Music 式 / 隐藏）；
///   ② 「音乐库」与「主页」两套 AM 化 —— 同一件事的**两次实现**（键、实现文件、生效页面
///      全不同），2026-10-14 被并进同一个 Section；
///   ③ 听歌页/传输条上的「设备按钮」「加号」—— 跟首页毫无关系，只是当初和
///      「隐藏首页顶部条」一起加进来的（当时 l10n 里只有那一个分节标题可用）。
///
/// 现在：
///   · 第 ③ 件**搬走了** → 「歌曲播放页」的 `declutter_description` 那一节
///     （同一套 `DeclutterChrome.reconcileNow()` 机制，那两颗键的 ownedKeys 也跟着走了）；
///   · 第 ② 件**拆回两节**：`home_section`（主页头部三态）与 `library_section`（音乐库）。
///     这两个键本来就在词典里（一个被合并成孤儿、一个只剩当段标签用），
///     所以这一拆**没有造任何新键**；
///   · 三态选择器不再借 `declutter_home_player_section`（"首页与播放器"）当标签 ——
///     那个键与它的 footer 已从词典删掉；现在段标签自己说明在选什么，
///     只有无障碍标签还指向 `home_section`；
///   · 原来跟在三态后面那颗「Apple Music 式主页」Toggle **删掉**了（见 body 里的说明：
///     它与"AM 式"那一段写同一个键，覆盖不到多出来的任何状态）；
///   · 「效果可能不明显。」×2 两句 footer 一并删除（其中一句原来还被当成正文塞在节尾）。
///
/// ── 本页开关之间的关系（2026-10-14 复核，2026-10-17 结构改动后仍成立）────────────────
///
/// ① `hide_home_header`（三态的"隐藏"段）打开后**接管整个页头**，`home_large_title`
///    随即让位 —— `Appearance/HomeHeaderAppearance.x.swift` 的 `apply` 里那句
///    `guard !UserDefaults.hideHomeHeader` 直接 `return`（只在日志里说一次 `standing down`），
///    共享的存储一个字节都不写。⚠️ 还有个真机复核过的细节：那句 `return` 在
///    `layout(...)` 里的 `clearScrim(...)` **之前** ⇒ **灰纱也不收**；而灰纱不在
///    `DeclutterChrome` 藏的那颗 `HomeHeaderView` 里（它是**同级兄弟**，见
///    `DeclutterChrome.x.swift:81-92` 与 `HomeHeaderAppearance.x.swift` 文件头）
///    ⇒ "顶部条没了、灰纱还在"是当前的实现结果，不是 bug。
///
/// ② 两颗 AM 化**各管一页、互不影响**（都默认开）：`home_large_title` 在
///    `HomeHeaderAppearance.x.swift`（主页，头部随滚动动 ⇒ 挂在页面 VC 上），
///    `library_large_title` 在 `LibraryAppearance.x.swift`（音乐库，头部静止 + 0.5s 复查节拍）。
///
/// ③ `library_large_title` **一颗管七件事**（闸门只有 `LibraryAppearance.isEnabled` 一处，
///    另外两片直接读它：`LibraryRowsAppearance.x.swift:51-52`、`LibrarySearchAppearance.x.swift:34-35`）：
///     ① 标题字号 ×1.25、上限 40pt（`LibraryAppearance.x.swift:224-228`）；
///     ② 标题挪到左沿 16pt（用 transform 位移，**不改** `textAlignment`）`:305-310`；
///     ③ 头像 + recents/search/plus 三颗按钮一起贴右沿打包、头像最右 `:312-329`；
///     ④ 顶部灰纱 alpha 归零（只在自己那一拍写、不进 0.5s 节拍）`:367-383`；
///     ⑤ **右侧那条"快速滚动条"整条从父视图里拿走**（不是 alpha=0；连"可拖动"一起关掉，
///        关开关时按原位放回）`:423-455`；
///     ⑥ 列表行/网格封面连续圆角 + 行内发丝线（`LibraryRowsAppearance.x.swift:93-100`）；
///     ⑦ 库内搜索的搜索框与 Cancel 变胶囊 + 同一份灰纱判据（`LibrarySearchAppearance.x.swift:59-77`）。
///    ⇒ **不建议拆成多颗**：七件事共享同一条 0.5s 节拍与两条互不相同的还原路径，
///      拆开就要各自建立"关掉时精确写回"的状态机（2026-10-14 已勘察、主动推迟）。
///
/// ④ `home_tile_tint` 的"要不要重启"见最后一节上面的那段注释（**启动时为"关"的那种情况，
///    关→开必须重启**；默认值是开，所以多数人察觉不到这一条）。
enum HomeHeaderStyle: Hashable {
    /// Spotify 原样（两颗都关）。
    case system
    /// 我们自绘的 AM 式页头（`homeLargeTitle == true`）。
    case amStyle
    /// 藏掉整个页头（`hideHomeHeader == true`）。
    case hidden
}

struct HomeAndLibrarySettingsView: View {

    @State private var shadow = Shadow()

    private struct Shadow {
        var hideHomeHeader = UserDefaults.hideHomeHeader
        var libraryLargeTitle = UserDefaults.libraryLargeTitle
        var homeLargeTitle = UserDefaults.homeLargeTitle
        var homeTileTint = UserDefaults.homeTileTint

        /// 首页头部三态 —— **派生值**，不落盘（真值仍是上面两个键）。
        ///
        /// ⚠️ 这是本页唯一一处"两个键映到一个 UI 控件"的地方，所以它**不参与
        /// `settingsShadowBinding`**（那套是"一进一出"的）：读走 `homeHeaderStyle`、
        /// 写走下面 `homeHeaderStyleBinding` 的 set。
        var homeHeaderStyle: HomeHeaderStyle {
            if hideHomeHeader { return .hidden }
            return homeLargeTitle ? .amStyle : .system
        }
    }

    /// 三态选择器的绑定：读 = 派生态；写 = **落到两个既有键**上（见 `Shadow.homeHeaderStyle` 的说明）。
    ///
    /// ⚠️ 落盘与副作用**必须写在这里**，不能写成 `.onChange(of: shadow.homeHeaderStyle)` ——
    ///    那是**派生**属性（`hideHomeHeader` / `homeLargeTitle` 算出来的），`onChange` 观察不到它。
    ///
    /// ⚠️ 为什么 `shadow` 与 `UserDefaults` 都要写：`Picker` 的段选中态由 SwiftUI 按 `selection`
    ///    求值决定，而"写 UserDefaults 不会让 SwiftUI 失效重绘"是本仓库踩过的坑
    ///    （见 `SettingsShadowBinding.swift` 文件头）—— 所以两者都要写。
    private var homeHeaderStyleBinding: Binding<HomeHeaderStyle> {
        Binding(
            get: { shadow.homeHeaderStyle },
            set: { style in
                switch style {
                case .system:
                    shadow.homeLargeTitle = false
                    shadow.hideHomeHeader = false
                    UserDefaults.homeLargeTitle = false
                    UserDefaults.hideHomeHeader = false
                case .amStyle:
                    shadow.homeLargeTitle = true
                    shadow.hideHomeHeader = false
                    UserDefaults.homeLargeTitle = true
                    UserDefaults.hideHomeHeader = false
                case .hidden:
                    shadow.hideHomeHeader = true
                    UserDefaults.hideHomeHeader = true
                    // `homeLargeTitle` 的值在"隐藏"态下**被忽略**（见文件头），刻意不动它 ——
                    // 用户从"隐藏"切回"AM 式/原样"时再由上面两个分支写准。
                }

                // 藏过的 chrome 不一定再有 layout 回合 ⇒ 当场复查一遍（见 `DeclutterChrome`）。
                DeclutterChrome.reconcileNow()
                // ⚠️ AM 式那半边**不在这里补推**：它的入口是 `HomeHeaderAppearance.apply(to:)`，
                //    需要一个**页面对象**，而设置页手上没有（硬凑会写错页面）。它靠首页自己的
                //    `viewDidLayoutSubviews` 那一拍落地 —— 关掉设置页回到首页时必然发生。
                //    "隐藏 ↔ AM 式"因此可能有一拍延迟，这是刻意的：宁可晚半拍，不猜页面。
            }
        )
    }

    var body: some View {
        List {
            // ── 主页头部：三态（原样 / Apple Music 式 / 隐藏）─────────────────────────
            //
            // ★ 2026-10-14（用户拍板）：原来 `hide_home_header` 与 `home_large_title` 是两颗
            //   各自独立的 Toggle，同时打开时后者**静默让位**（用户看到两颗都"开着"、实际一颗
            //   不生效，而且灰纱还留着）⇒ 合成一个三态选择。三个状态的键值对应：
            //       · 原样   = `homeLargeTitle == false && hideHomeHeader == false`
            //       · AM 式  = `homeLargeTitle == true  && hideHomeHeader == false`
            //       · 隐藏   = `hideHomeHeader == true`（此时 `homeLargeTitle` 的值**被忽略**）
            //   **两个键都保留**（存储语义不变、老值继续有效、不写迁移）。
            //   ⚠️ 第四象限（`homeLargeTitle == false && hideHomeHeader == true`）是可能存在的
            //      历史值 —— 它归入「隐藏」；用户一旦再选「原样」/「AM 式」，`hideHomeHeader`
            //      就会被写回 false，从此三态与键一一对应。
            //
            // ⚠️ 本节**刻意没有 header**：三个段标签里第一个就是 `home_section`（"主页"），
            //    本节再加一个"主页"标题会让同一个字符串在一屏里出现两次。
            // ⚠️ 选择器**没有可见标签**：原来那行是借 `declutter_home_player_section`
            //    （"首页与播放器"）的，词不达意，那个键已从词典删除；段标签自己说明在选什么，
            //    无障碍标签仍指向 `home_section`（只给 VoiceOver，不占屏）。
            // ⛔ 原来还跟来一颗「Apple Music 式主页」Toggle（2026-10-14 合并两节时留下的）。
            //    ★ 2026-10-17 **删掉那颗**：它与"AM 式"这一段**写的是同一个键**
            //    （`homeLargeTitle`），三态选择器已经把它能表达的两态（原样 / AM 式）全覆盖，
            //    隐藏态下它写进去的值又会被"切回"那一刻覆盖 ⇒ 留着只是同一句话在一屏出现两次，
            //    还多出一种"开着但不生效"的状态。删掉后本节只剩一件事：选头部样式。
            Section {
                Picker(selection: homeHeaderStyleBinding) {
                    Text("home_section".localized).tag(HomeHeaderStyle.system)
                    Text("home_large_title".localized).tag(HomeHeaderStyle.amStyle)
                    Text("hide_home_header".localized).tag(HomeHeaderStyle.hidden)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text("home_section".localized))
                // ⚠️ 这里**故意没有 `.onChange`**：落盘与副作用都写在 `homeHeaderStyleBinding` 的
                //    set 里。写成 `.onChange(of: shadow.homeHeaderStyle)` 是无效的 ——
                //    那是**派生**属性（由 `hideHomeHeader` / `homeLargeTitle` 算出来），观察不到。
            }

            // ── 音乐库 ──────────────────────────────────────────────────────────────
            //
            // 音乐库：**改原生**的第一批（不是加壳）—— 大标题左对齐 + 收掉顶部渐隐灰纱。
            // 这一颗一颗管七件事，清单与"为什么不拆"写在文件头 ③。
            Section(header: Text("library_section".localized)) {
                Toggle(
                    "library_large_title".localized,
                    isOn: settingsShadowBinding($shadow.libraryLargeTitle) { value in
                        UserDefaults.libraryLargeTitle = value
                    }
                )
            }

            // ── 首页小卡片 ──────────────────────────────────────────────────────────
            // ★ 2026-10-13（用户看 pw 的截图：「那几个小模块是经过处理的（喜欢的歌曲那几个小方框），
            //   底部的颜色会跟着封面的样子跑」）：把那排小卡片的底色改成**从它自己的封面取色**
            //   （普通 Spotify 那边这几格是一片灰）。出处 spoti.pw **v0.21.1** 的
            //   `Redesigned/Home/HomeTiles.m`（GPL-3.0）："a dark surface tinted faintly towards
            //   the cover's dominant colour"。做法、认形状的判据与"为什么这次是靠日志而不是转储"
            //   见 `Appearance/HomeShortcutTiles.x.swift` 文件头。
            // ⚠️ 生效时机（2026-10-14 复核）：
            //   · **关 → 开：要看"启动时它是开着还是关着"。** 钩子是**启动时按当时的值**决定装不装的
            //     —— `Tweak.x.swift:447` 调 `activateHomeShortcutTiles()`，里面第一句就是
            //     `guard HomeTileTint.launchEnabled else { return }`，而 `HomeShortcutTilesGroup()
            //     .activate()` 只在那一次跑。⇒ 启动时是**关**的：这一场整个 hook group 都不在，
            //     之后再怎么翻都收不到那些布局回合，**必须重启**；启动时是**开**的（这颗默认就是开）：
            //     后来关掉再开回来**不用**重启 —— 钩子一直在。
            //   · **开 → 关：钩子还在，但每一拍都提前返回**（三处 `guard isEnabled`）⇒ 新出现/被复用的
            //     卡片不再上色、封面也不再内缩。**已经上过色的那几格不会当场还原** —— 这条路没有
            //     restore，要等卡片自己重建。
            //   ⇒ ★ 2026-10-14（用户批准：「改」）：下面那行重启提示因此只命中"启动时是关的、
            //     现在被打开了"这一种（`HomeTileTint.launchEnabled` 是真正的启动快照）。
            //   ⇒ 用户可见的 footer 一个字都没加（`home_tile_tint_description` 仍是原 l10n）。
            Section(
                header: Text("home_tile_tint_section".localized),
                footer: Text("home_tile_tint_description".localized)
            ) {
                Toggle(
                    "home_tile_tint".localized,
                    isOn: settingsShadowBinding($shadow.homeTileTint) { value in
                        UserDefaults.homeTileTint = value
                    }
                )
            }

            // 「立即重启」：只在**当前值 ≠ 启动快照**时出现 —— 也就是"启动时是关的、现在打开了"
            // 那一种（见上面那段）。默认开的人永远不会看到这一行。
            RestartSection(visible: UserDefaults.homeTileTint != HomeTileTint.launchEnabled)

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    shadow = Shadow()
                    // 大标题那两颗是"下一次布局生效"（原页也没有当场落地），
                    // 需要当场复查的只有 `DeclutterChrome` 管的那几颗（含三态选择器里的"隐藏"）。
                    //
                    // ⚠️ 本页有 `RestartSection`（`home_tile_tint` 那颗），但它不进 `ownedKeys`、
                    //    也不改「重置本页」的作用面 —— 它只是读一下 `HomeTileTint.launchEnabled`
                    //    与当前值。（已知边角：`home_tile_tint` 被重置后回到默认的**开**，
                    //    若这一场启动时它是关的，那么 `homeTileTint != launchEnabled` 成立
                    //    ⇒ 重启提示会现身，这正是我们想要的提示。）
                    DeclutterChrome.reconcileNow()
                }
            )
        }
        .listStyle(InsetGroupedListStyle())
        .onAppear { shadow = Shadow() }
    }

    /// 本页「重置本页」的作用范围。
    ///
    /// ★ 2026-10-17：`hideConnectButton` / `hideAddToButton` 已随开关一起搬到
    /// 「歌曲播放页」（那边自己拥有它们），不在本页白名单里 —— 否则「重置本页」
    /// 会改掉另一页的设置。
    private static let ownedKeys = [
        "hideHomeHeader",
        "libraryLargeTitle",
        "homeLargeTitle",
        "homeTileTint",
    ]
}
