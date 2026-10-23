import SwiftUI
import UIKit

// 舞台窗口的 SwiftUI 根视图。
//
// ★ 2026-10-24（用户拍板）：舞台**只留仿 Folia 的那一档**（`LyricsStageTiltLayout`）。
//   原来还有一档"复用 `AppleMusicLyricsPage` 的整屏滚动歌词"，已删 ——
//   正常逐词歌词是进播放器那条线的事，舞台只负责"炫"。
//
// 分工：
//   · 背景 —— `AppleMusicLyricsBackdrop`（模糊封面 + 舞台式均匀暗化，见 `LyricsBackdropView`）；
//   · 正文 —— `LyricsStageTiltLayout`（3 行 3D 层叠 + 音节脉冲 + 光带）；
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
                } else {
                    LyricsStageTiltLayout(
                        lines: lines,
                        playbackTime: clock.playbackTime,
                        primaryColor: primaryColor,
                        showsTranslation: showsTranslation
                    )
                    .padding(.top, headerBand)
                    .padding(.bottom, footerBand)
                }

                chrome(safeArea: geometry.safeAreaInsets)
            }
        }
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
