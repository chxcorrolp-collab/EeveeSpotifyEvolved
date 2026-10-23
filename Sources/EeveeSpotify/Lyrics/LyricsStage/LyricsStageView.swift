import SwiftUI
import UIKit

// 舞台窗口的 SwiftUI 根视图。
//
// 分工：
//   · 背景 —— 复用 `AppleMusicLyricsBackdrop.makeBackground(style: .stage, solid: true)`
//     （模糊封面 + 舞台式均匀暗化，见 `LyricsBackdropView`）；
//   · 正文 —— 按样式二选一：`AppleMusicLyricsPage`（整屏滚动版）或
//     `LyricsStageTiltLayout`（大字错落版）；
//   · 壳 —— 曲名/歌手、关闭键、下拉把手、歌词署名。**这一层自己画**，不往
//     `AppleMusicLyricsPage` 的 `headerContent` 里塞：两档要用同一套壳，
//     否则换样式时标题会跳位置。
//
// ⚠️ 这里**不碰** Spotify 的原生视图。舞台是独立窗口（见 `LyricsStage.swift`），
//   盖住就行 —— 藏、挪、改 alpha 那套在 `NowPlayingIOS27` 里已经吃过太多次亏。

@available(iOS 26.0, *)
struct LyricsStageRootView: View {

    /// 行模型（换歌 / 重新取词时由宿主整体替换）。
    var lines: [LyricLine]
    /// 每帧变化的播放时间（`AppleMusicLyricsClock` 是 ObservableObject，
    /// 只有时间真的变了才发通知 —— 暂停时整页不重绘，见宿主那边的省电说明）。
    @ObservedObject var clock: AppleMusicLyricsClock
    var title: String
    var artist: String
    var provider: String
    var providerCredit: String
    var style: LyricsStageStyle
    var showsTranslation: Bool
    /// 没得画时那一句（还在查 / 没找到 / 纯音乐）。
    var statusText: String
    let onClose: () -> Void

    /// 白字是目前唯一"在任何封面上都读得清"的选择（背景已经压到 0.55 那档暗化）。
    private let primaryColor: Color = .white

    /// 正文顶部让出的高度（壳：把手 + 曲名 + 歌手）。
    ///
    /// 132 是按最坏情况倒推的：刘海机上 `safeArea.top ≈ 59`，把手在 +4、曲名从 +18 起、
    /// 两行文字 ≈ 40 ⇒ 壳的下沿到 117；再留 15 呼吸才是正文的起点。
    ///
    /// ⚠️ 给 `AppleMusicLyricsPage` 的 `contentInsets.top` 要**减半**再传：
    ///   它内部把 `contentInsets.top` 加了**两次**（`headerContent == nil` 那条分支），
    ///   见 `AppleMusicLyricsPage.body` 里 `scrollInsets` 的算法。传 66 ⇒ 实际 132。
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
                } else if style == .tilt {
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

    // MARK: - 逐词滚动那一档

    /// 复用现有 Apple Music 歌词页。
    ///
    /// 只改三处输入：
    ///   · `background` 给透明 —— 背景由外层铺（这一页的 `background` 是 `ignoresSafeArea` 的，
    ///     再铺一层模糊封面等于叠两次暗化）；
    ///   · `showsProviderFooter: false` —— 署名由外层壳固定在底部（滚动到底才看得到的那一行
    ///     在舞台里不合适）；
    ///   · `contentInsets` 让出外层壳的位置（顶部那个加倍见 `headerBand` 的说明）。
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
                //    为 nil 时会把 top/bottom **各加两次**（见它 `scrollInsets` 的算法：
                //    `(headerContent == nil ? contentInsets.top : …) + contentInsets.top`）
                //    ⇒ 66 × 2 = 132、36 × 2 = 72，与外层壳 `headerBand` / `footerBand` 对齐。
                //    那一页哪天改掉这个"加两次"，这两个值就得翻倍。
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
            // ⚠️ 下面四个（headerHeight / headerTopInset / footerHeight / fadeBottomBand）
            //    在**这一档里是不生效的**：没有 headerContent / footerContent 时，
            //    `fadeMaskStops` 走 `legacyFadeStops`，只读 `fadeBottomOpaqueRatio`。
            //    留着是为了和全屏歌词页那几个调用点的形状一致（改起来不用再背一遍标签）。
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

    /// 底部歌词署名（条款要求的"歌词在哪署名就在哪"，固定在屏底比"滚到底才看见"更实在）。
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
