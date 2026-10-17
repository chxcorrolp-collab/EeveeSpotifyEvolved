#!/usr/bin/env python3
"""把一份 EeveeSpotify 真机调试日志按「未完成事项总表」的条目分诊。

用途：`C:\\dsh\\me\\MEMORY_2026-10-17_Remaining-Work.md` 里 B 组那几件
（§3 歌单页搜索条 / chips、§4 折叠、§12 关于艺人折不掉、§16 间奏、
§18 NetEase、§23/§30 AMLL 折行与署名）全都等**同一份日志**。
这份脚本把"该怎么看"写成程序：跑一遍就给出每条的证据与结论，
不用再对着几十万字节的日志手工 grep。

用法：
    python Tools/log_triage.py "C:\\dsh\\readlog\\eeveespotify_debug_shared 104.log"

它只读文件、不联网、不改任何东西。找不到证据的条目会明确写 ✘ + 该看什么，
所以"日志里没有"与"代码没打"能区分开（这正是过去几轮踩过的坑）。
"""

from __future__ import annotations

import argparse
import re
import statistics
import sys
from dataclasses import dataclass, field
from typing import Iterable

LINE_RE = re.compile(r"^\[(?P<ts>[^\]]+)\]\s?(?P<body>.*)$")
TS_RE = re.compile(r"^\[(?P<ts>[^\]]+)\]\s*")


@dataclass
class Log:
    path: str
    lines: list[str] = field(default_factory=list)

    @property
    def first_ts(self) -> str:
        for line in self.lines:
            m = LINE_RE.match(line)
            if m:
                return m.group("ts")
        return "-"

    @property
    def last_ts(self) -> str:
        for line in reversed(self.lines):
            m = LINE_RE.match(line)
            if m:
                return m.group("ts")
        return "-"

    def bodies(self) -> Iterable[str]:
        for line in self.lines:
            m = LINE_RE.match(line)
            yield m.group("body") if m else line

    def find(self, needle: str) -> list[str]:
        return [line for line in self.lines if needle in line]


def read_log(path: str) -> Log:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        raw = handle.read().splitlines()
    return Log(path=path, lines=raw)


def body(line: str) -> str:
    m = LINE_RE.match(line)
    return m.group("body") if m else line


def section(title: str) -> None:
    print()
    print("=" * 4, title, "=" * 4)


def verdict(name: str, ok: bool, detail: str) -> None:
    print(f"  {'✔' if ok else '✘'} {name} — {detail}")


def numbers(pattern: str, text: str) -> list[float]:
    return [float(x) for x in re.findall(pattern, text)]


# MARK: - 各条目


def triage_init(log: Log) -> dict:
    section("构建 / 初始化")
    init = [b for b in log.bodies() if b.startswith("[INIT]")]
    for line in init[:12]:
        print(f"  {line[:160]}")
    about_hook = [b for b in log.bodies() if "about-data hook" in b]
    # 这一句在 `[EntityPageHeader] on — …` 那一行里
    hook_on = any("about-data hook on" in b for b in about_hook)
    print(f"  about-data hook: {'on' if hook_on else ('MISSING' if about_hook else '未打印')}")
    return {"about_data_hook": hook_on, "has_hook_line": bool(about_hook)}


