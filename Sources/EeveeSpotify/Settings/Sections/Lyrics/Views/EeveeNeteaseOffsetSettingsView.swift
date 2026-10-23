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
    /// 搜索词（歌名 / 歌手 / 曲目 id）。
    @State private var query = ""

    /// 保存的歌多到一屏看不完时才显示搜索框（太少时它只是噪音）；
    /// 已经在搜索时**保持显示**，否则清空后框会突然消失。
    private let searchAppearsAt = 6

    private var showsSearchField: Bool {
        !savedSongOffsets.isEmpty && (savedSongOffsets.count >= searchAppearsAt || !query.isEmpty)
    }

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

    /// 搜索过滤后的那一列。空搜索词 = 全部。
    private var visibleSavedSongs: [SavedSongOffset] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return savedSongOffsets }
        let needle = searchKey(trimmed)
        guard !needle.isEmpty else { return savedSongOffsets }
        let rawNeedle = trimmed.lowercased()
        return savedSongOffsets.filter { song in
            searchKey(song.title).contains(needle)
                || song.id.lowercased().contains(rawNeedle)
        }
    }

    /// 搜索归一化：**大小写 / 全角半角 / 变音符号都不敏感**，并且把平假名折成片假名
    /// （「ふり」与「フリ」互搜得到 —— 日文标题两种写法都常见）。
    private func searchKey(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        var result = ""
        for scalar in folded.unicodeScalars {
            if (0x3041...0x3096).contains(scalar.value),
               let katakana = Unicode.Scalar(scalar.value + 0x60) {
                result.unicodeScalars.append(katakana)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    @ViewBuilder private func savedSongsSection() -> some View {
        if showsSearchField {
            Section {
                TextField("netease_offset_search".localized, text: $query)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
        }

        Section(header: Text("netease_offset_saved".localized)) {
            if savedSongOffsets.isEmpty {
                Text(currentSongHasOverride
                     ? "netease_offset_saved_only_current".localized
                     : "netease_offset_saved_empty".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else if visibleSavedSongs.isEmpty {
                Text("netease_offset_no_matches".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(visibleSavedSongs) { song in
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
                .onDelete(perform: deleteVisibleSongs)
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
            VStack(alignment: .leading, spacing: 4) {
                Text("netease_offset_saved_count".localizeWithFormat(savedSongOffsets.count))
                Text("netease_offset_saved_description".localized)
            }
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

    /// 左滑删除：索引是**过滤后**那一列的位置，所以必须用 `visibleSavedSongs` 取 id。
    private func deleteVisibleSongs(at offsets: IndexSet) {
        for index in offsets where visibleSavedSongs.indices.contains(index) {
            NeteaseTimingOffset.clearOverride(forTrackId: visibleSavedSongs[index].id)
        }
        reapplyNeteaseTimingOffset()
        refreshCurrentSongOffset()
    }
}
