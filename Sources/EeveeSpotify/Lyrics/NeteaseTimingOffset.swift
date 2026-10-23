import Foundation

/// 网易云歌词的时间轴偏移（**只作用于网易云这一源**）。
///
/// ## 为什么只做网易云
///
/// 网易云是 UGC：同一首歌可能被不同人上传，时间轴质量参差不齐；而其它源
/// （Musixmatch / AMLL / Genius / Spicy / Petit / LRCLIB）来自官方或相对稳定的库，
/// 偏差通常是个别歌，不值得为它们各配一套偏移。用户 2026-10-20 拍板：只做网易云。
///
/// ## 只有单曲覆盖（2026-10-23 去掉"默认偏移"）
///
/// ```
/// 生效偏移 = 单曲覆盖（Spotify track id） ?? 0
/// ```
///
/// 用户 2026-10-23：「默认偏移这玩意没什么用，只留当前歌曲的偏移就好了」——
/// 默认值是"所有网易云歌词一起挪"，实际几乎没人用，反而让"这首歌到底存了多少"更难看清。
/// 所以这里只保留**按曲目**的那一层；键 `ngzhwm_neteaseOffsetMs` 不再读写。
///
/// ⚠️ 只对**实际给词是网易云**的那份歌词生效：取值点在
///    `NeteaseLyricsRepository.getLyrics`（按 `query.spotifyTrackId` 取），
///    回退到别的源时根本不会经过这里。
///
/// ⚠️ 用户可见的名称/说明由用户本人撰写；本枚举只负责存储与计算。
///    键名与 `UserDefaults.ownedKeys` 的登记见本文件末尾。
enum NeteaseTimingOffset {

    /// 单曲覆盖：`[Spotify track id: 毫秒]` 的 JSON 文本。
    ///
    /// 用 String 而不是 Data，是为了让它能走设置备份的“普通 `key=value`”路径
    /// （`SettingsBackup` 只对 `flagOverrides` 这一个 Data 键做特殊处理）。
    static let trackOffsetsKey = "ngzhwm_neteaseOffsetByTrack"
    /// 单曲覆盖的**显示名**：`[Spotify track id: "歌名 — 歌手"]` 的 JSON 文本。
    ///
    /// 为什么要它：设置页现在把**每一首保存过偏移的歌**列出来（用户要「A 歌偏移多少、
    /// B 歌偏移多少」），而单曲覆盖的键是 Spotify 的 track id —— 没有名字的话那一列全是
    /// 一串十六进制，没法选。只在用户改这一首的偏移时顺手记下来；老数据没有名字就显示
    /// 「未知歌曲 + 短 id」，不猜。
    static let trackTitlesKey = "ngzhwm_neteaseOffsetTrackTitles"

    /// 单级偏移的上下限（±5s）与步进（50ms）。
    static let maxOffsetMs = 5000
    static let stepMs = 50
    /// 单曲覆盖最多保留多少条。超过就按 key 排序丢掉最早的几条 ——
    /// 没有时间戳可排序，但至少行为是确定的，不会悄悄无限增长。
    static let maxTrackOverrides = 300

    /// 备份 / 全局重置 / 本页重置要认识的键。
    static var ownedKeys: [String] { [trackOffsetsKey, trackTitlesKey] }

    // MARK: - 单曲覆盖

    static var trackOffsets: [String: Int] {
        guard let text = UserDefaults.standard.string(forKey: trackOffsetsKey),
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// 单曲覆盖的显示名（见 `trackTitlesKey`）。老数据没有这一份 ⇒ 空字典。
    static var trackTitles: [String: String] {
        guard let text = UserDefaults.standard.string(forKey: trackTitlesKey),
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// 这一首实际生效的偏移（单曲覆盖 ?? 0）。
    static func offsetMs(forTrackId trackId: String) -> Int {
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let override = trackOffsets[trimmed] {
            return clamped(override)
        }
        return 0
    }

    static func hasOverride(forTrackId trackId: String) -> Bool {
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trackOffsets[trimmed] != nil
    }

    /// 写单曲覆盖。传 0 也照样存（0 也是一个明确的“这首歌不偏”），
    /// 想回到默认请用 `clearOverride`。
    ///
    /// - Parameter trackTitle: 这一首的显示名（`"歌名 — 歌手"`）。只在用户改当前播放这一首时传；
    ///   设置页的"已保存列表"里改别的歌时传 `nil`，保持已存的名字（没有就是没有）。
    static func setOffset(_ milliseconds: Int, forTrackId trackId: String, trackTitle: String? = nil) {
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var offsets = trackOffsets
        offsets[trimmed] = clamped(milliseconds)
        let saved = save(offsets)

        var titles = trackTitles
        if let trackTitle {
            let name = trackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                titles.removeValue(forKey: trimmed)
            } else {
                titles[trimmed] = String(name.prefix(120))
            }
        }
        // 只留还在偏移表里的名字（`save` 可能刚丢掉最老的那几条）。
        saveTitles(titles.filter { saved[$0.key] != nil })
    }

    static func clearOverride(forTrackId trackId: String) {
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var offsets = trackOffsets
        guard offsets.removeValue(forKey: trimmed) != nil else { return }
        save(offsets)
        var titles = trackTitles
        titles.removeValue(forKey: trimmed)
        saveTitles(titles)
    }

    /// 清掉全部单曲覆盖（设置页那颗「清除全部单曲偏移」用这个）。
    static func clearAllOverrides() {
        UserDefaults.standard.removeObject(forKey: trackOffsetsKey)
        UserDefaults.standard.removeObject(forKey: trackTitlesKey)
    }

    /// 完整重置/排障用：单曲覆盖全清，并顺手清掉旧版本留下的"默认偏移"键
    /// （2026-10-23 起不再使用 `ngzhwm_neteaseOffsetMs`，但老设备上可能还留着）。
    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: "ngzhwm_neteaseOffsetMs")
        clearAllOverrides()
    }

    // MARK: - 归一化

    /// 夹到 ±5s，并吸附到 50ms 的整数倍（UI 的步进就是这个粒度）。
    static func clamped(_ milliseconds: Int) -> Int {
        // 先夹范围再换算成步数：直接 `Double(milliseconds)` 在异常大的存储值上
        // 转回 Int 会溢出（本键可能被手改/导入过）。
        let bounded = min(max(milliseconds, -maxOffsetMs), maxOffsetMs)
        let steps = (Double(bounded) / Double(stepMs)).rounded()
        return min(max(Int(steps) * stepMs, -maxOffsetMs), maxOffsetMs)
    }

    @discardableResult
    private static func save(_ offsets: [String: Int]) -> [String: Int] {
        var offsets = offsets
        if offsets.count > maxTrackOverrides {
            let overflow = offsets.count - maxTrackOverrides
            for key in offsets.keys.sorted().prefix(overflow) {
                offsets.removeValue(forKey: key)
            }
        }

        guard let data = try? JSONEncoder().encode(offsets),
              let text = String(data: data, encoding: .utf8) else { return offsets }
        UserDefaults.standard.set(text, forKey: trackOffsetsKey)
        return offsets
    }

    /// 写"单曲显示名"那份小字典；空字典就把键删掉（备份/重置看到的是"没有"）。
    private static func saveTitles(_ titles: [String: String]) {
        if titles.isEmpty {
            UserDefaults.standard.removeObject(forKey: trackTitlesKey)
            return
        }
        guard let data = try? JSONEncoder().encode(titles),
              let text = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(text, forKey: trackTitlesKey)
    }
}
