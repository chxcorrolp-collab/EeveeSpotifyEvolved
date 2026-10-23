import SwiftUI
import UIKit

// 舞台窗口的 SwiftUI 根视图。
//
// ★★ 2026-10-24（用户：「歌词这部分，不能直接复用吗，iOS 27 这边只需要改动画就好了」）：
//   **两档又回来了**，分工变了：
//     · 实验开关**关**（默认）⇒ **直接复用 `AppleMusicLyricsPage`**（老布局那条线一直在用的
//       那一页：整屏滚动、逐词高亮、点行跳转、译文/副唱），我们只换壳与进场动画；
//     · 实验开关**开** ⇒ 仿 Folia 的 3D 层叠（`LyricsStageTiltLayout`）。
//   ⇒ 歌词键**永远**能开出歌词页，实验只决定"长什么样"。
//
// 分工：
//   · 背景 —— `AppleMusicLyricsBackdrop`（模糊封面 + 舞台式均匀暗化，见 `LyricsBackdropView`）；
//   · 正文 —— 上面二选一；
//   · 壳 —— 曲名/歌手、关闭键、下拉把手、歌词署名（**这一层自己画**，两档共用同一套位置）。
//
// ⚠️ 这里**不碰** Spotify 的原生视图：舞台是独立窗口（见 `LyricsStage.swift`），盖住就行。

@available(iOS 26.0, *)
struct LyricsStageRootView: View {

    /// 行模型（换歌 / 重新取词时由宿主整体替换）。
    var lines: [LyricLine]
    /// 每帧变化的播放时间（`AppleMusicLyricsClock` 是 ObservableObject）。
    @ObservedObject var clock: AppleMusicLyricsClock
    var title: String
    var artist: String
    var provider: String
    var providerCredit: String
    var showsTranslation: Bool
    /// 正文用哪一档：`true` = 仿 Folia 的 3D 层叠；`false` = **复用** `AppleMusicLyricsPage`。
    var usesStageTilt: Bool
    /// 没得画时那一句（还在查 / 没找到 / 纯音乐）。
    var statusText: String
    let onClose: () -> Void

    /// 白字是目前唯一"在任何封面上都读得清"的选择（背景已经压到 0.55 那档暗化）。
    private let primaryColor: Color = .white

    /// 正文顶部让出的高度（壳：把手 + 曲名 + 歌手）。`safeArea.top ≈ 59` ⇒ 壳下沿到 ~117。
    private let headerBand: CGFloat = 132
    /// 底部让出的高度（歌词署名那一行 + 安全区）。
    private let footerBand: CGFloat = 72

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AppleMusicLyricsBackdrop.makeBackground(style: .stage, solid: true)

                if lines.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if usesStageTilt {
                    LyricsStageTiltLayout(
                        lines: lines,
                        playbackTime: clock.playbackTime,
                        primaryColor: primaryColor,
                        showsTranslation: showsTranslation
                    )
                    .padding(.top, headerBand)
                    .padding(.bottom, footerBand)
                } else {
                    appleMusicPage
                }

                chrome(safeArea: geometry.safeAreaInsets)
            }
        }
    }

    // MARK: - 复用 `AppleMusicLyricsPage`（实验关着时的默认档）

    /// **直接复用**现有 Apple Music 歌词页（老布局"歌词进播放器"、以及 Spotify 全屏歌词页
    /// 挂的都是同一套渲染）。只改三处输入：
    ///   · `background` 给透明 —— 背景由外层铺（这一页的 `background` 是 `ignoresSafeArea` 的，
    ///     再铺一层模糊封面等于叠两次暗化）；
    ///   · `showsProviderFooter: false` —— 署名由外层壳固定在底部；
    ///   · `contentInsets` 让出外层壳的位置。
    ///
    /// ⚠️ 参数顺序必须与 `AppleMusicLyricsPage.init` 的声明顺序完全一致（它手写的 init 是位置敏感的）。
    private var appleMusicPage: some View {
        AppleMusicLyricsPage(
            lines: lines,
            playbackTime: clock.playbackTime,
            background: AnyView(Color.clear),
            onClose: nil,
            onSeek: { time in
                // 点行跳转只有一份实现（`+5ms` 那两个细节别自己抄一遍）。
                seekToTappedLyricLine(time)
            },
            contentInsets: EdgeInsets(
                // ⚠️ 这里传的是**一半**：`AppleMusicLyricsPage` 在 `headerContent` / `footerContent`
                //    为 nil 时会把 top/bottom **各加两次**（见它 `scrollInsets` 的算法）
                //    ⇒ 66 × 2 = 132、36 × 2 = 72，与外层壳 `headerBand` / `footerBand` 对齐。
                top: headerBand / 2,
                leading: 26,
                bottom: footerBand / 2,
                trailing: 26
            ),
            typography: .stage,
            showsBackgroundVocals: true,
            showsTranslation: showsTranslation,
            provider: provider,
            providerCredit: providerCredit,
            showsProviderFooter: false,
            primaryColor: primaryColor,
            headerContent: nil,
            footerContent: nil,
            closeContent: nil,
            // ⚠️ 下面四个在这一档里**不生效**（没有 headerContent / footerContent 时走
            //    `legacyFadeStops`，只读 `fadeBottomOpaqueRatio`）；留着是为了与全屏歌词页
            //    那几个调用点形状一致。
            headerHeight: 62,
            headerTopInset: -30,
            hidesShellOnScroll: false,
            fadeBottomOpaqueRatio: 0.9,
            footerHeight: 0,
            fadeBottomBand: 30,
            isStatic: false
        )
    }

    // MARK: - 空状态

    /// 没有行可画时**说清楚是哪一种**（"还在查" vs "没找到" vs "纯音乐"），
    /// 别让屏幕只剩一块黑 —— 那正是用户以前说的"点了没反应"。
    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(title.isEmpty ? "lyrics".localized : title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(primaryColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if !artist.isEmpty {
                Text(artist)
                    .font(.system(size: 13))
                    .foregroundColor(primaryColor.opacity(0.7))
                    .lineLimit(1)
            }

            Text(statusText)
                .font(.system(size: 15))
                .foregroundColor(primaryColor.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.top, 22)
        }
        .padding(.horizontal, 36)
    }

    // MARK: - 壳

    private func chrome(safeArea: EdgeInsets) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                LyricsShellChrome.header(
                    title: title,
                    artist: artist,
                    primaryColor: primaryColor
                )
                .padding(.top, safeArea.top + 18)

                Spacer(minLength: 0)

                creditRow
                    .padding(.bottom, max(safeArea.bottom, 10) + 4)
            }

            // 下拉把手：只做视觉提示，真正的关闭手势挂在 VC 的 pan 上（顶部 160pt 起手）。
            Capsule()
                .fill(primaryColor.opacity(0.35))
                .frame(width: 40, height: 4)
                .padding(.top, safeArea.top + 4)

            HStack {
                Spacer()
                LyricsShellChrome.close(primaryColor: primaryColor, onClose: onClose)
            }
            .padding(.top, safeArea.top + 2)
            .padding(.trailing, 10)
        }
    }

    /// 底部歌词署名（条款要求的"歌词在哪署名就在哪"）。
    private var creditText: String {
        providerCredit.isEmpty ? provider : providerCredit
    }

    @ViewBuilder
    private var creditRow: some View {
        if !creditText.isEmpty {
            Text("word_by_word_lyrics_provider".localizeWithFormat(creditText))
                .font(.system(size: 11))
                .foregroundColor(primaryColor.opacity(0.4))
                .lineLimit(1)
                .padding(.horizontal, 24)
        }
    }
}
