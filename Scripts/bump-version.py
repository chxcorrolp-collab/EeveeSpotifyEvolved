#!/usr/bin/env python3
r"""Set every version this repository displays, in one pass.

The repo shows its version in more than one place, and they are easy to let
drift:

  * ``control`` — ``Version:`` is what the .deb package and both IPA workflows
    read at build time (``grep -E '^Version:' control``);
  * ``Sources/EeveeSpotify/Tweak.x.swift`` — the runtime ``version`` and
    ``buildNumber`` constants (the settings page and the startup log show them);
  * ``README.md`` — the "Public release" row of the Versions table and the
    "Development last updated: <date>(build N)" line.

This script updates all of them. It is run by
``.github/workflows/bump-version.yml`` (Actions → "Bump version"), but it also
works locally:

    python3 Scripts/bump-version.py --version 6.6.9
    python3 Scripts/bump-version.py --version 6.6.9 --build 110
    python3 Scripts/bump-version.py --version 6.6.9 --no-readme --dry-run

Only the three files above are touched. ``version-update-locations.txt`` is the
human-readable note that points here; it does not contain a version.

The ``.deb`` filename/version is *derived* from ``control`` by the build
scripts, so it can never drift from it.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import re
import sys
from pathlib import Path

try:
    from zoneinfo import ZoneInfo

    _SHANGHAI = ZoneInfo("Asia/Shanghai")
except Exception:  # pragma: no cover - only on a Python without tzdata
    _SHANGHAI = None


ROOT = Path(__file__).resolve().parent.parent
CONTROL = ROOT / "control"
TWEAK = ROOT / "Sources" / "EeveeSpotify" / "Tweak.x.swift"
README = ROOT / "README.md"

VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
BUILD_RE = re.compile(r"^\d+$")
DATE_RE = re.compile(r"^\d{4}/\d{2}/\d{2}$")


class BumpError(RuntimeError):
    pass


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise BumpError(f"cannot read {path.relative_to(ROOT)}: {exc}") from exc


def _replace_once(text: str, pattern: str, replacement: str, where: str, flags: int = 0) -> str:
    new, count = re.subn(pattern, replacement, text, count=1, flags=flags)
    if count != 1:
        raise BumpError(f"{where}: expected exactly one match for {pattern!r}, found {count}")
    return new


def _write_if_changed(path: Path, before: str, after: str, dry_run: bool) -> bool:
    if after == before:
        return False
    if not dry_run:
        path.write_text(after, encoding="utf-8", newline="")
    rel = path.relative_to(ROOT)
    print(f"  {rel}: updated")
    return True


def _bump_control(version: str, dry_run: bool) -> bool:
    text = _read(CONTROL)
    new = _replace_once(
        text,
        r"^Version:\s*\S+.*$",
        f"Version: {version}",
        "control",
        flags=re.MULTILINE,
    )
    return _write_if_changed(CONTROL, text, new, dry_run)


def _bump_tweak(version: str, build: str, dry_run: bool) -> bool:
    text = _read(TWEAK)
    new = _replace_once(
        text,
        r'(static let version = ")[^"]*(")',
        rf"\g<1>{version}\g<2>",
        "Tweak.x.swift static let version",
    )
    new = _replace_once(
        new,
        r'(static let buildNumber = ")[^"]*(")',
        rf"\g<1>{build}\g<2>",
        "Tweak.x.swift static let buildNumber",
    )
    return _write_if_changed(TWEAK, text, new, dry_run)


def _bump_readme(version: str, build: str, date: str, dry_run: bool) -> bool:
    text = _read(README)
    # The Versions table row, e.g.:
    #   | Public release | [`v1.0.0`](https://github.com/.../releases) | 9.1.88 |
    # Only the short version in that row is touched — the Orion tool URL also
    # contains a v1.0.0, and it is not this project's version.
    new = _replace_once(
        text,
        r"(\| Public release \| \[`v)(\d+\.\d+\.\d+)(`\])",
        rf"\g<1>{version}\g<3>",
        "README.md Public release row",
    )
    #   Development last updated: `2026/10/22`(build 165).
    new = _replace_once(
        new,
        r"(Development last updated:\s*`)[^`]*(`\s*\(build\s*)\d+(\))",
        rf"\g<1>{date}\g<2>{build}\g<3>",
        "README.md development line",
    )
    return _write_if_changed(README, text, new, dry_run)


def _current_build() -> str | None:
    text = _read(TWEAK)
    match = re.search(r'static let buildNumber = "(\d+)"', text)
    return match.group(1) if match else None


def _default_date() -> str:
    now = _dt.datetime.now(_SHANGHAI) if _SHANGHAI is not None else _dt.datetime.now()
    return now.strftime("%Y/%m/%d")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Set every version shown by this repository.")
    parser.add_argument("--version", required=True, help="new version, X.Y.Z (e.g. 6.6.9)")
    parser.add_argument(
        "--build",
        help="build number (digits). Default: the current Tweak.x.swift buildNumber + 1",
    )
    parser.add_argument(
        "--date",
        help="date for the README development line, YYYY/MM/DD. Default: today in Asia/Shanghai",
    )
    parser.add_argument(
        "--no-readme",
        action="store_true",
        help="leave README.md alone (only control and Tweak.x.swift are updated)",
    )
    parser.add_argument("--dry-run", action="store_true", help="print changes without writing them")
    args = parser.parse_args(argv)

    if not VERSION_RE.match(args.version):
        print(f"error: --version must look like X.Y.Z, got {args.version!r}", file=sys.stderr)
        return 2

    if args.build is None:
        current = _current_build()
        if current is None:
            print("error: cannot read the current buildNumber from Tweak.x.swift; pass --build", file=sys.stderr)
            return 2
        build = str(int(current) + 1)
    else:
        build = args.build
    if not BUILD_RE.match(build):
        print(f"error: --build must be digits, got {build!r}", file=sys.stderr)
        return 2

    date = args.date or _default_date()
    if not DATE_RE.match(date):
        print(f"error: --date must look like YYYY/MM/DD, got {date!r}", file=sys.stderr)
        return 2
    try:
        _dt.datetime.strptime(date, "%Y/%m/%d")
    except ValueError:
        print(f"error: --date is not a real date: {date!r}", file=sys.stderr)
        return 2

    print(f"Bumping to {args.version} (build {build}), date {date}"
          + (" [dry-run]" if args.dry_run else ""))
    changed = False
    try:
        changed |= _bump_control(args.version, args.dry_run)
        changed |= _bump_tweak(args.version, build, args.dry_run)
        if not args.no_readme:
            changed |= _bump_readme(args.version, build, date, args.dry_run)
    except BumpError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if not changed:
        print("Nothing to do — every file already has that version/build.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
