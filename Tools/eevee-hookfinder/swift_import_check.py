#!/usr/bin/env python3
r"""
swift_import_check.py — 「用了 Foundation 的符号却没 import Foundation」的检查器。

★ 为什么必须有这一条（2026-10-17 真机 build 现场）：
    `ExperimentsOptions.swift` 一直只有 `Bool` 字段 —— `Codable` / `Decoder` 都在 stdlib 里，
    所以它**不 import 任何东西**也能编过。当我给它加了一句
    `Locale.current.region?.identifier == "CN"`，真机 build 直接报
        error: cannot find 'Locale' in scope
        error: cannot find 'TimeZone' in scope

    现有六条守卫**都挡不住这一类**，而且 `swiftc -parse` 也挡不住 —— `-parse` 只做语法分析、
    **不解析 import**（workflow 里那一步的注释就写着这句）。所以这类错只能等真机 build
    才暴露，而本机没有 Swift 工具链。这个脚本填的就是这个洞。

判据（保守，宁可漏报不误报）：
  1. 只看 `Sources/` 与 `Tests/` 下的 `*.swift`；
  2. 文件里出现任一 "Foundation 专属符号"（见 FOUNDATION_MARKERS）；
  3. 且它**没有** import 任何"会传递性带进 Foundation"的框架（见 REEXPORTING）。
  ⇒ 只有两个条件同时成立才报错。

⚠️ 为什么 REEXPORTING 里要塞 `Orion` / `Intents` 这些非 Foundation 框架：
   仓库里有 6 个 `import Orion` 的文件用到 `NSObject` / `Data` / `DispatchQueue` /
   `UserDefaults`，它们**在本仓一直是能编过的** —— 说明那条 import 链把 Foundation 带进来了
   （Orion 的 swiftmodule 对 Foundation 是 @_exported 的）。这是既成事实，不是我们要审的东西；
   把它们写进白名单，才不会把"已经编过的老文件"报成错。

Usage:
  python3 Tools/eevee-hookfinder/swift_import_check.py
  python3 Tools/eevee-hookfinder/swift_import_check.py --quiet

Exit code is 1 when any finding is reported, 0 otherwise.
"""

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCAN_DIRS = [REPO_ROOT / "Sources", REPO_ROOT / "Tests"]

# 会（传递性地）把 Foundation 带进作用域的框架。实测本仓 `import Orion` 也能带进来。
REEXPORTING = {
    "Foundation", "SwiftUI", "UIKit", "AppKit", "Combine",
    "CoreText", "CoreGraphics", "QuartzCore", "CoreImage", "CoreLocation",
    "AVFoundation", "AVKit", "MediaPlayer", "WebKit", "MapKit", "WidgetKit",
    "Charts", "PhotosUI", "Intents", "IntentsUI", "StoreKit", "SafariServices",
    "LinkPresentation", "MessageUI", "UserNotifications", "UniformTypeIdentifiers",
    "OSLog", "Orion",
}

# 只在 Foundation 里存在的符号（挑"几乎不会出现在别处"的那些）。
# 刻意**不含** `NSObject` / `Thread` 这类 objc-runtime 也会给的、太容易误报的。
FOUNDATION_MARKERS = [
    "Locale.current",
    "Locale.preferredLanguages",
    "TimeZone.current",
    "TimeZone(",
    "NSRegularExpression",
    "JSONDecoder",
    "JSONEncoder",
    "JSONSerialization",
    "NSCache",
    "UserDefaults",
    "NotificationCenter",
    "ProcessInfo",
    "FileManager",
    "CharacterSet",
    "NumberFormatter",
    "DateFormatter",
    "URLComponents",
    "Bundle.main",
    "String(format:",
    "DispatchQueue",
    "DispatchSemaphore",
    "NSRange(",
    "NSString(",
    "CGFloat",
]

IMPORT_RE = re.compile(
    r"^\s*(?:@_exported\s+)?import\s+"
    r"(?:class|struct|enum|protocol|func|var|let|typealias)?\s*"
    r"([A-Za-z_][A-Za-z0-9_]*)",
    re.M,
)


def scan() -> list[tuple[str, list[str]]]:
    findings: list[tuple[str, list[str]]] = []
    for directory in SCAN_DIRS:
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*.swift")):
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            imports = set(IMPORT_RE.findall(text))
            if imports & REEXPORTING:
                continue
            hits = [marker for marker in FOUNDATION_MARKERS if marker in text]
            if hits:
                findings.append((str(path.relative_to(REPO_ROOT)), hits))
    return findings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--quiet", action="store_true", help="只打印问题")
    args = parser.parse_args()

    findings = scan()
    if not findings:
        if not args.quiet:
            print(
                "OK：没有「用了 Foundation 符号却没 import Foundation」的文件"
                "（`swiftc -parse` 不解析 import，这一类只能靠这条挡）"
            )
        return 0

    print(f"发现 {len(findings)} 个文件用了 Foundation 的符号却没有 import 任何带 Foundation 的框架：")
    for path, hits in findings:
        print(f"  {path}")
        print(f"     用到：{', '.join(hits)}")
        print("     ⇒ 补一行 `import Foundation`（真机 build 会报 cannot find '…' in scope）")
    return 1


if __name__ == "__main__":
    sys.exit(main())