def triage_artist_page(log: Log) -> dict:
    section("艺人页（§12 / 照片 140 的现场 / 数据层 hook）")
    page_lines = [b for b in log.bodies() if "[EntityPageHeader] artist page —" in b]
    for line in page_lines[:4]:
        print(f"  {line[:240]}")
    leading_missing = [b for b in page_lines if "leading MISSING" in b]
    print(f"  进入艺人页次数: {len(page_lines)}，其中 leading MISSING: {len(leading_missing)}")

    captured = [b for b in log.bodies() if "about-artist captured" in b]
    for line in captured[:6]:
        print(f"  {line[:200]}")
    late = [b for b in captured if "captured late" in b]
    on_sight = [b for b in captured if "captured on sight" in b]
    not_read = [b for b in log.bodies() if "biography NOT READ" in b]
    fetcher = [b for b in log.bodies() if "artist-about fetcher" in b]
    class_found = any("SPTArtistAboutDataLoader" in b for b in fetcher)

    bio_sheet = [b for b in log.bodies() if "[ArtistBio]" in b]
    for line in bio_sheet[:12]:
        print(f"  {line[:200]}")
    loader = [b for b in bio_sheet if "loader —" in b]
    cleaned = [b for b in bio_sheet if "body cleaned" in b]
    links = [b for b in bio_sheet if "links found" in b]
    url_read = [b for b in bio_sheet if "url read" in b]
    url_not = [b for b in bio_sheet if "not readable" in b]

    print()
    verdict(
        "§12「关于艺人」折不掉",
        bool(captured),
        f"captured={len(captured)}（on sight {len(on_sight)} / late {len(late)}）, "
        f"早期 NOT READ={len(not_read)}"
        + ("（「露头即读」那条救回来了）" if on_sight or late else ""),
    )
    verdict(
        "§10 数据层类在不在",
        class_found,
        "fetcher 扫描里出现 `SPTArtistAboutDataLoader`"
        if class_found
        else "没扫到那个类（看 `[ArtistBio] artist-about fetcher` 那行）",
    )
    verdict(
        "§10 数据层 hook",
        bool(loader),
        f"`[ArtistBio] loader — …` {len(loader)} 行"
        + ("，正文与链接都到了" if loader else "（hook 没响 / 没装：看上面 about-data hook 的 on/MISSING）"),
    )
    verdict(
        "§ 正文清洗",
        bool(cleaned),
        f"body cleaned {len(cleaned)} 行（名字/听众行被剔掉）",
    )
    verdict(
        "§ 社交链接",
        bool(links),
        f"links found {len(links)} 行；url read {len(url_read)} / not readable {len(url_not)}",
    )
    return {
        "artist_page": bool(page_lines),
        "leading_missing": len(leading_missing),
        "captured_late": len(late),
        "loader": len(loader),
        "class_found": class_found,
    }


SEARCH_NEEDLES = [
    "FilterChips",
    "Toolbar.Content",
    "PL.Header",
    "SearchField",
    "SearchBar",
    "Header.UI.Toolbar",
    "Chips",
]


def triage_playlist(log: Log) -> dict:
    section("歌单页（§3 搜索条 / chips、§4 cell dump）")
    probe_pages = [
        b
        for b in log.bodies()
        if b.startswith("[HeaderProbe] ArtworkImage")
        or b.startswith("[HeaderProbe] CreativeWorkHeader")
    ]
    print(f"  [HeaderProbe] 报过的头部: {len(probe_pages)} 次")
    for line in probe_pages[:8]:
        print(f"    {line[:160]}")
    page_ids = [b for b in log.bodies() if b.startswith("[HeaderProbe]   page ids:")]
    print(f"  page ids 行数: {len(page_ids)}（每一行 = 3 个 id）")

    hits: dict[str, int] = {}
    for line in page_ids:
        for needle in SEARCH_NEEDLES:
            if needle.lower() in line.lower():
                hits[needle] = hits.get(needle, 0) + 1
    if hits:
        print("  page ids 里命中的搜索/chips 线索:")
        for needle, count in sorted(hits.items(), key=lambda kv: -kv[1]):
            print(f"    {needle}: {count}")
    else:
        print("  page ids 里**没有**搜索条 / chips 的任何线索")

    cell_dumps = [b for b in log.bodies() if b.startswith("[PageRepaint] cell #")]
    dropped = [b for b in log.bodies() if "dropping a section" in b]
    print(f"  [PageRepaint] cell dump: {len(cell_dumps)} 行；dropping a section: {len(dropped)} 行")
    for line in cell_dumps[:6]:
        print(f"    {line[:200]}")

    cell_needles = {}
    for line in cell_dumps:
        for needle in SEARCH_NEEDLES + ["PL.Header", "LikedSongs", "CreatorBiographyCard"]:
            if needle.lower() in line.lower():
                cell_needles[needle] = cell_needles.get(needle, 0) + 1
    if cell_needles:
        print("  cell dump 里命中的线索:")
        for needle, count in sorted(cell_needles.items(), key=lambda kv: -kv[1]):
            print(f"    {needle}: {count}")

    print()
    verdict(
        "§3 歌单页搜索条 / chips",
        bool(hits),
        "需要 page ids 里出现 FilterChips / Toolbar.Content 之类；命中即可以开始做"
        if hits
        else "日志里没有 → 要么这一页没被探针报到（看上面次数），要么控件不在这棵树上",
    )
    verdict(
        "§4 折叠的 cell 名",
        bool(cell_dumps),
        f"cell dump {len(cell_dumps)} 行（带 PL.Header 的歌单页也会打）",
    )
    return {"probe_pages": len(probe_pages), "search_hits": bool(hits)}


