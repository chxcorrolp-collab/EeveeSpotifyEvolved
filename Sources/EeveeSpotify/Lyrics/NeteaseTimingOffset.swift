import Foundation

/// 网易云歌词的时间轴偏移（**只作用于网易云这一源**）。
///
/// ## 为什么只做网易云
///
/// 网易云是 UGC：同一首歌可能被不同人上传，时间轴质量参差不齐；而其它源
/// （Musixmatch / AMLL / Genius / Spicy / Petit / LRCLIB）来自官方或相对稳定的库，
/// 偏差通常是个别歌，不值得为它们各配一套偏移。用户 2026-10-20 拍板：只做网易云。
///
/// ## 两级（单曲覆盖优先）
///
/// ```
/// 生效偏移 = 单曲覆盖（Spotify track id） ?? 网易云默认 ?? 0
/// ```
///
/// - 单曲覆盖解决“这一首的某个上传版本就是不对”；
/// - 网易云默认解决“这个源整体慢/快了几拍”。
///
/// ⚠️ 只对**实际给词是网易云**的那份歌词生效：取值点在
///    `NeteaseLyricsRepository.getLyrics`（按 `query.spotifyTrackId` 取），
///    回退到别的源时根本不会经过这里。
///
/// ⚠️ 用户可见的名称/说明由用户本人撰写；本枚举只负责存储与计算。
///    键名与 `UserDefaults.ownedKeys` 的登记见本文件末尾。
enum NeteaseTimingOffset {

    /// 网易云整体默认偏移（毫秒）。缺省 = 0。
    static let sourceOffsetKey = "ngzhwm_neteaseOffsetMs"
    /// 单曲覆盖：`[Spotify track id: 毫秒]` 的 JSON 文本。
    ///
    /// 用 String 而不是 Data，是为了让它能走设置备份的“普通 `key=value`”路径
    /// （`SettingsBackup` 只对 `flagOverrides` 这一个 Data 键做特殊处理）。
    static let trackOffsetsKey = "ngzhwm_neteaseOffsetByTrack"

    /// 单级偏移的上下限（±5s）与步进（50ms）。
    static let maxOffsetMs = 5000
    static let stepMs = 50
    /// 单曲覆盖最多保留多少条。超过就按 key 排序丢掉最早的几条 ——
    /// 没有时间戳可排序，但至少行为是确定的，不会悄悄无限增长。
    static let maxTrackOverrides = 300

    /// 备份 / 全局重置 / 本页重置要认识的键。
    static var ownedKeys: [String] { [sourceOffsetKey, trackOffsetsKey] }

    // MARK: - 默认偏移

    static var sourceOffsetMs: Int {
        get { clamped(UserDefaults.standard.integer(forKey: sourceOffsetKey)) }
        set { UserDefaults.standard.set(clamped(newValue), forKey: sourceOffsetKey) }
    }

    // MARK: - 单曲覆盖

    static var trackOffsets: [String: Int] {
        guard let text = UserDefaults.standard.string(forKey: trackOffsetsKey),
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// 这一首实际生效的偏移（单曲覆盖 ?? 默认 ?? 0）。
    static func offsetMs(forTrackId trackId: String) -> Int {
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let override = trackOffsets[trimmed] {
            return clamped(override)
        }
        return sourceOffsetMs
    }

    static func hasOverride(forTrackId trackId: String) -> Bool {
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trackOffsets[trimmed] != nil
    }

    /// 写单曲覆盖。传 0 也照样存（0 也是一个明确的“这首歌不偏”），
    /// 想回到默认请用 `clearOverride`。
    static func setOffset(_ milliseconds: Int, forTrackId trackId: String) {
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var offsets = trackOffsets
        offsets[trimmed] = clamped(milliseconds)
        save(offsets)
    }

    static func clearOverride(forTrackId trackId: String) {
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var offsets = trackOffsets
        guard offsets.removeValue(forKey: trimmed) != nil else { return }
        save(offsets)
    }

    /// 只清单曲覆盖（设置页那颗「清除全部单曲偏移」用这个；**不动**默认偏移）。
    static func clearAllOverrides() {
        UserDefaults.standard.removeObject(forKey: trackOffsetsKey)
    }

    /// 默认 + 单曲覆盖一起清（完整重置/排障用）。
    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: sourceOffsetKey)
        UserDefaults.standard.removeObject(forKey: trackOffsetsKey)
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

    private static func save(_ offsets: [String: Int]) {
        var offsets = offsets
        if offsets.count > maxTrackOverrides {
            let overflow = offsets.count - maxTrackOverrides
            for key in offsets.keys.sorted().prefix(overflow) {
                offsets.removeValue(forKey: key)
            }
        }

        guard let data = try? JSONEncoder().encode(offsets),
              let text = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(text, forKey: trackOffsetsKey)
    }
}
