import Foundation
import SwiftUI

/// 「网易云歌词偏移」独立页（2026-10-23 从歌词设置页里拆出来）。
///
/// 为什么单独一页（用户原话）：「设置页里面放个可点击进去的页面吧，和那些功能一样」——
/// 这个功能会随听歌不断长出新的条目，内嵌在歌词页里越拖越长；拆成子页之后
/// 入口和「歌词 / 听歌页 / 补丁」那些在同一组，页内只留这一件事。
///
/// 只有**单曲偏移**（2026-10-23 去掉「默认偏移」）：默认值是"所有网易云歌词一起挪"，
/// 实际没什么用，还会让"这首歌到底存了多少"更难看清。
struct EeveeNeteaseOffsetSettingsView: View {

    @State private var currentSongTrackId = ""
    @State private var currentSongOffsetMs = 0
    @State private var currentSongHasOverride = false
    /// 当前播放这首的显示名（只给"当前歌曲"那一行做副标题，不改任何存储）。
    @State private var currentSongTitle = ""
    @State private var currentSongArtist = ""
    /// 已保存的单曲偏移（**不含当前播放这首**；它在上面单独一行，避免同一首出现两次）。
    @State private var savedSongOffsets: [SavedSongOffset] = []

    private struct SavedSongOffset: Identifiable {
        let id: String
        let title: String
        let offsetMs: Int
    }

    var body: some View {
        List {
            currentSongSection()
            savedSongsSection()
            NonIPadSpacerView()
        }
        // ★ 2026-10-12：inset-grouped（胶囊卡片）—— 与其它自定义页保持一致。
        .listStyle(InsetGroupedListStyle())
        .onAppear { refreshCurrentSongOffset() }
    }

    // MARK: - 当前歌曲

