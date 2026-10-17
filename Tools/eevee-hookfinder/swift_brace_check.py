#!/usr/bin/env python3
"""粗粒度括号/字符串配对检查（本机能跑的唯一"编译前哨"）。

不是编译器，只做三件事：
  1. 花括号 / 圆括号 / 方括号的配对（跳过字符串字面量与注释）；
  2. 报告每个文件的第一处不配对位置（行号）；
  3. ★ 2026-10-17 新增：**悬空属性**（文件最后一个非空行是 `@available(...)` /
     `@MainActor` 这类属性，后面没有任何声明）。真实事故：一次源码拆分把
     `@available(iOS 26.0, *)` 和 `@MainActor` 留在了原文件末尾、声明体搬去了新文件 ——
     括号**完全配平**（所以第 1 条放行）、本地全绿，CI 编译才报
     `error: expected declaration`（两处，白跑一轮）。

用途：在没有 Mac 的机器上，改完 Swift 先过一遍，避免把"少一个大括号"这种
低级错误浪费在一次 CI 编译上。**它不能替代编译器**，只挡最蠢的错。

    python Tools/eevee-hookfinder/swift_brace_check.py Sources/EeveeSpotify/**/*.swift
"""

from __future__ import annotations

import sys
from pathlib import Path

PAIRS = {")": "(", "]": "[", "}": "{"}
OPEN = set("([{")

# 拆分时最容易被剪断留在末尾的属性（顺序无关，只做前缀匹配）。
ATTRIBUTE_PREFIXES = (
    "@available",
    "@MainActor",
    "@objc",
    "@inline",
    "@discardableResult",
    "@ViewBuilder",
    "@escaping",
    "@autoclosure",
    "@frozen",
    "@usableFromInline",
    "@propertyWrapper",
    "@resultBuilder",
    "@Observable",
)

# 同一行里出现这些，说明属性后面跟的是**真声明**（例如 `@objc protocol X { }`）。
DECLARATION_KEYWORDS = (
    "class ",
    "struct ",
    "enum ",
    "extension ",
    "actor ",
    "protocol ",
    "func ",
    "var ",
    "let ",
    "typealias ",
    "init(",
    "subscript",
)


def dangling_attribute(path: Path) -> list[str]:
    """最后一个非空行是属性、且同一行没有声明 ⇒ 悬空（编译期必报 expected declaration）。"""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    for index in range(len(lines) - 1, -1, -1):
        line = lines[index].strip()
        if not line:
            continue
        if not line.startswith(ATTRIBUTE_PREFIXES):
            return []
        if any(keyword in line for keyword in DECLARATION_KEYWORDS):
            return []
        return [
            f"{path}:{index + 1}: 悬空属性（后面没有声明）：{line} "
            f"— 拆分源码时把声明搬走了，属性忘了带走"
        ]
    return []


def check(path: Path) -> list[str]:
    src = path.read_text(encoding="utf-8", errors="replace")
    stack: list[tuple[str, int]] = []
    problems: list[str] = []

    i = 0
    line = 1
    n = len(src)
    while i < n:
        ch = src[i]

        if ch == "\n":
            line += 1
            i += 1
            continue

        # 行注释
        if src.startswith("//", i):
            while i < n and src[i] != "\n":
                i += 1
            continue

        # 块注释
        if src.startswith("/*", i):
            i += 2
            while i < n and not src.startswith("*/", i):
                if src[i] == "\n":
                    line += 1
                i += 1
            i += 2
            continue

        # 字符串字面量（含多行 """ 与 raw string #"..."#）
        #
        # ⚠️ raw string 必须单独处理：Swift 5 的 `#"..."#` 里 `\` 不是转义，
        # 而里面的正则（例如 `[^\s"<>]+`）会带引号 —— 不认它就会把那个引号
        # 当成字符串结尾，后面的方括号全部错位（`CleanShareLinks.x.swift` 就是
        # 这么被误报的）。
        if ch == "#" and src.startswith('#"', i):
            hashes = 0
            while i + hashes < n and src[i + hashes] == "#":
                hashes += 1
            terminator = '"' + ("#" * hashes)
            i += hashes + 1
            while i < n:
                if src[i] == "\n":
                    line += 1
                if src.startswith(terminator, i):
                    i += len(terminator)
                    break
                i += 1
            continue

        if src.startswith('"""', i):
            i += 3
            while i < n and not src.startswith('"""', i):
                if src[i] == "\n":
                    line += 1
                i += 1
            i += 3
            continue

        if ch == '"':
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == '"' or src[i] == "\n":
                    break
                i += 1
            i += 1
            continue

        if ch in OPEN:
            stack.append((ch, line))
            i += 1
            continue

        if ch in PAIRS:
            if not stack:
                problems.append(f"{path}:{line}: 多余的 '{ch}'")
                return problems
            opener, oline = stack.pop()
            if opener != PAIRS[ch]:
                problems.append(f"{path}:{line}: '{ch}' 与第 {oline} 行的 '{opener}' 不匹配")
                return problems
            i += 1
            continue

        i += 1

    for opener, oline in stack:
        problems.append(f"{path}:{oline}: '{opener}' 没有闭合")

    return problems


def main(argv: list[str]) -> int:
    targets: list[Path] = []
    for arg in argv[1:]:
        p = Path(arg)
        if p.is_dir():
            targets.extend(sorted(p.rglob("*.swift")))
        elif p.is_file():
            targets.append(p)

    if not targets:
        # 默认扫源码树
        targets = sorted(Path("Sources").rglob("*.swift"))

    all_problems: list[str] = []
    for t in targets:
        all_problems.extend(check(t))
        all_problems.extend(dangling_attribute(t))

    if all_problems:
        print(f"发现 {len(all_problems)} 处问题：")
        for p in all_problems:
            print("  " + p)
        return 1

    print(f"OK：{len(targets)} 个文件括号/字符串配对正常，且没有悬空属性")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
