import Foundation

/// 「歌词舞台」的排版样式（设置 → 实验 → 歌词舞台）。
///
/// ★ 2026-10-24：这一条线是**参考** Folia（`C:\Users\ngzhwm\Documents\GitHub\folia-major`，
///   AGPL-3.0）的**排版思路与参数**，不是它的代码 —— 依据见
///   `C:\dsh\me\HANDOFF_2026-10-23_EeveeSpotify-ng_LyricsStage-Folia.md` 第 4 节的分级：
///   A 档（Classic 逐词发光 / 三档时序 / Tilt 大字错落）照设计做，C 档（WebGL / Pixi / 3D）
///   一个都不碰，且**不复制任何代码或注释**。
///
/// 两档的分工：
///   · `appleMusic` —— 复用 `AppleMusicLyricsPage`：整屏滚动、逐词点亮、间奏点阵、点行跳转
///     全都在，只换背景（舞台式模糊封面）；它解决的问题是"新版听歌页没有全屏歌词了"。
///   · `tilt` —— 自己排的舞台：一屏 3~4 行、焦点行大字、按距离错落 + 轻微斜排，
///     **不给滚动**（换行由焦点自己推），观感接近 Folia 的 `tilt`。
///
/// ⚠️ Folia 的 `cadenza`（散字 + 圆环焦点）**没有**做：它要逐字自由落位，成本比前两档
///   高一个量级。按交接文档 §7 的排期，它是"1+2 真机验收之后"的加码。所以这个枚举里
///   现在只有两档 —— **不预留第三个不可用的选项**（用户点了没反应比没有更糟）。
enum LyricsStageStyle: String, Codable, CaseIterable, Hashable {
    /// 整屏滚动的逐词歌词（复用现有 Apple Music 歌词页）。
    case appleMusic
    /// 大字错落的舞台排版（自排）。
    case tilt

    /// 设置页那颗选择器上显示的名字。
    ///
    /// ⚠️ 键名走 `titleKey` 再 `.localized`：`Tools/l10n_lint.py` 认"算出键名再返回"的
    ///   形状（见脚本 ① 的说明），写成 `switch` + `return "…"` 的那几条算**可达**；
    ///   反过来把三个 `.localized` 直接写在 View 里、这里只存裸串，那个脚本也会认不出来。
    var titleKey: String {
        switch self {
        case .appleMusic: return "lyrics_stage_style_apple_music"
        case .tilt: return "lyrics_stage_style_tilt"
        }
    }

    var displayName: String { titleKey.localized }
}
