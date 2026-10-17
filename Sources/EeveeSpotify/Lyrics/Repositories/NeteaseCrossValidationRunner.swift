import Foundation

// MARK: - NetEase 交叉验证（执行层）
//
// 判据与"为什么这样判"全在 `NetEaseCrossValidation.swift` 顶部；这里只负责**问谁**、
// **花多少时间**、**拿到结论之后怎么记账**。
//
// ★ 触发条件（为什么不是每首歌都验）：见 `NeteaseLyricsRepository.shouldVerifyNeteasePick`。
//   一句话：**只在"三道闸门没有全过"时才验**（歌手对不上 / 网易没给歌手名 ⇒ 走了
//   "时长最近"兜底）。这类候选正是历史上所有错歌现场的样子（日志 45 / 102 / 108），
//   而"歌名 + 歌手 + 时长都对得上"的候选再验就是把每首歌的请求量翻几倍去确认一件
//   几乎不会错的事。
//
// ★ 为什么要有时间预算：`SpicyLyricsRepository` 对 503（同步还在生成）是**同步阻塞**
//   退避重试（2/3/4.5/6.75/10s，最坏约 26s）。验证是挂在取词热路径上的，不能让它
//   把一次正常的取词拖到几十秒。所以每个裁判源各有预算，整体还有总预算 ——
//   超时按"没拿到文本"处理（`.unknown`），**不做任何判定**，也绝不取消原路径。
//
// ★ 判错之后做什么：**不是弃用 NetEase**，而是回到 NetEase 自己的候选表里换下一条
//   （`NeteaseLyricsRepository` 那边负责）。理由：用户用网易多半是看中它的
//   **yrc 逐字 + 中文翻译 + 罗马音**，换源等于赢了正确性、输了功能。

struct NeteaseCrossValidationRunner {

    /// 单次判定的结论。
    struct Outcome {
        let verdict: NeteaseCrossVerdict
        /// 给出结论的那个裁判源（`unknown` 时为 `-`）。
        let arbiterName: String
        let overlap: Double
        let reason: String

        static func unknown(_ reason: String) -> Outcome {
            Outcome(verdict: .unknown, arbiterName: "-", overlap: 0, reason: reason)
        }
    }

    /// 单个裁判源的预算（秒）。
    static let perArbiterBudget: TimeInterval = 3.0
    /// 整次验证的总预算（秒）—— 三个裁判源全部超时也不会拖过这个数。
    static let overallBudget: TimeInterval = 6.0

    // MARK: 裁判源

    private struct Arbiter {
        let name: String
        let fetch: (LyricsSearchQuery, LyricsOptions) throws -> LyricsDto
    }

    /// 一级裁判，**只放身份由 Spotify Track ID 锚定的源**。
    ///
    /// 顺序按"单次开销"排：AMLL 是一次 GET；SpicyLyrics 一次 GET（503 时会退避，
    /// 由时间预算兜住）；Musixmatch 要过令牌与 macro 两步，最重。
    /// 命中即停（`confirm` / `reject` 都立即返回），所以顺序只影响开销，不影响正确性。
    private static func arbiters() -> [Arbiter] {
        var list = [Arbiter]()

        // ★ AMLL 的模糊搜索一旦打开，它就不再是"按 track id 直取"（会退化成按歌名搜），
        //   那时它和网易得的是同一种病 —— **没有资格当裁判**。这里直接排除，
        //   而不是"用了再说"：一个会猜身份的源给不出"身份对不对"的结论。
        if !UserDefaults.experimentsOptions.amllFuzzySearch {
            list.append(
                Arbiter(name: "AMLL") { query, options in
                    try AmllTtmlLyricsRepository.shared.getLyrics(query, options: options)
                }
            )
        }

        list.append(
            Arbiter(name: "SpicyLyrics") { query, options in
                try SpicyLyricsRepository.shared.getLyrics(query, options: options)
            }
        )

        list.append(
            Arbiter(name: "Musixmatch") { query, options in
                try MusixmatchLyricsRepository.shared.getLyrics(query, options: options)
            }
        )

        return list
    }

    // MARK: 入口

    /// 拿一级裁判源的歌词去核对网易挑中的那一条。
    ///
    /// - Parameter neteaseLines: 网易**选中候选**的歌词行（原文，不要传译文／罗马音）。
    /// - Returns: `confirm` ⇒ 放心用；`reject` ⇒ 换下一条候选；`unknown` ⇒ 什么都不知道，照旧。
    static func verify(
        query: LyricsSearchQuery,
        options: LyricsOptions,
        neteaseLines: [String]
    ) -> Outcome {
        let candidates = arbiters()
        guard !candidates.isEmpty else {
            writeDebugLog("[NetEase] verify — no eligible arbiter, skipping")
            return .unknown("no-arbiter")
        }

        let deadline = Date().addingTimeInterval(overallBudget)

        for arbiter in candidates {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.2 else {
                writeDebugLog("[NetEase] verify — overall budget exhausted")
                break
            }
            let budget = min(perArbiterBudget, remaining)

            guard let arbiterLines = LyricsLinesBudget.lines(budget, {
                try arbiter.fetch(query, options).lines.map { $0.content }
            }) else {
                writeDebugLog("[NetEase] verify arbiter=\(arbiter.name) no usable text")
                continue
            }

            let result = NeteaseCrossValidation.compare(reference: arbiterLines, candidate: neteaseLines)
            let percent = String(format: "%.2f", result.overlap)
            writeDebugLog(
                "[NetEase] verify arbiter=\(arbiter.name) overlap=\(percent)"
                    + " verdict=\(result.verdict.rawValue) reason=\(result.reason)"
            )

            // `unknown` 不代表"没结论"以外的任何意思 —— 继续问下一家，
            // 三家的 `unknown` 合起来仍然是 `unknown`（信息不足就是信息不足）。
            if result.verdict != .unknown {
                return Outcome(
                    verdict: result.verdict,
                    arbiterName: arbiter.name,
                    overlap: result.overlap,
                    reason: result.reason
                )
            }
        }

        return .unknown("no-verdict")
    }
}
