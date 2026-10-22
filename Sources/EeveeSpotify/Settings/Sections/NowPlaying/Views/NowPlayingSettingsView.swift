import SwiftUI
import UIKit

/// 「听歌页」——听歌页（Now Playing）上所有属于**我们自己的**开关。
///
/// ## 为什么单独一页（2026-10-13 用户：「设置页面有点乱了」，拍板方案 B）
///
/// 这些开关原来全塞在「扩展」那一页里（`EeveeExtrasSettingsView`，627 行、24 个开关 +
/// 8 个子页入口），而「扩展」在根页只占一行 ⇒ 想找"听歌页那一屏"要进两层、还要在
/// 一页里滚很久。现在按**页面**拆开：听歌页 / 标签栏与迷你条 / 首页与音乐库 /
/// 歌单与专辑页，四个都在根页上一步可达。
///
/// ## ★★ 2026-10-22（用户）：五件结构改动整合成一颗总开关
///
/// 用户原话：
/// > 整合以下功能：整页取色底，隐藏Spotify歌曲播放页模块/隐藏Spotify官方单行歌词/
/// > 隐藏两个胶囊，歌词进播放器。上述功能整合，名字为：修改Spotify听歌页布局，
/// > 放在歌曲播放页的最上面（默认开启）。
/// > 然后：展示音量条，展示（自画）单行歌词，展示罗马化歌词，展示歌词翻译，
/// > 未播放歌词行模糊化，控制键替换为本地 这些功能作为 修改Spotify听歌页布局 的二级菜单
/// > （除了展示音量条这个功能，其他的默认开启）。然后，展示音量条下面写一个：
/// > 该功能测试中，不推荐开启。
///
/// 于是本页三节：
///   · `now_playing_section` —— **一颗总开关**（五件结构改动，默认开）+
///     它下面那行**二级菜单**（音量条 / 单行歌词 / 罗马化 / 译文 / 未播放行模糊 / 控制键字形）；
///   · `declutter_description` —— 按类名藏 Spotify 自己的 chrome（迷你条、
///     以及 ★ 2026-10-17 从「首页与音乐库」搬来的**传输条两颗按钮**：设备/输出切换、加号）。
///     ⚠️ 原来这一节还有「隐藏官方单行歌词」「隐藏两颗胶囊」两颗 —— 2026-10-22 起
///     它们进了上面的总开关，不再单列。
///   · `player_cards_section` —— 听歌页**卡片类**清爽（一张卡一个键 + 一颗总开关）。
///
/// ⚠️ 罗马化与译文那两颗读的是**歌词页那批键**（`NgzhwmSettingsViewModel` 的
/// `anyRomanizationEnabled` / `isNeteaseHideTranslationEnabled`），两面永远同步。
/// 因此它们**不在本页的「重置本页」里** —— 重置本页不该偷偷改掉歌词页的设置。
struct NowPlayingSettingsView: View {

    /// 本页所有开关的**影子值**。为什么需要、怎么用见 `settingsShadowBinding` 的文件头。
    @State private var shadow = Shadow()

    private struct Shadow {
        /// ★ 2026-10-22：「修改Spotify听歌页布局」总开关。
        var nowPlayingLayout = UserDefaults.nowPlayingLayout
        // ── 总开关的二级菜单（这六颗只在总开关打开时显示） ──
        var nowPlayingVolume = UserDefaults.nowPlayingVolume
        var nowPlayingSingleLyric = UserDefaults.nowPlayingSingleLyric
        var nowPlayingBlurUnplayedLyrics = UserDefaults.nowPlayingBlurUnplayedLyrics
        var nowPlayingControlGlyphs = UserDefaults.nowPlayingControlGlyphs
        // 与「设置 → 歌词」那两颗**同一批键**（不是新造的一套）。
        var showRomanizedLyrics = NgzhwmSettingsViewModel.anyRomanizationEnabled
        var showLyricsTranslation = !NgzhwmSettingsViewModel.isNeteaseHideTranslationEnabled
        // ── 清爽：不属于总开关，各占一行 ──
        var hideMiniPlayerBar = UserDefaults.hideMiniPlayerBar
        /// ★ 2026-10-17 从「首页与音乐库」搬来（传输条上那两颗按钮，见 declutter 那一节）。
        var hideConnectButton = UserDefaults.hideConnectButton
        var hideAddToButton = UserDefaults.hideAddToButton
        /// 听歌页卡片那批（总开关 + 一张卡一个键）。用一个字典装：加卡片不用改这里。
        var hidePlayerCards = PlayerCardsDeclutter.masterHidden
        var playerCards: [PlayerCard: Bool] = PlayerCardsDeclutter.snapshot()
    }