    @ViewBuilder private func currentSongSection() -> some View {
        Section {
            if currentSongTrackId.isEmpty {
                Text("netease_offset_no_netease_track".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("netease_offset_current_song".localized)
                        if !currentSongDisplayName.isEmpty {
                            Text(currentSongDisplayName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(formattedOffset(currentSongOffsetMs))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 12) {
                    Button("-0.1s") { adjustCurrentSong(by: -100) }
                    Button("+0.1s") { adjustCurrentSong(by: 100) }
                    Spacer()
                    if currentSongHasOverride {
                        Button {
                            NeteaseTimingOffset.clearOverride(forTrackId: currentSongTrackId)
                            reapplyNeteaseTimingOffset()
                            refreshCurrentSongOffset()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .foregroundColor(.red)
                        .accessibilityLabel(Text("netease_offset_delete_song".localized))
                    } else {
                        Button("netease_offset_save_song".localized) { saveCurrentSong() }
                            .font(.caption)
                        Text("netease_offset_autosave_hint".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text("netease_offset_description".localized)
        }
    }

    // MARK: - 已保存

    @ViewBuilder private func savedSongsSection() -> some View {
        Section(header: Text("netease_offset_saved".localized)) {
            if savedSongOffsets.isEmpty {
                Text(currentSongHasOverride
                     ? "netease_offset_saved_only_current".localized
                     : "netease_offset_saved_empty".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(savedSongOffsets) { song in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(formattedOffset(song.offsetMs))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Spacer()
                        Button("-0.1s") { adjustSavedSong(song, by: -100) }
                        Button("+0.1s") { adjustSavedSong(song, by: 100) }
                        Button {
                            NeteaseTimingOffset.clearOverride(forTrackId: song.id)
                            reapplyNeteaseTimingOffset()
                            refreshCurrentSongOffset()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .foregroundColor(.red)
                        .accessibilityLabel(Text("netease_offset_delete_song".localized))
                    }
                    .buttonStyle(.borderless)
                }
                .onDelete(perform: deleteSavedSongs)
            }

            if !NeteaseTimingOffset.trackOffsets.isEmpty {
                Button("netease_offset_clear_all".localized) {
                    NeteaseTimingOffset.clearAllOverrides()
                    reapplyNeteaseTimingOffset()
                    refreshCurrentSongOffset()
                }
                .foregroundColor(.red)
            }
        } footer: {
            Text("netease_offset_saved_description".localized)
        }
    }

    // MARK: - 数据

    private func formattedOffset(_ milliseconds: Int) -> String {
        String(format: "%+.2fs", Double(milliseconds) / 1000)
    }

    /// `"歌名 — 歌手"`（缺一项就只留另一项；两项都空 = 空串）。
    private var currentSongDisplayName: String {
        [currentSongTitle, currentSongArtist]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    /// 「当前歌曲」那一行：只在当前歌词**实际来自网易云**时取到 track id。
    private func refreshCurrentSongOffset() {
        let isNetease = currentLyricsProvider == LyricsSource.netease.description
        let trackId = isNetease ? currentLyricsDtoTrackId : ""
        currentSongTrackId = trackId
        currentSongHasOverride = !trackId.isEmpty && NeteaseTimingOffset.hasOverride(forTrackId: trackId)
        currentSongOffsetMs = trackId.isEmpty ? 0 : NeteaseTimingOffset.offsetMs(forTrackId: trackId)

        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        currentSongTitle = track?.string(ifResponding: "trackTitle") ?? ""
        currentSongArtist = track?.string(ifResponding: "artistName")
            ?? track?.string(ifResponding: "artistTitle")
            ?? ""

        refreshSavedSongOffsets()
    }

    /// 已保存那一列：**不含当前播放这首**（它在上面单独一行，避免同一首出现两次）。
    private func refreshSavedSongOffsets() {
        let offsets = NeteaseTimingOffset.trackOffsets
        let titles = NeteaseTimingOffset.trackTitles
        let currentId = currentSongTrackId
        let unknownName = "netease_offset_unknown_song".localized

        savedSongOffsets = offsets.compactMap { entry -> SavedSongOffset? in
            if !currentId.isEmpty, entry.key == currentId { return nil }
            let stored = titles[entry.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = stored.isEmpty ? unknownName + " · " + shortTrackId(entry.key) : stored
            return SavedSongOffset(id: entry.key, title: name, offsetMs: entry.value)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 老数据没有存过歌名：只显示 track id 的后 6 位，不编造。
    private func shortTrackId(_ trackId: String) -> String {
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return trimmed }
        return String(trimmed.suffix(6))
    }

    private func adjustCurrentSong(by deltaMs: Int) {
        guard !currentSongTrackId.isEmpty else { return }
        let base = NeteaseTimingOffset.offsetMs(forTrackId: currentSongTrackId)
        NeteaseTimingOffset.setOffset(
            base + deltaMs,
            forTrackId: currentSongTrackId,
            trackTitle: currentSongDisplayName
        )
        reapplyNeteaseTimingOffset()
        refreshCurrentSongOffset()
    }

    /// 显式的「保存」：为当前这首建一条单曲覆盖（值 = 当前生效值）。
    ///
    /// 有它是因为 ±0.1s 虽然**当场就存**，但用户看不到"保存"这个动作，以为没存上。
    /// 存完 `currentSongHasOverride` 变真 ⇒ 这颗键换成删除键，列表里也多一行。
    private func saveCurrentSong() {
        guard !currentSongTrackId.isEmpty else { return }
        let value = NeteaseTimingOffset.offsetMs(forTrackId: currentSongTrackId)
        NeteaseTimingOffset.setOffset(
            value,
            forTrackId: currentSongTrackId,
            trackTitle: currentSongDisplayName
        )
        reapplyNeteaseTimingOffset()
        refreshCurrentSongOffset()
    }

    /// 已保存列表里的某一首：改的**不是当前播放这首**，不传歌名（保持已存的名字）。
    private func adjustSavedSong(_ song: SavedSongOffset, by deltaMs: Int) {
        let base = NeteaseTimingOffset.offsetMs(forTrackId: song.id)
        NeteaseTimingOffset.setOffset(base + deltaMs, forTrackId: song.id)
        reapplyNeteaseTimingOffset()
        refreshCurrentSongOffset()
    }

    private func deleteSavedSongs(at offsets: IndexSet) {
        for index in offsets where savedSongOffsets.indices.contains(index) {
            NeteaseTimingOffset.clearOverride(forTrackId: savedSongOffsets[index].id)
        }
        reapplyNeteaseTimingOffset()
        refreshCurrentSongOffset()
    }
}