def triage_interlude(log: Log) -> dict:
    section("间奏（§16 / §17）")
    lines = [b for b in log.bodies() if "[Interlude]" in b]
    for line in lines[:10]:
        print(f"  {line[:200]}")
    gaps: list[float] = []
    counts: list[tuple[int, int]] = []
    for line in lines:
        m = re.search(r"([0-9]+) interlude\(s\) in ([0-9]+) line\(s\)", line)
        if m:
            counts.append((int(m.group(1)), int(m.group(2))))
        g = re.search(r"gaps=\[([0-9.,\s]*)\]", line)
        if g and g.group(1).strip():
            gaps.extend(float(x) for x in g.group(1).split(",") if x.strip())
    if gaps:
        gaps_sorted = sorted(gaps)
        over4 = sum(1 for x in gaps if x >= 4.0)
        over28 = sum(1 for x in gaps if x >= 2.8)
        print(
            f"  gaps: n={len(gaps)} min={gaps_sorted[0]:.1f} "
            f"median={statistics.median(gaps_sorted):.1f} max={gaps_sorted[-1]:.1f}"
        )
        print(f"  ≥4s: {over4} 段；≥2.8s: {over28} 段")
        print(f"  分布: {[round(x, 1) for x in gaps_sorted]}")
    else:
        print("  gaps=[…] 没有（这一版还没加那个字段，或这首歌没判出间奏）")
    print()
    verdict(
        "§16 间奏出现过",
        any(n > 0 for n, _ in counts),
        f"{counts}" if counts else "日志里没有 `[Interlude]` 行",
    )
    verdict(
        "§17 阈值是否合适",
        bool(gaps),
        "有 gaps 分布就能定最终阈值（现在逐字来源也用 4s）" if gaps else "等带 gaps=[…] 的那一版",
    )
    return {"interludes": counts, "gaps": gaps}


WRAP_RE = re.compile(
    r"\[LyricWrap\]\s+fs=(?P<fs>[0-9.]+)\s+w=(?P<w>[^\s]+)\s+"
    r"layout=(?P<layout>[0-9.]+)\s+text=(?P<text>[0-9.]+)"
    r"(?:\s+fit=(?P<fit>[0-9.]+))?"
    r"(?:\s+ct=(?P<ct>[0-9.]+)\s+\((?P<ctfont>[^/)]*)\s*/\s*(?P<uifont>[^)]*)\))?"
    r".*?breaks=\[(?P<breaks>[0-9,\s]*)\]"
)


def triage_wrap(log: Log) -> dict:
    section("折行（Starboy 的「额外换行」）")
    rows = []
    for line in log.lines:
        m = WRAP_RE.search(line)
        if m:
            rows.append({k: (float(v) if k in {"fs", "w", "layout", "text", "fit", "ct"} and v else v)
                         for k, v in m.groupdict().items()})
    print(f"  [LyricWrap] 行数: {len(rows)}")
    if not rows:
        verdict("折行诊断", False, "日志里没有 `[LyricWrap]`（`logWrapDecisionIfUseful` 没触发）")
        return {}

    no_break_but_wide = [r for r in rows if not str(r["breaks"]).strip() and r["text"] > r["layout"]]
    with_break = [r for r in rows if str(r["breaks"]).strip()]
    fit_rows = [r for r in rows if r.get("fit")]
    ct_rows = [r for r in rows if r.get("ct")]
    print(f"  给了断点: {len(with_break)}；给了断点且 text>layout 却没断: {len(no_break_but_wide)}")
    for r in no_break_but_wide[:6]:
        print(f"    text={r['text']} > layout={r['layout']} breaks=[]  ← 这一行会多折一次")
    if ct_rows:
        sample = ct_rows[:5]
        print("  折行字体量出的宽度 ct 与前缀:")
        for r in sample:
            print(
                f"    text={r['text']} layout={r['layout']} ct={r['ct']}"
                f"  ({r.get('ctfont')} / {r.get('uifont')})"
            )
        same = all(abs(r["ct"] - r["text"]) <= max(2.0, r["text"] * 0.02) for r in ct_rows)
        print(f"  ct ≈ text 的行: {'全部' if same else '并非全部'}"
              "（≈text ⇒ 字体不是问题，问题在断点下标；<layout ⇒ 折行字体落到了别的字面）")
    if fit_rows:
        over = [r for r in fit_rows if r["fit"] > r["layout"] + 0.5]
        print(f"  fit 复核后仍超宽的行: {len(over)} / {len(fit_rows)}")
    print()
    verdict(
        "折行根因",
        bool(ct_rows),
        "有 ct= 就能定案（字体 vs 断点下标）" if ct_rows else "等带 ct= 的那一版日志",
    )
    verdict(
        "折行修复是否生效",
        bool(fit_rows),
        f"fit 行数 {len(fit_rows)}，超宽 {len([r for r in fit_rows if r['fit'] > r['layout'] + 0.5])}"
        if fit_rows
        else "等带 fit= 的那一版",
    )
    return {"rows": len(rows), "wide_no_break": len(no_break_but_wide)}