    /// 二级菜单的缩进（只缩文字，右侧那枚切换器仍然贴着行尾）。
    private static let submenuIndent: CGFloat = 18

    var body: some View {
        List {
            Section(
                header: Text("now_playing_section".localized),
                // 「关掉即还原」和"官方单行歌词要重启"这两句放在节脚：它们说的是整颗总开关的
                // 行为，挂在标题下面会把第一行撑得过高（五条名字已经够长了）。
                footer: Text("now_playing_layout_footer".localized)
            ) {
                // ★★ 2026-10-22（用户）：总开关在**本页最上面、默认开启**。
                //
                // 它把五件结构改动收成一颗（`UserDefaults.nowPlayingLayout`）：
                // 整页取色底 / 隐藏Spotify歌曲播放页模块 / 隐藏Spotify官方单行歌词 /
                // 隐藏两颗胶囊 / 歌词进播放器。拨它时会把那五颗旧键一起写成同一个值
                // （`applyLayoutChange`），落地代码仍然读各自的键 ⇒
                // 备份 / 导入 / 日志里看到的值与屏幕上的总开关永远一致。
                //
                // 第二行小字由那五颗的**现有译名**拼出来（见 `integratedFeaturesText`）：
                // 不再维护第二份文案，也不会出现"总开关说 A、里面写 B"。
                Toggle(
                    isOn: settingsShadowBinding($shadow.nowPlayingLayout) { value in
                        applyLayoutChange(value)
                    }
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("now_playing_layout".localized)
                        Text(integratedFeaturesText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // 二级菜单：只改各自的键；总开关关着时整段收起
                // （音量条与控制键的 `isEnabled` 里还各带一道总开关的门，见两处注释）。
                if shadow.nowPlayingLayout {
                    // 底部音量条：kumone 播放页下半屏的那一条（Apple Music 没有）。
                    // 落在**我们自己的透明覆盖层**上（`NowPlayingPageOverlay`），不碰 Spotify 属性。
                    // ★ 2026-10-22：它现在是二级菜单里**唯一默认关**的一项，并在标签下面
                    //   写明「该功能测试中，不推荐开启。」（写法照原来 `now_playing_one_screen`
                    //   的第二行说明）。
                    Toggle(
                        isOn: settingsShadowBinding($shadow.nowPlayingVolume) { value in
                            UserDefaults.nowPlayingVolume = value
                            // 打开就当场落地（页面还挂着的话），关掉当场把那一层拿走。
                            if value {
                                NowPlayingPageOverlay.reapply()
                            } else {
                                NowPlayingPageOverlay.remove(reason: "switch off")
                            }
                        }
                    ) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("now_playing_volume".localized)
                            Text("now_playing_volume_description".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, Self.submenuIndent)
                    }

                    // ★ 2026-10-04（用户建议的第二条）：收起歌词那一屏，在**大封面与歌词键之间**
                    // 画一行居中的当前歌词（"类似 Spotify 的单行歌词，但这行歌词我们自己画"）。
                    // 落点是封面底边与控件条上沿的中点，做法见 `NowPlayingLyricsPlate.applySingleLyric`。
                    Toggle(
                        isOn: settingsShadowBinding($shadow.nowPlayingSingleLyric) { value in
                            UserDefaults.nowPlayingSingleLyric = value
                            // 开/关都当场生效（页面还挂着的话）：关掉就是当场把它收起来。
                            NowPlayingLyricsPlate.reapply()
                        }
                    ) {
                        submenuLabel("now_playing_single_lyric".localized)
                    }

                    // ★ 2026-10-12（用户）：「我觉得有人不会用这个东西，去用正常的去了」——
                    // 所以把歌词那两档也给一颗**总开关**，不用先去歌词页翻逐语言那三颗。
                    // ⚠️ 与 设置 → 歌词 里那几颗**是同一批键**（不是新造的一套）：两面永远同步。
                    //   · 罗马化：日/中/韩三颗里**有一颗开着**就算开；关掉则三颗全关；
                    //   · 译文：与歌词页那颗「隐藏译文」互为反相（键只有一个）。
                    Toggle(
                        isOn: settingsShadowBinding($shadow.showRomanizedLyrics) { value in
                            NgzhwmSettingsViewModel.setAllRomanization(value)
                            // 这个指纹进过宿主的 `isCurrent` ⇒ 下一拍就重建，不用等换歌。
                            NowPlayingLyricsPlate.reapply()
                        }
                    ) {
                        submenuLabel("show_romanized_lyrics".localized)
                    }

                    Toggle(
                        isOn: settingsShadowBinding($shadow.showLyricsTranslation) { value in
                            NgzhwmSettingsViewModel.setHideTranslation(!value)
                            NowPlayingLyricsPlate.reapply()
                        }
                    ) {
                        submenuLabel("show_lyrics_translation".localized)
                    }

                    // ★ 2026-10-12（用户）：「现在是未播放歌词行是模糊不清的，加个功能叫
                    // **未播放歌词行模糊化**。关闭之后，未当前播放歌词行不模糊化」。
                    // 关着 = 非当前行只变淡、不发糊；开着（2026-10-22 起的默认）= 回到改动前那条公式。
                    Toggle(
                        isOn: settingsShadowBinding($shadow.nowPlayingBlurUnplayedLyrics) { value in
                            UserDefaults.nowPlayingBlurUnplayedLyrics = value
                            // 这个开关进了宿主那条指纹 ⇒ 下一拍就重建，不用等换歌。
                            NowPlayingLyricsPlate.reapply()
                        }
                    ) {
                        submenuLabel("now_playing_blur_unplayed_lyrics".localized)
                    }

                    // 控制键换成本地字形：原生按钮留着（动作/状态/无障碍全在），
                    // 只把按钮里的原生图标设成透明、叠一个我们自己的 SF Symbol 字形。
                    // 做法照 pw v0.21.1 的 `PlayerControls.x`（GPL-3.0）：见 `NowPlayingControlsPlate` 文件头。
                    Toggle(
                        isOn: settingsShadowBinding($shadow.nowPlayingControlGlyphs) { value in
                            UserDefaults.nowPlayingControlGlyphs = value
                            if value {
                                NowPlayingControlsPlate.reapply()
                            } else {
                                NowPlayingControlsPlate.restore()
                            }
                        }
                    ) {
                        submenuLabel("now_playing_control_glyphs".localized)
                    }
                }

                // ⛔「禁止回弹」已于 2026-10-03 夜删除（真机日志 41）：
                // 它把列表的 `alwaysBounceVertical` 关掉，用户实测**开了就划不掉播放器**
                // （下拉关闭是经过列表那一层接管的，那个属性是链条的一环）。
                // 列表拖拽时剩下的那点橡皮筋是"一屏"**无法消除**的残留 ——
                // 要碰它就得先有办法自己接管关闭手势。理由写在 `NowPlayingOneScreen` 文件头。
            }

            Section(footer: Text("declutter_description".localized)) {
                // ⚠️ 这一颗属于「迷你播放条那一族」（五颗）：
                //    藏整条 = 本页；玻璃 + 圆封面 = 「标签栏与迷你条」页；
                //    设备按钮 + 加号 = **本页**（★ 2026-10-17 从「首页与音乐库」搬来，
                //    见下面那两颗的说明）。2026-10-14 那轮以"移动 Toggle 会改掉用户找开关的路径"
                //    为由拒绝搬家，2026-10-17 用户点名后**只搬了错位的那两颗**：
                //    它们管的是 `Components.ConnectButtonOutputSwitcher` / `Components.UI.AddToButton`
                //    —— 迷你条与播放器传输条共用的按钮，跟"首页与音乐库"没有任何关系。
                Toggle(
                    "hide_mini_player_bar".localized,
                    isOn: settingsShadowBinding($shadow.hideMiniPlayerBar) { value in
                        UserDefaults.hideMiniPlayerBar = value
                        // 藏过的 chrome 不一定再有 layout 回合 ⇒ 当场复查一遍（见 `DeclutterChrome`）。
                        DeclutterChrome.reconcileNow()
                    }
                )

                // ★ 2026-10-17（用户：「有些功能是不是有些该搬家了，比如前三个有关于外观的设置」）：
                //   这两颗原来摆在「首页与音乐库」页里，但它们藏的是**传输条上的两颗按钮**
                //   （设备/输出切换、加号）—— 迷你播放条和播放器共用同一套控件，跟首页无关。
                //   现在与上面那颗同处一节：同一套 `DeclutterChrome` 判据、同一句 footer 说明。
                //   ⚠️ 中文名「隐藏喜欢按钮」而代码认的是**加号**（`Components.UI.AddToButton`）——
                //   那是 l10n 的值问题（与 `entity_page_am_header_section` 的「（歌单）」同类），
                //   本次不动文案，只把开关搬到它真正管的那一屏对应的设置页。
                Toggle(
                    "hide_connect_button".localized,
                    isOn: settingsShadowBinding($shadow.hideConnectButton) { value in
                        UserDefaults.hideConnectButton = value
                        DeclutterChrome.reconcileNow()
                    }
                )

                Toggle(
                    "hide_add_to_button".localized,
                    isOn: settingsShadowBinding($shadow.hideAddToButton) { value in
                        UserDefaults.hideAddToButton = value
                        DeclutterChrome.reconcileNow()
                    }
                )
            }

            // ★ 2026-10-13（用户拍板）：听歌页**卡片类**清爽。
            //
            // 上游那套 `PlayerHideSettingsView` 一共 18 颗（含 6 颗按钮）；我们只取卡片，
            // 因为"藏掉按钮 = 功能没了"，而其中几颗（分享 / 队列 / Connect / 收藏）用户
            // 2026-10-11 亲手点名在用。判据、marker 表、缓存与"折成 0 高"的做法全写在
            // `Appearance/PlayerDeclutter.x.swift`，这里只摆开关。
            Section(
                header: Text("player_cards_section".localized)
            ) {
                Toggle(
                    "hide_player_cards".localized,
                    isOn: settingsShadowBinding($shadow.hidePlayerCards) { value in
                        PlayerCardsDeclutter.masterHidden = value
                        // 卡片是滚动列表的 cell，改完要让那一列重新问一次尺寸。
                        PlayerCardsDeclutter.refresh()
                    }
                )

                // 总开关开着就不再摆那 10 行（与上游一致）：既是省一屏，也免得两个入口
                // 看起来在互相打架。
                if !shadow.hidePlayerCards {
                    ForEach(PlayerCard.allCases, id: \.self) { card in
                        Toggle(
                            card.labelKey.localized,
                            isOn: settingsShadowBinding(cardBinding(card)) { value in
                                PlayerCardsDeclutter.setHidden(card, value)
                                PlayerCardsDeclutter.refresh()
                            }
                        )
                    }
                }
            }

            // ⛔「双击手势」整节已于 2026-10-04 删除（用户拍板：先删掉，之后再搞）。
            //   它不是"坏了"才删：切歌那条路日志 8/17 证明能用；删是因为 ——
            //   ① 手势挂在页面根视图上，**在播放键上方双击也会跳歌**（本该是播放/暂停）；
            //   ② 最该起作用的全屏歌词那一面默认关、从没验过；
            //   ③ 最近 8 份日志里它一次都没被用过。
            //   重做时的三条要求（控件上不认 / 单击让位 / 另选挂点）见
            //   `Tools/eevee-hookfinder/SESSION_2026-10-03_NIGHT.md` §10。
            //   ⇒ 上游 `Player/PlayerGestures.x.swift` 正是按这三条重写的，移植计划见
            //      本轮讨论（排在编译通过之后的第一件）。

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    // 先重同步影子值（否则开关还显示旧状态），再按**重置后**的总开关落地。
                    shadow = Shadow()
                    applyLayoutChange(UserDefaults.nowPlayingLayout)
                    // 卡片那批：让听歌页那列 cell 重新问一次尺寸（开关值已经删回默认了）。
                    PlayerCardsDeclutter.refresh()
                }
            )
        }
        .listStyle(InsetGroupedListStyle())
        // 每次进页重新同步一次：别处（Flag 页、重置、上一版遗留的存储）改了 UserDefaults 时
        // 影子值不该停在旧值上。
        .onAppear {
            // ★ 2026-10-22：那五颗结构键的唯一合法来源是总开关；备份导入 / 旧版本残留
            //   都可能把它们写歪 ⇒ 进页先按总开关归一，再读影子值（详见 `normalizeNowPlayingLayoutKeys`）。
            //   真的改到了东西（例如刚导入完旧备份）就当场重放一遍，别让听歌页停在旧状态。
            if UserDefaults.normalizeNowPlayingLayoutKeys() > 0 {
                applyLayoutChange(UserDefaults.nowPlayingLayout)
            }
            shadow = Shadow()
        }
    }

    /// 总开关的第二行小字：把它整合进来的那五条**逐项**列出来。
    ///
    /// 为什么用 `%@` 拼、而不是再手写一份文案：这五条的名字本来就在词典里（它们以前各占一行），
    /// 翻译是现成的；以后改其中一条的措辞，这里跟着变，不会出现"总开关说 A、里面写 B"。
    private var integratedFeaturesText: String {
        let names = [
            "now_playing_backdrop".localized,
            "now_playing_one_screen".localized,
            "hide_singalong_line".localized,
            "hide_npv_pills".localized,
            "now_playing_lyrics_in_player".localized,
        ].joined(separator: " · ")
        return "now_playing_layout_description".localizeWithFormat(names)
    }

    /// 二级菜单一行的文本（缩进一级，让人一眼看出它挂在总开关下面）。
    ///
    /// 传进来的是**已经翻好**的文本：调用点写成 `submenuLabel("…".localized)`，
    /// 让 l10n 检查仍能把那些键认成"在用的"（`Tools/l10n_lint.py` 只认
    /// 字面量直接跟 `.localized` 的形状）。
    private func submenuLabel(_ text: String) -> some View {
        Text(text)
            .padding(.leading, Self.submenuIndent)
    }

    /// 总开关的「当场落地 / 还原」。
    ///
    /// 先把那五颗旧键写成同一个值 —— 落地代码读的仍然是各自的键
    /// （取色底 / 一屏 / 隐藏官方单行歌词 / 两颗胶囊 / 歌词进播放器），
    /// 这样备份、导入、日志里的值与屏幕上的总开关永远一致。
    ///
    /// 然后逐个叫"复查/重放"入口：**关掉时它们自己走还原分支** ——
    /// 每个入口的 `apply` 里都有 `guard isEnabled else { restore/remove }`，所以这里
    /// 不需要分两套分支，也不会漏掉"关总开关后屏幕上还留着"的东西。
    /// 音量条与控制键这两颗二级菜单项也在其中：它们的 `isEnabled` 带着总开关的门。
    private func applyLayoutChange(_ enabled: Bool) {
        UserDefaults.nowPlayingLayout = enabled
        UserDefaults.nowPlayingBackdrop = enabled
        UserDefaults.nowPlayingOneScreen = enabled
        UserDefaults.nowPlayingLyricsInPlayer = enabled
        UserDefaults.hideSingalongLine = enabled
        UserDefaults.hideNowPlayingPills = enabled

        refreshNowPlayingBackdrop()
        NowPlayingOneScreen.reapply()
        NowPlayingPageOverlay.reapply()
        NowPlayingControlsPlate.reapply()
        // 歌词进播放器 / 单行歌词：`reapply()` 自己按总开关与子开关重建或回滚。
        NowPlayingLyricsPlate.reapply()
        // 官方单行歌词 + 两颗胶囊：藏过的 chrome 不一定再有 layout 回合 ⇒ 当场复查。
        DeclutterChrome.reconcileNow()
    }

    /// 本页「重置本页」的作用范围。
    ///
    /// ⚠️ 故意**不含** `showRomanizedLyrics` / `showLyricsTranslation` 背后的那几个歌词页键：
    /// 那两颗开关是"同一批键的另一个入口"，在听歌页重置它们等于偷偷改掉歌词页的设置。
    private static let ownedKeys = [
        // ★ 2026-10-22：总开关 + 它写的那五颗旧键（总开关关掉时五颗一起写 false）。
        "nowPlayingLayout",
        "nowPlayingBackdrop",
        "nowPlayingOneScreen",
        "nowPlayingVolume",
        "nowPlayingLyricsInPlayer",
        "nowPlayingSingleLyric",
        "nowPlayingBlurUnplayedLyrics",
        "nowPlayingControlGlyphs",
        "hideMiniPlayerBar",
        "hideSingalongLine",
        "hideNowPlayingPills",
        // ★ 2026-10-17：从「首页与音乐库」搬来的两颗（传输条按钮）—— 它们的"当场落地"
        // 也是 `DeclutterChrome.reconcileNow()`，与上面几颗同一个 afterReset 分支。
        "hideConnectButton",
        "hideAddToButton",
    ]
    // 听歌页卡片那批（11 个键）由 `PlayerCard` / `PlayerCardsDeclutter` 自己拥有：
    // 加一张卡片只改那一处，这里跟着走 —— 本页的「重置本页」因此不会漏键。
    + PlayerCardsDeclutter.allKeys

    /// 某一张卡片的影子值绑定（键在 `PlayerCard.key`，值在 `Shadow.playerCards` 字典里）。
    private func cardBinding(_ card: PlayerCard) -> Binding<Bool> {
        Binding(
            get: { shadow.playerCards[card] ?? false },
            set: { shadow.playerCards[card] = $0 }
        )
    }
}