def triage_amll(log: Log) -> dict:
    section("AMLL（§25 / §30）")
    lines = [
        b
        for b in log.bodies()
        if "[AMLL]" in b and ("mapped" in b or "credited" in b or "skipped" in b or "coverage" in b)
    ]
    for line in lines[:10]:
        print(f"  {line[:200]}")
    mapped = [b for b in lines if "mapped" in b]
    credited = [b for b in lines if "credited to community author" in b]
    skipped = [b for b in lines if "skipped" in b]
    coverage = [b for b in lines if "word-level coverage" in b]
    print()
    verdict("§30 AMLL 映射", bool(mapped), f"mapped {len(mapped)} 行")
    verdict("§30 作者署名", bool(credited), f"credited {len(credited)} 行")
    verdict("§30 跳过翻译/罗马音轨", bool(skipped), f"skipped {len(skipped)} 行")
    verdict(
        "§27 逐词是否保住",
        all("keeping words" in c for c in coverage) if coverage else False,
        f"coverage {len(coverage)} 行" if coverage else "没有 coverage 行",
    )
    return {"mapped": len(mapped), "credited": len(credited)}


def triage_netease(log: Log) -> dict:
    section("NetEase（§18）")
    lines = [b for b in log.bodies() if "[NetEase] Chosen" in b]
    for line in lines[:8]:
        print(f"  {line[:200]}")
    has_artist = [line for line in lines if "—" in body(line) and " ? " not in line]
    print()
    verdict(
        "§18 选中的歌带歌手名",
        bool(has_artist),
        f"Chosen {len(lines)} 行，带歌手名 {len(has_artist)} 行"
        if lines
        else "日志里没有 `[NetEase] Chosen` 行",
    )
    return {"chosen": len(lines), "with_artist": len(has_artist)}


def triage_errors(log: Log) -> None:
    section("错误 / 警告")
    patterns = ["ORION ERROR", "ERROR", "crash", "exception", "failed to", "MISSING"]
    seen: dict[str, int] = {}
    examples: dict[str, str] = {}
    for line in log.lines:
        for pattern in patterns:
            if pattern in line:
                seen[pattern] = seen.get(pattern, 0) + 1
                examples.setdefault(pattern, body(line)[:160])
    if not seen:
        print("  没有匹配到错误类关键字")
        return
    for pattern, count in sorted(seen.items(), key=lambda kv: -kv[1]):
        print(f"  {pattern}: {count}  ← {examples[pattern]}")


def triage_timeline(log: Log) -> None:
    section("时间线")
    print(f"  文件: {log.path}")
    print(f"  行数: {len(log.lines)}")
    print(f"  时间: {log.first_ts}  →  {log.last_ts}")
    print("  ⚠️ 照片的文件时间要和这里对得上；差一分钟以上就说明不是同一场。")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", help="日志路径（C:\\dsh\\readlog\\eeveespotify_debug_shared NN.log）")
    parser.add_argument("--quiet", action="store_true", help="只打最后的结论")
    args = parser.parse_args(argv)

    try:
        sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
    except Exception:
        pass

    log = read_log(args.log)
    if not log.lines:
        print("空日志")
        return 1

    triage_timeline(log)
    if not args.quiet:
        triage_init(log)
        triage_artist_page(log)
        triage_playlist(log)
        triage_interlude(log)
        triage_wrap(log)
        triage_amll(log)
        triage_netease(log)
        triage_errors(log)
    else:
        triage_artist_page(log)
        triage_playlist(log)
        triage_interlude(log)
        triage_wrap(log)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
